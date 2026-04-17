#!/usr/bin/env python3
"""
JSON DSL Backend — Flask
Auth Proxy + User Roles + Chat Quota + AI Chat (SSE) + App Store (OSS)

启动: python3 tools/ai_server.py
"""

import json
import os
import re
import base64
import uuid
import urllib.parse
from datetime import date
from functools import wraps

import requests
from flask import Flask, request, jsonify, Response, stream_with_context, send_from_directory
from flask_sock import Sock

# ══════════════════════════════════════════════════════════
# 配置
# ══════════════════════════════════════════════════════════

SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://127.0.0.1:8000")
SUPABASE_ANON_KEY = (
    "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9"
    ".eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3NzYzNjU0NjIsICJleHAiOiAyMDkxNzI1NDYyfQ"
    ".yDol0HCrVCJ_XlWTAb3k89aAwb-KzMlSMw-EHEIpB2k"
)
SUPABASE_SERVICE_KEY = (
    "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9"
    ".eyJyb2xlIjogInNlcnZpY2Vfcm9sZSIsICJpc3MiOiAic3VwYWJhc2UiLCAiaWF0IjogMTc3NjM2NTQ2MiwgImV4cCI6IDIwOTE3MjU0NjJ9"
    ".vF-RNvJfdUyhExR8cFdefdMVmw4yHCCaFMd_-gZC5Es"
)
SUPABASE_DB_URL = "postgresql://supabase_admin:kWwuSeqL4Xey66QsUBD7MsUl@127.0.0.1:5432/postgres"

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"
DEEPSEEK_MODEL = "deepseek-chat"

MINIO_ENDPOINT = "http://127.0.0.1:9000"
MINIO_ACCESS_KEY = "m3wZkIA5EgmEwkctueZM"
MINIO_SECRET_KEY = "m9M7M70F6SpsQxTZZ6roLklq33AUMV8mzAm1RJGk"
MINIO_PUBLIC_URL = "https://app-oss-endpoint.dapangyu.work"

PORT = 5566
TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates")
DSL_SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "JSON-DSL.md")

# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}

app = Flask(__name__)
sock = Sock(app)

# ══════════════════════════════════════════════════════════
# DB 辅助（直接用 psycopg2 或 HTTP 走 PostgREST）
# ══════════════════════════════════════════════════════════

def _db_query(sql, params=None):
    """通过 docker exec 执行 SQL（简易方案，避免额外依赖）"""
    import subprocess
    if params:
        for i, p in enumerate(params):
            ph = f"${i+1}"
            if isinstance(p, str):
                sql = sql.replace(ph, f"'{p}'", 1)
            elif p is None:
                sql = sql.replace(ph, "NULL", 1)
            else:
                sql = sql.replace(ph, str(p), 1)

    result = subprocess.run(
        ["docker", "exec", "supabase-db", "psql", "-U", "supabase_admin",
         "-d", "postgres", "-t", "-A", "-c", sql],
        capture_output=True, text=True, timeout=10
    )
    return result.stdout.strip()


def _db_execute(sql, params=None):
    """执行 INSERT/UPDATE/DELETE"""
    _db_query(sql, params)


# ══════════════════════════════════════════════════════════
# 工具函数
# ══════════════════════════════════════════════════════════

def _supabase_headers(token=None):
    h = {"apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _service_headers():
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


def _get_user_role(user):
    """从 app_metadata 获取角色，默认 user"""
    return user.get("app_metadata", {}).get("role", "user")


def _extract_user_info(user):
    meta = user.get("user_metadata", {})
    return {
        "id": user.get("id"),
        "email": user.get("email"),
        "username": meta.get("username", ""),
        "avatar_url": meta.get("avatar_url", ""),
        "role": _get_user_role(user),
    }


def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "未提供认证 token"}), 401
        token = auth[7:]
        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=10,
        )
        if resp.status_code != 200:
            return jsonify({"error": "token 无效或已过期"}), 401
        request.supabase_user = resp.json()
        request.supabase_token = token
        request.user_role = _get_user_role(request.supabase_user)
        return f(*args, **kwargs)
    return decorated


def require_role(*roles):
    """装饰器：要求特定角色"""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if request.user_role not in roles:
                return jsonify({"error": f"权限不足，需要 {'/'.join(roles)} 角色"}), 403
            return f(*args, **kwargs)
        return decorated
    return decorator


