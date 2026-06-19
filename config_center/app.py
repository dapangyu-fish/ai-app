"""Config Center — 客户端公共配置下发服务

设计要点（与同仓库 backend/ 代码独立，可同机或独立部署）：
- 可和主后端同机运行，也可以迁移到独立机器；运行时配置不进仓库
- SQLite 单文件存储；轻量 KV + 类型 + 注释 + 修改审计
- 公开 endpoint /api/v1/public 不需鉴权，返回整包 JSON + ETag
- Admin UI 用签名 cookie session（itsdangerous），密码明文存在 /etc/config-center/.env
  （root 可读；user 可随时改 env 重启服务生效）
"""

import hashlib
import io
import importlib.util
import json
import os
import secrets
import shutil
import sqlite3
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote

from flask import (
    Flask,
    Response,
    abort,
    g,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)
from flask_caching import Cache
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

import requests  # present in the shared backend image (user_center uses it too)

import dashboard_helpers as _dash  # pure, unit-tested data-shaping helpers

# ── 启动期：读 env ──
# supervisor 通过 environment= 注入 CONFIG_CENTER_ENV_PATH 指向 /etc/config-center/.env
# 解析这个 .env 把里面 KEY=VALUE 全注入到 os.environ（已存在的不覆盖，让 shell env 优先）
_env_path = os.environ.get("CONFIG_CENTER_ENV_PATH", "")
if _env_path and Path(_env_path).is_file():
    with open(_env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            os.environ.setdefault(k, v)

ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/config-center/config.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8088"))

MINIO_PUBLIC_URL = os.environ.get(
    "MINIO_PUBLIC_URL", "https://myapp-oss-endpoint.dapangyu.work"
).rstrip("/")
_minio_url_parts = MINIO_PUBLIC_URL.split("://", 1)
_minio_default_secure = (
    _minio_url_parts[0] == "https" if len(_minio_url_parts) > 1 else True
)
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", _minio_url_parts[-1])
MINIO_SECURE = os.environ.get(
    "MINIO_SECURE", "true" if _minio_default_secure else "false"
).lower() in ("1", "true", "yes", "on")
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "")

APK_RELEASE_BUCKET = os.environ.get("APK_RELEASE_BUCKET", "myapp-releases")
APK_LATEST_OBJECT = os.environ.get("APK_LATEST_OBJECT", "android/apk/latest.apk")
APK_METADATA_OBJECT = os.environ.get("APK_METADATA_OBJECT", "android/apk/latest.json")
APK_SHA256_OBJECT = os.environ.get(
    "APK_SHA256_OBJECT", "android/apk/latest.apk.sha256"
)
APK_MAX_BYTES = int(os.environ.get("APK_MAX_BYTES", str(500 * 1024 * 1024)))
APK_CHUNK_BYTES = int(os.environ.get("APK_CHUNK_BYTES", str(8 * 1024 * 1024)))
APK_CHUNK_MAX_BYTES = int(
    os.environ.get("APK_CHUNK_MAX_BYTES", str(16 * 1024 * 1024))
)
APK_UPLOAD_TMP_DIR = os.environ.get(
    "APK_UPLOAD_TMP_DIR", "/var/lib/config-center/uploads"
)

# ── 统一管理后台 dashboard glue：上游服务地址/凭证（经 env_file backend.env 注入）──
# 仅用于 dashboard 只读聚合 + 用户管理代理；凭证只在服务端使用，不下发浏览器。
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
BACKEND_URL = os.environ.get(
    "BACKEND_URL", os.environ.get("CONFIG_CENTER_BACKEND_URL", "http://backend:5566")
).rstrip("/")
AGENT_NODE_TOKEN = os.environ.get("AGENT_NODE_REGISTRATION_TOKEN", "") or os.environ.get(
    "AGENT_NODE_TOKEN", ""
)
FAAS_CAP_MIN = int(os.environ.get("FAAS_OPENFAAS_MIN_REPLICAS", "0") or "0")
FAAS_CAP_MAX = int(os.environ.get("FAAS_OPENFAAS_MAX_REPLICAS", "1") or "1")
DASH_HTTP_TIMEOUT = 12

if not ADMIN_PASSWORD:
    raise RuntimeError(
        "ADMIN_PASSWORD env 必须设置（建议放 /etc/config-center/.env，root 600）"
    )
if not SESSION_SECRET:
    raise RuntimeError(
        "SESSION_SECRET env 必须设置 —— openssl rand -hex 32"
    )

COOKIE_NAME = "cc_session"
COOKIE_MAX_AGE = 7 * 24 * 3600  # 7 天
LOGIN_RATELIMIT_WINDOW = 15 * 60
LOGIN_RATELIMIT_MAX = 5

# ── DB ──
Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)


