"""Canonical AI provider registry.

The public contract is intentionally still env based. This module only centralizes
the non-secret defaults and adapter capability rules so backend, agent-node and
myapp-ctl do not each carry separate provider logic.
"""

from __future__ import annotations

import os
from copy import deepcopy
from typing import Any

from .deepseek.provider import PROVIDER as DEEPSEEK_PROVIDER
from .minimax.provider import PROVIDER as MINIMAX_PROVIDER
from .schema import (
    LEGACY_DISABLED_PROVIDER_IDS,
    ORDERED_AGENT_IDS,
    PROVIDER_ENV_SUFFIXES,
    capability_enabled_value,
    default_adapter_kind,
    env_bool_for_prefix,
    env_for_prefix,
    normalize_agent_id,
    normalize_provider_id,
    provider_id_from_prefix,
    provider_prefix,
    split_csv,
)


BUILTIN_PROVIDERS = {
    "deepseek": DEEPSEEK_PROVIDER,
    "minimax": MINIMAX_PROVIDER,
}


def builtin_provider(provider_id: str) -> dict[str, Any]:
    return deepcopy(BUILTIN_PROVIDERS.get(normalize_provider_id(provider_id), {}))


def builtin_adapter(provider_id: str, agent_id: str) -> dict[str, Any]:
    provider = builtin_provider(provider_id)
    adapters = provider.get("adapters") if isinstance(provider.get("adapters"), dict) else {}
    return deepcopy(adapters.get(normalize_agent_id(agent_id), {}))


def provider_has_auth_env(env: dict[str, str], provider_id: str) -> bool:
    provider_id = normalize_provider_id(provider_id)
    prefix = provider_prefix(provider_id)
    if env.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", ""):
        return True
    codex_env_key = env.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN")
    if env.get(f"{prefix}_CODEX_BASE_URL", "") and env.get(f"{prefix}_CODEX_MODEL", "") and codex_env_key and env.get(codex_env_key, ""):
        return True
    opencode_env_key = env.get(f"{prefix}_OPENCODE_ENV_KEY", f"{prefix}_OPENCODE_AUTH_TOKEN")
    if env.get(f"{prefix}_OPENCODE_BASE_URL", "") and env.get(f"{prefix}_OPENCODE_MODEL", "") and opencode_env_key and env.get(opencode_env_key, ""):
        return True
    provider = BUILTIN_PROVIDERS.get(provider_id, {})
    return any(env.get(env_name, "") for env_name in provider.get("auth_env_fallbacks", ()))


def discover_provider_ids(env: dict[str, str] | None = None) -> list[str]:
    env = env or os.environ
    explicit_ids = split_csv(env.get("AI_PROVIDER_IDS", ""))
    if explicit_ids:
        provider_ids = explicit_ids
    else:
        provider_ids = ["deepseek"]
        if provider_has_auth_env(env, "minimax"):
            provider_ids.append("minimax")

    for env_name in env:
        for suffix in PROVIDER_ENV_SUFFIXES:
            if not env_name.endswith(suffix):
                continue
            prefix = env_name[: -len(suffix)]
            if prefix in {"", "ANTHROPIC"}:
                continue
            provider_id = provider_id_from_prefix(prefix)
            if provider_id in LEGACY_DISABLED_PROVIDER_IDS or provider_id in provider_ids:
                continue
            if provider_has_auth_env(env, provider_id):
                provider_ids.append(provider_id)
            break

    result: list[str] = []
    seen: set[str] = set()
    for provider_id in provider_ids:
        normalized = normalize_provider_id(provider_id, default="")
        if not normalized or normalized in LEGACY_DISABLED_PROVIDER_IDS or normalized in seen:
            continue
        seen.add(normalized)
        result.append(normalized)
    return result or ["deepseek"]


def provider_auth_token(env: dict[str, str], provider_id: str, prefix: str, provider: dict[str, Any]) -> str:
    token = env_for_prefix(env, prefix, "ANTHROPIC_AUTH_TOKEN")
    if token:
        return token
    for env_name in provider.get("auth_env_fallbacks", ()):
        fallback = env.get(env_name, "")
        if fallback:
            return fallback
    return ""