# ══════════════════════════════════════════════════════════
# 聊天配额
# ══════════════════════════════════════════════════════════

def _get_quota_info(user_id, role):
    """返回 (used, limit, remaining)"""
    limit = ROLE_QUOTAS.get(role, 30)
    today = date.today().isoformat()
    row = _db_query(
        f"SELECT used_count FROM public.chat_quotas WHERE user_id = $1 AND date = $2",
        [user_id, today]
    )
    used = int(row) if row else 0
    return used, limit, max(0, limit - used)


def _increment_quota(user_id):
    today = date.today().isoformat()
    _db_execute(
        f"INSERT INTO public.chat_quotas (user_id, date, used_count) "
        f"VALUES ($1, $2, 1) "
        f"ON CONFLICT (user_id, date) DO UPDATE SET used_count = chat_quotas.used_count + 1",
        [user_id, today]
    )


# ══════════════════════════════════════════════════════════
# Auth API（保留原有，增加 role 字段）
# ══════════════════════════════════════════════════════════

@app.route("/api/auth/register", methods=["POST"])
def register():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    username = body.get("username", "").strip()

    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400
    if len(password) < 6:
        return jsonify({"error": "密码至少 6 位"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/signup",
        headers=_supabase_headers(),
        json={"email": email, "password": password,
              "data": {"username": username or email.split("@")[0]}},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or data.get("message") or str(data)
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    needs_confirm = user.get("email_confirmed_at") is None

    result = {
        "message": "注册成功，请查收验证邮件" if needs_confirm else "注册成功",
        "needs_confirm": needs_confirm,
        "user": _extract_user_info(user),
    }
    if not needs_confirm and data.get("access_token"):
        result["access_token"] = data["access_token"]
        result["refresh_token"] = data["refresh_token"]
        result["expires_in"] = data.get("expires_in", 3600)

    return jsonify(result), 200


@app.route("/api/auth/verify", methods=["POST"])
def verify_otp():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    token = body.get("token", "").strip()
    if not email or not token:
        return jsonify({"error": "邮箱和验证码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/verify",
        headers=_supabase_headers(),
        json={"type": "signup", "email": email, "token": token},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or "验证失败"
        if "expired" in msg.lower() or "invalid" in msg.lower():
            msg = "验证码已过期或无效，请重新发送"
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "message": "邮箱验证成功",
        "access_token": data.get("access_token"),
        "refresh_token": data.get("refresh_token"),
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })


@app.route("/api/auth/resend", methods=["POST"])
def resend_verification():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    if not email:
        return jsonify({"error": "邮箱不能为空"}), 400
    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/resend",
        headers=_supabase_headers(),
        json={"type": "signup", "email": email},
        timeout=15,
    )
    if resp.status_code >= 400:
        return jsonify({"error": resp.json().get("msg", "发送失败")}), resp.status_code
    return jsonify({"message": "验证邮件已重新发送"})


@app.route("/api/auth/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers=_supabase_headers(),
        json={"email": email, "password": password},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or "登录失败"
        if "Invalid login" in msg:
            msg = "邮箱或密码错误"
        elif "Email not confirmed" in msg:
            msg = "邮箱未验证，请查收验证邮件"
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })


@app.route("/api/auth/refresh", methods=["POST"])
def refresh_token():
    body = request.get_json(silent=True) or {}
    rt = body.get("refresh_token", "")
    if not rt:
        return jsonify({"error": "refresh_token 不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token",
        headers=_supabase_headers(),
        json={"refresh_token": rt},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "刷新失败")}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })


@app.route("/api/auth/logout", methods=["POST"])
@require_auth
def logout():
    requests.post(f"{SUPABASE_URL}/auth/v1/logout",
                  headers=_supabase_headers(request.supabase_token), timeout=10)
    return jsonify({"message": "已登出"})


@app.route("/api/auth/user", methods=["GET"])
@require_auth
def get_user():
    return jsonify(_extract_user_info(request.supabase_user))


