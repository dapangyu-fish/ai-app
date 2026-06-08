#!/usr/bin/env python3
"""Run one AI agent turn inside the isolated agent runtime container.

The agent-node service owns Docker and writes the payload file. This runner only
accepts structured payload fields and builds the supported CLI command itself,
so agent-node is not an arbitrary remote shell.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Iterable, Optional


PROJECT_ROOT = os.environ.get("AI_APP_PROJECT_ROOT", "/app")
WORKSPACE = os.environ.get("AI_APP_WORKSPACE", "/workspace")


def _str(value: object, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


def _toml_string(value: object) -> str:
    return json.dumps(_str(value), ensure_ascii=False)


def _safe_env(payload_env: dict) -> dict:
    env = {
        "HOME": "/home/agent",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": os.environ.get(
            "PATH",
            "/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        ),
        "AI_APP_WORKSPACE": WORKSPACE,
        "AI_APP_PROJECT_ROOT": PROJECT_ROOT,
        "IS_SANDBOX": "1",
        "PYTHONUNBUFFERED": "1",
        "npm_config_cache": "/home/agent/.npm",
        "CODEX_HOME": "/home/agent/.codex",
    }
    allowed_prefixes = (
        "ANTHROPIC_",
        "CLAUDE_CODE_",
        "API_TIMEOUT_MS",
        "AI_APP_",
        "CODEX_",
        "MINIO_PUBLIC_URL",
        "REGISTRY_BASE_URL",
    )
    merged = {}
    for source in (os.environ, payload_env or {}):
        for key, value in source.items():
            merged[str(key)] = value
    for key, value in merged.items():
        key = _str(key).strip()
        if not key or "=" in key:
            continue
        if key in {"PATH", "HOME", "PWD", "SHELL"}:
            continue
        if key == "MYAPP_CODEX_AUTH_TOKEN" or key.startswith(allowed_prefixes) or key in allowed_prefixes:
            env[key] = _str(value)
    return env


def _normalize_flag(value: object) -> str:
    return _str(value).strip().lower().replace("_", "-")


def _codex_needs_relay(codex: dict) -> bool:
    relay = _normalize_flag(codex.get("relay") or codex.get("responses_relay") or codex.get("protocol_relay"))
    upstream_wire_api = _normalize_flag(codex.get("upstream_wire_api") or codex.get("upstream_api"))
    return relay in {"1", "true", "yes", "on", "codex-relay", "chat-completions"} or upstream_wire_api in {
        "chat-completions",
        "openai-chat-completions",
    }


def _free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_port(port: int, proc: subprocess.Popen, timeout_seconds: float = 10.0) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"codex-relay exited early with code {proc.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return
        except OSError as exc:
            last_error = exc
            time.sleep(0.1)
    raise RuntimeError(f"codex-relay did not open 127.0.0.1:{port}: {last_error}")


def _start_codex_relay(payload: dict, env: dict) -> tuple[dict, subprocess.Popen | None, list[threading.Thread]]:
    codex = dict(payload.get("codex") or {})
    if not _codex_needs_relay(codex):
        return payload, None, []

    upstream = _str(codex.get("base_url")).strip().rstrip("/")
    env_key = _str(codex.get("env_key")).strip()
    upstream_token = _str(env.get(env_key)).strip() if env_key else ""
    if not upstream or not upstream_token:
        raise RuntimeError("codex-relay requires codex.base_url and configured codex env token")

    port = _free_local_port()
    relay_env = dict(env)
    relay_env.update(
        {
            "CODEX_RELAY_UPSTREAM": upstream,
            "CODEX_RELAY_API_KEY": upstream_token,
            "CODEX_RELAY_PORT": str(port),
            "RUST_LOG": relay_env.get("CODEX_RELAY_LOG", "codex_relay=warn"),
        }
    )
    relay_bin = _str(codex.get("relay_bin") or os.environ.get("CODEX_RELAY_BIN") or "codex-relay")
    proc = subprocess.Popen(
        [relay_bin],
        cwd=PROJECT_ROOT,
        env=relay_env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    threads: list[threading.Thread] = []
    if proc.stdout is not None:
        threads.append(threading.Thread(target=_relay, args=("stderr", proc.stdout), daemon=True))
    if proc.stderr is not None:
        threads.append(threading.Thread(target=_relay, args=("stderr", proc.stderr), daemon=True))
    for thread in threads:
        thread.start()
    try:
        _wait_for_port(port, proc)
    except Exception:
        _stop_process(proc, threads)
        raise

    relayed_payload = dict(payload)
    relayed_codex = dict(codex)
    relayed_codex["base_url"] = f"http://127.0.0.1:{port}/v1"
    relayed_codex["wire_api"] = "responses"
    relayed_payload["codex"] = relayed_codex
    return relayed_payload, proc, threads


def _stop_process(proc: subprocess.Popen | None, threads: list[threading.Thread]) -> None:
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    for thread in threads:
        thread.join(timeout=1)


def _claude_cmd(payload: dict) -> list[str]:
    cmd = [
        os.environ.get("CLAUDE_BIN", "/usr/local/bin/claude"),
        "--dangerously-skip-permissions",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p",
        _str(payload.get("prompt")),
    ]
    resume_id = _str(payload.get("resume_id")).strip()
    session_id = _str(payload.get("cli_session_id") or payload.get("session_id")).strip()
    system_prompt = _str(payload.get("system_prompt"))
    if resume_id:
        cmd.extend(["-r", resume_id])
    else:
        cmd.extend(["--session-id", session_id])
        if system_prompt:
            cmd.extend(["--append-system-prompt", system_prompt])
    return cmd


def _codex_cmd(payload: dict) -> list[str]:
    codex = payload.get("codex") or {}
    provider_key = _str(codex.get("provider_id") or payload.get("provider_id") or "custom")
    provider_key = provider_key.replace("-", "_")
    provider_name = _str(codex.get("provider_name") or provider_key)
    cmd = [
        os.environ.get("CODEX_BIN", "/usr/local/bin/codex"),
        "-C",
        PROJECT_ROOT,
        "exec",
    ]
    resume_id = _str(payload.get("resume_id")).strip()
    if resume_id:
        cmd.append("resume")
    cmd.extend(
        [
            "--json",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
            "--output-last-message",
            str(Path(WORKSPACE) / "codex-last-message.txt"),
            "-c",
            f"model_provider={_toml_string(provider_key)}",
            "-c",
            f"model={_toml_string(codex.get('model', ''))}",
            "-c",
            f"model_providers.{provider_key}.name={_toml_string(provider_name)}",
            "-c",
            f"model_providers.{provider_key}.base_url={_toml_string(codex.get('base_url', ''))}",
            "-c",
            f"model_providers.{provider_key}.env_key={_toml_string(codex.get('env_key', ''))}",
            "-c",
            f"model_providers.{provider_key}.wire_api={_toml_string(codex.get('wire_api', 'responses'))}",
        ]
    )
    context_window = _str(codex.get("context_window")).strip()
    if context_window.isdigit():
        cmd.extend(["-c", f"model_context_window={context_window}"])
    if resume_id:
        cmd.extend([resume_id, "-"])
    else:
        cmd.append("-")
    return cmd


def _relay(prefix: str, stream: Iterable[bytes]) -> None:
    target = sys.stdout if prefix == "stdout" else sys.stderr
    for raw in stream:
        text = raw.decode("utf-8", errors="replace")
        target.write(text)
        target.flush()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: agent_runner.py <payload.json>", file=sys.stderr)
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    agent_id = _str(payload.get("agent_id"), "claude").lower().replace("_", "-")
    env = _safe_env(payload.get("env") or {})
    Path(WORKSPACE).mkdir(parents=True, exist_ok=True)
    relay_proc: subprocess.Popen | None = None
    relay_threads: list[threading.Thread] = []
    if agent_id == "codex":
        payload, relay_proc, relay_threads = _start_codex_relay(payload, env)
        cmd = _codex_cmd(payload)
        stdin_data = _str(payload.get("prompt")).encode("utf-8")
    elif agent_id == "claude":
        cmd = _claude_cmd(payload)
        stdin_data = None
    else:
        print(f"unsupported agent_id: {agent_id}", file=sys.stderr)
        return 2

    try:
        proc = subprocess.Popen(
            cmd,
            cwd=PROJECT_ROOT,
            env=env,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert proc.stdout is not None
        assert proc.stderr is not None
        threads = [
            threading.Thread(target=_relay, args=("stdout", proc.stdout), daemon=True),
            threading.Thread(target=_relay, args=("stderr", proc.stderr), daemon=True),
        ]
        for thread in threads:
            thread.start()
        if stdin_data is not None:
            assert proc.stdin is not None
            proc.stdin.write(stdin_data)
            proc.stdin.close()
        returncode = proc.wait()
        for thread in threads:
            thread.join(timeout=1)
        return returncode
    finally:
        _stop_process(relay_proc, relay_threads)


if __name__ == "__main__":
    raise SystemExit(main())
