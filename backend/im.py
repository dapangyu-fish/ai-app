#!/usr/bin/env python3
"""
OpenIM 集成路由
─────────────────────────────────────────────────────────
作用：业务系统 (Supabase) 用户 ↔ OpenIM 用户的桥接。

流程（客户端登录后）：
  1. 客户端用业务 token 调 POST /api/im/token
  2. 后端 require_auth 拿到 supabase_user
  3. 把 supabase user.id (UUID 字符串) 去掉 hyphen 后当 OpenIM userID
     ※ OpenIM 拒绝含 `-` 的 userID（errCode=1001 "userID is legal"），必须 strip
  4. 用 admin secret → admin_token → 确保 OpenIM 用户存在 → 签 user token
  5. 返回 {im_user_id, im_token, ws_url, api_url}

为啥 user_register 要每次都跑：
  OpenIM user_register 是幂等的（已存在不会报错），调用代价小（一次内部 RPC）。
  避免我们维护"哪些用户已注册过"的状态——保持后端无状态，重启 / 多副本都不影响。

admin_token 缓存：
  一次签 7 天有效。模块内存缓存 + 兜底过期就重签。
"""

import time
import logging
import threading
import requests
from flask import jsonify, request
from auth import require_auth
from config import (
    OPENIM_API_URL,
    OPENIM_WS_URL,
    OPENIM_SECRET,
    OPENIM_PLATFORM_WEB,
)

logger = logging.getLogger(__name__)

# ── admin token 缓存 ──
_admin_token_cache = {"token": None, "expires_at": 0.0}
_admin_token_lock = threading.Lock()


def _new_operation_id() -> str:
    """OpenIM API 要求每个请求带 operationID（用作日志追踪），随手用时间戳"""
    return f"backend-{int(time.time() * 1000)}"


def _post_openim(path: str, body: dict, *, admin_token: str = None, timeout: int = 10) -> dict:
    """POST 调 OpenIM API。统一错误处理。

    OpenIM 响应格式：{"errCode": 0, "errMsg": "", "errDlt": "", "data": {...}}
    errCode == 0 表示成功，否则失败。
    """
    headers = {
        "Content-Type": "application/json",
        "operationID": _new_operation_id(),
    }
    if admin_token:
        headers["token"] = admin_token

    url = f"{OPENIM_API_URL.rstrip('/')}{path}"
    resp = requests.post(url, json=body, headers=headers, timeout=timeout)

    if resp.status_code != 200:
        raise RuntimeError(f"OpenIM {path} HTTP {resp.status_code}: {resp.text[:200]}")

    data = resp.json()
    if data.get("errCode", -1) != 0:
        raise RuntimeError(f"OpenIM {path} errCode={data.get('errCode')} errMsg={data.get('errMsg')}")

    return data.get("data", {})


def _get_admin_token(force_refresh: bool = False) -> str:
    """拿（或刷新）admin token。线程安全 + 缓存。"""
    now = time.time()
    if not force_refresh:
        with _admin_token_lock:
            if _admin_token_cache["token"] and _admin_token_cache["expires_at"] > now + 60:
                return _admin_token_cache["token"]

    # 重新签：用 secret 换 admin token（userID=imAdmin，platformID=平台号无所谓）
    data = _post_openim(
        "/auth/get_admin_token",
        {
            "secret": OPENIM_SECRET,
            "userID": "imAdmin",  # OpenIM 默认管理员 ID（v3.8 默认）
        },
    )
    token = data.get("token")
    if not token:
        raise RuntimeError(f"OpenIM admin token 响应缺 token 字段: {data}")
    # OpenIM token 默认 7 天，保守按 6 天缓存
    expires_at = now + 6 * 86400
    with _admin_token_lock:
        _admin_token_cache["token"] = token
        _admin_token_cache["expires_at"] = expires_at
    logger.info(f"[IM] 刷新 admin token 成功，缓存 6 天")
    return token


def _ensure_user_registered(user_id: str, *, nickname: str = "", face_url: str = "", admin_token: str = None) -> None:
    """确保 OpenIM 里有这个用户。已存在的会报错 — 我们把"已存在"当成功处理。

    OpenIM v3.8 user_register 协议：
      POST /user/user_register
      body: { "users": [ { "userID": "...", "nickname": "...", "faceURL": "..." } ], "secret": "..." }
      （注意：v3.8 这里直接吃 secret，不一定要 admin token；我们两个都带稳一点）
    """
    if admin_token is None:
        admin_token = _get_admin_token()

    body = {
        "secret": OPENIM_SECRET,
        "users": [
            {
                "userID": user_id,
                "nickname": nickname or user_id[:8],  # 默认显示 ID 前 8 位
                "faceURL": face_url or "",
            }
        ],
    }
    try:
        _post_openim("/user/user_register", body, admin_token=admin_token)
    except RuntimeError as e:
        msg = str(e).lower()
        # OpenIM 里"已存在"会报 errCode=1102 之类。我们当作成功
        if "1102" in msg or "exist" in msg or "registered" in msg:
            return
        raise