@app.route("/api/auth/user", methods=["PUT"])
@require_auth
def update_user():
    body = request.get_json(silent=True) or {}
    update_data = {}
    if "username" in body: update_data["username"] = body["username"]
    if "avatar_url" in body: update_data["avatar_url"] = body["avatar_url"]
    if not update_data:
        return jsonify({"error": "没有要更新的字段"}), 400

    resp = requests.put(f"{SUPABASE_URL}/auth/v1/user",
                        headers=_supabase_headers(request.supabase_token),
                        json={"data": update_data}, timeout=10)
    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "更新失败")}), resp.status_code
    return jsonify({"message": "更新成功", "user": _extract_user_info(data)})


@app.route("/api/auth/avatar", methods=["POST"])
@require_auth
def upload_avatar():
    body = request.get_json(silent=True) or {}
    avatar_base64 = body.get("avatar_base64", "")
    if not avatar_base64:
        return jsonify({"error": "avatar_base64 不能为空"}), 400
    if "," in avatar_base64:
        avatar_base64 = avatar_base64.split(",", 1)[1]
    try:
        image_bytes = base64.b64decode(avatar_base64)
    except Exception:
        return jsonify({"error": "无效的 Base64 数据"}), 400

    user_id = request.supabase_user.get("id", "unknown")
    file_name = f"{user_id}.png"
    upload_resp = requests.post(
        f"{SUPABASE_URL}/storage/v1/object/avatars/{file_name}",
        headers={"apikey": SUPABASE_SERVICE_KEY,
                 "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
                 "Content-Type": "image/png", "x-upsert": "true"},
        data=image_bytes, timeout=15,
    )
    if upload_resp.status_code >= 400:
        return jsonify({"error": f"存储上传失败: {upload_resp.text}"}), 502

    public_url = f"{SUPABASE_URL}/storage/v1/object/public/avatars/{file_name}"
    requests.put(f"{SUPABASE_URL}/auth/v1/user",
                 headers=_supabase_headers(request.supabase_token),
                 json={"data": {"avatar_url": public_url}}, timeout=10)
    return jsonify({"message": "头像更新成功", "avatar_url": public_url})


@app.route("/api/auth/quota", methods=["GET"])
@require_auth
def get_quota():
    """查询当前用户今日配额"""
    user_id = request.supabase_user.get("id")
    used, limit, remaining = _get_quota_info(user_id, request.user_role)
    return jsonify({
        "role": request.user_role,
        "used": used,
        "limit": limit,
        "remaining": remaining,
    })


# ══════════════════════════════════════════════════════════
# AI Chat (SSE) — 带配额检查 + JSON 代码块检测
# ══════════════════════════════════════════════════════════

