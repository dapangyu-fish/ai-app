#!/usr/bin/env python3
"""
认证模块 - 用户认证相关接口
"""

import base64
import os
import time
import requests
from functools import wraps
from flask import request, jsonify
from config import (
    SUPABASE_URL, SUPABASE_INTERNAL_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY,
    ROLE_QUOTAS
)
from database import get_quota_info


def _supabase_headers(token=None):
    """生成 Supabase 请求头"""
    h = {"apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _service_headers():
    """生成 Supabase 服务端请求头"""
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


def ensure_avatar_bucket():
    """确保 Supabase Storage 的 `avatars` 桶存在（public-read，头像走公共 URL）。幂等。

    头像上传写 `storage/v1/object/avatars/...`、读 `.../object/public/avatars/...`，
    但这个桶此前没有任何地方创建 → 首次上传报 404「Bucket not found」。本函数在
    **部署期**（myapp-ctl deploy）与**上传遇 404 时**都会调用，二者均幂等。返回 True=已就绪。"""
    try:
        resp = requests.post(
            f"{SUPABASE_INTERNAL_URL}/storage/v1/bucket",
            headers=_service_headers(),
            json={"id": "avatars", "name": "avatars", "public": True},
            timeout=10,
        )
    except Exception as e:  # noqa: BLE001 — 网络异常不应让调用方崩
        print(f"[avatar] ensure bucket 异常: {e}")
        return False
    body = (resp.text or "").lower()
    # 200/201=新建；已存在时 Supabase 返回含 "already exists"/"Duplicate"（status 多为 400/409）
    if resp.status_code in (200, 201) or "exist" in body or "duplicate" in body:
        return True
    print(f"[avatar] ensure bucket 失败 {resp.status_code}: {resp.text[:200]}")
    return False


def _get_user_role(user):
    """从 app_metadata 获取角色，默认 user"""
    return user.get("app_metadata", {}).get("role", "user")


def _extract_user_info(user):
    """从 Supabase 用户对象提取用户信息"""
    meta = user.get("user_metadata", {})
    return {
        "id": str(user.get("id", "")),
        "email": user.get("email", ""),
        "username": meta.get("username", ""),
        "avatar_url": meta.get("avatar_url", ""),
        "role": _get_user_role(user),
    }


def find_user_by_email(email):
    """
    通过邮箱查找 Supabase 用户 ID
    使用 Supabase Admin API

    Returns:
        user_id (str) 或 None
    """
    try:
        # 使用 Supabase Admin API 列出用户
        resp = requests.get(
            f"{SUPABASE_INTERNAL_URL}/auth/v1/admin/users",
            headers=_service_headers(),
            timeout=10,
        )

        if resp.status_code != 200:
            print(f"[Auth] Failed to fetch users: {resp.status_code}")
            return None

        data = resp.json()
        users = data.get("users", [])

        # 查找匹配的邮箱
        for user in users:
            if user.get("email", "").lower() == email.lower():
                return user.get("id")

        return None
    except Exception as e:
        print(f"[Auth] Error finding user by email: {e}")
        return None


def find_user_by_phone(phone):
    """
    通过手机号查找 Supabase 用户 ID
    使用 Supabase Admin API

    注意：目前 Supabase 还未启用手机号注册，此函数预留接口

    Returns:
        user_id (str) 或 None
    """
    try:
        # 使用 Supabase Admin API 列出用户
        resp = requests.get(
            f"{SUPABASE_INTERNAL_URL}/auth/v1/admin/users",
            headers=_service_headers(),
            timeout=10,
        )

        if resp.status_code != 200:
            print(f"[Auth] Failed to fetch users: {resp.status_code}")
            return None

        data = resp.json()
        users = data.get("users", [])

        # 查找匹配的手机号
        for user in users:
            if user.get("phone", "") == phone:
                return user.get("id")

        return None
    except Exception as e:
        print(f"[Auth] Error finding user by phone: {e}")
        return None


def require_auth(f):
    """装饰器：要求用户登录"""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "未提供认证 token"}), 401
        token = auth[7:]
        user = verify_access_token(token)
        if user is None:
            return jsonify({"error": "token 无效或已过期"}), 401
        request.supabase_user = user
        request.supabase_token = token
        request.user_role = _get_user_role(request.supabase_user)
        return f(*args, **kwargs)
    return decorated


def verify_access_token(token):
    """校验 Supabase access token，成功返回 user dict，失败返回 None。"""
    if not token:
        return None
    resp = requests.get(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/user",
        headers=_supabase_headers(token),
        timeout=10,
    )
    if resp.status_code != 200:
        return None
    return resp.json()


def require_auth_socketio(f):
    """装饰器：SocketIO 事件要求用户登录"""
    @wraps(f)
    def decorated(*args, **kwargs):
        # SocketIO 通过 request.args 传递 token
        token = request.args.get("token", "")
        if not token:
            from flask_socketio import emit
            emit('asr_error', {"error": "未提供认证 token"})
            return

        resp = requests.get(
            f"{SUPABASE_INTERNAL_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=10,
        )
        if resp.status_code != 200:
            from flask_socketio import emit
            emit('asr_error', {"error": "token 无效或已过期"})
            return

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