def _sign_user_token(user_id: str, platform_id: int, admin_token: str = None) -> str:
    """给 user 签一个 IM token（业务后端代签，客户端只拿到这个 token，不接触 secret）"""
    if admin_token is None:
        admin_token = _get_admin_token()

    data = _post_openim(
        "/auth/get_user_token",
        {
            "secret": OPENIM_SECRET,
            "platformID": platform_id,
            "userID": user_id,
        },
        admin_token=admin_token,
    )
    token = data.get("token")
    if not token:
        raise RuntimeError(f"OpenIM get_user_token 响应缺 token 字段: {data}")
    return token


# ============================================================
# Flask 路由
# ============================================================

def _to_im_user_id(supabase_user_id: str) -> str:
    """Supabase UUID → OpenIM userID。去掉 hyphen（OpenIM 拒绝含 - 的 userID）"""
    return (supabase_user_id or "").replace("-", "")


@require_auth
def get_im_token():
    """
    POST /api/im/token

    Body (可选): { "platform": 1 }     # 1=iOS 2=Android 5=Web ...

    Returns 200:
      {
        "im_user_id": "...",     # Supabase UUID 去掉 - 后的形式（OpenIM userID 限制）
        "im_token": "...",
        "ws_url": "ws://...",
        "api_url": "http://...",
      }
    """
    user = request.supabase_user
    raw_user_id = str(user.get("id", ""))
    if not raw_user_id:
        return jsonify({"error": "Supabase 用户没有 id 字段"}), 500

    user_id = _to_im_user_id(raw_user_id)

    body = request.get_json(silent=True) or {}
    platform_id = int(body.get("platform", OPENIM_PLATFORM_WEB))

    # nickname / 头像 — 从 Supabase 用户元数据取
    meta = user.get("user_metadata", {}) or {}
    nickname = meta.get("username") or user.get("email", "").split("@")[0] or user_id[:8]
    face_url = meta.get("avatar_url", "") or ""

    try:
        admin_token = _get_admin_token()
        _ensure_user_registered(user_id, nickname=nickname, face_url=face_url, admin_token=admin_token)
        im_token = _sign_user_token(user_id, platform_id, admin_token=admin_token)
    except RuntimeError as e:
        # admin token 可能过期，强制刷一次再重试一次
        try:
            admin_token = _get_admin_token(force_refresh=True)
            _ensure_user_registered(user_id, nickname=nickname, face_url=face_url, admin_token=admin_token)
            im_token = _sign_user_token(user_id, platform_id, admin_token=admin_token)
        except RuntimeError as e2:
            logger.error(f"[IM] 取 token 失败 user={user_id}: {e2}")
            return jsonify({"error": f"OpenIM error: {e2}"}), 502

    return jsonify({
        "im_user_id": user_id,
        "im_token": im_token,
        "ws_url": OPENIM_WS_URL,
        "api_url": OPENIM_API_URL,
    })


@require_auth
def lookup_user():
    """
    GET /api/im/users/lookup?user_id=xxx

    把 OpenIM userID 映射回业务用户名 / 头像，给客户端的好友卡片用。
    传进来的 user_id 可能带 / 不带 hyphen，统一 strip 后再查 OpenIM。
    """
    target_user_id = _to_im_user_id((request.args.get("user_id") or "").strip())
    if not target_user_id:
        return jsonify({"error": "缺少 user_id 参数"}), 400

    try:
        admin_token = _get_admin_token()
        data = _post_openim(
            "/user/get_users_info",
            {"userIDs": [target_user_id]},
            admin_token=admin_token,
        )
    except RuntimeError as e:
        logger.error(f"[IM] lookup 失败 user={target_user_id}: {e}")
        return jsonify({"error": str(e)}), 502

    users = data.get("usersInfo") or data.get("users") or []
    if not users:
        return jsonify({"error": "用户不存在"}), 404

    u = users[0]
    return jsonify({
        "user_id": u.get("userID", target_user_id),
        "nickname": u.get("nickname", ""),
        "face_url": u.get("faceURL", ""),
    })
