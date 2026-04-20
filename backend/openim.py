#!/usr/bin/env python3
"""
OpenIM 集成模块 - 桥接 Supabase 用户系统与 OpenIM

职责:
1. 用户注册/登录时自动在 OpenIM 注册并获取 userToken
2. 代理客户端获取 OpenIM token (避免暴露 adminToken/secret)
3. 提供 FCM 推送 token 注册接口
"""

import hashlib
import logging
import time

import requests
from flask import Blueprint, jsonify, request

from config import OPENIM_API_URL, OPENIM_ADMIN_SECRET, OPENIM_WS_URL

logger = logging.getLogger(__name__)

openim_bp = Blueprint("openim", __name__, url_prefix="/api/im")

# ---------- 内部工具 ----------

def _admin_headers():
    """OpenIM Admin API 通用请求头"""
    return {
        "Content-Type": "application/json",
        "operationID": f"admin_{int(time.time()*1000)}",
    }


def _get_admin_token() -> str:
    """获取 OpenIM admin token (用于服务端管理操作)"""
    resp = requests.post(
        f"{OPENIM_API_URL}/auth/get_admin_token",
        json={"secret": OPENIM_ADMIN_SECRET, "userID": "imAdmin"},
        headers=_admin_headers(),
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()
    if data.get("errCode") != 0:
        raise Exception(f"获取 admin token 失败: {data.get('errMsg')}")
    return data["data"]["token"]


def _openim_user_id(supabase_uid: str) -> str:
    """将 Supabase UUID 映射为 OpenIM userID (去掉连字符, 保持唯一)"""
    return supabase_uid.replace("-", "")


def _register_openim_user(admin_token: str, user_id: str, nickname: str, face_url: str = "") -> bool:
    """在 OpenIM Server 注册用户"""
    resp = requests.post(
        f"{OPENIM_API_URL}/user/user_register",
        json={
            "users": [{
                "userID": user_id,
                "nickname": nickname,
                "faceURL": face_url,
            }]
        },
        headers={
            **_admin_headers(),
            "token": admin_token,
        },
        timeout=10,
    )
    data = resp.json()
    if data.get("errCode") == 0:
        return True
    if "already" in data.get("errMsg", "").lower() or data.get("errCode") == 1101:
        logger.info(f"OpenIM 用户 {user_id} 已存在, 跳过注册")
        return True
    logger.error(f"OpenIM 注册失败: {data}")
    return False


def _get_user_token(admin_token: str, user_id: str, platform_id: int = 5) -> str:
    """
    获取 OpenIM 用户 token
    platformID: 1=iOS, 2=Android, 3=Windows, 4=macOS, 5=Web, 7=Linux, 8=Flutter
    """
    resp = requests.post(
        f"{OPENIM_API_URL}/auth/get_user_token",
        json={
            "userID": user_id,
            "platformID": platform_id,
        },
        headers={
            **_admin_headers(),
            "token": admin_token,
        },
        timeout=10,
    )
    data = resp.json()
    if data.get("errCode") != 0:
        raise Exception(f"获取 user token 失败: {data.get('errMsg')}")
    return data["data"]["token"]


# ---------- API 路由 ----------

@openim_bp.route("/token", methods=["POST"])
def get_im_token():
    """
    客户端登录后调用此接口获取 OpenIM 连接凭证

    请求: { "platform": 2 }   // 1=iOS, 2=Android, 5=Web, 8=Flutter
    需要: Authorization: Bearer <supabase_token>

    响应: {
        "im_user_id": "xxx",
        "im_token": "xxx",
        "ws_url": "ws://xxx:10001",
        "api_url": "http://xxx:10002"
    }
    """
    from auth import get_current_user

    user = get_current_user()
    if not user:
        return jsonify({"error": "未登录"}), 401

    platform_id = request.json.get("platform", 8) if request.is_json else 8

    try:
        admin_token = _get_admin_token()

        im_user_id = _openim_user_id(user["id"])
        nickname = user.get("username") or user.get("email", "").split("@")[0]
        face_url = user.get("avatar_url", "")

        _register_openim_user(admin_token, im_user_id, nickname, face_url)

        im_token = _get_user_token(admin_token, im_user_id, platform_id)

        return jsonify({
            "im_user_id": im_user_id,
            "im_token": im_token,
            "ws_url": OPENIM_WS_URL,
            "api_url": OPENIM_API_URL,
        })
    except Exception as e:
        logger.exception("获取 IM token 失败")
        return jsonify({"error": str(e)}), 500


@openim_bp.route("/update_profile", methods=["POST"])
def update_im_profile():
    """
    同步用户资料到 OpenIM (昵称/头像变更时调用)

    请求: { "nickname": "新昵称", "face_url": "https://..." }
    """
    from auth import get_current_user

    user = get_current_user()
    if not user:
        return jsonify({"error": "未登录"}), 401

    body = request.get_json(force=True)
    im_user_id = _openim_user_id(user["id"])

    try:
        admin_token = _get_admin_token()

        update_data = {"userID": im_user_id}
        if "nickname" in body:
            update_data["nickname"] = body["nickname"]
        if "face_url" in body:
            update_data["faceURL"] = body["face_url"]

        resp = requests.post(
            f"{OPENIM_API_URL}/user/update_user_info",
            json={"userInfo": update_data},
            headers={**_admin_headers(), "token": admin_token},
            timeout=10,
        )
        data = resp.json()
        if data.get("errCode") != 0:
            return jsonify({"error": data.get("errMsg")}), 500

        return jsonify({"ok": True})
    except Exception as e:
        logger.exception("更新 IM 资料失败")
        return jsonify({"error": str(e)}), 500


@openim_bp.route("/push_token", methods=["POST"])
def register_push_token():
    """
    注册 FCM 推送 token (Android 优先)

    请求: { "fcm_token": "xxx", "platform": 2 }
    """
    from auth import get_current_user

    user = get_current_user()
    if not user:
        return jsonify({"error": "未登录"}), 401

    body = request.get_json(force=True)
    fcm_token = body.get("fcm_token")
    if not fcm_token:
        return jsonify({"error": "缺少 fcm_token"}), 400

    im_user_id = _openim_user_id(user["id"])

    try:
        admin_token = _get_admin_token()

        resp = requests.post(
            f"{OPENIM_API_URL}/third/fcm_update_token",
            json={
                "userID": im_user_id,
                "fcmToken": fcm_token,
                "platformID": body.get("platform", 2),
            },
            headers={**_admin_headers(), "token": admin_token},
            timeout=10,
        )
        data = resp.json()
        if data.get("errCode") != 0:
            logger.warning(f"FCM token 注册失败: {data.get('errMsg')}")
            return jsonify({"error": data.get("errMsg")}), 500

        return jsonify({"ok": True})
    except Exception as e:
        logger.exception("注册 FCM token 失败")
        return jsonify({"error": str(e)}), 500