def _load_dsl_spec():
    """加载 JSON-DSL.md 规范"""
    try:
        with open(DSL_SPEC_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def _load_registry_summary():
    """从 app_registry 加载已有 app/component 摘要"""
    try:
        rows = _db_query(
            "SELECT type, name, version, description, dsl_spec FROM public.app_registry "
            "WHERE is_public = true ORDER BY type, name"
        )
        if not rows:
            return ""
        lines = []
        for row in rows.split("\n"):
            parts = row.split("|")
            if len(parts) >= 4:
                t, n, v, d = parts[0], parts[1], parts[2], parts[3]
                spec = parts[4] if len(parts) > 4 else ""
                lines.append(f"- [{t}] {n} v{v}: {d}" + (f"\n  规格: {spec}" if spec else ""))
        return "\n".join(lines)
    except Exception:
        return ""


DSL_SYSTEM_PROMPT = """你是 JSON-DSL v3.3 应用设计师。用户通过语音与你交流，你帮助他们设计和生成 JSON-APP。

## 工作模式
1. **先讨论**：了解用户需求，确认功能点和 UI 风格。简单需求可以一轮直接生成。
2. **再生成**：用户确认后，输出完整可运行的 JSON-APP。
3. **可修改**：用户提出调整时，修改 JSON 并重新输出完整版本。
4. **崩溃修复**：如果用户发来崩溃日志，分析原因并输出修复后的完整 JSON。

## 输出要求
- JSON 必须包含 meta（name/version/type:"app"/description）
- 必须是完整可运行的 JSON-APP
- 用 ```json ... ``` 代码块包裹
- 回复尽量简洁，因为用户在手机上看字幕

## JSON-DSL 规范
{dsl_spec}

## 已注册的 APP 和组件（可通过 dependencies 引用）
{registry_summary}
"""


@app.route("/chat", methods=["POST"])
@require_auth
def chat():
    """SSE 流式 AI 对话 — 带配额检查和 JSON 检测"""
    user_id = request.supabase_user.get("id")
    role = request.user_role

    # 配额检查
    used, limit, remaining = _get_quota_info(user_id, role)
    if remaining <= 0:
        return jsonify({
            "error": f"今日对话次数已用完（{used}/{limit}）",
            "quota": {"used": used, "limit": limit, "remaining": 0},
        }), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    if not messages:
        return jsonify({"error": "messages is required"}), 400

    # 注入 DSL system prompt（如果消息列表第一条不是 system）
    if not messages or messages[0].get("role") != "system":
        dsl_spec = _load_dsl_spec()
        registry = _load_registry_summary()
        system_msg = DSL_SYSTEM_PROMPT.replace("{dsl_spec}", dsl_spec).replace("{registry_summary}", registry or "暂无")
        messages.insert(0, {"role": "system", "content": system_msg})

    # 递增配额
    _increment_quota(user_id)
    new_remaining = remaining - 1

    def generate():
        full_content = ""
        try:
            resp = requests.post(
                DEEPSEEK_URL,
                headers={"Content-Type": "application/json",
                         "Authorization": f"Bearer {DEEPSEEK_KEY}"},
                json={"model": DEEPSEEK_MODEL, "messages": messages, "stream": True},
                stream=True, timeout=120,
            )
            for line in resp.iter_lines(decode_unicode=True):
                if not line:
                    continue
                if line.startswith("data:"):
                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            full_content += content
                            event = json.dumps({"content": content}, ensure_ascii=False)
                            yield f"data: {event}\n\n"
                    except (json.JSONDecodeError, IndexError, KeyError):
                        pass

            # 流结束 — 检测是否包含 JSON 代码块
            json_match = re.search(r'```json\s*\n(.*?)\n```', full_content, re.DOTALL)
            if json_match:
                try:
                    json_app = json.loads(json_match.group(1))
                    event = json.dumps({
                        "has_json": True,
                        "json_app": json_app,
                    }, ensure_ascii=False)
                    yield f"data: {event}\n\n"
                except json.JSONDecodeError:
                    pass

            # 发送配额信息
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )


# ══════════════════════════════════════════════════════════
# AI 崩溃修复
# ══════════════════════════════════════════════════════════

