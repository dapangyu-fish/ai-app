"""User Center —— Supabase 用户管理后台

设计要点：
- 跑在和 config-center 同一台机器，独立服务（独立端口、独立 .env、独立 supervisor program）
- 所有写操作走 Supabase Admin API（保留 GoTrue 的副作用：audit log / session revoke / webhook）
- 列表/搜索也走 API（用户量小，HTTP 分页够了；以后量大再升级到混合模式）
- Admin UI 用签名 cookie session（itsdangerous），密码与 config-center 共用一份
- 审计日志（who 改了 who 什么字段）落 SQLite 单文件
"""

import json
import secrets
import sqlite3
import time
import urllib.parse
from contextlib import contextmanager
from pathlib import Path
import os

import requests
from flask import (
    Flask, abort, flash, g, redirect, render_template, request, url_for
)
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

# ── 启动期：读 env ──
# supervisor 通过 environment= 注入 USER_CENTER_ENV_PATH 指向 /etc/user-center/.env
_env_path = os.environ.get("USER_CENTER_ENV_PATH", "")
if _env_path and Path(_env_path).is_file():
    with open(_env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/user-center/audit.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8089"))

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")

if not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_PASSWORD env 必须设置（建议 /etc/user-center/.env，root 600）")
if not SESSION_SECRET:
    raise RuntimeError("SESSION_SECRET env 必须设置 —— openssl rand -hex 32")
if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
    raise RuntimeError("SUPABASE_URL 和 SUPABASE_SERVICE_KEY 必须设置")

COOKIE_NAME = "uc_session"
COOKIE_MAX_AGE = 7 * 24 * 3600  # 7 天
LOGIN_RATELIMIT_WINDOW = 15 * 60
LOGIN_RATELIMIT_MAX = 5

VALID_ROLES = ("user", "pro", "admin")


# ────────────────────────────── DB ──────────────────────────────

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
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS audit_log (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                ts          INTEGER NOT NULL,
                actor       TEXT    NOT NULL,
                target_id   TEXT    NOT NULL,
                target_email TEXT,
                action      TEXT    NOT NULL,
                details     TEXT,
                ip          TEXT
            );
            CREATE INDEX IF NOT EXISTS audit_log_ts ON audit_log(ts DESC);
            CREATE INDEX IF NOT EXISTS audit_log_target ON audit_log(target_id);
            """
        )


def log_audit(actor: str, target_id: str, target_email: str | None,
              action: str, details: str | None, ip: str) -> None:
    with db_conn() as conn:
        conn.execute(
            "INSERT INTO audit_log(ts, actor, target_id, target_email, action, details, ip) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (int(time.time()), actor, target_id, target_email, action, details, ip),
        )


# 启动时即建库（gunicorn 不会跑 __main__）
init_db()


# ────────────────────────────── Supabase Admin API ──────────────────────────────

def _sb_headers() -> dict:
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


def sb_list_users(page: int = 1, per_page: int = 50) -> dict:
    """返回 {"users": [...], "total_pages": int}"""
    r = requests.get(
        f"{SUPABASE_URL}/auth/v1/admin/users",
        headers=_sb_headers(),
        params={"page": page, "per_page": per_page},
        timeout=10,
    )
    r.raise_for_status()
    data = r.json()
    # GoTrue 不直接返回总页数，但 link header 里有；先用 users 长度估算
    return {
        "users": data.get("users", []),
        "total_pages": data.get("aud", page + (1 if len(data.get("users", [])) == per_page else 0)),
    }


def sb_get_user(user_id: str) -> dict | None:
    r = requests.get(
        f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
        headers=_sb_headers(), timeout=10,
    )
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def sb_update_app_metadata(user_id: str, patch: dict) -> dict:
    """读 → 合并 → 写。直接 PUT app_metadata 是替换，不能丢 provider/providers 这些原值"""
    user = sb_get_user(user_id)
    if not user:
        raise ValueError(f"user {user_id} not found")
    new_meta = {**user.get("app_metadata", {}), **patch}
    r = requests.put(
        f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
        headers=_sb_headers(),
        json={"app_metadata": new_meta},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


def sb_set_banned(user_id: str, ban: bool) -> dict:
    """ban=True 设 100 年；ban=False 用 'none'（GoTrue 文档约定的解禁值）"""
    body = {"ban_duration": "876000h" if ban else "none"}
    r = requests.put(
        f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
        headers=_sb_headers(),
        json=body,
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


def sb_send_recovery(email: str) -> dict:
    """让 GoTrue 给该邮箱发密码重置链接"""
    r = requests.post(
        f"{SUPABASE_URL}/auth/v1/admin/generate_link",
        headers=_sb_headers(),
        json={"type": "recovery", "email": email},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


def sb_force_email_confirm(user_id: str) -> dict:
    """手动把 email 标为已验证（绕过验证邮件）。用于"邮件没收到"的客服兜底场景。"""
    r = requests.put(
        f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
        headers=_sb_headers(),
        json={"email_confirm": True},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


# ────────────────────────────── Auth ──────────────────────────────

serializer = URLSafeTimedSerializer(SESSION_SECRET, salt="user-center-session")
_login_attempts: dict[str, list[float]] = {}


def _client_ip() -> str:
    fwd = request.headers.get("X-Forwarded-For", "")
    return fwd.split(",")[0].strip() if fwd else (request.remote_addr or "")


def _check_login_ratelimit(ip: str) -> bool:
    now = time.time()
    bucket = _login_attempts.setdefault(ip, [])
    cutoff = now - LOGIN_RATELIMIT_WINDOW
    bucket[:] = [t for t in bucket if t > cutoff]
    if len(bucket) >= LOGIN_RATELIMIT_MAX:
        return False
    bucket.append(now)
    return True


def _current_user() -> str | None:
    raw = request.cookies.get(COOKIE_NAME)
    if not raw:
        return None
    try:
        data = serializer.loads(raw, max_age=COOKIE_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None
    return data.get("u") if isinstance(data, dict) else None


def require_login():
    user = _current_user()
    if not user:
        return redirect(url_for("login_page", next=request.path))
    g.admin_user = user
    return None


# ────────────────────────────── Flask ──────────────────────────────

app = Flask(__name__)
app.secret_key = SESSION_SECRET


@app.before_request
def _gate():
    # 登录 / 静态 / 健康检查 不拦
    if request.endpoint in ("login_page", "do_login", "do_logout", "static", "healthz"):
        return None
    return require_login()


@app.template_filter("ts")
def _filter_ts(ts) -> str:
    if not ts:
        return ""
    if isinstance(ts, str):
        # supabase 返回 ISO 字符串，原样显示截断
        return ts[:19].replace("T", " ")
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(ts)))


@app.template_filter("role_of")
def _filter_role(user: dict) -> str:
    return (user.get("app_metadata") or {}).get("role", "user")


@app.template_filter("banned")
def _filter_banned(user: dict) -> bool:
    bu = user.get("banned_until")
    if not bu:
        return False
    # banned_until = "none" 或 ISO 时间；future 时间表示禁用
    if bu == "none":
        return False
    return True


@app.template_filter("quota_override")
def _filter_quota_override(user: dict):
    """返回 int 或 None（None = 无 override，按 role 默认）"""
    v = (user.get("app_metadata") or {}).get("quota_limit_override")
    return v if isinstance(v, int) and v > 0 else None


@app.template_filter("email_confirmed")
def _filter_email_confirmed(user: dict) -> bool:
    return bool(user.get("email_confirmed_at"))


@app.route("/login", methods=["GET"])
def login_page():
    return render_template("login.html", error=None, next=request.args.get("next", "/"))


@app.route("/login", methods=["POST"])
def do_login():
    ip = _client_ip()
    if not _check_login_ratelimit(ip):
        return render_template("login.html",
                               error="尝试次数过多，请 15 分钟后再试",
                               next=request.form.get("next", "/")), 429
    u = (request.form.get("username") or "").strip()
    p = request.form.get("password") or ""
    if not (secrets.compare_digest(u, ADMIN_USERNAME) and
            secrets.compare_digest(p, ADMIN_PASSWORD)):
        return render_template("login.html",
                               error="账号或密码错误",
                               next=request.form.get("next", "/")), 401
    cookie_val = serializer.dumps({"u": u})
    nxt = request.form.get("next") or "/"
    if not nxt.startswith("/"):
        nxt = "/"
    resp = redirect(nxt)
    resp.set_cookie(COOKIE_NAME, cookie_val,
                    max_age=COOKIE_MAX_AGE, httponly=True, secure=True, samesite="Lax")
    return resp


@app.route("/logout", methods=["POST"])
def do_logout():
    resp = redirect(url_for("login_page"))
    resp.delete_cookie(COOKIE_NAME)
    return resp


# ── 用户列表 ──
@app.route("/")
def dashboard():
    page = max(1, int(request.args.get("page", "1")))
    per_page = 50
    q = (request.args.get("q") or "").strip().lower()
    try:
        listing = sb_list_users(page=page, per_page=per_page)
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502

    users = listing["users"]
    if q:
        users = [u for u in users if q in (u.get("email") or "").lower()
                 or q in (u.get("user_metadata", {}).get("username") or "").lower()
                 or q in (u.get("id") or "")]

    # 最近 50 条审计日志
    with db_conn() as conn:
        rows = conn.execute(
            "SELECT ts, actor, target_email, action, details, ip "
            "FROM audit_log ORDER BY ts DESC LIMIT 50"
        ).fetchall()
        audit = [dict(r) for r in rows]

    return render_template(
        "dashboard.html",
        admin_user=g.admin_user,
        users=users,
        page=page,
        per_page=per_page,
        q=q,
        valid_roles=VALID_ROLES,
        has_more=len(listing["users"]) == per_page,
        audit=audit,
    )


# ── 改 role ──
@app.route("/users/<user_id>/role", methods=["POST"])
def change_role(user_id):
    new_role = (request.form.get("role") or "").strip()
    if new_role not in VALID_ROLES:
        return f"role 必须是 {VALID_ROLES} 之一", 400
    try:
        before = sb_get_user(user_id)
        if not before:
            return "user 不存在", 404
        old_role = (before.get("app_metadata") or {}).get("role", "user")
        if old_role == new_role:
            flash(f"{before.get('email')} 已经是 {new_role}，无变化")
            return redirect(url_for("dashboard", q=request.form.get("q", "")))
        sb_update_app_metadata(user_id, {"role": new_role})
        log_audit(g.admin_user, user_id, before.get("email"),
                  "change_role",
                  json.dumps({"from": old_role, "to": new_role}, ensure_ascii=False),
                  _client_ip())
        flash(f"已把 {before.get('email')} 从 {old_role} 改为 {new_role}")
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502
    return redirect(url_for("dashboard", q=request.form.get("q", "")))


# ── ban / unban ──
@app.route("/users/<user_id>/ban", methods=["POST"])
def toggle_ban(user_id):
    target_state = request.form.get("state") == "ban"
    try:
        before = sb_get_user(user_id)
        if not before:
            return "user 不存在", 404
        sb_set_banned(user_id, target_state)
        log_audit(g.admin_user, user_id, before.get("email"),
                  "ban" if target_state else "unban",
                  None, _client_ip())
        flash(f"{'已封禁' if target_state else '已解禁'} {before.get('email')}")
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502
    return redirect(url_for("dashboard", q=request.form.get("q", "")))


# ── 发密码重置邮件 ──
@app.route("/users/<user_id>/send_recovery", methods=["POST"])
def send_recovery(user_id):
    try:
        user = sb_get_user(user_id)
        if not user or not user.get("email"):
            return "user 不存在或无邮箱", 404
        sb_send_recovery(user["email"])
        log_audit(g.admin_user, user_id, user.get("email"),
                  "send_recovery", None, _client_ip())
        flash(f"已发送密码重置邮件给 {user['email']}")
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502
    return redirect(url_for("dashboard", q=request.form.get("q", "")))


# ── 强制确认邮箱（绕过验证邮件）──
@app.route("/users/<user_id>/confirm_email", methods=["POST"])
def confirm_email(user_id):
    try:
        before = sb_get_user(user_id)
        if not before:
            return "user 不存在", 404
        if before.get("email_confirmed_at"):
            flash(f"{before.get('email')} 邮箱已经是已确认状态")
            return redirect(url_for("dashboard", q=request.form.get("q", "")))
        sb_force_email_confirm(user_id)
        log_audit(g.admin_user, user_id, before.get("email"),
                  "force_confirm_email", None, _client_ip())
        flash(f"已把 {before.get('email')} 的邮箱标记为已确认")
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502
    return redirect(url_for("dashboard", q=request.form.get("q", "")))


# ── 设/清除 per-user quota override ──
# 写入 app_metadata.quota_limit_override (int)。后端 get_quota_info 优先读这个字段。
@app.route("/users/<user_id>/quota_override", methods=["POST"])
def set_quota_override(user_id):
    raw = (request.form.get("limit") or "").strip()
    try:
        before = sb_get_user(user_id)
        if not before:
            return "user 不存在", 404
        old_override = (before.get("app_metadata") or {}).get("quota_limit_override")

        if raw == "":
            # 清除 override —— 显式塞 None；sb_update_app_metadata 用 dict merge，None 会保留
            # 改用读出来手动 pop 然后整个写回
            current = before.get("app_metadata") or {}
            new_meta = {k: v for k, v in current.items() if k != "quota_limit_override"}
            r = requests.put(
                f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}",
                headers=_sb_headers(),
                json={"app_metadata": new_meta},
                timeout=10,
            )
            r.raise_for_status()
            log_audit(g.admin_user, user_id, before.get("email"),
                      "clear_quota_override",
                      json.dumps({"was": old_override}, ensure_ascii=False),
                      _client_ip())
            flash(f"已清除 {before.get('email')} 的 quota override（恢复 role 默认）")
        else:
            try:
                limit = int(raw)
            except ValueError:
                return "limit 必须是正整数", 400
            if limit <= 0 or limit > 10_000_000:
                return "limit 必须 > 0 且 ≤ 10000000", 400
            sb_update_app_metadata(user_id, {"quota_limit_override": limit})
            log_audit(g.admin_user, user_id, before.get("email"),
                      "set_quota_override",
                      json.dumps({"from": old_override, "to": limit}, ensure_ascii=False),
                      _client_ip())
            flash(f"已把 {before.get('email')} 的每日 quota 设为 {limit}")
    except requests.HTTPError as e:
        return f"Supabase API 错误: {e}", 502
    return redirect(url_for("dashboard", q=request.form.get("q", "")))


@app.route("/healthz")
def healthz():
    return "ok\n", 200, {"Content-Type": "text/plain"}


# 本地开发用（生产走 gunicorn -c gunicorn_conf.py app:app）
if __name__ == "__main__":
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=True)
