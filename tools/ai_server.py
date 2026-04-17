#!/usr/bin/env python3
"""
JSON DSL Backend — Flask + Supabase Auth Proxy + AI Chat (SSE) + Marketplace

启动: python3 tools/ai_server.py
"""

import json
import os
import base64
import uuid
import urllib.parse
from functools import wraps

import requests
from flask import Flask, request, jsonify, Response, stream_with_context, send_from_directory

# ══════════════════════════════════════════════════════════
# 配置
# ══════════════════════════════════════════════════════════

SUPABASE_URL = "http://103.233.254.179:8000"
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

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"
DEEPSEEK_MODEL = "deepseek-chat"

PORT = 5566
TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates")

app = Flask(__name__)


# ══════════════════════════════════════════════════════════
# 工具函数
# ══════════════════════════════════════════════════════════

def _supabase_headers(token=None):
    """构建 Supabase 请求头"""
    h = {
        "apikey": SUPABASE_ANON_KEY,
        "Content-Type": "application/json",
    }
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _service_headers():
    """使用 service_role key 的请求头（管理员操作）"""
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


def require_auth(f):
    """装饰器：要求 Authorization header 中的 Bearer token"""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "未提供认证 token"}), 401
        token = auth[7:]
        # 向 Supabase 验证 token
        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=10,
        )
        if resp.status_code != 200:
            return jsonify({"error": "token 无效或已过期"}), 401
        request.supabase_user = resp.json()
        request.supabase_token = token
        return f(*args, **kwargs)
    return decorated


# ══════════════════════════════════════════════════════════
# Auth API
# ══════════════════════════════════════════════════════════

@app.route("/api/auth/register", methods=["POST"])
def register():
    """注册（邮箱+密码），会发送验证邮件"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    username = body.get("username", "").strip()

    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400
    if len(password) < 6:
        return jsonify({"error": "密码至少 6 位"}), 400

    # 注册
    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/signup",
        headers=_supabase_headers(),
        json={
            "email": email,
            "password": password,
            "data": {"username": username or email.split("@")[0]},
        },
        timeout=15,
    )

    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or data.get("message") or str(data)
        return jsonify({"error": msg}), resp.status_code

    # 检查是否需要邮箱确认
    user = data.get("user", {})
    needs_confirm = user.get("email_confirmed_at") is None

    result = {
        "message": "注册成功，请查收验证邮件" if needs_confirm else "注册成功",
        "needs_confirm": needs_confirm,
        "user": {
            "id": user.get("id"),
            "email": user.get("email"),
            "username": user.get("user_metadata", {}).get("username", ""),
        },
    }

    # 如果已自动确认，返回 token
    if not needs_confirm and data.get("access_token"):
        result["access_token"] = data["access_token"]
        result["refresh_token"] = data["refresh_token"]
        result["expires_in"] = data.get("expires_in", 3600)

    return jsonify(result), 200


@app.route("/api/auth/verify", methods=["POST"])
def verify_otp():
    """验证邮箱 OTP 验证码"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    token = body.get("token", "").strip()

    if not email or not token:
        return jsonify({"error": "邮箱和验证码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/verify",
        headers=_supabase_headers(),
        json={
            "type": "signup",
            "email": email,
            "token": token,
        },
        timeout=15,
    )

    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or "验证失败"
        if "expired" in msg.lower() or "invalid" in msg.lower():
            msg = "验证码已过期或无效，请重新发送"
        return jsonify({"error": msg}), resp.status_code

    # 验证成功，返回 token
    user = data.get("user", {})
    return jsonify({
        "message": "邮箱验证成功",
        "access_token": data.get("access_token"),
        "refresh_token": data.get("refresh_token"),
        "expires_in": data.get("expires_in", 3600),
        "user": {
            "id": user.get("id"),
            "email": user.get("email"),
            "username": user.get("user_metadata", {}).get("username", ""),
            "avatar_url": user.get("user_metadata", {}).get("avatar_url", ""),
        },
    })


@app.route("/api/auth/resend", methods=["POST"])
def resend_verification():
    """重新发送验证邮件"""
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
        data = resp.json()
        msg = data.get("msg") or "发送失败"
        return jsonify({"error": msg}), resp.status_code

    return jsonify({"message": "验证邮件已重新发送"})


@app.route("/api/auth/login", methods=["POST"])
def login():
    """登录（邮箱+密码）"""
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
        msg = data.get("msg") or data.get("error_description") or data.get("message", "登录失败")
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
        "user": {
            "id": user.get("id"),
            "email": user.get("email"),
            "username": user.get("user_metadata", {}).get("username", ""),
            "avatar_url": user.get("user_metadata", {}).get("avatar_url", ""),
        },
    })