@app.route("/api/ai/fix-app", methods=["POST"])
@require_auth
def fix_app():
    """接收崩溃日志 + JSON，返回修复建议"""
    body = request.get_json(silent=True) or {}
    crash_log = body.get("crash_log", "")
    json_config = body.get("json_config", "")

    if not crash_log or not json_config:
        return jsonify({"error": "crash_log 和 json_config 不能为空"}), 400

    # 不额外消耗配额，但需要登录
    prompt = f"""以下 JSON-APP 运行时崩溃了，请修复：

## 崩溃日志
{crash_log}

## 当前 JSON
```json
{json_config if isinstance(json_config, str) else json.dumps(json_config, ensure_ascii=False, indent=2)}
```

请分析原因并输出修复后的完整 JSON（用 ```json 代码块包裹）。"""

    dsl_spec = _load_dsl_spec()
    messages = [
        {"role": "system", "content": f"你是 JSON-DSL 调试专家。\n\n## 规范\n{dsl_spec}"},
        {"role": "user", "content": prompt},
    ]

    def generate():
        full_content = ""
        try:
            resp = requests.post(
                DEEPSEEK_URL,
                headers={"Content-Type": "application/json",
                         "Authorization": f"Bearer {DEEPSEEK_KEY}"},
                json={"model": DEEPSEEK_MODEL, "messages": messages, "stream": True},
                stream=True, timeout=120,
            )
            for line in resp.iter_lines(decode_unicode=True):
                if not line: continue
                if line.startswith("data:"):
                    data_str = line[5:].strip()
                    if data_str == "[DONE]": break
                    try:
                        chunk = json.loads(data_str)
                        content = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                        if content:
                            full_content += content
                            yield f'data: {json.dumps({"content": content}, ensure_ascii=False)}\n\n'
                    except Exception: pass

            json_match = re.search(r'```json\s*\n(.*?)\n```', full_content, re.DOTALL)
            if json_match:
                try:
                    fixed = json.loads(json_match.group(1))
                    yield f'data: {json.dumps({"has_json": True, "json_app": fixed}, ensure_ascii=False)}\n\n'
                except Exception: pass
            yield "data: [DONE]\n\n"
        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(stream_with_context(generate()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"})


# ══════════════════════════════════════════════════════════
# App Store — 基于 app_registry + MinIO
# ══════════════════════════════════════════════════════════

def _minio_upload(bucket, key, data, content_type="application/json"):
    """上传文件到 MinIO（使用 requests + 预签名 PUT 的简易方式）"""
    # 简易方案：用 mc 命令行上传
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        if isinstance(data, str):
            f.write(data)
        else:
            json.dump(data, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    result = subprocess.run(
        ["mc", "cp", tmp_path, f"app/{bucket}/{key}"],
        capture_output=True, text=True, timeout=30,
    )
    os.unlink(tmp_path)
    if result.returncode != 0:
        raise Exception(f"MinIO upload failed: {result.stderr}")
    return f"{MINIO_PUBLIC_URL}/{bucket}/{key}"


@app.route("/api/store/apps", methods=["GET"])
def store_apps():
    """列出所有公开 APP"""
    rows = _db_query(
        "SELECT id, name, version, description, author_name, download_url, tags "
        "FROM public.app_registry WHERE type = 'app' AND is_public = true ORDER BY created_at DESC"
    )
    apps = []
    if rows:
        for row in rows.split("\n"):
            parts = row.split("|")
            if len(parts) >= 6:
                apps.append({
                    "id": parts[0], "name": parts[1], "version": parts[2],
                    "description": parts[3], "author": parts[4],
                    "download_url": parts[5],
                    "tags": parts[6].strip("{}").split(",") if len(parts) > 6 and parts[6] else [],
                })
    return jsonify({"apps": apps})


@app.route("/api/store/components", methods=["GET"])
def store_components():
    """列出所有公开组件"""
    rows = _db_query(
        "SELECT id, name, version, description, author_name, download_url "
        "FROM public.app_registry WHERE type = 'component' AND is_public = true ORDER BY name"
    )
    components = []
    if rows:
        for row in rows.split("\n"):
            parts = row.split("|")
            if len(parts) >= 6:
                components.append({
                    "id": parts[0], "name": parts[1], "version": parts[2],
                    "description": parts[3], "author": parts[4],
                    "download_url": parts[5],
                })
    return jsonify({"components": components})


@app.route("/api/store/publish", methods=["POST"])
@require_auth
@require_role("pro", "admin")
def store_publish():
    """发布 JSON-APP/组件到市场"""
    body = request.get_json(silent=True) or {}
    json_content = body.get("json_content")
    if not json_content:
        return jsonify({"error": "json_content 不能为空"}), 400

    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "无效的 JSON"}), 400

    meta = json_content.get("meta", {})
    app_type = meta.get("type", "app")
    if app_type not in ("app", "component", "library"):
        return jsonify({"error": "meta.type 必须是 app 或 component"}), 400
    if app_type == "library":
        app_type = "component"

    name = meta.get("name", "unnamed")
    version = meta.get("version", "1.0.0")
    description = meta.get("description", "")
    dsl_spec = meta.get("dsl_spec", description)

    # 分配 ID
    prefix = "app" if app_type == "app" else "comp"
    app_id = f"{prefix}_{uuid.uuid4().hex[:8]}"

    # 写入 meta.id
    json_content.setdefault("meta", {})["id"] = app_id

    # 上传到 MinIO
    bucket = "json-app" if app_type == "app" else "json-component"
    oss_key = f"{app_id}/{name}-{version}.json"
    try:
        download_url = _minio_upload(bucket, oss_key, json_content)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

    # 写入 registry
    user = request.supabase_user
    user_id = user.get("id")
    author_name = user.get("user_metadata", {}).get("username", user.get("email", ""))
    _db_execute(
        "INSERT INTO public.app_registry "
        "(id, type, name, version, description, author_id, author_name, oss_bucket, oss_key, download_url, meta_json, dsl_spec) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [app_id, app_type, name, version, description, user_id, author_name,
         bucket, oss_key, download_url,
         json.dumps(meta, ensure_ascii=False), dsl_spec]
    )

    return jsonify({
        "message": "发布成功",
        "id": app_id,
        "download_url": download_url,
    })


