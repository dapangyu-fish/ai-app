"""Shared AI provider schema helpers."""

from __future__ import annotations

import re

LEGACY_DISABLED_PROVIDER_IDS = {"glm", "cc"}

PROVIDER_ENV_SUFFIXES = (
    "_ANTHROPIC_BASE_URL",
    "_ANTHROPIC_AUTH_TOKEN",
    "_ANTHROPIC_MODEL",
    "_ANTHROPIC_DEFAULT_OPUS_MODEL",
    "_ANTHROPIC_DEFAULT_SONNET_MODEL",
    "_ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "_CODEX_BASE_URL",
    "_CODEX_MODEL",
    "_CODEX_ENV_KEY",
    "_CODEX_AUTH_TOKEN",
    "_CODEX_RELAY",
    "_CODEX_UPSTREAM_WIRE_API",
    "_OPENCODE_BASE_URL",
    "_OPENCODE_MODEL",
    "_OPENCODE_ENV_KEY",
    "_OPENCODE_AUTH_TOKEN",
    "_OPENCODE_PROVIDER_NPM",
)

ORDERED_AGENT_IDS = ("claude", "codex", "opencode")


def split_csv(value: str) -> list[str]:
    return [item.strip() for item in str(value or "").split(",") if item.strip()]


def normalize_provider_id(value: object, default: str = "custom") -> str:
    text = re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower()).strip("-")
    return text or default


def provider_prefix(provider_id: str) -> str:
    return "".join(ch.upper() if ch.isalnum() else "_" for ch in str(provider_id or ""))


def provider_id_from_prefix(prefix: str) -> str:
    return str(prefix or "").lower().replace("_", "-")


def normalize_agent_id(value: object, default: str = "") -> str:
    text = str(value or "").strip().lower().replace("_", "-")
    return text or default


def env_for_prefix(env: dict[str, str], prefix: str, key: str, default: str = "") -> str:
    value = env.get(f"{prefix}_{key}")
    return value if value is not None else default


def env_bool_for_prefix(env: dict[str, str], prefix: str, key: str, default: str = "1") -> bool:
    value = env.get(f"{prefix}_{key}")
    if value is None and key == "PROVIDER_VISIBLE":
        value = env.get(f"{prefix}_VISIBLE")
    if value is None:
        value = default
    return str(value).strip().lower() not in {"0", "false", "no", "off", "disabled", "hidden"}


def default_adapter_kind(agent_id: str) -> str:
    normalized = normalize_agent_id(agent_id)
    if normalized == "claude":
        return "anthropic"
    if normalized == "codex":
        return "openai-responses"
    if normalized == "opencode":
        return "opencode"
    return normalized or "unknown"


def capability_enabled_value(value: object, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off", "disabled"}
    return bool(value)