@app.route("/api/auth/refresh", methods=["POST"])
def refresh_token():
    """刷新 access_token"""
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
        msg = data.get("msg") or data.get("error_description") or "刷新失败"
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": {
            "id": user.get("id"),
            "email": user.get("email"),
            "username": user.get("user_metadata", {}).get("username", ""),
            "avatar_url": user.get("user_metadata", {}).get("avatar_url", ""),
        },
    })


@app.route("/api/auth/logout", methods=["POST"])
@require_auth
def logout():
    """登出"""
    requests.post(
        f"{SUPABASE_URL}/auth/v1/logout",
        headers=_supabase_headers(request.supabase_token),
        timeout=10,
    )
    return jsonify({"message": "已登出"})


@app.route("/api/auth/user", methods=["GET"])
@require_auth
def get_user():
    """获取当前用户信息"""
    user = request.supabase_user
    meta = user.get("user_metadata", {})
    return jsonify({
        "id": user.get("id"),
        "email": user.get("email"),
        "username": meta.get("username", ""),
        "avatar_url": meta.get("avatar_url", ""),
        "created_at": user.get("created_at"),
    })


@app.route("/api/auth/user", methods=["PUT"])
@require_auth
def update_user():
    """修改用户名 / 头像"""
    body = request.get_json(silent=True) or {}
    update_data = {}

    if "username" in body:
        update_data["username"] = body["username"]
    if "avatar_url" in body:
        update_data["avatar_url"] = body["avatar_url"]

    if not update_data:
        return jsonify({"error": "没有要更新的字段"}), 400

    resp = requests.put(
        f"{SUPABASE_URL}/auth/v1/user",
        headers=_supabase_headers(request.supabase_token),
        json={"data": update_data},
        timeout=10,
    )

    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "更新失败")}), resp.status_code

    meta = data.get("user_metadata", {})
    return jsonify({
        "message": "更新成功",
        "user": {
            "id": data.get("id"),
            "email": data.get("email"),
            "username": meta.get("username", ""),
            "avatar_url": meta.get("avatar_url", ""),
        },
    })


@app.route("/api/auth/avatar", methods=["POST"])
@require_auth
def upload_avatar():
    """上传头像（Base64）→ Supabase Storage avatars 桶 → 更新 user_metadata"""
    body = request.get_json(silent=True) or {}
    avatar_base64 = body.get("avatar_base64", "")

    if not avatar_base64:
        return jsonify({"error": "avatar_base64 不能为空"}), 400

    # 去掉 data URI 前缀
    if "," in avatar_base64:
        avatar_base64 = avatar_base64.split(",", 1)[1]

    try:
        image_bytes = base64.b64decode(avatar_base64)
    except Exception:
        return jsonify({"error": "无效的 Base64 数据"}), 400

    user_id = request.supabase_user.get("id", "unknown")
    file_name = f"{user_id}.png"

    # 上传到 Supabase Storage (用 service_role key 绕过 RLS)
    upload_resp = requests.post(
        f"{SUPABASE_URL}/storage/v1/object/avatars/{file_name}",
        headers={
            "apikey": SUPABASE_SERVICE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
            "Content-Type": "image/png",
            "x-upsert": "true",  # 覆盖已有文件
        },
        data=image_bytes,
        timeout=15,
    )

    if upload_resp.status_code >= 400:
        return jsonify({"error": f"存储上传失败: {upload_resp.text}"}), 502

    # 公开访问 URL
    public_url = f"{SUPABASE_URL}/storage/v1/object/public/avatars/{file_name}"

    # 更新 user_metadata.avatar_url 为存储 URL
    requests.put(
        f"{SUPABASE_URL}/auth/v1/user",
        headers=_supabase_headers(request.supabase_token),
        json={"data": {"avatar_url": public_url}},
        timeout=10,
    )

    return jsonify({"message": "头像更新成功", "avatar_url": public_url})


