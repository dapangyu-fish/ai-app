"""通用推送分发层 —— 通道(channel) 与具体 provider 解耦
─────────────────────────────────────────────────────────
设计：
  device_tokens.channel       —— 'apns' | 'fcm' | 'getui' | 'huawei' | ...
  device_tokens.channel_meta  —— JSONB，通道私有字段
                                  apns:  {"env": "sandbox" | "production"}
                                  fcm:   {"app_id": "..."} 或 {}
                                  getui: {"app_id": "...", "vendor": "huawei"}

加新通道 = 新增 provider 模块（实现 push 函数）+ 在该模块尾部 register("xxx", push)
本文件不感知具体通道；im.py 也只调 dispatch()，schema 不需要因新通道变化。
"""

from dataclasses import dataclass, field
from typing import Optional, Callable, Dict
import logging

logger = logging.getLogger(__name__)


@dataclass
class PushPayload:
    """通用 payload —— 各 provider 自己映射到自家协议字段"""
    title: str
    body: str
    badge: Optional[int] = None
    custom: Optional[dict] = None      # 业务字段（conversation_id / sender_id 等），原样下发
    collapse_id: Optional[str] = None  # 同会话合并的 id（APNs apns-collapse-id / FCM collapse_key 等）


@dataclass
class PushResult:
    ok: bool
    expired_token: bool = False        # token 已失效 → dispatcher 调用方应该删 DB 那条
    retryable: bool = False             # 是否值得重试（5xx / IO 异常）
    status_code: Optional[int] = None
    reason: Optional[str] = None


# channel name → push function
# 函数签名: push(*, token: str, meta: dict, payload: PushPayload) -> PushResult
_PUSHERS: Dict[str, Callable[..., PushResult]] = {}


def register(channel: str, push_fn: Callable[..., PushResult]) -> None:
    """provider 自注册 —— 在 provider 模块底部调用"""
    if channel in _PUSHERS:
        logger.warning(f"[push] channel {channel} 重复注册，新值覆盖旧值")
    _PUSHERS[channel] = push_fn
    logger.info(f"[push] registered channel: {channel}")


def is_supported(channel: str) -> bool:
    return channel in _PUSHERS


def supported_channels() -> list[str]:
    return sorted(_PUSHERS.keys())


def dispatch(*, channel: str, token: str, meta: dict, payload: PushPayload) -> PushResult:
    """按 channel 派发到对应 provider。

    未注册的 channel → 返回 ok=False（不抛异常），让 webhook 主流程不被未知 channel 卡死。
    provider 内部抛异常 → 视为可重试（retryable=True），但本轮算失败。
    """
    fn = _PUSHERS.get(channel)
    if fn is None:
        logger.info(
            f"[push] channel={channel} 未实现，跳过 token=...{token[-8:] if len(token) > 8 else token}"
        )
        return PushResult(ok=False, reason=f"channel '{channel}' not implemented")
    try:
        return fn(token=token, meta=meta or {}, payload=payload)
    except Exception as e:
        logger.error(f"[push] {channel} provider 抛异常: {e}", exc_info=True)
        return PushResult(ok=False, retryable=True, reason=str(e))


# ── 注册所有内置 provider ──
# 每个 provider 模块在 import 时调 register() 自己；新增通道在这里加一行 import 即可
from . import apns_provider  # noqa: E402,F401
from . import fcm_provider   # noqa: E402,F401