def build_provider(provider_id: str, env: dict[str, str] | None = None) -> dict[str, Any]:
    env = env or os.environ
    provider_id = normalize_provider_id(provider_id)
    prefix = provider_prefix(provider_id)
    builtin = BUILTIN_PROVIDERS.get(provider_id, {})
    claude = (builtin.get("adapters") or {}).get("claude", {})
    default_model = claude.get("model", "")

    base_url = env_for_prefix(env, prefix, "ANTHROPIC_BASE_URL", claude.get("base_url", ""))
    auth_token = provider_auth_token(env, provider_id, prefix, builtin)
    model = env_for_prefix(env, prefix, "ANTHROPIC_MODEL", default_model)
    opus_model = env_for_prefix(env, prefix, "ANTHROPIC_DEFAULT_OPUS_MODEL", model)
    sonnet_model = env_for_prefix(env, prefix, "ANTHROPIC_DEFAULT_SONNET_MODEL", model)
    haiku_model = env_for_prefix(env, prefix, "ANTHROPIC_DEFAULT_HAIKU_MODEL", model)
    subagent_model = env_for_prefix(env, prefix, "CLAUDE_CODE_SUBAGENT_MODEL", model)
    effort_level = env_for_prefix(env, prefix, "CLAUDE_CODE_EFFORT_LEVEL", "max")
    timeout_ms = env_for_prefix(env, prefix, "API_TIMEOUT_MS", "600000")

    cli_env = {
        "ANTHROPIC_BASE_URL": base_url,
        "ANTHROPIC_AUTH_TOKEN": auth_token,
        "ANTHROPIC_MODEL": model,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": opus_model,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnet_model,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": haiku_model,
        "CLAUDE_CODE_SUBAGENT_MODEL": subagent_model,
        "CLAUDE_CODE_EFFORT_LEVEL": effort_level,
        "API_TIMEOUT_MS": timeout_ms,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": env_for_prefix(env, prefix, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
    }

    anthropic_configured = bool(base_url and auth_token and model)
    return {
        "id": provider_id,
        "name": env_for_prefix(env, prefix, "PROVIDER_NAME", builtin.get("name", provider_id)),
        "description": env_for_prefix(
            env,
            prefix,
            "PROVIDER_DESCRIPTION",
            builtin.get("description", "Anthropic-compatible Claude Code provider"),
        ),
        "type": "anthropic",
        "base_url": base_url,
        "api_key": auth_token,
        "models": {
            "default": model,
            "haiku": haiku_model,
            "sonnet": sonnet_model,
            "opus": opus_model,
        },
        "agent_model": subagent_model,
        "cli_env": cli_env,
        "cli_model": model,
        "supported_agents": split_csv(env_for_prefix(
            env,
            prefix,
            "SUPPORTED_AGENTS",
            ",".join((builtin.get("adapters") or {}).keys()),
        )),
        "anthropic_configured": anthropic_configured,
        "configured": anthropic_configured,
        "visible": env_bool_for_prefix(env, prefix, "PROVIDER_VISIBLE", builtin.get("visible", "1")),
    }


def provider_codex_config(provider_id: str, env: dict[str, str] | None = None) -> dict[str, Any]:
    env = env or os.environ
    provider_id = normalize_provider_id(provider_id)
    prefix = provider_prefix(provider_id)
    default_codex = builtin_adapter(provider_id, "codex")
    model = env_for_prefix(env, prefix, "CODEX_MODEL", default_codex.get("model", ""))
    base_url = env_for_prefix(env, prefix, "CODEX_BASE_URL", default_codex.get("base_url", ""))
    env_key = env_for_prefix(env, prefix, "CODEX_ENV_KEY", default_codex.get("env_key", f"{prefix}_CODEX_AUTH_TOKEN"))
    wire_api = env_for_prefix(env, prefix, "CODEX_WIRE_API", default_codex.get("wire_api", "responses"))
    context_window = env_for_prefix(env, prefix, "CODEX_CONTEXT_WINDOW", str(default_codex.get("context_window", "")))
    provider_name = env_for_prefix(env, prefix, "CODEX_PROVIDER_NAME", default_codex.get("provider_name", provider_id))
    relay = env_for_prefix(env, prefix, "CODEX_RELAY", default_codex.get("relay", ""))
    upstream_wire_api = env_for_prefix(env, prefix, "CODEX_UPSTREAM_WIRE_API", default_codex.get("upstream_wire_api", ""))
    auth_token = env.get(env_key, "") if env_key else ""
    return {
        "provider_name": provider_name,
        "base_url": base_url,
        "model": model,
        "wire_api": wire_api,
        "upstream_wire_api": upstream_wire_api,
        "relay": relay,
        "env_key": env_key,
        "context_window": context_window,
        "configured": bool(base_url and model and env_key and auth_token),
    }