@contextmanager
def db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with db_conn() as conn:
        # WAL 模式：允许 reader 与 writer 并发，admin 写入不阻塞 /api/v1/public 高并发读
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")  # WAL + NORMAL 是社区推荐的安全/性能平衡
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS configs (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                value_type TEXT NOT NULL,
                comment TEXT NOT NULL DEFAULT '',
                updated_at INTEGER NOT NULL,
                updated_by TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT NOT NULL,
                action TEXT NOT NULL,
                old_value TEXT,
                new_value TEXT,
                actor TEXT NOT NULL,
                ts INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);
            """
        )
        # 首次初始化：种子数据
        seeds = [
            ("pause_register", "false", "bool", "暂停新用户注册"),
            ("pause_login", "false", "bool", "暂停登录"),
            ("pause_request", "false", "bool", "紧急熔断：暂停所有客户端请求"),
            (
                "ai_generation_pipeline",
                '"json_dsl_v1"',
                "string",
                "AI APP 生成链路：json_dsl_v1 或 dart_to_json_v2",
            ),
            ("splash_text", '""', "string", "闪屏底部文案（空串=不显示）"),
            ("splash_duration_ms", "1500", "number", "闪屏展示时长（毫秒）"),
        ]
        now = int(time.time())
        for k, v, t, c in seeds:
            row = conn.execute("SELECT 1 FROM configs WHERE key=?", (k,)).fetchone()
            if row is None:
                conn.execute(
                    "INSERT INTO configs (key,value,value_type,comment,updated_at,updated_by)"
                    " VALUES (?,?,?,?,?,?)",
                    (k, v, t, c, now, "system"),
                )


# ── 值类型转换 ──
# 内部存储约定：configs.value 永远是 JSON-serialized 字符串
#   bool   true/false 字面量   → "true" / "false"
#   number 数字字面量            → "123" / "1.5"
#   string JSON 引号字符串       → "\"hello\""
#   json   任意 JSON           → 原样
# 这样 /api/v1/public 直接 json.loads 就能拿到原始类型


def normalize_value(value_type: str, raw: str) -> str:
    raw = raw.strip()
    if value_type == "bool":
        if raw.lower() in ("true", "1", "yes", "on"):
            return "true"
        if raw.lower() in ("false", "0", "no", "off", ""):
            return "false"
        raise ValueError(f"非法 bool 值: {raw!r}")
    if value_type == "number":
        try:
            return str(int(raw))
        except ValueError:
            return json.dumps(float(raw))
    if value_type == "string":
        return json.dumps(raw, ensure_ascii=False)
    if value_type == "json":
        return json.dumps(json.loads(raw), ensure_ascii=False)
    raise ValueError(f"未知 value_type: {value_type}")


def display_value(value_type: str, stored: str) -> str:
    """把 DB 里的存储格式还原成给表单显示的"自然形态"。"""
    try:
        parsed = json.loads(stored)
    except json.JSONDecodeError:
        return stored
    if value_type == "string" and isinstance(parsed, str):
        return parsed
    if value_type == "json":
        return json.dumps(parsed, ensure_ascii=False, indent=2)
    return stored


# ── Auth ──
serializer = URLSafeTimedSerializer(SESSION_SECRET, salt="config-center-session")


def get_current_user() -> str | None:
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return None
    try:
        data = serializer.loads(token, max_age=COOKIE_MAX_AGE)
        return data.get("u")
    except (BadSignature, SignatureExpired):
        return None


def require_user() -> str:
    user = get_current_user()
    if not user:
        abort(401)
    return user


# 简易内存级登录限流（每 IP 15 分钟 5 次）
_login_buckets: dict[str, list[float]] = {}


def login_allowed(ip: str) -> bool:
    now = time.time()
    cutoff = now - LOGIN_RATELIMIT_WINDOW
    bucket = [t for t in _login_buckets.get(ip, []) if t > cutoff]
    if len(bucket) >= LOGIN_RATELIMIT_MAX:
        _login_buckets[ip] = bucket
        return False
    bucket.append(now)
    _login_buckets[ip] = bucket
    return True


# ── App ──
app = Flask(
    __name__,
    template_folder=str(Path(__file__).parent / "templates"),
)
app.config["MAX_CONTENT_LENGTH"] = APK_MAX_BYTES + 1024 * 1024

# 进程内 LRU 缓存。关键不变量：缓存 key 拼了 SQLite 文件 mtime（含 -wal/-shm），
# admin 一改 → mtime 变 → 所有 worker 同步看到新 key 自动 miss → 重载，不需 Redis。
# TTL 60s 仅作为兜底（防止极端时间漂移；正常情况下 mtime 永远是新鲜源）。
cache = Cache(
    app,
    config={
        "CACHE_TYPE": "SimpleCache",
        "CACHE_DEFAULT_TIMEOUT": 60,
        "CACHE_THRESHOLD": 32,  # 配置项 mtime 变化频率极低，cache 池小一点足矣
    },
)


def _db_version() -> float:
    """SQLite 文件 mtime（含 -wal/-shm）。stat() 是 µs 级开销。"""
    paths = (DB_PATH, DB_PATH + "-wal", DB_PATH + "-shm")
    mtimes = []
    for p in paths:
        try:
            mtimes.append(os.path.getmtime(p))
        except OSError:
            pass
    return max(mtimes, default=0.0)


def _build_public_payload() -> tuple[bytes, str]:
    """从 SQLite 拉所有配置，序列化 + 算 ETag。仅 cache miss 时调用。"""
    with db_conn() as conn:
        rows = conn.execute(
            "SELECT key,value,value_type FROM configs ORDER BY key"
        ).fetchall()
    out: dict = {}
    for r in rows:
        try:
            out[r["key"]] = json.loads(r["value"])
        except json.JSONDecodeError:
            out[r["key"]] = r["value"]
    body = json.dumps(
        out, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
    return body, etag


def get_public_payload_cached() -> tuple[bytes, str]:
    """带 mtime-version 的缓存读取。命中路径：dict 查 + stat()，约 1-2 µs。"""
    key = f"public:v={_db_version()}"
    cached = cache.get(key)
    if cached is None:
        cached = _build_public_payload()
        cache.set(key, cached)
    return cached


def _public_object_url(bucket: str, object_name: str) -> str:
    return f"{MINIO_PUBLIC_URL}/{quote(bucket)}/{quote(object_name, safe='/')}"


def _apk_release_url() -> str:
    return _public_object_url(APK_RELEASE_BUCKET, APK_LATEST_OBJECT)


def _apk_metadata_url() -> str:
    return _public_object_url(APK_RELEASE_BUCKET, APK_METADATA_OBJECT)


def _minio_client():
    minio_cls, _s3_error = _load_minio()
    if minio_cls is None:
        raise RuntimeError("当前 Python 环境缺少 minio 包")
    if not MINIO_ACCESS_KEY or not MINIO_SECRET_KEY:
        raise RuntimeError("MINIO_ACCESS_KEY / MINIO_SECRET_KEY 未配置")
    return minio_cls(
        MINIO_ENDPOINT,
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=MINIO_SECURE,
    )


def _minio_available() -> bool:
    return importlib.util.find_spec("minio") is not None


def _load_minio():
    try:
        from minio import Minio as MinioClient
        from minio.error import S3Error as MinioS3Error
    except ImportError:
        return None, Exception
    return MinioClient, MinioS3Error


def _ensure_public_bucket(client) -> None:
    if not client.bucket_exists(APK_RELEASE_BUCKET):
        client.make_bucket(APK_RELEASE_BUCKET)
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"AWS": ["*"]},
                "Action": ["s3:GetObject"],
                "Resource": [f"arn:aws:s3:::{APK_RELEASE_BUCKET}/*"],
            }
        ],
    }
    client.set_bucket_policy(APK_RELEASE_BUCKET, json.dumps(policy))


def _read_object_json(client, bucket: str, object_name: str) -> dict | None:
    _minio_cls, s3_error = _load_minio()
    resp = None
    try:
        resp = client.get_object(bucket, object_name)
        return json.loads(resp.data.decode("utf-8"))
    except s3_error:
        return None
    except Exception:
        return None
    finally:
        if resp is not None:
            resp.close()
            resp.release_conn()


def _apk_release_state() -> dict:
    state = {
        "enabled": bool(MINIO_ACCESS_KEY and MINIO_SECRET_KEY and _minio_available()),
        "bucket": APK_RELEASE_BUCKET,
        "object": APK_LATEST_OBJECT,
        "url": _apk_release_url(),
        "metadata_url": _apk_metadata_url(),
        "max_mb": APK_MAX_BYTES // (1024 * 1024),
        "exists": False,
        "error": "",
        "metadata": None,
    }
    if not state["enabled"]:
        state["error"] = "未配置 MinIO 凭据，上传功能不可用"
        return state
    _minio_cls, s3_error = _load_minio()
    try:
        client = _minio_client()
        meta = _read_object_json(client, APK_RELEASE_BUCKET, APK_METADATA_OBJECT)
        state["metadata"] = meta
        stat = client.stat_object(APK_RELEASE_BUCKET, APK_LATEST_OBJECT)
        state["exists"] = True
        state["size"] = stat.size
        state["last_modified"] = stat.last_modified
        state["etag"] = stat.etag
    except s3_error as e:
        code = getattr(e, "code", "")
        if code not in ("NoSuchBucket", "NoSuchKey", "NoSuchObject"):
            state["error"] = str(e)
    except Exception as e:
        state["error"] = str(e)
    return state


def _json_error(message: str, status: int = 400):
    return jsonify({"ok": False, "error": message}), status


def _clean_apk_filename(filename: str) -> str:
    return Path((filename or "").replace("\\", "/")).name


def _validate_apk_request(filename: str, size: int | None = None) -> str:
    clean = _clean_apk_filename(filename)
    if not clean:
        raise ValueError("请选择 APK 文件")
    if not clean.lower().endswith(".apk"):
        raise ValueError("只允许上传 .apk 文件")
    if size is not None:
        if size <= 0:
            raise ValueError("APK 文件为空")
        if size > APK_MAX_BYTES:
            raise ValueError(f"APK 超过上限 {APK_MAX_BYTES // (1024 * 1024)} MB")
    return clean


def _effective_chunk_max_bytes() -> int:
    return max(1024 * 1024, APK_CHUNK_MAX_BYTES)


def _effective_chunk_bytes() -> int:
    preferred = max(1024 * 1024, APK_CHUNK_BYTES)
    return min(preferred, _effective_chunk_max_bytes())


def _publish_apk_file(
    *,
    apk_path: str,
    size: int,
    sha256: str,
    original_name: str,
    version_name: str,
    build_number: str,
    release_notes: str,
    user: str,
) -> dict:
    client = _minio_client()
    _ensure_public_bucket(client)
    with open(apk_path, "rb") as f:
        client.put_object(
            APK_RELEASE_BUCKET,
            APK_LATEST_OBJECT,
            f,
            size,
            content_type="application/vnd.android.package-archive",
        )

    uploaded_at = int(time.time())
    metadata = {
        "url": _apk_release_url(),
        "bucket": APK_RELEASE_BUCKET,
        "object": APK_LATEST_OBJECT,
        "filename": original_name,
        "size": size,
        "sha256": sha256,
        "version_name": version_name,
        "build_number": build_number,
        "release_notes": release_notes,
        "uploaded_by": user,
        "uploaded_at": uploaded_at,
        "uploaded_at_iso": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(uploaded_at)
        ),
    }
    metadata_bytes = json.dumps(
        metadata, ensure_ascii=False, indent=2, sort_keys=True
    ).encode("utf-8")
    sha_line = f"{sha256}  {Path(APK_LATEST_OBJECT).name}\n".encode("utf-8")
    client.put_object(
        APK_RELEASE_BUCKET,
        APK_METADATA_OBJECT,
        io.BytesIO(metadata_bytes),
        len(metadata_bytes),
        content_type="application/json",
    )
    client.put_object(
        APK_RELEASE_BUCKET,
        APK_SHA256_OBJECT,
        io.BytesIO(sha_line),
        len(sha_line),
        content_type="text/plain; charset=utf-8",
    )
    with db_conn() as conn:
        _audit(
            conn,
            "apk_release",
            "upload",
            None,
            json.dumps(metadata, ensure_ascii=False, sort_keys=True),
            user,
        )
    return metadata


def _upload_root() -> Path:
    root = Path(APK_UPLOAD_TMP_DIR)
    root.mkdir(parents=True, exist_ok=True)
    return root


def _upload_dir(upload_id: str) -> Path:
    if not upload_id or any(ch not in "0123456789abcdef" for ch in upload_id):
        abort(404)
    if len(upload_id) != 32:
        abort(404)
    return _upload_root() / upload_id


def _upload_meta_path(upload_id: str) -> Path:
    return _upload_dir(upload_id) / "meta.json"


def _read_upload_meta(upload_id: str) -> dict:
    path = _upload_meta_path(upload_id)
    if not path.is_file():
        abort(404)
    return json.loads(path.read_text(encoding="utf-8"))


def _write_upload_meta(upload_id: str, meta: dict) -> None:
    upload_dir = _upload_dir(upload_id)
    upload_dir.mkdir(parents=True, exist_ok=True)
    path = upload_dir / "meta.json"
    tmp = upload_dir / "meta.json.tmp"
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def _copy_apk_to_temp(file_storage) -> tuple[str, int, str]:
    tmp = tempfile.NamedTemporaryFile(
        prefix="config-center-apk-", suffix=".apk", delete=False
    )
    tmp_path = tmp.name
    size = 0
    first_bytes = b""
    digest = hashlib.sha256()
    try:
        with tmp:
            while True:
                chunk = file_storage.stream.read(1024 * 1024)
                if not chunk:
                    break
                if not first_bytes:
                    first_bytes = chunk[:4]
                size += len(chunk)
                if size > APK_MAX_BYTES:
                    raise ValueError(f"APK 超过上限 {APK_MAX_BYTES // (1024 * 1024)} MB")
                digest.update(chunk)
                tmp.write(chunk)
        if size <= 0:
            raise ValueError("APK 文件为空")
        if not first_bytes.startswith(b"PK"):
            raise ValueError("文件内容不像有效 APK（APK 应为 ZIP 容器）")
        return tmp_path, size, digest.hexdigest()
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


@app.template_filter("ts_local")
def ts_local(ts: int | None) -> str:
    if not ts:
        return ""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


@app.errorhandler(401)
def _unauth(_e):
    return redirect(url_for("login_get"))


@app.errorhandler(413)
def _payload_too_large(_e):
    return _flash(f"上传文件超过上限 {APK_MAX_BYTES // (1024 * 1024)} MB", kind="err")


@app.after_request
def _security_headers(resp: Response) -> Response:
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    return resp


# ── 公开 API（无鉴权 + CORS + ETag + 进程内缓存）──
@app.route("/api/v1/public", methods=["GET", "OPTIONS"])
def public_config():
    if request.method == "OPTIONS":
        resp = Response(status=204)
        resp.headers["Access-Control-Allow-Origin"] = "*"
        resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "If-None-Match, Content-Type"
        return resp

    body, etag = get_public_payload_cached()

    if request.headers.get("If-None-Match") == etag:
        resp = Response(status=304)
    else:
        resp = Response(body, mimetype="application/json; charset=utf-8")

    resp.headers["ETag"] = etag
    resp.headers["Cache-Control"] = "no-cache"
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Expose-Headers"] = "ETag"
    return resp


# ── Login / Logout ──
@app.route("/login", methods=["GET"])
def login_get():
    if get_current_user():
        return redirect(url_for("admin"))
    return render_template("login.html", error=request.args.get("error"))


@app.route("/login", methods=["POST"])
def login_post():
    ip = request.headers.get("X-Real-IP", request.remote_addr or "unknown")
    if not login_allowed(ip):
        return redirect(url_for("login_get", error="rate_limited"))

    username = request.form.get("username", "")
    password = request.form.get("password", "")
    user_ok = secrets.compare_digest(username.encode(), ADMIN_USERNAME.encode())
    pass_ok = secrets.compare_digest(password.encode(), ADMIN_PASSWORD.encode())
    if not (user_ok and pass_ok):
        return redirect(url_for("login_get", error="invalid"))

    token = serializer.dumps({"u": username})
    resp = redirect(url_for("admin"))
    resp.set_cookie(
        COOKIE_NAME,
        token,
        max_age=COOKIE_MAX_AGE,
        httponly=True,
        secure=True,
        samesite="Lax",
    )
    return resp


@app.route("/logout", methods=["POST"])
def logout():
    resp = redirect(url_for("login_get"))
    resp.delete_cookie(COOKIE_NAME)
    return resp


# ── Admin ──
@app.route("/", methods=["GET"])
def root():
    return redirect(url_for("admin") if get_current_user() else url_for("login_get"))


@app.route("/admin", methods=["GET"])
def admin():
    user = require_user()
    g.current_user = user
    with db_conn() as conn:
        cfg_rows = conn.execute("SELECT * FROM configs ORDER BY key").fetchall()
        log_rows = conn.execute(
            "SELECT * FROM audit_log ORDER BY ts DESC LIMIT 30"
        ).fetchall()
    configs = []
    for row in cfg_rows:
        d = dict(row)
        d["display"] = display_value(d["value_type"], d["value"])
        configs.append(d)
    return render_template(
        "dashboard.html",
        user=user,
        configs=configs,
        logs=[dict(r) for r in log_rows],
        apk_release=_apk_release_state(),
        flash=request.args.get("flash"),
        flash_kind=request.args.get("flash_kind", "ok"),
    )


def _audit(conn, key: str, action: str, old: str | None, new: str | None, actor: str):
    conn.execute(
        "INSERT INTO audit_log (key,action,old_value,new_value,actor,ts) VALUES (?,?,?,?,?,?)",
        (key, action, old, new, actor, int(time.time())),
    )


@app.route("/admin/configs/new", methods=["POST"])
def create_config():
    user = require_user()
    key = (request.form.get("key", "") or "").strip()
    value_type = request.form.get("value_type", "string")
    value_raw = request.form.get("value", "")
    comment = request.form.get("comment", "").strip()

    if not key or not key.replace("_", "").replace("-", "").isalnum():
        return _flash("key 只能含字母/数字/下划线/横线", kind="err")
    try:
        value = normalize_value(value_type, value_raw)
    except ValueError as e:
        return _flash(f"值非法：{e}", kind="err")

    now = int(time.time())
    with db_conn() as conn:
        if conn.execute("SELECT 1 FROM configs WHERE key=?", (key,)).fetchone():
            return _flash(f"key {key!r} 已存在", kind="err")
        conn.execute(
            "INSERT INTO configs (key,value,value_type,comment,updated_at,updated_by)"
            " VALUES (?,?,?,?,?,?)",
            (key, value, value_type, comment, now, user),
        )
        _audit(conn, key, "create", None, value, user)
    return _flash(f"已新增 {key}")


@app.route("/admin/configs/<key>", methods=["POST"])
def update_config(key: str):
    user = require_user()
    value_type = request.form.get("value_type", "string")
    value_raw = request.form.get("value", "")
    comment = request.form.get("comment", "").strip()

    try:
        value = normalize_value(value_type, value_raw)
    except ValueError as e:
        return _flash(f"{key}: 值非法：{e}", kind="err")

    now = int(time.time())
    with db_conn() as conn:
        old = conn.execute("SELECT value FROM configs WHERE key=?", (key,)).fetchone()
        if old is None:
            return _flash(f"key {key!r} 不存在", kind="err")
        if (
            old["value"] == value
            and conn.execute(
                "SELECT comment, value_type FROM configs WHERE key=?", (key,)
            ).fetchone()["comment"]
            == comment
        ):
            # 没变化就别记审计了
            return _flash(f"{key} 无变化")
        conn.execute(
            "UPDATE configs SET value=?, value_type=?, comment=?, updated_at=?, updated_by=?"
            " WHERE key=?",
            (value, value_type, comment, now, user, key),
        )
        _audit(conn, key, "update", old["value"], value, user)
    return _flash(f"已保存 {key}")


@app.route("/admin/configs/<key>/delete", methods=["POST"])
def delete_config(key: str):
    user = require_user()
    with db_conn() as conn:
        old = conn.execute("SELECT value FROM configs WHERE key=?", (key,)).fetchone()
        if old is None:
            return _flash(f"key {key!r} 不存在", kind="err")
        conn.execute("DELETE FROM configs WHERE key=?", (key,))
        _audit(conn, key, "delete", old["value"], None, user)
    return _flash(f"已删除 {key}")


@app.route("/admin/apk/upload", methods=["POST"])
def upload_apk_release():
    user = require_user()
    apk = request.files.get("apk")
    original_name = apk.filename if apk is not None else ""

    version_name = (request.form.get("version_name", "") or "").strip()
    build_number = (request.form.get("build_number", "") or "").strip()
    release_notes = (request.form.get("release_notes", "") or "").strip()

    tmp_path = ""
    try:
        original_name = _validate_apk_request(original_name)
        tmp_path, size, sha256 = _copy_apk_to_temp(apk)
        _publish_apk_file(
            apk_path=tmp_path,
            size=size,
            sha256=sha256,
            original_name=original_name,
            version_name=version_name,
            build_number=build_number,
            release_notes=release_notes,
            user=user,
        )
        return _flash(f"APK 已上传，固定链接已更新：{_apk_release_url()}")
    except Exception as e:
        return _flash(f"APK 上传失败：{e}", kind="err")
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


@app.route("/admin/apk/upload", methods=["GET"])
def upload_apk_release_get():
    return redirect(url_for("admin"))


@app.route("/api/admin/apk/state", methods=["GET"])
def api_apk_state():
    require_user()
    return jsonify({"ok": True, "release": _apk_release_state()})


@app.route("/api/admin/apk/uploads", methods=["POST"])
def api_create_apk_upload():
    user = require_user()
    payload = request.get_json(silent=True) or {}
    try:
        filename = _validate_apk_request(
            str(payload.get("filename") or ""), int(payload.get("size") or 0)
        )
    except (TypeError, ValueError) as e:
        return _json_error(str(e), 400)

    upload_id = uuid.uuid4().hex
    size = int(payload.get("size") or 0)
    chunk_size = _effective_chunk_bytes()
    total_parts = (size + chunk_size - 1) // chunk_size
    now = int(time.time())
    meta = {
        "upload_id": upload_id,
        "filename": filename,
        "size": size,
        "chunk_size": chunk_size,
        "total_parts": total_parts,
        "version_name": (payload.get("version_name") or "").strip(),
        "build_number": (payload.get("build_number") or "").strip(),
        "release_notes": (payload.get("release_notes") or "").strip(),
        "created_by": user,
        "created_at": now,
        "updated_at": now,
        "received": {},
    }
    _write_upload_meta(upload_id, meta)
    return jsonify(
        {
            "ok": True,
            "upload_id": upload_id,
            "chunk_size": chunk_size,
            "total_parts": total_parts,
        }
    )


@app.route(
    "/api/admin/apk/uploads/<upload_id>/chunks/<int:index>",
    methods=["PUT", "POST"],
)
def api_upload_apk_chunk(upload_id: str, index: int):
    user = require_user()
    meta = _read_upload_meta(upload_id)
    if meta.get("created_by") != user:
        return _json_error("无权访问这个上传任务", 403)
    total_parts = int(meta["total_parts"])
    if index < 0 or index >= total_parts:
        return _json_error("分片序号非法", 400)

    data = request.get_data(cache=False)
    if not data:
        return _json_error("分片为空", 400)
    chunk_max_bytes = _effective_chunk_max_bytes()
    if len(data) > chunk_max_bytes:
        return _json_error(
            f"单个分片超过上限 {chunk_max_bytes // (1024 * 1024)} MB", 413
        )

    size = int(meta["size"])
    chunk_size = int(meta["chunk_size"])
    expected_size = min(chunk_size, size - index * chunk_size)
    if len(data) != expected_size:
        return _json_error("分片大小不匹配，请重新上传", 400)

    upload_dir = _upload_dir(upload_id)
    part_path = upload_dir / f"{index:06d}.part"
    tmp_path = upload_dir / f"{index:06d}.part.tmp"
    tmp_path.write_bytes(data)
    tmp_path.replace(part_path)
    meta["received"][str(index)] = len(data)
    meta["updated_at"] = int(time.time())
    _write_upload_meta(upload_id, meta)
    return jsonify({"ok": True, "index": index, "bytes": len(data)})


@app.route("/api/admin/apk/uploads/<upload_id>/complete", methods=["POST"])
def api_complete_apk_upload(upload_id: str):
    user = require_user()
    meta = _read_upload_meta(upload_id)
    if meta.get("created_by") != user:
        return _json_error("无权访问这个上传任务", 403)

    upload_dir = _upload_dir(upload_id)
    total_parts = int(meta["total_parts"])
    size = int(meta["size"])
    chunk_size = int(meta["chunk_size"])
    merged_path = str(upload_dir / "merged.apk")
    digest = hashlib.sha256()
    total = 0
    first_bytes = b""

    try:
        with open(merged_path, "wb") as out:
            for index in range(total_parts):
                part_path = upload_dir / f"{index:06d}.part"
                if not part_path.is_file():
                    return _json_error(f"缺少分片 {index + 1}/{total_parts}", 400)
                expected_size = min(chunk_size, size - index * chunk_size)
                actual_size = part_path.stat().st_size
                if actual_size != expected_size:
                    return _json_error(f"分片 {index + 1} 大小不匹配", 400)
                with open(part_path, "rb") as part:
                    while True:
                        chunk = part.read(1024 * 1024)
                        if not chunk:
                            break
                        if not first_bytes:
                            first_bytes = chunk[:4]
                        digest.update(chunk)
                        total += len(chunk)
                        out.write(chunk)

        if total != size:
            return _json_error("合并后的 APK 大小不匹配", 400)
        if not first_bytes.startswith(b"PK"):
            return _json_error("文件内容不像有效 APK（APK 应为 ZIP 容器）", 400)

        metadata = _publish_apk_file(
            apk_path=merged_path,
            size=size,
            sha256=digest.hexdigest(),
            original_name=meta["filename"],
            version_name=meta.get("version_name", ""),
            build_number=meta.get("build_number", ""),
            release_notes=meta.get("release_notes", ""),
            user=user,
        )
        shutil.rmtree(upload_dir, ignore_errors=True)
        return jsonify({"ok": True, "metadata": metadata, "release": _apk_release_state()})
    except Exception as e:
        return _json_error(f"APK 发布失败：{e}", 500)


@app.route("/api/admin/apk/uploads/<upload_id>", methods=["DELETE"])
def api_abort_apk_upload(upload_id: str):
    user = require_user()
    meta = _read_upload_meta(upload_id)
    if meta.get("created_by") != user:
        return _json_error("无权访问这个上传任务", 403)
    shutil.rmtree(_upload_dir(upload_id), ignore_errors=True)
    return jsonify({"ok": True})


# ══════════════════════ 统一管理后台 Dashboard（SPA + 只读代理 + 用户管理）══════════════════════
# 把用户管理 / FaaS / Agent 面板整合进 config-center。所有路由 require_user() 鉴权；
# 上游服务凭证只在服务端使用。除用户管理（显式管理动作）外，FaaS/Agent 均只读代理现有 API，
# 不改动 backend / 产品代码。

def _dash_err(msg: str, code: int = 502):
    return jsonify({"error": msg}), code


def _sb_headers() -> dict:
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


def _sb_ready() -> bool:
    return bool(SUPABASE_URL and SUPABASE_SERVICE_KEY)


def _sb_get_user(user_id: str):
    r = requests.get(
        f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
        headers=_sb_headers(), timeout=DASH_HTTP_TIMEOUT,
    )
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def _backend_get(path: str, headers: dict | None = None, params: dict | None = None):
    r = requests.get(
        f"{BACKEND_URL}{path}", headers=headers or {}, params=params or {},
        timeout=DASH_HTTP_TIMEOUT,
    )
    r.raise_for_status()
    return r.json()


def _agent_headers() -> dict:
    return {"Authorization": f"Bearer {AGENT_NODE_TOKEN}"} if AGENT_NODE_TOKEN else {}


# ── SPA shell ──
@app.route("/admin/dashboard", methods=["GET"])
def admin_dashboard_spa():
    require_user()
    index = Path(__file__).parent / "static" / "dashboard" / "index.html"
    if not index.is_file():
        return Response(
            "dashboard 未构建：请在 config_center/dashboard 下 `npm run build` 生成 static/dashboard/",
            503, mimetype="text/plain; charset=utf-8",
        )
    return Response(index.read_text(encoding="utf-8"), mimetype="text/html")


# ── Tab: 配置下发（进程内）──
@app.route("/api/admin/dashboard/configs", methods=["GET"])
def dash_configs():
    require_user()
    with db_conn() as conn:
        cfg = [dict(r) for r in conn.execute("SELECT * FROM configs ORDER BY key").fetchall()]
        audit = [dict(r) for r in conn.execute(
            "SELECT * FROM audit_log ORDER BY ts DESC LIMIT 50").fetchall()]
    for c in cfg:
        c["display"] = display_value(c["value_type"], c["value"])
    return jsonify({"configs": cfg, "audit": audit, "apk": _apk_release_state()})


# ── Tab: 用户管理（代理 Supabase GoTrue Admin API）──
@app.route("/api/admin/dashboard/users", methods=["GET"])
def dash_users():
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置（缺 SUPABASE_URL / SUPABASE_SERVICE_KEY）", 503)
    page = request.args.get("page", "1")
    per = request.args.get("per_page", "100")
    try:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/admin/users", headers=_sb_headers(),
            params={"page": page, "per_page": per}, timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"Supabase 用户列表失败: {e}")
    out = _dash.shape_users_page(r.json())
    out["page"] = int(page)
    return jsonify(out)


@app.route("/api/admin/dashboard/users/create", methods=["POST"])
def dash_users_create():
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    d = request.get_json(silent=True) or {}
    email = (d.get("email") or "").strip()
    password = d.get("password") or ""
    role = d.get("role") or "user"
    username = (d.get("username") or "").strip() or None
    if not email or len(password) < 6:
        return _dash_err("email 必填、密码至少 6 位", 400)
    body = {"email": email, "password": password, "email_confirm": True,
            "app_metadata": {"role": role}}
    if username:
        body["user_metadata"] = {"username": username}
    try:
        r = requests.post(f"{SUPABASE_URL}/auth/v1/admin/users", headers=_sb_headers(),
                          json=body, timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"创建用户失败: {e}")
    return jsonify({"ok": True, "user": _dash.shape_user(r.json())})


@app.route("/api/admin/dashboard/users/<user_id>/role", methods=["POST"])
def dash_users_role(user_id: str):
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    role = (request.get_json(silent=True) or {}).get("role")
    if role not in ("user", "pro", "admin"):
        return _dash_err("role 取值非法", 400)
    try:
        u = _sb_get_user(user_id)
        if not u:
            return _dash_err("用户不存在", 404)
        new_meta = {**(u.get("app_metadata") or {}), "role": role}
        r = requests.put(f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
                         headers=_sb_headers(), json={"app_metadata": new_meta},
                         timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"改角色失败: {e}")
    return jsonify({"ok": True, "user": _dash.shape_user(r.json())})


@app.route("/api/admin/dashboard/users/<user_id>/ban", methods=["POST"])
def dash_users_ban(user_id: str):
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    ban = bool((request.get_json(silent=True) or {}).get("ban"))
    try:
        r = requests.put(f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
                         headers=_sb_headers(),
                         json={"ban_duration": "876000h" if ban else "none"},
                         timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"封禁操作失败: {e}")
    return jsonify({"ok": True, "user": _dash.shape_user(r.json())})


@app.route("/api/admin/dashboard/users/<user_id>/confirm_email", methods=["POST"])
def dash_users_confirm(user_id: str):
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    try:
        r = requests.put(f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
                         headers=_sb_headers(), json={"email_confirm": True},
                         timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"确认邮箱失败: {e}")
    return jsonify({"ok": True})


@app.route("/api/admin/dashboard/users/<user_id>/recovery", methods=["POST"])
def dash_users_recovery(user_id: str):
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    try:
        u = _sb_get_user(user_id)
        if not u or not u.get("email"):
            return _dash_err("用户不存在或无邮箱", 404)
        r = requests.post(f"{SUPABASE_URL}/auth/v1/admin/generate_link",
                          headers=_sb_headers(),
                          json={"type": "recovery", "email": u["email"]},
                          timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except requests.RequestException as e:
        return _dash_err(f"发送重置邮件失败: {e}")
    return jsonify({"ok": True})


@app.route("/api/admin/dashboard/users/<user_id>/quota", methods=["POST"])
def dash_users_quota(user_id: str):
    require_user()
    if not _sb_ready():
        return _dash_err("用户管理未配置", 503)
    raw = (request.get_json(silent=True) or {}).get("quota")
    try:
        u = _sb_get_user(user_id)
        if not u:
            return _dash_err("用户不存在", 404)
        meta = dict(u.get("app_metadata") or {})
        if raw in (None, "", "null"):
            meta.pop("quota_limit_override", None)
        else:
            meta["quota_limit_override"] = int(raw)
        r = requests.put(f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
                         headers=_sb_headers(), json={"app_metadata": meta},
                         timeout=DASH_HTTP_TIMEOUT)
        r.raise_for_status()
    except (requests.RequestException, ValueError) as e:
        return _dash_err(f"配额设置失败: {e}")
    return jsonify({"ok": True, "user": _dash.shape_user(r.json())})


# ── Tab: FaaS 服务（代理 backend，派生 启动时间/实例数/容量范围/当前容量）──
@app.route("/api/admin/dashboard/faas", methods=["GET"])
def dash_faas():
    require_user()
    try:
        health = _backend_get("/api/faas/health")
    except requests.RequestException:
        health = {}
    deploy_mode = (health.get("deploy_mode") if isinstance(health, dict) else None) or "local-docker"
    try:
        raw = _backend_get("/api/faas/services",
                           params={"all_users": "1", "include_disabled": "1"})
    except requests.RequestException as e:
        return _dash_err(f"FaaS 列表失败: {e}")
    services = raw.get("services", raw.get("items", raw)) if isinstance(raw, dict) else raw
    if not isinstance(services, list):
        services = []
    views = [_dash.compute_faas_view(s, deploy_mode, FAAS_CAP_MIN, FAAS_CAP_MAX)
             for s in services if isinstance(s, dict)]
    return jsonify({
        "services": views,
        "overview": _dash.compute_faas_overview(views),
        "deploy_mode": deploy_mode,
        "health": health,
    })


# ── Tab: Agent 节点（代理 backend 聚合接口）──
@app.route("/api/admin/dashboard/agents", methods=["GET"])
def dash_agents():
    require_user()
    try:
        data = _backend_get("/api/ai/agent_nodes", headers=_agent_headers(),
                            params={"namespace": "all",
                                    "probe": request.args.get("probe", "0")})
    except requests.RequestException as e:
        return _dash_err(f"Agent 列表失败: {e}")
    return jsonify(_dash.shape_agents(data))


@app.route("/api/admin/dashboard/agents/<node_id>", methods=["GET"])
def dash_agent_detail(node_id: str):
    require_user()
    try:
        data = _backend_get(f"/api/ai/agent_nodes/{node_id}", headers=_agent_headers(),
                            params={"runs": "1"})
    except requests.RequestException as e:
        return _dash_err(f"Agent 详情失败: {e}")
    return jsonify(data)


def _flash(msg: str, kind: str = "ok"):
    return redirect(url_for("admin", flash=msg, flash_kind=kind))


# ── 启动时一次性建表 + 种子；gunicorn / dev 都走同一路径 ──
init_db()


# ── Main: 本地 dev 用 `python app.py`，生产由 gunicorn 通过 `app:app` 接管 ──
if __name__ == "__main__":
    # 仅监听 127.0.0.1，外网由 nginx 反代
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
