#!/usr/bin/env python3
"""
APNs HTTP/2 推送 —— 用 .p8 Auth Key + JWT 直推 Apple Push Notification Service
─────────────────────────────────────────────────────────
为啥不走 OpenIM 的 push 模块：
  OpenIM 3.8 push 只支持 geTui / fcm / jpush 三家 3rd party 通道，没有原生 APNs 选项。
  我们走自建：OpenIM `beforeOfflinePush` webhook 通知后端 → 后端用 .p8 直推 APNs。

为啥 .p8 不进 git：
  这个 PEM 私钥相当于你 push 服务的钥匙，泄露后任何人能给你 app 的所有用户发推送。
  存在 /etc/apns/AuthKey_<KEY_ID>.p8，权限 600 给 root。
  config.py 只引用路径，不存内容。

为啥用 PyJWT + httpx 而不是 aioapns：
  服务器已装 PyJWT + cryptography，少装一个依赖。APNs HTTP/2 协议本身简单：
  POST https://api(.sandbox).push.apple.com/3/device/{token}
       headers: { authorization: bearer <jwt>, apns-topic: <bundleID>, apns-push-type: alert }
       body: { "aps": {...}, "custom": {...} }
"""

import json
import logging
import time
from pathlib import Path
from typing import Optional

import httpx
import jwt

from config import (
    APNS_KEY_PATH,
    APNS_KEY_ID,
    APNS_TEAM_ID,
    APNS_BUNDLE_ID,
    APNS_USE_SANDBOX,
)

logger = logging.getLogger(__name__)

# JWT token 缓存：APNs provider token 有效期最长 60 分钟，按 50 分钟刷
_jwt_cache = {"token": None, "expires_at": 0.0}


def _apns_host() -> str:
    """Sandbox / Production 走不同 host，但都用 :443"""
    return (
        "https://api.sandbox.push.apple.com"
        if APNS_USE_SANDBOX
        else "https://api.push.apple.com"
    )


def _build_provider_jwt() -> str:
    """生成 / 复用 APNs provider authentication token (JWT)

    规范：https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
      header: { alg: ES256, kid: <Key ID> }
      claims: { iss: <Team ID>, iat: <epoch> }
      签名: ECDSA P-256 + SHA-256，私钥用 .p8
    """
    now = time.time()
    if _jwt_cache["token"] and _jwt_cache["expires_at"] > now + 60:
        return _jwt_cache["token"]

    key_path = Path(APNS_KEY_PATH)
    if not key_path.exists():
        raise FileNotFoundError(
            f"APNs .p8 not found at {APNS_KEY_PATH} —— "
            "scp 上传 .p8 后再启动 backend"
        )
    private_key_pem = key_path.read_bytes()

    token = jwt.encode(
        {
            "iss": APNS_TEAM_ID,
            "iat": int(now),
        },
        private_key_pem,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID},
    )
    _jwt_cache["token"] = token
    _jwt_cache["expires_at"] = now + 50 * 60  # 50 分钟，给自己留点 margin
    logger.info("[APNs] provider JWT 已刷新")
    return token


def push_to_device(
    *,
    device_token: str,
    title: str,
    body: str,
    badge: Optional[int] = None,
    custom: Optional[dict] = None,
    collapse_id: Optional[str] = None,
) -> bool:
    """给指定 deviceToken 推一条 alert 消息

    Returns:
        True 推送成功；False 失败（已记日志）
        APNs 410 = device token expired/invalid，调用方应该删数据库里那条
    """
    try:
        provider_jwt = _build_provider_jwt()
    except Exception as e:
        logger.error(f"[APNs] 构造 JWT 失败: {e}")
        return False

    aps = {
        "alert": {"title": title, "body": body},
        "sound": "default",
        "mutable-content": 1,  # 让 Notification Service Extension 可以改写
    }
    if badge is not None:
        aps["badge"] = badge
    payload = {"aps": aps}
    if custom:
        payload.update(custom)

    headers = {
        "authorization": f"bearer {provider_jwt}",
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",  # 立即送（如果 badge-only 静默推就用 5）
    }
    if collapse_id:
        headers["apns-collapse-id"] = collapse_id

    url = f"{_apns_host()}/3/device/{device_token}"

    try:
        # APNs 必须 HTTP/2 + ALPN h2，httpx 装 h2 就支持
        with httpx.Client(http2=True, timeout=10.0) as client:
            resp = client.post(url, headers=headers, content=json.dumps(payload))
    except Exception as e:
        logger.error(f"[APNs] 推送 IO 异常: {e}")
        return False

    if resp.status_code == 200:
        logger.info(f"[APNs] ✅ 推送成功 token=...{device_token[-8:]}")
        return True

    # 错误处理
    try:
        err = resp.json()
    except Exception:
        err = {"raw": resp.text[:200]}
    logger.warning(
        f"[APNs] ❌ 推送失败 status={resp.status_code} reason={err} token=...{device_token[-8:]}"
    )

    # 410 / BadDeviceToken: token 失效，调用方该删 DB 里的记录
    if resp.status_code == 410 or err.get("reason") in ("BadDeviceToken", "Unregistered"):
        from database import db_execute  # 避免循环 import
        db_execute(
            "DELETE FROM device_tokens WHERE token = %s",
            (device_token,),
        )
        logger.info(f"[APNs] 已清理失效 token=...{device_token[-8:]}")
    return False