def provider_opencode_config(provider_id: str, env: dict[str, str] | None = None) -> dict[str, Any]:
    env = env or os.environ
    provider_id = normalize_provider_id(provider_id)
    prefix = provider_prefix(provider_id)
    default_opencode = builtin_adapter(provider_id, "opencode")
    default_codex = builtin_adapter(provider_id, "codex")
    model = env_for_prefix(env, prefix, "OPENCODE_MODEL", default_opencode.get("model", default_codex.get("model", "")))
    base_url = env_for_prefix(env, prefix, "OPENCODE_BASE_URL", default_opencode.get("base_url", default_codex.get("base_url", "")))
    env_key = env_for_prefix(
        env,
        prefix,
        "OPENCODE_ENV_KEY",
        default_opencode.get("env_key", env_for_prefix(env, prefix, "CODEX_ENV_KEY", default_codex.get("env_key", f"{prefix}_CODEX_AUTH_TOKEN"))),
    )
    provider_name = env_for_prefix(
        env,
        prefix,
        "OPENCODE_PROVIDER_NAME",
        default_opencode.get("provider_name", default_codex.get("provider_name", provider_id)),
    )
    provider_npm = env_for_prefix(env, prefix, "OPENCODE_PROVIDER_NPM", default_opencode.get("provider_npm", "@ai-sdk/openai-compatible"))
    auth_token = env.get(env_key, "") if env_key else ""
    return {
        "provider_name": provider_name,
        "base_url": base_url,
        "model": model,
        "env_key": env_key,
        "provider_npm": provider_npm,
        "configured": bool(base_url and model and env_key and auth_token),
    }


def build_providers(env: dict[str, str] | None = None) -> dict[str, dict[str, Any]]:
    env = env or os.environ
    providers = {provider_id: build_provider(provider_id, env) for provider_id in discover_provider_ids(env)}
    for provider_id, provider in providers.items():
        provider["codex"] = provider_codex_config(provider_id, env)
        provider["opencode"] = provider_opencode_config(provider_id, env)
        provider["configured"] = bool(
            provider.get("anthropic_configured")
            or ((provider.get("codex") or {}).get("configured"))
            or ((provider.get("opencode") or {}).get("configured"))
        )
    return providers


def provider_ids_from_env(env: dict[str, str]) -> list[str]:
    ids = [normalize_provider_id(item) for item in split_csv(env.get("AI_PROVIDER_IDS", ""))]
    seen: set[str] = set()
    out: list[str] = []
    for provider_id in ids:
        if provider_id not in seen:
            out.append(provider_id)
            seen.add(provider_id)
    if out:
        return out
    for key, value in env.items():
        if key.endswith("_ANTHROPIC_AUTH_TOKEN") and value:
            provider_id = normalize_provider_id(key[: -len("_ANTHROPIC_AUTH_TOKEN")])
            if provider_id not in out:
                out.append(provider_id)
    for key, value in env.items():
        if key.endswith("_CODEX_BASE_URL") and value:
            provider_id = normalize_provider_id(key[: -len("_CODEX_BASE_URL")])
            prefix = provider_prefix(provider_id)
            env_key = env.get(f"{prefix}_CODEX_ENV_KEY") or f"{prefix}_CODEX_AUTH_TOKEN"
            if env.get(f"{prefix}_CODEX_MODEL") and env_key and env.get(env_key) and provider_id not in out:
                out.append(provider_id)
    for key, value in env.items():
        if key.endswith("_OPENCODE_BASE_URL") and value:
            provider_id = normalize_provider_id(key[: -len("_OPENCODE_BASE_URL")])
            prefix = provider_prefix(provider_id)
            env_key = env.get(f"{prefix}_OPENCODE_ENV_KEY") or f"{prefix}_OPENCODE_AUTH_TOKEN"
            if env.get(f"{prefix}_OPENCODE_MODEL") and env_key and env.get(env_key) and provider_id not in out:
                out.append(provider_id)
    return out


