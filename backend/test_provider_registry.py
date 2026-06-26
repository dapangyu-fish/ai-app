#!/usr/bin/env python3
"""Provider registry behavior checks.

This is intentionally dependency-free so it can run on control hosts without
starting Flask or loading backend service dependencies.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from providers import registry  # noqa: E402


def _env() -> dict[str, str]:
    return {
        "AI_PROVIDER_IDS": "deepseek,minimax",
        "DEEPSEEK_ANTHROPIC_AUTH_TOKEN": "deepseek-token",
        "MINIMAX_ANTHROPIC_AUTH_TOKEN": "minimax-token",
    }


def test_builtin_provider_defaults() -> None:
    providers = registry.build_providers(_env())

    deepseek = providers["deepseek"]
    assert deepseek["name"] == "DeepSeek V4 Pro"
    assert deepseek["supported_agents"] == ["claude", "codex", "opencode"]
    assert deepseek["codex"]["relay"] == "codex-relay"
    assert deepseek["codex"]["upstream_wire_api"] == "chat-completions"
    assert deepseek["codex"]["context_window"] == "262144"
    assert deepseek["opencode"]["provider_npm"] == "@ai-sdk/openai-compatible"

    minimax = providers["minimax"]
    assert minimax["name"] == "MiniMax M3"
    assert minimax["supported_agents"] == ["claude", "codex", "opencode"]
    assert minimax["codex"]["relay"] == ""
    assert minimax["codex"]["context_window"] == "512000"
    assert minimax["opencode"]["provider_npm"] == "@ai-sdk/openai-compatible"


def test_capabilities_from_env() -> None:
    env = {
        **_env(),
        "DEEPSEEK_ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
        "DEEPSEEK_ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
        "DEEPSEEK_CODEX_BASE_URL": "https://api.deepseek.com/v1",
        "DEEPSEEK_CODEX_MODEL": "deepseek-v4-pro",
        "DEEPSEEK_CODEX_ENV_KEY": "DEEPSEEK_ANTHROPIC_AUTH_TOKEN",
        "DEEPSEEK_CODEX_WIRE_API": "responses",
        "DEEPSEEK_CODEX_RELAY": "codex-relay",
        "DEEPSEEK_OPENCODE_BASE_URL": "https://api.deepseek.com/v1",
        "DEEPSEEK_OPENCODE_MODEL": "deepseek-v4-pro",
        "DEEPSEEK_OPENCODE_ENV_KEY": "DEEPSEEK_ANTHROPIC_AUTH_TOKEN",
    }
    capabilities = registry.provider_capabilities_from_env(env, provider_filter=["deepseek"])
    assert capabilities == [
        {
            "provider_id": "deepseek",
            "agent_id": "claude",
            "adapter_kind": "anthropic",
            "status": "configured",
            "enabled": True,
        },
        {
            "provider_id": "deepseek",
            "agent_id": "codex",
            "adapter_kind": "openai-chat-completions-relay",
            "status": "configured",
            "enabled": True,
        },
        {
            "provider_id": "deepseek",
            "agent_id": "opencode",
            "adapter_kind": "opencode",
            "status": "configured",
            "enabled": True,
        },
    ]


def test_native_codex_provider() -> None:
    env = {
        "AI_PROVIDER_IDS": "native-codex",
        "NATIVE_CODEX_CODEX_AUTH_MODE": "native",
        "NATIVE_CODEX_CODEX_WIRE_API": "native",
        "NATIVE_CODEX_CODEX_MODEL": "gpt-5.5",
        "NATIVE_CODEX_CODEX_HOME_PATH": "/home/fish/.codex",
        "NATIVE_CODEX_CODEX_MACHINE_ID_PATH": "/etc/machine-id",
        "NATIVE_CODEX_CODEX_CONTAINER_USER": "1000:1000",
    }
    providers = registry.build_providers(env)
    native = providers["native-codex"]
    assert native["configured"] is True
    assert native["supported_agents"] == ["codex"]
    assert native["codex"]["configured"] is True
    assert native["codex"]["auth_mode"] == "native"
    assert native["codex"]["wire_api"] == "native"
    assert native["codex"]["home_path"] == "/home/fish/.codex"
    assert native["codex"]["container_user"] == "1000:1000"
    assert registry.provider_capabilities_from_env(env) == [
        {
            "provider_id": "native-codex",
            "agent_id": "codex",
            "adapter_kind": "native-codex",
            "status": "configured",
            "enabled": True,
        }
    ]


if __name__ == "__main__":
    test_builtin_provider_defaults()
    test_capabilities_from_env()
    test_native_codex_provider()
    print(json.dumps({"ok": True}, sort_keys=True))