def register():
    """用户注册"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    username = body.get("username", "").strip()

    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400
    if len(password) < 6:
        return jsonify({"error": "密码至少 6 位"}), 400

    resp = requests.post(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/signup",
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


def verify_otp():
    """验证邮箱 OTP"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    token = body.get("token", "").strip()
    if not email or not token:
        return jsonify({"error": "邮箱和验证码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/verify",
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


def resend_verification():
    """重新发送验证邮件"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    if not email:
        return jsonify({"error": "邮箱不能为空"}), 400
    resp = requests.post(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/resend",
        headers=_supabase_headers(),
        json={"type": "signup", "email": email},
        timeout=15,
    )
    if resp.status_code >= 400:
        return jsonify({"error": resp.json().get("msg", "发送失败")}), resp.status_code
    return jsonify({"message": "验证邮件已重新发送"})


def login():
    """用户登录"""
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/token?grant_type=password",
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


def refresh_token():
    """刷新 Token"""
    body = request.get_json(silent=True) or {}
    rt = body.get("refresh_token", "")
    if not rt:
        return jsonify({"error": "refresh_token 不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_INTERNAL_URL}/auth/v1/token?grant_type=refresh_token",
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


def demo_login():
    """Demo 模式登录：用预置的专用 demo 账号做 password grant，拿到一个**真实可验证**的 JWT。
    FaaS 公共组靠这个 JWT 派生不可伪造的组内假名（HMAC(secret, app_id‖uid)），从而把
    demo 账号的数据与真实用户隔离。账号需在部署主机预先创建（见 demo-replay 运维清单），
    凭据放在后端 env（DEMO_ACCOUNT_EMAIL / DEMO_ACCOUNT_PASSWORD），绝不下发到客户端。"""
    email = os.environ.get("DEMO_ACCOUNT_EMAIL", "").strip()
    password = os.environ.get("DEMO_ACCOUNT_PASSWORD", "").strip()
    if not email or not password:
        return jsonify({"error": "demo 模式未配置", "code": "DEMO_NOT_CONFIGURED"}), 503
    try:
        resp = requests.post(
            f"{SUPABASE_INTERNAL_URL}/auth/v1/token?grant_type=password",
            headers=_supabase_headers(),
            json={"email": email, "password": password},
            timeout=15,
        )
        data = resp.json()
    except Exception:
        return jsonify({"error": "demo 账号暂不可用", "code": "DEMO_UNAVAILABLE"}), 503
    if resp.status_code >= 400 or "access_token" not in data:
        return jsonify({"error": "demo 账号暂不可用", "code": "DEMO_UNAVAILABLE"}), 503
    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
        "demo": True,
    })


@require_auth
def logout():
    """用户登出"""
    requests.post(f"{SUPABASE_INTERNAL_URL}/auth/v1/logout",
                  headers=_supabase_headers(request.supabase_token), timeout=10)
    return jsonify({"message": "已登出"})


@require_auth
def get_user():
    """获取当前用户信息"""
    return jsonify(_extract_user_info(request.supabase_user))


@require_auth
def update_user():
    """更新用户信息"""
    body = request.get_json(silent=True) or {}
    update_data = {}
    if "username" in body: update_data["username"] = body["username"]
    if "avatar_url" in body: update_data["avatar_url"] = body["avatar_url"]
    if not update_data:
        return jsonify({"error": "没有要更新的字段"}), 400

    resp = requests.put(f"{SUPABASE_INTERNAL_URL}/auth/v1/user",
                        headers=_supabase_headers(request.supabase_token),
                        json={"data": update_data}, timeout=10)
    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "更新失败")}), resp.status_code
    return jsonify({"message": "更新成功", "user": _extract_user_info(data)})


@require_auth
def upload_avatar():
    """上传头像"""
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

    def _do_upload():
        return requests.post(
            f"{SUPABASE_INTERNAL_URL}/storage/v1/object/avatars/{file_name}",
            headers={"apikey": SUPABASE_SERVICE_KEY,
                     "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
                     "Content-Type": "image/png", "x-upsert": "true"},
            data=image_bytes, timeout=15,
        )

    upload_resp = _do_upload()
    if upload_resp.status_code == 404:
        # avatars 桶不存在（部署期未建或被删）→ 现场建桶并重试，自愈
        ensure_avatar_bucket()
        upload_resp = _do_upload()
    if upload_resp.status_code >= 400:
        return jsonify({"error": f"存储上传失败: {upload_resp.text}"}), 502

    public_url = f"{SUPABASE_URL}/storage/v1/object/public/avatars/{file_name}?t={int(time.time())}"
    meta_resp = requests.put(f"{SUPABASE_INTERNAL_URL}/auth/v1/user",
                 headers=_supabase_headers(request.supabase_token),
                 json={"data": {"avatar_url": public_url}}, timeout=10)
    if meta_resp.status_code >= 400:
        return jsonify({"error": f"头像已上传但更新用户信息失败: {meta_resp.text}"}), 502
    return jsonify({"message": "头像更新成功", "avatar_url": public_url})


@require_auth
def get_quota():
    """获取用户配额"""
    user_id = request.supabase_user.get("id")
    used, limit, remaining = get_quota_info(
        user_id, request.user_role, ROLE_QUOTAS,
        app_metadata=request.supabase_user.get("app_metadata"),
    )
    return jsonify({
        "role": request.user_role,
        "used": used,
        "limit": limit,
        "remaining": remaining,
    })