def provider_has_anthropic_adapter(env: dict[str, str], provider_id: str) -> bool:
    prefix = provider_prefix(provider_id)
    return bool(env.get(f"{prefix}_ANTHROPIC_BASE_URL") and env.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN") and env.get(f"{prefix}_ANTHROPIC_MODEL"))


def provider_has_codex_responses_adapter(
    env: dict[str, str],
    provider_id: str,
    *,
    wire_api_case_sensitive: bool = False,
) -> bool:
    prefix = provider_prefix(provider_id)
    env_key = env.get(f"{prefix}_CODEX_ENV_KEY") or f"{prefix}_CODEX_AUTH_TOKEN"
    wire_api = env.get(f"{prefix}_CODEX_WIRE_API") or "responses"
    wire_api_ok = wire_api == "responses" if wire_api_case_sensitive else wire_api.strip().lower() == "responses"
    return bool(
        env.get(f"{prefix}_CODEX_BASE_URL")
        and env.get(f"{prefix}_CODEX_MODEL")
        and env_key
        and env.get(env_key)
        and wire_api_ok
    )


def provider_has_opencode_adapter(
    env: dict[str, str],
    provider_id: str,
    *,
    require_explicit_env_key: bool = False,
) -> bool:
    prefix = provider_prefix(provider_id)
    env_key = env.get(f"{prefix}_OPENCODE_ENV_KEY")
    if not env_key and not require_explicit_env_key:
        env_key = f"{prefix}_OPENCODE_AUTH_TOKEN"
    return bool(env.get(f"{prefix}_OPENCODE_BASE_URL") and env.get(f"{prefix}_OPENCODE_MODEL") and env_key and env.get(env_key))


def provider_codex_adapter_kind(env: dict[str, str], provider_id: str) -> str:
    prefix = provider_prefix(provider_id)
    relay = (env.get(f"{prefix}_CODEX_RELAY") or "").strip().lower().replace("_", "-")
    upstream_wire_api = (env.get(f"{prefix}_CODEX_UPSTREAM_WIRE_API") or "").strip().lower().replace("_", "-")
    if relay or upstream_wire_api in {"chat-completions", "openai-chat-completions"}:
        return "openai-chat-completions-relay"
    return "openai-responses"


def provider_allows_agent(env: dict[str, str], provider_id: str, agent_id: str) -> bool:
    prefix = provider_prefix(provider_id)
    raw = env.get(f"{prefix}_SUPPORTED_AGENTS", "")
    if raw:
        allowed = {normalize_agent_id(item) for item in raw.split(",") if str(item or "").strip()}
        return normalize_agent_id(agent_id) in allowed
    return True


def provider_capabilities_from_env(
    env: dict[str, str],
    *,
    provider_filter: list[str] | None = None,
    agent_filter: list[str] | None = None,
    codex_wire_api_case_sensitive: bool = False,
    opencode_requires_explicit_env_key: bool = False,
) -> list[dict[str, Any]]:
    allowed_providers = {normalize_provider_id(item) for item in (provider_filter or []) if str(item or "").strip()}
    allowed_agents = {normalize_agent_id(item) for item in (agent_filter or []) if str(item or "").strip()}
    capabilities: list[dict[str, Any]] = []
    for provider_id in provider_ids_from_env(env):
        if allowed_providers and provider_id not in allowed_providers:
            continue
        if provider_has_anthropic_adapter(env, provider_id) and provider_allows_agent(env, provider_id, "claude") and (not allowed_agents or "claude" in allowed_agents):
            capabilities.append({
                "provider_id": provider_id,
                "agent_id": "claude",
                "adapter_kind": "anthropic",
                "status": "configured",
                "enabled": True,
            })
        if (
            provider_has_codex_responses_adapter(
                env,
                provider_id,
                wire_api_case_sensitive=codex_wire_api_case_sensitive,
            )
            and provider_allows_agent(env, provider_id, "codex")
            and (not allowed_agents or "codex" in allowed_agents)
        ):
            capabilities.append({
                "provider_id": provider_id,
                "agent_id": "codex",
                "adapter_kind": provider_codex_adapter_kind(env, provider_id),
                "status": "configured",
                "enabled": True,
            })
        if (
            provider_has_opencode_adapter(
                env,
                provider_id,
                require_explicit_env_key=opencode_requires_explicit_env_key,
            )
            and provider_allows_agent(env, provider_id, "opencode")
            and (not allowed_agents or "opencode" in allowed_agents)
        ):
            capabilities.append({
                "provider_id": provider_id,
                "agent_id": "opencode",
                "adapter_kind": "opencode",
                "status": "configured",
                "enabled": True,
            })
    return capabilities


def default_agent_from_provider_env(env: dict[str, str], provider_id: str) -> str:
    if provider_has_anthropic_adapter(env, provider_id):
        return "claude"
    if provider_has_codex_responses_adapter(env, provider_id):
        return "codex"
    if provider_has_opencode_adapter(env, provider_id):
        return "opencode"
    return "claude"


def builtin_supported_agents(existing: dict[str, str], prefix: str) -> str:
    raw = existing.get(f"{prefix}_SUPPORTED_AGENTS", "").strip()
    if not raw:
        return ",".join(ORDERED_AGENT_IDS)
    agents = [normalize_agent_id(item) for item in raw.split(",") if item.strip()]
    if set(agents) == {"claude", "codex"}:
        return ",".join(ORDERED_AGENT_IDS)
    return ",".join(agents)


def parse_capabilities(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, str):
        import json

        try:
            value = json.loads(value or "[]")
        except json.JSONDecodeError:
            value = []
    if not isinstance(value, list):
        return []
    out: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        provider_id = normalize_provider_id(item.get("provider_id") or item.get("provider"), default="")
        agent_id = normalize_agent_id(item.get("agent_id") or item.get("agent"))
        if not provider_id or not agent_id:
            continue
        out.append({
            "provider_id": provider_id,
            "agent_id": agent_id,
            "adapter_kind": normalize_agent_id(item.get("adapter_kind") or item.get("adapter") or default_adapter_kind(agent_id), default_adapter_kind(agent_id)),
            "status": normalize_agent_id(item.get("status") or "configured", "configured"),
            "enabled": capability_enabled_value(item.get("enabled"), True),
        })
    return out
