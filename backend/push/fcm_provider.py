"""FCM HTTP v1 推送 provider
─────────────────────────────────────────────────────────
FCM 旧版 legacy server key（fcm.googleapis.com/fcm/send）2024-06 已停用，
只能走 v1 API：
  POST https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send
  Authorization: Bearer <OAuth access_token>

access_token 用 service account JSON 通过 OAuth 换出来（google-auth 库），
TTL 1 小时，library 自带 refresh。

meta 协议：
  {} 或 {"app_id": "xxx"} —— FCM 没 sandbox/prod 区分。app_id 字段当前 noop，
  预留给未来多 firebase project 场景

为啥 service-account.json 不进 git：
  这把 JSON 等同于 admin SDK 凭证，泄露后任何人都能用你的 Firebase 项目
  发推送、改 Auth、读 Firestore（如果开了）。存在 /etc/fcm/service-account.json
  权限 600。

config 依赖：
  FCM_SERVICE_ACCOUNT_PATH —— 默认 /etc/fcm/service-account.json
  FCM_PROJECT_ID            —— Firebase 项目 ID，例如 myapp-4b49d
"""

import json
import logging
from pathlib import Path

import httpx

from . import register, PushResult, PushPayload

logger = logging.getLogger(__name__)

# 延迟 import + 延迟构造 credentials，避免没装 google-auth 时 import 直接挂掉
_credentials = None
_creds_load_error = None


def _get_credentials():
    """加载 service account 并返回 Credentials 对象。失败缓存错误避免每次重试都打 IO。"""
    global _credentials, _creds_load_error
    if _credentials is not None:
        return _credentials
    if _creds_load_error is not None:
        # 已知失败不重试（misconfiguration 重试也没用，要人介入）
        raise _creds_load_error

    from config import FCM_SERVICE_ACCOUNT_PATH
    try:
        from google.oauth2 import service_account
    except ImportError as e:
        _creds_load_error = RuntimeError(
            f"google-auth 未安装：pip install google-auth>=2.0.0. 原始错误: {e}"
        )
        raise _creds_load_error

    p = Path(FCM_SERVICE_ACCOUNT_PATH)
    if not p.exists():
        _creds_load_error = FileNotFoundError(
            f"FCM service account 不存在: {FCM_SERVICE_ACCOUNT_PATH}. "
            f"去 Firebase Console → Project Settings → Service Accounts 下载后放到这"
        )
        raise _creds_load_error

    _credentials = service_account.Credentials.from_service_account_file(
        str(p),
        scopes=["https://www.googleapis.com/auth/firebase.messaging"],
    )
    logger.info(f"[FCM] credentials 加载成功 from {FCM_SERVICE_ACCOUNT_PATH}")
    return _credentials


def _get_access_token() -> str:
    """拿当前有效的 OAuth access_token。google-auth library 自带 refresh 逻辑。"""
    from google.auth.transport.requests import Request
    creds = _get_credentials()
    if not creds.valid:
        creds.refresh(Request())
    return creds.token


def push(*, token: str, meta: dict, payload: PushPayload) -> PushResult:
    """给指定 FCM token 推一条 alert 消息

    错误处理（参考 https://firebase.google.com/docs/cloud-messaging/manage-tokens）:
      - UNREGISTERED / INVALID_ARGUMENT (token 字段) / SENDER_ID_MISMATCH
        → expired_token=True，im.py 删 DB 那条
      - QUOTA_EXCEEDED / UNAVAILABLE / INTERNAL → retryable
    """
    from config import FCM_PROJECT_ID
    if not FCM_PROJECT_ID:
        return PushResult(
            ok=False,
            reason="FCM_PROJECT_ID 未配置（backend.env 加 FCM_PROJECT_ID=<your-firebase-project-id>）",
        )

    try:
        access_token = _get_access_token()
    except Exception as e:
        # 配置/凭证问题，retryable=False —— 修了再试
        return PushResult(ok=False, reason=f"获取 OAuth token 失败: {e}")

    # FCM v1 message 结构 —— android.priority="high" 等价 APNs priority=10（立刻推）
    message: dict = {
        "token": token,
        "notification": {
            "title": payload.title,
            "body": payload.body,
        },
        "android": {
            "priority": "high",
        },
    }

    # data 段：FCM 要求值全是 string，把 int / dict 都 json.dumps 成字符串
    # 客户端拿到的 RemoteMessage.data 字段也是 Map<String,String>
    if payload.custom:
        message["data"] = {
            k: (v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
            for k, v in payload.custom.items()
        }
    if payload.collapse_id:
        # FCM 用 collapse_key，效果一样：同 key 的旧未送达消息会被新的覆盖
        message["android"]["collapse_key"] = payload.collapse_id
    if payload.badge is not None:
        # Android 没原生 badge 概念（厂商 launcher 各自实现），塞 data 里让客户端自己处理
        message.setdefault("data", {})["badge"] = str(payload.badge)

    url = f"https://fcm.googleapis.com/v1/projects/{FCM_PROJECT_ID}/messages:send"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json; UTF-8",
    }
    body = {"message": message}

    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.post(url, headers=headers, json=body)
    except Exception as e:
        logger.error(f"[FCM] 推送 IO 异常: {e}")
        return PushResult(ok=False, retryable=True, reason=str(e))

    if resp.status_code == 200:
        logger.info(f"[FCM] ✅ 推送成功 token=...{token[-12:]}")
        return PushResult(ok=True, status_code=200)

    # 解析 v1 错误响应：{"error":{"code":404,"status":"NOT_FOUND",
    #   "details":[{"@type":"...FcmError","errorCode":"UNREGISTERED"}]}}
    try:
        err = resp.json().get("error", {})
    except Exception:
        err = {"raw": resp.text[:200]}

    fcm_error_code = ""
    for d in (err.get("details") or []):
        if d.get("errorCode"):
            fcm_error_code = d["errorCode"]
            break
    status = err.get("status", "")
    reason = fcm_error_code or status or str(err)

    logger.warning(
        f"[FCM] ❌ 推送失败 status={resp.status_code} fcm_error={fcm_error_code} "
        f"status_field={status} token=...{token[-12:]}"
    )

    # 这些错误码意味着 token 永久失效，应该删 DB
    expired_codes = {"UNREGISTERED", "INVALID_ARGUMENT", "SENDER_ID_MISMATCH"}
    expired = fcm_error_code in expired_codes or resp.status_code == 404

    # 5xx + QUOTA_EXCEEDED 值得重试
    retryable = resp.status_code >= 500 or fcm_error_code in ("UNAVAILABLE", "INTERNAL", "QUOTA_EXCEEDED")

    return PushResult(
        ok=False,
        expired_token=expired,
        retryable=retryable,
        status_code=resp.status_code,
        reason=reason,
    )


register("fcm", push)