@app.route("/api/store/delete/<app_id>", methods=["DELETE"])
@require_auth
def store_delete(app_id):
    """下架 APP/组件"""
    row = _db_query(f"SELECT author_id FROM public.app_registry WHERE id = $1", [app_id])
    if not row:
        return jsonify({"error": "未找到"}), 404

    user_id = request.supabase_user.get("id")
    if row != user_id and request.user_role != "admin":
        return jsonify({"error": "只有作者或管理员可以删除"}), 403

    _db_execute(f"DELETE FROM public.app_registry WHERE id = $1", [app_id])
    return jsonify({"message": "已删除"})


# ══════════════════════════════════════════════════════════
# 兼容旧市场接口（从 templates/ 读取）
# ══════════════════════════════════════════════════════════

def _scan_templates():
    apps = []
    if not os.path.isdir(TEMPLATES_DIR):
        return apps
    for fname in sorted(os.listdir(TEMPLATES_DIR)):
        if not fname.endswith(".json"): continue
        try:
            with open(os.path.join(TEMPLATES_DIR, fname), "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception: continue
        meta = data.get("meta", {})
        if meta.get("type") == "library" or "ui" not in data:
            continue
        apps.append({
            "file": fname,
            "name": meta.get("name", fname.replace(".json", "")),
            "version": meta.get("version", data.get("version", "?")),
            "description": meta.get("description", ""),
            "author": meta.get("author", ""),
            "download": f"/download/{urllib.parse.quote(fname)}",
        })
    return apps


@app.route("/app-list")
def app_list():
    return jsonify({"apps": _scan_templates()})


@app.route("/download/<path:fname>")
def download_file(fname):
    if ".." in fname or "/" in fname:
        return jsonify({"error": "Invalid"}), 403
    return send_from_directory(os.path.abspath(TEMPLATES_DIR), fname, mimetype="application/json")


# ══════════════════════════════════════════════════════════
# 豆包 ASR — 实时流式语音识别 (WebSocket 双向代理)
# ══════════════════════════════════════════════════════════

DOUBAO_ASR_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
DOUBAO_APP_ID = "7743486317"
DOUBAO_ACCESS_KEY = "J0z68ifh_njxKDL_ukJXFMBabaf5cUcV"
DOUBAO_RESOURCE_ID = "volc.seedasr.sauc.duration"


def _asr_header(msg_type, flags, serial, compress):
    return bytes([(0x1 << 4) | 0x1, (msg_type << 4) | flags, (serial << 4) | compress, 0x00])


def _asr_parse(data):
    """解析豆包二进制响应 -> 识别文本"""
    import struct as st, gzip as gz
    if len(data) < 4 or ((data[1] >> 4) & 0xF) != 0x9:
        return None
    off = 8
    if len(data) < off + 4:
        return None
    ps = st.unpack('>I', data[off:off+4])[0]
    raw = data[off+4:off+4+ps]
    if (data[2] & 0xF) == 0x1:
        raw = gz.decompress(raw)
    return json.loads(raw).get("result", {}).get("text")


@sock.route("/api/asr/ws")
def asr_websocket(ws):
    """
    WebSocket 实时 ASR 代理:
      1. 客户端发文本 {"token":"Bearer xxx"} 鉴权
      2. 客户端发二进制: PCM 音频块 (16kHz 16bit mono, 每包200ms=6400B)
      3. 客户端发文本 "END" 结束
      4. 服务端返文本: {"text":"实时识别"} / {"error":"..."}
    """
    import websocket as ws_lib
    import struct, gzip, threading

    print("[ASR] WebSocket connected")

    # 鉴权
    try:
        auth_data = json.loads(ws.receive(timeout=10))
        token = auth_data.get("token", "").replace("Bearer ", "")
        r = requests.get(f"{SUPABASE_URL}/auth/v1/user",
                         headers=_supabase_headers(token), timeout=5)
        if r.status_code != 200:
            print(f"[ASR] Auth failed: {r.status_code}")
            ws.send(json.dumps({"error": "认证失败"})); return
        ws.send(json.dumps({"status": "ready"}))
        print("[ASR] Auth OK, sent ready")
    except Exception as e:
        print(f"[ASR] Auth error: {e}")
        ws.send(json.dumps({"error": f"认证异常: {e}"})); return

    # 连接豆包
    try:
        dws = ws_lib.create_connection(DOUBAO_ASR_URL, header=[
            f"X-Api-App-Key: {DOUBAO_APP_ID}",
            f"X-Api-Access-Key: {DOUBAO_ACCESS_KEY}",
            f"X-Api-Resource-Id: {DOUBAO_RESOURCE_ID}",
            f"X-Api-Connect-Id: {str(uuid.uuid4())}",
        ], timeout=15)
        print("[ASR] Doubao connected")
    except Exception as e:
        print(f"[ASR] Doubao connect failed: {e}")
        ws.send(json.dumps({"error": f"ASR连接失败: {e}"})); return

    # full client request
    params = {
        "user": {"uid": "app"},
        "audio": {"format": "pcm", "rate": 16000, "bits": 16, "channel": 1, "language": "zh-CN"},
        "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True, "result_type": "full"},
    }
    pl = gzip.compress(json.dumps(params).encode())
    dws.send(_asr_header(0x1, 0x0, 0x1, 0x1) + struct.pack('>I', len(pl)) + pl, opcode=0x2)
    dws.recv()
    print("[ASR] Doubao session started")

    # 后台线程：读豆包结果推给客户端
    stop = threading.Event()
    audio_chunks = [0]  # 计数器
    def reader():
        while not stop.is_set():
            try:
                dws.settimeout(0.3)
                resp = dws.recv()
                if resp:
                    text = _asr_parse(resp)
                    if text is not None:
                        print(f"[ASR] Result: {text}")
                        ws.send(json.dumps({"text": text}, ensure_ascii=False))
            except ws_lib.WebSocketTimeoutException:
                continue
            except Exception as ex:
                print(f"[ASR] Reader error: {ex}")
                break
    t = threading.Thread(target=reader, daemon=True)
    t.start()

    # 主循环：客户端音频转发豆包
    try:
        while True:
            msg = ws.receive(timeout=60)
            if msg is None:
                print("[ASR] Client disconnected")
                break
            if isinstance(msg, str):
                if msg.strip().upper() == "END":
                    print(f"[ASR] END received, total audio chunks: {audio_chunks[0]}")
                    emp = gzip.compress(b'')
                    dws.send(_asr_header(0x2, 0x2, 0x0, 0x1) + struct.pack('>I', len(emp)) + emp, opcode=0x2)
                    import time; time.sleep(0.8)
                    break
                print(f"[ASR] Unexpected text msg: {msg[:100]}")
                continue
            audio_chunks[0] += 1
            if audio_chunks[0] <= 3 or audio_chunks[0] % 50 == 0:
                print(f"[ASR] Audio chunk #{audio_chunks[0]}, size={len(msg)}B")
            c = gzip.compress(msg)
            dws.send(_asr_header(0x2, 0x0, 0x0, 0x1) + struct.pack('>I', len(c)) + c, opcode=0x2)
    except Exception as ex:
        print(f"[ASR] Main loop error: {ex}")
    finally:
        print(f"[ASR] Session end, total chunks: {audio_chunks[0]}")
        stop.set(); t.join(timeout=2); dws.close()


# ══════════════════════════════════════════════════════════
# CORS
# ══════════════════════════════════════════════════════════

@app.after_request
def after_request(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response

@app.route("/", defaults={"path": ""}, methods=["OPTIONS"])
@app.route("/<path:path>", methods=["OPTIONS"])
def options_handler(path):
    return "", 204


# ══════════════════════════════════════════════════════════
# 启动
# ══════════════════════════════════════════════════════════

if __name__ == "__main__":
    print(f"🚀 JSON DSL Backend on http://0.0.0.0:{PORT}")
    print(f"   Auth:  /api/auth/{{register,login,verify,refresh,logout,user,avatar,quota}}")
    print(f"   Chat:  POST /chat (SSE, quota-limited, DSL-aware)")
    print(f"   Fix:   POST /api/ai/fix-app (crash repair)")
    print(f"   Store: /api/store/{{apps,components,publish,delete}}")
    print(f"   Old:   /app-list, /download/<file>")
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