# ══════════════════════════════════════════════════════════
# AI Chat (SSE)
# ══════════════════════════════════════════════════════════

@app.route("/chat", methods=["POST"])
def chat():
    """SSE 流式 AI 对话"""
    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])

    if not messages:
        return jsonify({"error": "messages is required"}), 400

    def generate():
        try:
            resp = requests.post(
                DEEPSEEK_URL,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {DEEPSEEK_KEY}",
                },
                json={
                    "model": DEEPSEEK_MODEL,
                    "messages": messages,
                    "stream": True,
                },
                stream=True,
                timeout=60,
            )

            for line in resp.iter_lines(decode_unicode=True):
                if not line:
                    continue
                if line.startswith("data:"):
                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        yield "data: [DONE]\n\n"
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            event = json.dumps({"content": content}, ensure_ascii=False)
                            yield f"data: {event}\n\n"
                    except (json.JSONDecodeError, IndexError, KeyError):
                        pass
        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
        },
    )


# ══════════════════════════════════════════════════════════
# Marketplace
# ══════════════════════════════════════════════════════════

def _scan_market():
    apps, components = [], []
    if not os.path.isdir(TEMPLATES_DIR):
        return apps, components

    for fname in sorted(os.listdir(TEMPLATES_DIR)):
        if not fname.endswith(".json"):
            continue
        fpath = os.path.join(TEMPLATES_DIR, fname)
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue

        meta = data.get("meta", {})
        entry = {
            "file": fname,
            "name": meta.get("name", fname.replace(".json", "")),
            "version": meta.get("version", data.get("version", "unknown")),
            "description": meta.get("description", ""),
            "author": meta.get("author", ""),
            "download": f"/download/{urllib.parse.quote(fname)}",
        }

        if meta.get("type") == "library":
            entry["exports"] = meta.get("exports", [])
            components.append(entry)
        elif "ui" in data:
            apps.append(entry)
        else:
            entry["exports"] = meta.get("exports", [])
            components.append(entry)

    return apps, components


@app.route("/app-list")
def app_list():
    apps, _ = _scan_market()
    return jsonify({"apps": apps})


@app.route("/component-list")
def component_list():
    _, components = _scan_market()
    return jsonify({"components": components})


@app.route("/download/<path:fname>")
def download_file(fname):
    if ".." in fname or "/" in fname or "\\" in fname:
        return jsonify({"error": "Invalid filename"}), 403
    return send_from_directory(
        os.path.abspath(TEMPLATES_DIR), fname,
        mimetype="application/json",
    )


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
    print(f"   POST /api/auth/register  — 注册")
    print(f"   POST /api/auth/login     — 登录")
    print(f"   POST /api/auth/refresh   — 刷新 token")
    print(f"   POST /api/auth/logout    — 登出")
    print(f"   GET  /api/auth/user      — 获取用户信息")
    print(f"   PUT  /api/auth/user      — 修改用户名/头像")
    print(f"   POST /api/auth/avatar    — 上传头像(base64)")
    print(f"   POST /chat               — AI 对话 (SSE)")
    print(f"   GET  /app-list           — App 市场")
    print(f"   GET  /download/<file>    — 下载 JSON")
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
