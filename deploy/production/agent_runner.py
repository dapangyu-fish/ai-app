#!/usr/bin/env python3
"""Run one AI agent turn inside the isolated agent runtime container.

The agent-node service owns Docker and writes the payload file. This runner only
accepts structured payload fields and builds the supported CLI command itself,
so agent-node is not an arbitrary remote shell.
"""

from __future__ import annotations

import json
import os
import re
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
        "OPENCODE_HOME": "/home/agent",
    }
    allowed_prefixes = (
        "ANTHROPIC_",
        "CLAUDE_CODE_",
        "API_TIMEOUT_MS",
        "AI_APP_",
        "CODEX_",
        "OPENCODE_",
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


def _opencode_provider_key(payload: dict) -> str:
    codex = payload.get("codex") or {}
    provider_key = _str(codex.get("opencode_provider_id") or codex.get("provider_id") or payload.get("provider_id") or "custom")
    return provider_key.strip().lower().replace("_", "-") or "custom"


def _opencode_provider_npm(codex: dict) -> str:
    configured = _str(codex.get("opencode_provider_npm") or codex.get("opencode_npm")).strip()
    if configured:
        return configured
    wire_api = _normalize_flag(codex.get("opencode_wire_api") or codex.get("wire_api"))
    if wire_api == "responses":
        return "@ai-sdk/openai"
    return "@ai-sdk/openai-compatible"


def _opencode_config(payload: dict) -> tuple[str, Path]:
    codex = payload.get("codex") or {}
    provider_key = _opencode_provider_key(payload)
    provider_name = _str(codex.get("opencode_provider_name") or codex.get("provider_name") or provider_key)
    model = _str(codex.get("opencode_model") or codex.get("model")).strip()
    base_url = _str(codex.get("opencode_base_url") or codex.get("base_url")).strip()
    env_key = _str(codex.get("opencode_env_key") or codex.get("env_key")).strip()
    if not model or not base_url or not env_key:
        raise RuntimeError("opencode requires model, base_url, and env_key")
    provider_npm = _opencode_provider_npm(codex)
    model_ref = f"{provider_key}/{model}"
    config = {
        "$schema": "https://opencode.ai/config.json",
        "model": model_ref,
        "enabled_providers": [provider_key],
        "provider": {
            provider_key: {
                "npm": provider_npm,
                "name": provider_name,
                "options": {
                    "baseURL": base_url,
                    "apiKey": f"{{env:{env_key}}}",
                },
                "models": {
                    model: {
                        "name": _str(codex.get("opencode_model_name") or model),
                    }
                },
            }
        },
    }
    config_path = Path(WORKSPACE) / ".opencode-runtime.json"
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return model_ref, config_path


def _opencode_cmd(payload: dict) -> tuple[list[str], Path]:
    model_ref, config_path = _opencode_config(payload)
    cmd = [
        os.environ.get("OPENCODE_BIN", "/usr/local/bin/opencode"),
        "run",
        "--format",
        "json",
        "--model",
        model_ref,
        "--agent",
        _str((payload.get("codex") or {}).get("opencode_agent") or "build"),
        "--dangerously-skip-permissions",
        "--log-level",
        _str(os.environ.get("OPENCODE_LOG_LEVEL") or "ERROR"),
    ]
    resume_id = _str(payload.get("resume_id")).strip()
    if resume_id:
        cmd.extend(["--session", resume_id])
    cmd.append(_str(payload.get("prompt")))
    return cmd, config_path


def _opencode_session_id(stdout_chunks: list[str]) -> str:
    session_id = ""
    for chunk in stdout_chunks:
        for line in chunk.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            value = _str(event.get("sessionID") or event.get("session_id")).strip()
            if value:
                session_id = value
    return session_id


def _opencode_db_candidates(env: dict) -> list[Path]:
    home = Path(_str(env.get("HOME") or "/home/agent"))
    opencode_home = Path(_str(env.get("OPENCODE_HOME") or home))
    candidates = [
        home / ".local/share/opencode/opencode.db",
        opencode_home / ".local/share/opencode/opencode.db",
        opencode_home / "opencode.db",
    ]
    out: list[Path] = []
    seen: set[str] = set()
    for path in candidates:
        text = str(path)
        if text in seen:
            continue
        seen.add(text)
        out.append(path)
    return out


def _opencode_latest_session_id(env: dict, since_ms: int) -> str:
    try:
        import sqlite3
    except Exception:
        return ""
    for db_path in _opencode_db_candidates(env):
        if not db_path.exists():
            continue
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
            try:
                row = conn.execute(
                    """
                    select id
                    from session
                    where time_created >= ? or time_updated >= ?
                    order by time_updated desc, time_created desc
                    limit 1
                    """,
                    (since_ms, since_ms),
                ).fetchone()
            finally:
                conn.close()
        except Exception:
            continue
        if row and row[0]:
            return _str(row[0]).strip()
    return ""


def _extract_opencode_export_json(raw: str) -> dict:
    start = raw.find("{")
    if start < 0:
        return {}
    try:
        return json.loads(raw[start:])
    except json.JSONDecodeError:
        return {}


def _split_inline_think(text: str) -> tuple[str, str]:
    thinking_parts: list[str] = []

    def replace(match: re.Match) -> str:
        thinking = _str(match.group(1)).strip()
        if thinking:
            thinking_parts.append(thinking)
        return ""

    cleaned = re.sub(r"<think>\s*(.*?)\s*</think>", replace, text, flags=re.IGNORECASE | re.DOTALL).strip()
    return "\n".join(thinking_parts).strip(), cleaned


def _emit_opencode_export(session_id: str, env: dict) -> None:
    if not session_id:
        return
    try:
        proc = subprocess.run(
            [os.environ.get("OPENCODE_BIN", "/usr/local/bin/opencode"), "export", session_id],
            cwd=PROJECT_ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=float(os.environ.get("OPENCODE_EXPORT_TIMEOUT_SECONDS", "30")),
        )
    except subprocess.TimeoutExpired:
        print(
            json.dumps(
                {
                    "type": "opencode_export_error",
                    "sessionID": session_id,
                    "message": "OpenCode export timed out",
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
        return
    if proc.returncode != 0:
        message = (proc.stderr or proc.stdout or "").strip()
        print(json.dumps({"type": "opencode_export_error", "sessionID": session_id, "message": message}, ensure_ascii=False), flush=True)
        return
    data = _extract_opencode_export_json(proc.stdout or "")
    reasoning_parts: list[str] = []
    text_parts: list[str] = []
    for message in data.get("messages") or []:
        if not isinstance(message, dict):
            continue
        if (message.get("info") or {}).get("role") != "assistant":
            continue
        reasoning_parts = []
        text_parts = []
        for part in message.get("parts") or []:
            if not isinstance(part, dict):
                continue
            text = _str(part.get("text")).strip()
            if not text:
                continue
            if part.get("type") == "reasoning":
                reasoning_parts.append(text)
            elif part.get("type") == "text":
                inline_thinking, cleaned_text = _split_inline_think(text)
                if inline_thinking:
                    reasoning_parts.append(inline_thinking)
                if cleaned_text:
                    text_parts.append(cleaned_text)
    print(
        json.dumps(
            {
                "type": "opencode_export",
                "sessionID": session_id,
                "reasoning": "\n".join(reasoning_parts).strip(),
                "text": "\n".join(text_parts).strip(),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )


def _relay(prefix: str, stream: Iterable[bytes], sink: list[str] | None = None) -> None:
    target = sys.stdout if prefix == "stdout" else sys.stderr
    for raw in stream:
        text = raw.decode("utf-8", errors="replace")
        if sink is not None:
            sink.append(text)
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
    elif agent_id == "opencode":
        cmd, config_path = _opencode_cmd(payload)
        env["OPENCODE_CONFIG"] = str(config_path)
        stdin_data = None
    elif agent_id == "claude":
        cmd = _claude_cmd(payload)
        stdin_data = None
    else:
        print(f"unsupported agent_id: {agent_id}", file=sys.stderr)
        return 2

    try:
        opencode_started_ms = int(time.time() * 1000) if agent_id == "opencode" else 0
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
        stdout_chunks: list[str] = []
        stdout_sink = stdout_chunks if agent_id == "opencode" else None
        threads = [
            threading.Thread(target=_relay, args=("stdout", proc.stdout, stdout_sink), daemon=True),
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
        if agent_id == "opencode" and returncode == 0:
            session_id = _opencode_session_id(stdout_chunks) or _opencode_latest_session_id(env, opencode_started_ms)
            _emit_opencode_export(session_id, env)
        return returncode
    finally:
        _stop_process(relay_proc, relay_threads)


if __name__ == "__main__":
    raise SystemExit(main())
