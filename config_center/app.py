"""Config Center — 客户端公共配置下发服务

设计要点（与同仓库 backend/ 完全独立）：
- 跑在和主后端不同的物理机/路径上，主后端挂了它仍然可用
- SQLite 单文件存储；轻量 KV + 类型 + 注释 + 修改审计
- 公开 endpoint /api/v1/public 不需鉴权，返回整包 JSON + ETag
- Admin UI 用签名 cookie session（itsdangerous），密码明文存在 /etc/config-center/.env
  （root 可读；user 可随时改 env 重启服务生效）
"""

import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from flask import Flask, Response, abort, g, redirect, render_template, request, url_for
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

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


@app.template_filter("ts_local")
def ts_local(ts: int | None) -> str:
    if not ts:
        return ""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


@app.errorhandler(401)
def _unauth(_e):
    return redirect(url_for("login_get"))


@app.after_request
def _security_headers(resp: Response) -> Response:
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    return resp


# ── 公开 API（无鉴权 + CORS + ETag）──
@app.route("/api/v1/public", methods=["GET", "OPTIONS"])
def public_config():
    if request.method == "OPTIONS":
        resp = Response(status=204)
        resp.headers["Access-Control-Allow-Origin"] = "*"
        resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "If-None-Match, Content-Type"
        return resp

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
    body = json.dumps(out, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    import hashlib

    etag = '"' + hashlib.sha256(body.encode("utf-8")).hexdigest()[:16] + '"'

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


def _flash(msg: str, kind: str = "ok"):
    return redirect(url_for("admin", flash=msg, flash_kind=kind))


# ── Main ──
if __name__ == "__main__":
    init_db()
    # 仅监听 127.0.0.1，外网由 nginx 反代
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
