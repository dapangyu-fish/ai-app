#!/usr/bin/env python3
"""
认证模块 - 用户认证相关接口
"""

import base64
import time
import requests
from functools import wraps
from flask import request, jsonify
from config import (
    SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY,
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


def require_auth(f):
    """装饰器：要求用户登录"""
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


def verify_otp():
    """验证邮箱 OTP"""
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


def refresh_token():
    """刷新 Token"""
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


@require_auth
def logout():
    """用户登出"""
    requests.post(f"{SUPABASE_URL}/auth/v1/logout",
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

    resp = requests.put(f"{SUPABASE_URL}/auth/v1/user",
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
    upload_resp = requests.post(
        f"{SUPABASE_URL}/storage/v1/object/avatars/{file_name}",
        headers={"apikey": SUPABASE_SERVICE_KEY,
                 "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
                 "Content-Type": "image/png", "x-upsert": "true"},
        data=image_bytes, timeout=15,
    )
    if upload_resp.status_code >= 400:
        return jsonify({"error": f"存储上传失败: {upload_resp.text}"}), 502

    public_base_url = os.environ.get("SUPABASE_PUBLIC_URL", "https://app-auth.dapangyu.work")
    public_url = f"{public_base_url}/storage/v1/object/public/avatars/{file_name}?t={int(time.time())}"
    meta_resp = requests.put(f"{SUPABASE_URL}/auth/v1/user",
                 headers=_supabase_headers(request.supabase_token),
                 json={"data": {"avatar_url": public_url}}, timeout=10)
    if meta_resp.status_code >= 400:
        return jsonify({"error": f"头像已上传但更新用户信息失败: {meta_resp.text}"}), 502
    return jsonify({"message": "头像更新成功", "avatar_url": public_url})


@require_auth
def get_quota():
    """获取用户配额"""
    user_id = request.supabase_user.get("id")
    used, limit, remaining = get_quota_info(user_id, request.user_role, ROLE_QUOTAS)
    return jsonify({
        "role": request.user_role,
        "used": used,
        "limit": limit,
        "remaining": remaining,
    })
