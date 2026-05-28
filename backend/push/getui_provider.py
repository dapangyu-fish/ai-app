"""GeTui RestAPI V2 推送 provider.

服务端使用 AppKey + MasterSecret 换取接口 token，再按 CID 单推。
真实凭证只允许放在 /etc/ai-app/backend.env 或进程环境变量中，不进入仓库。
"""

import hashlib
import json
import logging
import time
import uuid
from typing import Any

import httpx

from config import (
    GETUI_APP_ID,
    GETUI_APP_KEY,
    GETUI_BASE_URL,
    GETUI_MASTER_SECRET,
    GETUI_TTL_MS,
)
from . import register, PushPayload, PushResult

logger = logging.getLogger(__name__)

_token_cache = {"token": None, "expires_at_ms": 0}


def _is_configured() -> bool:
    return bool(GETUI_APP_ID and GETUI_APP_KEY and GETUI_MASTER_SECRET)


def _base_url() -> str:
    return f"{GETUI_BASE_URL.rstrip('/')}/{GETUI_APP_ID}"


def _truncate(value: str, limit: int) -> str:
    value = value or ""
    return value if len(value) <= limit else value[: limit - 1] + "…"


def _json_payload(payload: PushPayload) -> str:
    data = dict(payload.custom or {})
    if payload.badge is not None:
        data["badge"] = payload.badge
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def _notify_id(collapse_id: str | None) -> int | None:
    if not collapse_id:
        return None
    # GeTui notify_id 范围 0..2147483647；稳定 hash 可复用同会话覆盖语义。
    return int(hashlib.sha256(collapse_id.encode("utf-8")).hexdigest()[:8], 16) % 2147483647


def _get_auth_token(*, force_refresh: bool = False) -> str:
    now_ms = int(time.time() * 1000)
    cached = _token_cache.get("token")
    expires_at_ms = int(_token_cache.get("expires_at_ms") or 0)
    if not force_refresh and cached and expires_at_ms > now_ms + 5 * 60 * 1000:
        return str(cached)

    timestamp = str(now_ms)
    raw = f"{GETUI_APP_KEY}{timestamp}{GETUI_MASTER_SECRET}"
    sign = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    body = {
        "sign": sign,
        "timestamp": timestamp,
        "appkey": GETUI_APP_KEY,
    }
    url = f"{_base_url()}/auth"

    with httpx.Client(timeout=10.0) as client:
        resp = client.post(
            url,
            headers={"Content-Type": "application/json;charset=utf-8"},
            json=body,
        )
    data = _safe_json(resp)
    if resp.status_code != 200 or not _code_is(data.get("code"), 0):
        raise RuntimeError(
            f"GeTui auth failed status={resp.status_code} code={data.get('code')} msg={data.get('msg')}"
        )

    token_data = data.get("data") or {}
    token = token_data.get("token")
    expire_time = token_data.get("expire_time")
    if not token:
        raise RuntimeError("GeTui auth response missing token")

    try:
        expires_at_ms = int(expire_time)
    except Exception:
        expires_at_ms = now_ms + 24 * 60 * 60 * 1000
    _token_cache["token"] = token
    _token_cache["expires_at_ms"] = expires_at_ms
    logger.info("[GeTui] auth token refreshed")
    return str(token)


def _safe_json(resp: httpx.Response) -> dict[str, Any]:
    try:
        data = resp.json()
        return data if isinstance(data, dict) else {"raw": data}
    except Exception:
        return {"raw": resp.text[:300]}


def _code_is(code: Any, expected: int) -> bool:
    return str(code) == str(expected)


def _request_body(*, cid: str, payload: PushPayload) -> dict[str, Any]:
    title = _truncate(payload.title, 50)
    body = _truncate(payload.body, 256)
    custom_payload = _json_payload(payload)
    notify_id = _notify_id(payload.collapse_id)

    notification: dict[str, Any] = {
        "title": title,
        "body": body,
        "click_type": "payload",
        "payload": custom_payload,
    }
    if payload.collapse_id:
        notification["thread_id"] = payload.collapse_id
    if notify_id is not None:
        notification["notify_id"] = notify_id

    android_notification: dict[str, Any] = {
        "title": title,
        "body": body,
        "click_type": "startapp",
    }
    if notify_id is not None:
        android_notification["notify_id"] = notify_id

    ios_payload: dict[str, Any] = {
        "type": "notify",
        "payload": custom_payload,
        "aps": {
            "alert": {"title": title, "body": body},
            "content-available": 0,
            "sound": "default",
        },
    }
    if payload.badge is not None:
        ios_payload["auto_badge"] = str(payload.badge)
    if payload.collapse_id:
        ios_payload["apns-collapse-id"] = payload.collapse_id

    return {
        "request_id": uuid.uuid4().hex,
        "settings": {"ttl": GETUI_TTL_MS},
        "audience": {"cid": [cid]},
        "push_message": {"notification": notification},
        "push_channel": {
            "android": {"ups": {"notification": android_notification}},
            "ios": ios_payload,
        },
    }


def _send_once(*, cid: str, payload: PushPayload, force_auth: bool = False) -> tuple[httpx.Response, dict[str, Any]]:
    token = _get_auth_token(force_refresh=force_auth)
    url = f"{_base_url()}/push/single/cid"
    headers = {
        "Content-Type": "application/json;charset=utf-8",
        "token": token,
    }
    body = _request_body(cid=cid, payload=payload)
    with httpx.Client(timeout=10.0) as client:
        resp = client.post(url, headers=headers, json=body)
    return resp, _safe_json(resp)


def push(*, token: str, meta: dict, payload: PushPayload) -> PushResult:
    """给指定 GeTui CID 推一条通知。

    token 参数在该 provider 中表示 GeTui ClientID(CID)，由客户端 SDK 获取并上传。
    """
    if not _is_configured():
        return PushResult(
            ok=False,
            reason="GETUI_APP_ID/GETUI_APP_KEY/GETUI_MASTER_SECRET 未配置",
        )

    try:
        resp, data = _send_once(cid=token, payload=payload)
        if _code_is(data.get("code"), 10001):
            # token 失效时按官方建议被动刷新一次。
            _token_cache["token"] = None
            resp, data = _send_once(cid=token, payload=payload, force_auth=True)
    except Exception as e:
        logger.error(f"[GeTui] 推送 IO/鉴权异常: {e}")
        return PushResult(ok=False, retryable=True, reason=str(e))

    code = data.get("code")
    if resp.status_code == 200 and _code_is(code, 0):
        logger.info(f"[GeTui] ✅ 推送成功 cid=...{token[-8:]}")
        return PushResult(ok=True, status_code=200)

    msg = str(data.get("msg") or data.get("raw") or "")
    logger.warning(
        f"[GeTui] ❌ 推送失败 status={resp.status_code} code={code} msg={msg[:160]} cid=...{token[-8:]}"
    )

    expired = _code_is(code, 20001) and "target user is invalid" in msg
    retryable = resp.status_code >= 500 or str(code) in {
        "2",
        "10001",
        "10003",
        "10005",
        "30019",
        "30022",
    }
    return PushResult(
        ok=False,
        expired_token=expired,
        retryable=retryable,
        status_code=resp.status_code,
        reason=f"code={code} msg={msg[:200]}",
    )


register("getui", push)
