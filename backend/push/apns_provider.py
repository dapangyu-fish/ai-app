"""APNs HTTP/2 推送 provider
─────────────────────────────────────────────────────────
meta 协议：
  {"env": "sandbox"}     → 走 api.sandbox.push.apple.com（dev 包 / Xcode 自动签名）
  {"env": "production"}  → 走 api.push.apple.com（TestFlight / AppStore）

一个 .p8 同时对 sandbox 和 production 有效，只 host 不同。

为啥 .p8 不进 git：
  这把 PEM 私钥相当于 push 服务的钥匙，泄露后任何人都能给所有用户发推送。
  存在 /etc/apns/AuthKey_<KEY_ID>.p8，权限 600 给 root。
"""

import json
import logging
import time
from pathlib import Path

import httpx
import jwt

from config import (
    APNS_KEY_PATH,
    APNS_KEY_ID,
    APNS_TEAM_ID,
    APNS_BUNDLE_ID,
    APNS_USE_SANDBOX,
)
from . import register, PushResult, PushPayload

logger = logging.getLogger(__name__)

_HOST_SANDBOX = "https://api.sandbox.push.apple.com"
_HOST_PROD = "https://api.push.apple.com"

# JWT cache：APNs provider token 有效期最长 60 分钟，按 50 分钟刷
_jwt_cache = {"token": None, "expires_at": 0.0}


def _build_provider_jwt() -> str:
    """生成 / 复用 APNs provider authentication token (JWT)

    规范: https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
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
            f"APNs .p8 not found at {APNS_KEY_PATH} —— scp 上传 .p8 后再启动 backend"
        )
    private_key_pem = key_path.read_bytes()

    token = jwt.encode(
        {"iss": APNS_TEAM_ID, "iat": int(now)},
        private_key_pem,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID},
    )
    _jwt_cache["token"] = token
    _jwt_cache["expires_at"] = now + 50 * 60
    logger.info("[APNs] provider JWT 已刷新")
    return token


def _resolve_host(meta: dict) -> tuple[str, str]:
    """根据 meta.env 选 host。返回 (host, env_label_for_log)"""
    env = (meta or {}).get("env")
    if env == "sandbox":
        return _HOST_SANDBOX, "sandbox"
    if env == "production":
        return _HOST_PROD, "production"
    # 老数据没 env：按全局 config 兜底（迁移完成 + 客户端重新注册后这条路径应走不到）
    fallback = _HOST_SANDBOX if APNS_USE_SANDBOX else _HOST_PROD
    return fallback, f"fallback({'sandbox' if APNS_USE_SANDBOX else 'production'})"


def push(*, token: str, meta: dict, payload: PushPayload) -> PushResult:
    """给指定 deviceToken 推一条 alert 消息

    APNs 410 / BadDeviceToken / Unregistered → expired_token=True，
    调用方 (im.py) 应该删 DB 里那条 row。
    """
    try:
        provider_jwt = _build_provider_jwt()
    except Exception as e:
        logger.error(f"[APNs] 构造 JWT 失败: {e}")
        return PushResult(ok=False, retryable=True, reason=str(e))

    aps = {
        "alert": {"title": payload.title, "body": payload.body},
        "sound": "default",
        "mutable-content": 1,  # 允许 Notification Service Extension 改写
    }
    if payload.badge is not None:
        aps["badge"] = payload.badge
    body = {"aps": aps}
    if payload.custom:
        body.update(payload.custom)

    headers = {
        "authorization": f"bearer {provider_jwt}",
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",  # 立即送（badge-only 静默推用 5）
    }
    if payload.collapse_id:
        headers["apns-collapse-id"] = payload.collapse_id

    host, env_label = _resolve_host(meta)
    url = f"{host}/3/device/{token}"

    try:
        # APNs 强制 HTTP/2 + ALPN h2，httpx 装了 h2 包就支持
        with httpx.Client(http2=True, timeout=10.0) as client:
            resp = client.post(url, headers=headers, content=json.dumps(body))
    except Exception as e:
        logger.error(f"[APNs] 推送 IO 异常: {e}")
        return PushResult(ok=False, retryable=True, reason=str(e))

    if resp.status_code == 200:
        logger.info(f"[APNs] ✅ 推送成功 env={env_label} token=...{token[-8:]}")
        return PushResult(ok=True, status_code=200)

    try:
        err = resp.json()
    except Exception:
        err = {"raw": resp.text[:200]}
    reason = err.get("reason") if isinstance(err, dict) else None
    logger.warning(
        f"[APNs] ❌ 推送失败 env={env_label} status={resp.status_code} reason={err} token=...{token[-8:]}"
    )

    expired = resp.status_code == 410 or reason in ("BadDeviceToken", "Unregistered")
    return PushResult(
        ok=False,
        expired_token=expired,
        retryable=resp.status_code >= 500,
        status_code=resp.status_code,
        reason=str(reason or err),
    )


register("apns", push)
