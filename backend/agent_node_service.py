#!/usr/bin/env python3
"""Agent node service.

Each agent host runs this service close to Docker. The backend submits
structured AI runs to it; the node starts one isolated runtime container per run
and streams the container output back as JSONL events.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin

import requests
import jwt
from flask import Flask, Response, jsonify, request, send_file, stream_with_context


APP = Flask(__name__)

NODE_ID = os.environ.get("AGENT_NODE_ID", os.uname().nodename)
NODE_NAME = os.environ.get("AGENT_NODE_NAME", NODE_ID).strip()[:128] or NODE_ID
RUNTIME_IMAGE = os.environ.get("AGENT_NODE_RUNTIME_IMAGE", "dapangyufish/myapp-agent-runtime:latest")
STATE_ROOT = Path(os.environ.get("AGENT_NODE_STATE_ROOT", "/var/lib/myapp/agent-node/state"))
WORKSPACE_ROOT = Path(os.environ.get("AGENT_NODE_WORKSPACE_ROOT", "/var/lib/myapp/agent-node/workspaces"))
HOST_STATE_ROOT = Path(os.environ.get("AGENT_NODE_HOST_STATE_ROOT", str(STATE_ROOT)))
HOST_WORKSPACE_ROOT = Path(os.environ.get("AGENT_NODE_HOST_WORKSPACE_ROOT", str(WORKSPACE_ROOT)))
LOG_DIR = Path(os.environ.get("AGENT_NODE_LOG_DIR", "/var/log/myapp/agent-node"))
PROJECT_ROOT = os.environ.get("AGENT_NODE_PROJECT_ROOT", "/app")
CONTAINER_CPUS = os.environ.get("AGENT_NODE_CONTAINER_CPUS", "2")
CONTAINER_MEMORY = os.environ.get("AGENT_NODE_CONTAINER_MEMORY", "2g")
CONTAINER_PIDS_LIMIT = os.environ.get("AGENT_NODE_CONTAINER_PIDS_LIMIT", "512")
DOCKER_NETWORK = os.environ.get("AGENT_NODE_DOCKER_NETWORK", "myapp_default")
ALLOW_HOST_GATEWAY = os.environ.get("AGENT_NODE_ALLOW_HOST_GATEWAY", "0").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
PROVIDER_PROXY_BASE_URL = os.environ.get("AGENT_NODE_PROVIDER_PROXY_BASE_URL", "http://agent-node:5590").rstrip("/")
PROVIDER_PROXY_TOKEN_TTL_SECONDS = int(os.environ.get("AGENT_NODE_PROVIDER_PROXY_TOKEN_TTL_SECONDS", "21600"))
PROVIDER_PROXY_CONNECT_TIMEOUT_SECONDS = float(os.environ.get("AGENT_NODE_PROVIDER_PROXY_CONNECT_TIMEOUT_SECONDS", "30"))
PROVIDER_PROXY_READ_TIMEOUT_SECONDS = float(os.environ.get("AGENT_NODE_PROVIDER_PROXY_READ_TIMEOUT_SECONDS", "900"))
INITIAL_FILES_MAX_BYTES = int(os.environ.get("AGENT_NODE_INITIAL_FILES_MAX_BYTES", str(20 * 1024 * 1024)))
NODE_TOKEN = os.environ.get("AGENT_NODE_TOKEN", "")
REGISTRATION_TOKEN = os.environ.get("AGENT_NODE_REGISTRATION_TOKEN", NODE_TOKEN)
AUTH_MODE = os.environ.get("AGENT_NODE_AUTH_MODE", "shared").strip().lower().replace("_", "-")
OWNER_USER_ID = os.environ.get("AGENT_NODE_OWNER_USER_ID", "").strip()
PRIVATE_KEY_PATH = os.environ.get("AGENT_NODE_PRIVATE_KEY_PATH", "").strip()
BUILD_COMMIT = (
    os.environ.get("MYAPP_BUILD_COMMIT")
    or os.environ.get("AGENT_NODE_BUILD_COMMIT")
    or "unknown"
).strip()[:128] or "unknown"
BUILD_VERSION = (
    os.environ.get("MYAPP_BUILD_VERSION")
    or os.environ.get("AGENT_NODE_BUILD_VERSION")
    or BUILD_COMMIT
).strip()[:128] or BUILD_COMMIT
PULL_ENABLED = os.environ.get("AGENT_NODE_PULL_ENABLED", "0").strip().lower() in {"1", "true", "yes", "on"}
PULL_BACKEND_URL = os.environ.get("AGENT_NODE_BACKEND_URL", "").rstrip("/")
PULL_INTERVAL_SECONDS = float(os.environ.get("AGENT_NODE_POLL_INTERVAL_IDLE_SECONDS", "1"))
PULL_TIMEOUT_SECONDS = float(os.environ.get("AGENT_NODE_POLL_TIMEOUT_SECONDS", "5"))
PULL_ERROR_BACKOFF_MAX_SECONDS = float(os.environ.get("AGENT_NODE_POLL_ERROR_BACKOFF_MAX_SECONDS", "30"))
PULL_EVENT_FLUSH_LIVE_SECONDS = float(os.environ.get("AGENT_NODE_EVENT_FLUSH_LIVE_MS", "200")) / 1000.0
PULL_EVENT_FLUSH_BACKGROUND_SECONDS = float(os.environ.get("AGENT_NODE_EVENT_FLUSH_BACKGROUND_SECONDS", "5"))
PULL_EVENT_BATCH_MAX = int(os.environ.get("AGENT_NODE_EVENT_BATCH_MAX", "64"))
try:
    NODE_CAPACITY = max(1, int(os.environ.get("AGENT_NODE_CAPACITY", "1")))
except ValueError:
    NODE_CAPACITY = 1
try:
    NODE_QUEUE_MAX = max(0, int(os.environ.get("AGENT_NODE_QUEUE_MAX", str(NODE_CAPACITY))))
except ValueError:
    NODE_QUEUE_MAX = NODE_CAPACITY
RUN_RETENTION_SECONDS = int(os.environ.get("AGENT_NODE_RUN_RETENTION_SECONDS", "604800"))
RUN_SNAPSHOT_MAX_FILE_BYTES = int(os.environ.get("AGENT_NODE_RUN_SNAPSHOT_MAX_FILE_BYTES", "52428800"))
RUN_SNAPSHOT_MAX_FILES = int(os.environ.get("AGENT_NODE_RUN_SNAPSHOT_MAX_FILES", "5000"))
PROVIDER_MODE = os.environ.get("AGENT_NODE_PROVIDER_MODE", "master").strip().lower().replace("_", "-")
if AUTH_MODE in {"private", "user-private"}:
    PROVIDER_MODE = "local"
PROVIDER_IDS = [
    item.strip().lower().replace("_", "-")
    for item in os.environ.get("AGENT_NODE_PROVIDER_IDS", "").split(",")
    if item.strip()
]
AGENT_IDS = [
    item.strip().lower().replace("_", "-")
    for item in os.environ.get("AGENT_NODE_AGENT_IDS", "claude,codex").split(",")
    if item.strip()
]


def _default_adapter_kind(agent_id: str) -> str:
    normalized = str(agent_id or "").strip().lower().replace("_", "-")
    if normalized == "claude":
        return "anthropic"
    if normalized == "codex":
        return "openai-responses"
    return normalized or "unknown"


def _capability_enabled_value(value: object, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off", "disabled"}
    return bool(value)


def _provider_allows_agent(provider_id: str, agent_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    raw = str(os.environ.get(f"{prefix}_SUPPORTED_AGENTS") or "").strip()
    if raw:
        allowed = {
            item.strip().lower().replace("_", "-")
            for item in raw.split(",")
            if item.strip()
        }
        return str(agent_id or "").strip().lower().replace("_", "-") in allowed
    return True


def _configured_capabilities() -> list[dict]:
    raw = os.environ.get("AGENT_NODE_CAPABILITIES", "").strip()
    if raw:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = []
        if isinstance(parsed, list):
            out = []
            for item in parsed:
                if not isinstance(item, dict):
                    continue
                provider_id = str(item.get("provider_id") or item.get("provider") or "").strip().lower().replace("_", "-")
                agent_id = str(item.get("agent_id") or item.get("agent") or "").strip().lower().replace("_", "-")
                if not provider_id or not agent_id:
                    continue
                out.append(
                    {
                        "provider_id": provider_id,
                        "agent_id": agent_id,
                        "adapter_kind": str(item.get("adapter_kind") or item.get("adapter") or _default_adapter_kind(agent_id)).strip().lower().replace("_", "-"),
                        "status": str(item.get("status") or "configured").strip().lower().replace("_", "-"),
                        "enabled": _capability_enabled_value(item.get("enabled"), True),
                    }
                )
            if out:
                return out
    if PROVIDER_MODE != "local":
        return []
    out = []
    for provider_id in PROVIDER_IDS:
        prefix = _provider_prefix(provider_id)
        anthropic_ok = (
            _local_provider_value(prefix, "ANTHROPIC_BASE_URL")
            and _local_provider_value(prefix, "ANTHROPIC_AUTH_TOKEN")
            and _local_provider_value(prefix, "ANTHROPIC_MODEL")
        )
        if anthropic_ok and _provider_allows_agent(provider_id, "claude") and (not AGENT_IDS or "claude" in AGENT_IDS):
            out.append(
                {
                    "provider_id": provider_id,
                    "agent_id": "claude",
                    "adapter_kind": "anthropic",
                    "status": "configured",
                    "enabled": True,
                }
            )
        codex_env_key = _local_provider_value(prefix, "CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN")
        codex_ok = (
            _local_provider_value(prefix, "CODEX_BASE_URL")
            and _local_provider_value(prefix, "CODEX_MODEL")
            and codex_env_key
            and os.environ.get(codex_env_key, "")
            and _local_provider_value(prefix, "CODEX_WIRE_API", "responses") == "responses"
        )
        if codex_ok and _provider_allows_agent(provider_id, "codex") and (not AGENT_IDS or "codex" in AGENT_IDS):
            out.append(
                {
                    "provider_id": provider_id,
                    "agent_id": "codex",
                    "adapter_kind": "openai-responses",
                    "status": "configured",
                    "enabled": True,
                }
            )
    return out
_RUNS: dict[str, dict] = {}
_RUNS_LOCK = threading.Lock()
_PULL_RUNS_LOCK = threading.Lock()
_PULL_STARTING_RUNS: set[str] = set()
_ABORT_MARKERS: dict[str, int] = {}
_PROXY_TOKENS: dict[str, dict] = {}
_PROXY_LOCK = threading.Lock()
_CLEANUP_THREAD_STARTED = False
_CLEANUP_THREAD_LOCK = threading.Lock()
_ACTIVE_RUN_STATUSES = {"starting", "running"}
_ABORT_MARKER_TTL_MS = 5 * 60 * 1000
_SNAPSHOT_SKIP_DIRS = {
    ".cache",
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "build",
    "node_modules",
}
_RUN_MARKER_FILES = {"client_actions.json"}


def _now_ms() -> int:
    return int(time.time() * 1000)


def _safe_part(value: object, fallback: str) -> str:
    text = str(value or "").strip()
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("._")
    return text[:96] or fallback


def _json_line(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")


def _auth_ok() -> bool:
    if not NODE_TOKEN:
        return True
    header = request.headers.get("Authorization", "")
    return header == f"Bearer {NODE_TOKEN}"


@APP.before_request
def _require_auth():
    if request.path == "/health" or request.path.startswith("/proxy/"):
        return None
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    return None


def _run_log_path(run_id: str) -> Path:
    return LOG_DIR / f"{_safe_part(run_id, 'run')}.jsonl"


def _run_payload_path(run_id: str) -> Path:
    return WORKSPACE_ROOT / "_payloads" / f"{_safe_part(run_id, 'run')}.json"


def _docker_bind_source(path: Path) -> Path:
    """Translate agent-node container paths to host paths for Docker bind mounts."""
    try:
        return HOST_STATE_ROOT / path.relative_to(STATE_ROOT)
    except ValueError:
        pass
    try:
        return HOST_WORKSPACE_ROOT / path.relative_to(WORKSPACE_ROOT)
    except ValueError:
        return path


def _session_paths(user_id: str, session_id: str, job_id: str) -> dict[str, Path]:
    safe_user = _safe_part(user_id, "user")
    safe_session = _safe_part(session_id, "session")
    safe_job = _safe_part(job_id, "job")
    session_root = STATE_ROOT / safe_user / safe_session
    workspace_session_root = WORKSPACE_ROOT / safe_user / safe_session
    return {
        "claude": session_root / "claude",
        "claude_config": session_root / ".claude.json",
        "codex": session_root / "codex",
        "session_workspace": workspace_session_root,
        "runs_root": workspace_session_root / "runs",
        "workspace": workspace_session_root / "current",
        "run_workspace": workspace_session_root / "runs" / safe_job,
    }


def _clear_run_markers(workspace: Path) -> None:
    for name in _RUN_MARKER_FILES:
        path = workspace / name
        try:
            if path.is_file() or path.is_symlink():
                path.unlink()
        except OSError:
            pass


def _copy_workspace_snapshot(source: Path, target: Path, log_path: Path) -> None:
    if not source.exists():
        return
    tmp = target.with_name(f".{target.name}.tmp-{uuid.uuid4().hex[:8]}")
    if tmp.exists():
        shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    copied_files = 0
    copied_bytes = 0
    skipped_files = 0
    try:
        for root, dirs, files in os.walk(source):
            root_path = Path(root)
            dirs[:] = [
                name
                for name in dirs
                if name not in _SNAPSHOT_SKIP_DIRS and not name.startswith(".tmp-")
            ]
            rel_root = root_path.relative_to(source)
            for name in files:
                if copied_files >= RUN_SNAPSHOT_MAX_FILES:
                    skipped_files += 1
                    continue
                src = root_path / name
                try:
                    if src.is_symlink() or not src.is_file():
                        skipped_files += 1
                        continue
                    size = src.stat().st_size
                    if size > RUN_SNAPSHOT_MAX_FILE_BYTES:
                        skipped_files += 1
                        continue
                    dst = tmp / rel_root / name
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
                    copied_files += 1
                    copied_bytes += size
                except OSError:
                    skipped_files += 1
        if target.exists():
            shutil.rmtree(target)
        tmp.replace(target)
        _json_line(
            log_path,
            {
                "type": "workspace_snapshot",
                "path": str(target),
                "files": copied_files,
                "bytes": copied_bytes,
                "skipped": skipped_files,
                "ts": _now_ms(),
            },
        )
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def _safe_workspace_file(workspace: Path, relative_path: object) -> Path:
    text = str(relative_path or "").replace("\\", "/").lstrip("/")
    if not text or "\x00" in text:
        raise ValueError("initial file path is empty or invalid")
    root = workspace.resolve()
    target = (workspace / text).resolve()
    if target == root or root not in target.parents:
        raise ValueError(f"initial file path escapes workspace: {text}")
    return target


def _write_initial_files(workspace: Path, initial_files: object) -> None:
    if initial_files in (None, "", []):
        return
    if not isinstance(initial_files, list):
        raise ValueError("initial_files must be a list")
    if len(initial_files) > 20:
        raise ValueError("too many initial files")

    total_bytes = 0
    for item in initial_files:
        if not isinstance(item, dict):
            raise ValueError("initial file entry must be an object")
        target = _safe_workspace_file(workspace, item.get("path") or item.get("name"))
        if "content_b64" in item:
            import base64

            data = base64.b64decode(str(item.get("content_b64") or ""), validate=True)
        else:
            data = str(item.get("content") or "").encode("utf-8")
        total_bytes += len(data)
        if total_bytes > INITIAL_FILES_MAX_BYTES:
            raise ValueError("initial files exceed size limit")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def _secret_redactions(payload: dict) -> list[str]:
    values: list[str] = []
    env = payload.get("env") if isinstance(payload.get("env"), dict) else {}
    for key, value in env.items():
        upper = str(key).upper()
        if any(marker in upper for marker in ("TOKEN", "KEY", "SECRET", "PASSWORD")):
            text = str(value or "")
            if len(text) >= 8:
                values.append(text)
    for token in payload.get("_proxy_tokens") or []:
        text = str(token or "")
        if len(text) >= 8:
            values.append(text)
    values.sort(key=len, reverse=True)
    deduped: list[str] = []
    seen = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        deduped.append(value)
    return deduped


def _redact_text(text: str, redactions: list[str]) -> str:
    for value in redactions:
        text = text.replace(value, f"<redacted len={len(value)}>")
    return text


def _issue_proxy_token(run_id: str, upstream_base_url: str, upstream_token: str, *, provider_id: str, agent_id: str) -> str:
    token = secrets.token_urlsafe(32)
    with _PROXY_LOCK:
        _PROXY_TOKENS[token] = {
            "run_id": run_id,
            "provider_id": provider_id,
            "agent_id": agent_id,
            "upstream_base_url": upstream_base_url.rstrip("/"),
            "upstream_token": upstream_token,
            "created_at": time.time(),
            "expires_at": time.time() + PROVIDER_PROXY_TOKEN_TTL_SECONDS,
        }
    return token


def _provider_prefix(provider_id: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "_", str(provider_id or "").upper()).strip("_")


def _local_provider_value(prefix: str, key: str, default: str = "") -> str:
    return str(os.environ.get(f"{prefix}_{key}") or default or "").strip()


CAPABILITIES = _configured_capabilities()


def _apply_local_provider(payload: dict) -> None:
    """Optionally replace backend-provided provider credentials with node-local ones.

    master mode keeps today's central-key behavior: backend sends provider config
    to this agent-node, then the node mints a per-run proxy token for the runtime
    container. local mode lets an agent host use its own ai-providers.env so large
    hosts can carry separate provider quotas/keys without exposing them to the
    backend process.
    """
    mode = PROVIDER_MODE or "master"
    if mode in {"master", "backend", "remote"}:
        return
    if mode not in {"local", "node", "self", "agent-local"}:
        raise ValueError(f"unsupported AGENT_NODE_PROVIDER_MODE: {mode}")

    provider_id = str(payload.get("provider_id") or "").strip().lower().replace("_", "-")
    agent_id = str(payload.get("agent_id") or "claude").strip().lower().replace("_", "-")
    prefix = _provider_prefix(provider_id)
    if not prefix:
        raise ValueError("local provider mode requires provider_id")

    env = dict(payload.get("env") or {})
    codex = dict(payload.get("codex") or {})

    anthropic_base_url = _local_provider_value(prefix, "ANTHROPIC_BASE_URL")
    anthropic_token = _local_provider_value(prefix, "ANTHROPIC_AUTH_TOKEN")
    anthropic_model = _local_provider_value(prefix, "ANTHROPIC_MODEL")

    if agent_id == "claude":
        if not anthropic_base_url or not anthropic_token or not anthropic_model:
            raise ValueError(f"local provider {provider_id} is missing Anthropic-compatible config")
        env.update(
            {
                "ANTHROPIC_BASE_URL": anthropic_base_url,
                "ANTHROPIC_AUTH_TOKEN": anthropic_token,
                "ANTHROPIC_MODEL": anthropic_model,
                "ANTHROPIC_DEFAULT_OPUS_MODEL": _local_provider_value(prefix, "ANTHROPIC_DEFAULT_OPUS_MODEL", anthropic_model),
                "ANTHROPIC_DEFAULT_SONNET_MODEL": _local_provider_value(prefix, "ANTHROPIC_DEFAULT_SONNET_MODEL", anthropic_model),
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": _local_provider_value(prefix, "ANTHROPIC_DEFAULT_HAIKU_MODEL", anthropic_model),
                "CLAUDE_CODE_SUBAGENT_MODEL": _local_provider_value(prefix, "CLAUDE_CODE_SUBAGENT_MODEL", anthropic_model),
                "CLAUDE_CODE_EFFORT_LEVEL": _local_provider_value(prefix, "CLAUDE_CODE_EFFORT_LEVEL", "max"),
            }
        )
    elif agent_id == "codex":
        codex_base_url = _local_provider_value(prefix, "CODEX_BASE_URL")
        codex_model = _local_provider_value(prefix, "CODEX_MODEL")
        codex_env_key = _local_provider_value(prefix, "CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN")
        codex_token = str(os.environ.get(codex_env_key) or anthropic_token or "").strip()
        if not codex_base_url or not codex_model or not codex_token:
            raise ValueError(f"local provider {provider_id} is missing Codex config")
        codex.update(
            {
                "provider_name": _local_provider_value(prefix, "CODEX_PROVIDER_NAME", provider_id),
                "base_url": codex_base_url,
                "model": codex_model,
                "wire_api": _local_provider_value(prefix, "CODEX_WIRE_API", "responses"),
                "env_key": "MYAPP_CODEX_AUTH_TOKEN",
                "context_window": _local_provider_value(prefix, "CODEX_CONTEXT_WINDOW", str(codex.get("context_window") or "")),
            }
        )
        env["MYAPP_CODEX_AUTH_TOKEN"] = codex_token
    else:
        raise ValueError(f"local provider mode does not support agent_id: {agent_id}")

    payload["env"] = env
    payload["codex"] = codex


def _revoke_proxy_tokens(tokens: list[str]) -> None:
    if not tokens:
        return
    with _PROXY_LOCK:
        for token in tokens:
            _PROXY_TOKENS.pop(token, None)


def _cleanup_proxy_tokens() -> None:
    now = time.time()
    with _PROXY_LOCK:
        expired = [token for token, data in _PROXY_TOKENS.items() if float(data.get("expires_at") or 0) <= now]
        for token in expired:
            _PROXY_TOKENS.pop(token, None)


def _prepare_provider_proxy(payload: dict) -> list[str]:
    """Replace real provider tokens with per-run proxy tokens before runtime launch."""
    _cleanup_proxy_tokens()
    env = dict(payload.get("env") or {})
    codex = dict(payload.get("codex") or {})
    run_id = str(payload.get("run_id") or "")
    provider_id = str(payload.get("provider_id") or "")
    agent_id = str(payload.get("agent_id") or "")
    issued: list[str] = []

    anthropic_base_url = str(env.get("ANTHROPIC_BASE_URL") or "").strip()
    anthropic_token = str(env.get("ANTHROPIC_AUTH_TOKEN") or "").strip()
    if anthropic_base_url and anthropic_token:
        token = _issue_proxy_token(
            run_id,
            anthropic_base_url,
            anthropic_token,
            provider_id=provider_id,
            agent_id=agent_id,
        )
        issued.append(token)
        env["ANTHROPIC_BASE_URL"] = f"{PROVIDER_PROXY_BASE_URL}/proxy/{token}"
        env["ANTHROPIC_AUTH_TOKEN"] = token

    codex_base_url = str(codex.get("base_url") or "").strip()
    codex_env_key = str(codex.get("env_key") or "").strip()
    codex_token = str(env.get(codex_env_key) or "").strip() if codex_env_key else ""
    if codex_base_url and codex_env_key and codex_token:
        token = _issue_proxy_token(
            run_id,
            codex_base_url,
            codex_token,
            provider_id=provider_id,
            agent_id=agent_id,
        )
        issued.append(token)
        codex["base_url"] = f"{PROVIDER_PROXY_BASE_URL}/proxy/{token}"
        env[codex_env_key] = token

    payload["env"] = env
    payload["codex"] = codex
    payload["_proxy_tokens"] = issued
    return issued


def _docker_cmd(run_id: str, payload: dict, payload_path: Path, paths: dict[str, Path]) -> tuple[list[str], dict]:
    container_name = f"myapp-agent-{_safe_part(run_id, uuid.uuid4().hex)}"
    for key, path in paths.items():
        if key == "claude_config":
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                first_start = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
                path.write_text(json.dumps({"firstStartTime": first_start}) + "\n", encoding="utf-8")
            path.chmod(0o666)
            continue
        path.mkdir(parents=True, exist_ok=True)
        if key == "workspace":
            _clear_run_markers(path)
        path.chmod(0o777)
    payload_path.parent.mkdir(parents=True, exist_ok=True)
    runtime_env = {
        key: str(value)
        for key, value in (payload.get("env") or {}).items()
        if key and "=" not in str(key)
    }
    payload_without_env = dict(payload)
    payload_without_env["env"] = {}
    payload_without_env.pop("_proxy_tokens", None)
    payload_path.write_text(json.dumps(payload_without_env, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    cmd = [
        "docker",
        "run",
        "--rm",
        "--name",
        container_name,
        "--cpus",
        CONTAINER_CPUS,
        "--memory",
        CONTAINER_MEMORY,
        "--pids-limit",
        CONTAINER_PIDS_LIMIT,
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--user",
        "10001:10001",
        "--workdir",
        PROJECT_ROOT,
        "-v",
        f"{_docker_bind_source(paths['claude'])}:/home/agent/.claude:rw",
        "-v",
        f"{_docker_bind_source(paths['claude_config'])}:/home/agent/.claude.json:rw",
        "-v",
        f"{_docker_bind_source(paths['codex'])}:/home/agent/.codex:rw",
        "-v",
        f"{_docker_bind_source(paths['workspace'])}:/workspace:rw",
        "-v",
        f"{_docker_bind_source(payload_path)}:/run/myapp-agent/payload.json:ro",
        "-e",
        "AI_APP_WORKSPACE=/workspace",
        "-e",
        f"AI_APP_PROJECT_ROOT={PROJECT_ROOT}",
    ]
    if ALLOW_HOST_GATEWAY:
        cmd.extend(["--add-host", "host.docker.internal:host-gateway"])
    for key in sorted(runtime_env):
        cmd.extend(["-e", key])
    if DOCKER_NETWORK:
        cmd.extend(["--network", DOCKER_NETWORK])
    cmd.extend([RUNTIME_IMAGE, "python3", "/opt/myapp/agent_runner.py", "/run/myapp-agent/payload.json"])
    docker_env = os.environ.copy()
    docker_env.update(runtime_env)
    return cmd, docker_env


def _pump_stream(log_path: Path, kind: str, stream, redactions: list[str]) -> None:
    assert stream is not None
    for raw in iter(stream.readline, b""):
        line = raw.decode("utf-8", errors="replace")
        if redactions:
            line = _redact_text(line, redactions)
        _json_line(log_path, {"type": kind, "line": line, "ts": _now_ms()})


def _emit_client_actions(log_path: Path, workspace: Path) -> None:
    path = workspace / "client_actions.json"
    if not path.exists():
        return
    try:
        if path.stat().st_size > 65536:
            _json_line(log_path, {"type": "client_actions_error", "message": "client_actions.json too large", "ts": _now_ms()})
            return
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        _json_line(log_path, {"type": "client_actions_error", "message": str(exc), "ts": _now_ms()})
        return
    _json_line(log_path, {"type": "client_actions", "payload": payload, "ts": _now_ms()})


def _start_run_thread(
    run_id: str,
    payload: dict,
    cmd: list[str],
    docker_env: dict,
    log_path: Path,
    paths: dict[str, Path],
    proxy_tokens: list[str],
    redactions: list[str],
) -> None:
    def abort_requested() -> bool:
        with _RUNS_LOCK:
            return bool((_RUNS.get(run_id) or {}).get("abort_requested"))

    def target() -> None:
        proc: Optional[subprocess.Popen] = None
        status = "failed"
        returncode: Optional[int] = None
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                env=docker_env,
                bufsize=0,
            )
            with _RUNS_LOCK:
                if run_id in _RUNS:
                    _RUNS[run_id]["container"] = cmd[cmd.index("--name") + 1] if "--name" in cmd else ""
                    _RUNS[run_id]["pid"] = proc.pid
                    _RUNS[run_id]["status"] = "running"
            _json_line(log_path, {"type": "container_started", "pid": proc.pid, "ts": _now_ms()})
            if abort_requested():
                container = cmd[cmd.index("--name") + 1] if "--name" in cmd else ""
                if container:
                    subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    _json_line(log_path, {"type": "abort_applied", "container": container, "ts": _now_ms()})
            threads = [
                threading.Thread(target=_pump_stream, args=(log_path, "stdout", proc.stdout, redactions), daemon=True),
                threading.Thread(target=_pump_stream, args=(log_path, "stderr", proc.stderr, redactions), daemon=True),
            ]
            for thread in threads:
                thread.start()
            returncode = proc.wait()
            for thread in threads:
                thread.join(timeout=1)
            if returncode == 0:
                status = "done"
            elif abort_requested():
                status = "aborted"
            else:
                status = "failed"
        except Exception as exc:
            _json_line(log_path, {"type": "error", "message": str(exc), "ts": _now_ms()})
            status = "failed"
        finally:
            _revoke_proxy_tokens(proxy_tokens)
            try:
                _copy_workspace_snapshot(paths["workspace"], paths["run_workspace"], log_path)
            except Exception as exc:
                _json_line(log_path, {"type": "workspace_snapshot_error", "message": str(exc), "ts": _now_ms()})
            try:
                _emit_client_actions(log_path, paths["run_workspace"])
            except Exception as exc:
                _json_line(log_path, {"type": "client_actions_error", "message": str(exc), "ts": _now_ms()})
            with _RUNS_LOCK:
                if run_id in _RUNS:
                    _RUNS[run_id]["status"] = status
                    _RUNS[run_id]["returncode"] = returncode
                    _RUNS[run_id]["finished_at"] = _now_ms()
            _json_line(
                log_path,
                {"type": "stop", "status": status, "returncode": returncode, "ts": _now_ms()},
            )

    threading.Thread(target=target, name=f"agent-run-{run_id[:12]}", daemon=True).start()


def _redacted_start_payload(payload: dict, cmd: list[str]) -> dict:
    env = payload.get("env") or {}
    return {
        "type": "start",
        "run_id": payload.get("run_id"),
        "session_id": payload.get("session_id"),
        "job_id": payload.get("job_id"),
        "user_id": payload.get("user_id"),
        "provider_id": payload.get("provider_id"),
        "agent_id": payload.get("agent_id"),
        "resume": bool(payload.get("resume_id")),
        "env_keys": sorted(env.keys()),
        "cmd": [part if "TOKEN" not in part and "KEY" not in part else "<redacted>" for part in cmd],
        "ts": _now_ms(),
    }


def _load_run_from_log(run_id: str) -> dict:
    log_path = _run_log_path(run_id)
    state = {"run_id": run_id, "status": "unknown", "log_path": str(log_path)}
    if not log_path.exists():
        return state
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "start":
            state.update({
                "session_id": event.get("session_id", ""),
                "job_id": event.get("job_id", ""),
                "user_id": event.get("user_id", ""),
                "provider_id": event.get("provider_id", ""),
                "agent_id": event.get("agent_id", ""),
                "started_at": event.get("ts"),
                "status": "started",
            })
        elif event.get("type") == "stop":
            state.update({
                "status": event.get("status", "stopped"),
                "returncode": event.get("returncode"),
                "finished_at": event.get("ts"),
            })
    return state


def _run_artifact_workspaces(run_id: str) -> list[Path]:
    workspaces: list[Path] = []
    with _RUNS_LOCK:
        run = _RUNS.get(run_id) or {}
    for key in ("run_workspace_path", "workspace_path"):
        raw = run.get(key)
        if raw:
            workspaces.append(Path(str(raw)))
    if workspaces:
        return workspaces
    state = _load_run_from_log(run_id)
    session_id = str(state.get("session_id") or "")
    job_id = str(state.get("job_id") or "")
    if not session_id or not job_id:
        return []
    paths = _session_paths(str(state.get("user_id") or "user"), session_id, job_id)
    return [paths["run_workspace"], paths["workspace"]]


def _safe_artifact_path(workspace: Path, relative_path: str) -> Optional[Path]:
    relative_path = str(relative_path or "app.json").strip() or "app.json"
    candidate = (workspace / relative_path).resolve()
    try:
        candidate.relative_to(workspace.resolve())
    except ValueError:
        return None
    if not candidate.is_file():
        return None
    return candidate


def _newest_mtime(path: Path) -> float:
    try:
        newest = path.stat().st_mtime
    except OSError:
        return 0
    if not path.is_dir():
        return newest
    for root, dirs, files in os.walk(path):
        root_path = Path(root)
        for name in dirs + files:
            try:
                newest = max(newest, (root_path / name).stat().st_mtime)
            except OSError:
                continue
    return newest


def _docker_active_agent_containers() -> dict[str, dict]:
    proc = subprocess.run(
        ["docker", "ps", "--filter", "name=myapp-agent-", "--format", "{{json .}}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    rows: dict[str, dict] = {}
    if proc.returncode != 0:
        return rows
    for line in proc.stdout.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = str(item.get("Names") or item.get("Name") or "").strip()
        if not name or name.startswith("myapp-agent-node") or not name.startswith("myapp-agent-"):
            continue
        run_id = _safe_part(name.removeprefix("myapp-agent-"), "run")
        rows[run_id] = {
            "run_id": run_id,
            "container": name,
            "docker_status": item.get("Status", ""),
        }
    return rows


def _run_start_metadata(run_id: str) -> dict:
    log_path = _run_log_path(run_id)
    if not log_path.exists():
        return {}
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for _ in range(20):
                line = handle.readline()
                if not line:
                    break
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("type") == "start":
                    return {
                        "run_id": item.get("run_id") or run_id,
                        "session_id": item.get("session_id") or "",
                        "job_id": item.get("job_id") or "",
                        "user_id": item.get("user_id") or "",
                        "provider_id": item.get("provider_id") or "",
                        "agent_id": item.get("agent_id") or "",
                        "created_at": item.get("ts") or 0,
                    }
    except OSError:
        return {}
    return {}


@APP.get("/health")
def health():
    running = len(_docker_active_agent_containers())
    _cleanup_proxy_tokens()
    with _PROXY_LOCK:
        proxy_tokens = len(_PROXY_TOKENS)
    return jsonify({
        "ok": True,
        "node_id": NODE_ID,
        "name": NODE_NAME,
        "display_name": NODE_NAME,
        "image": RUNTIME_IMAGE,
        "build_commit": BUILD_COMMIT,
        "build_version": BUILD_VERSION,
        "version": BUILD_VERSION,
        "running": running,
        "proxy_tokens": proxy_tokens,
        "capacity": NODE_CAPACITY,
        "queue_max": NODE_QUEUE_MAX,
        "provider_mode": PROVIDER_MODE,
        "provider_ids": PROVIDER_IDS,
        "agent_ids": AGENT_IDS,
        "capabilities": CAPABILITIES,
    })


@APP.get("/private_auth")
def private_auth():
    if NODE_TOKEN:
        expected = f"Bearer {NODE_TOKEN}"
        if request.headers.get("Authorization", "") != expected:
            return jsonify({"error": "unauthorized"}), 401
    else:
        return jsonify({"error": "private auth token is not configured"}), 400
    token = _private_pull_jwt()
    if not token:
        return jsonify({"error": "private auth is not configured"}), 400
    return jsonify({
        "ok": True,
        "header": "X-MyApp-Agent-JWT",
        "token": token,
        "node_id": NODE_ID,
        "expires_in_seconds": 120,
    })


def _proxy_lookup(token: str) -> Optional[dict]:
    _cleanup_proxy_tokens()
    with _PROXY_LOCK:
        data = _PROXY_TOKENS.get(token)
        if not data:
            return None
        return dict(data)


def _upstream_headers(proxy_token: str, upstream_token: str) -> dict:
    hop_by_hop = {
        "host",
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "content-length",
    }
    headers = {}
    auth_seen = False
    for key, value in request.headers.items():
        lower = key.lower()
        if lower in hop_by_hop:
            continue
        text = str(value)
        if proxy_token and proxy_token in text:
            text = text.replace(proxy_token, upstream_token)
        if lower in {"authorization", "x-api-key", "api-key", "anthropic-auth-token"}:
            auth_seen = True
        headers[key] = text
    if not auth_seen:
        headers["Authorization"] = f"Bearer {upstream_token}"
    return headers


def _response_headers(upstream_response: requests.Response) -> list[tuple[str, str]]:
    excluded = {
        "content-encoding",
        "content-length",
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }
    return [
        (key, value)
        for key, value in upstream_response.headers.items()
        if key.lower() not in excluded
    ]


@APP.route("/proxy/<token>", defaults={"subpath": ""}, methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
@APP.route("/proxy/<token>/<path:subpath>", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
def provider_proxy(token: str, subpath: str):
    proxy = _proxy_lookup(token)
    if not proxy:
        return jsonify({"error": "provider proxy token expired or invalid"}), 401
    run_id = str(proxy.get("run_id") or "")
    upstream_base = str(proxy.get("upstream_base_url") or "").rstrip("/")
    upstream_token = str(proxy.get("upstream_token") or "")
    if not upstream_base or not upstream_token:
        return jsonify({"error": "provider proxy is misconfigured"}), 502
    upstream_url = urljoin(f"{upstream_base}/", subpath)
    if request.query_string:
        upstream_url = f"{upstream_url}?{request.query_string.decode('utf-8', errors='replace')}"
    try:
        upstream = requests.request(
            request.method,
            upstream_url,
            headers=_upstream_headers(token, upstream_token),
            data=request.get_data(),
            stream=True,
            timeout=(PROVIDER_PROXY_CONNECT_TIMEOUT_SECONDS, PROVIDER_PROXY_READ_TIMEOUT_SECONDS),
        )
    except requests.RequestException as exc:
        if run_id:
            _json_line(
                _run_log_path(run_id),
                {
                    "type": "proxy_error",
                    "method": request.method,
                    "subpath": subpath,
                    "upstream_url": upstream_url,
                    "message": str(exc),
                    "ts": _now_ms(),
                },
            )
        return jsonify({"error": "provider proxy upstream request failed", "detail": str(exc)}), 502
    if run_id:
        _json_line(
            _run_log_path(run_id),
            {
                "type": "proxy_response",
                "method": request.method,
                "subpath": subpath,
                "upstream_url": upstream_url,
                "status_code": upstream.status_code,
                "content_type": upstream.headers.get("content-type", ""),
                "ts": _now_ms(),
            },
        )

    def generate():
        try:
            for chunk in upstream.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    return Response(
        stream_with_context(generate()),
        status=upstream.status_code,
        headers=_response_headers(upstream),
    )


@APP.post("/v1/runs")
def create_run():
    data = request.get_json(silent=True) or {}
    try:
        run_id = _create_local_run(data)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    return jsonify({"run_id": run_id, "status": "starting", "events_url": f"/v1/runs/{run_id}/events"}), 202


def _create_local_run(data: dict) -> str:
    session_id = str(data.get("session_id") or "").strip()
    prompt = str(data.get("prompt") or "")
    if not session_id or not prompt:
        raise ValueError("session_id and prompt are required")
    run_id = _safe_part(data.get("run_id") or uuid.uuid4().hex, "run")
    job_id = _safe_part(data.get("job_id") or run_id, "job")
    user_id = _safe_part(data.get("user_id") or "user", "user")
    payload = {
        "run_id": run_id,
        "session_id": session_id,
        "job_id": job_id,
        "user_id": user_id,
        "provider_id": str(data.get("provider_id") or ""),
        "agent_id": str(data.get("agent_id") or "claude"),
        "resume_id": str(data.get("resume_id") or ""),
        "cli_session_id": str(data.get("cli_session_id") or ""),
        "prompt": prompt,
        "system_prompt": str(data.get("system_prompt") or ""),
        "env": data.get("env") or {},
        "codex": data.get("codex") or {},
    }
    paths = _session_paths(user_id, session_id, job_id)
    payload_path = _run_payload_path(run_id)
    try:
        paths["workspace"].mkdir(parents=True, exist_ok=True)
        _write_initial_files(paths["workspace"], data.get("initial_files"))
        _apply_local_provider(payload)
        proxy_tokens = _prepare_provider_proxy(payload)
    except ValueError as exc:
        raise ValueError(str(exc))
    redactions = _secret_redactions(payload)
    cmd, docker_env = _docker_cmd(run_id, payload, payload_path, paths)
    log_path = _run_log_path(run_id)
    _json_line(log_path, _redacted_start_payload(payload, cmd))
    with _RUNS_LOCK:
        abort_until = _ABORT_MARKERS.pop(run_id, 0)
        abort_requested = abort_until > _now_ms()
        _RUNS[run_id] = {
            "run_id": run_id,
            "session_id": session_id,
            "job_id": job_id,
            "user_id": user_id,
            "provider_id": payload["provider_id"],
            "agent_id": payload["agent_id"],
            "status": "starting",
            "created_at": _now_ms(),
            "log_path": str(log_path),
            "session_workspace_path": str(paths["session_workspace"]),
            "workspace_path": str(paths["workspace"]),
            "run_workspace_path": str(paths["run_workspace"]),
            "proxy_tokens": len(proxy_tokens),
            "abort_requested": abort_requested,
        }
    if abort_requested:
        _json_line(log_path, {"type": "abort_requested", "reason": "pre_start", "ts": _now_ms()})
    _start_run_thread(run_id, payload, cmd, docker_env, log_path, paths, proxy_tokens, redactions)
    return run_id


@APP.get("/v1/runs")
def list_runs():
    include_history = request.args.get("history") in {"1", "true", "yes"}
    try:
        limit = int(request.args.get("limit", "20") or "20")
    except ValueError:
        limit = 20
    limit = max(1, min(limit, 500))
    docker_active = _docker_active_agent_containers()
    with _RUNS_LOCK:
        memory_rows = [dict(row) for row in _RUNS.values()]
        for row in _RUNS.values():
            run_id = str(row.get("run_id") or "")
            if row.get("status") == "running" and run_id and run_id not in docker_active:
                row["status"] = "failed"
                row["returncode"] = row.get("returncode", "-")
                row["finished_at"] = _now_ms()
        memory_rows = [dict(row) for row in _RUNS.values()]
    active_rows = [
        row for row in memory_rows
        if row.get("status") == "starting"
        or (row.get("status") == "running" and str(row.get("run_id") or "") in docker_active)
    ]
    known_active = {str(row.get("run_id") or "") for row in active_rows}
    for run_id, docker_row in docker_active.items():
        if run_id in known_active:
            continue
        row = _run_start_metadata(run_id)
        row.update(docker_row)
        row.setdefault("session_id", "")
        row.setdefault("agent_id", "")
        row.setdefault("provider_id", "")
        row["status"] = "running"
        active_rows.append(row)
    history_rows = [row for row in memory_rows if row.get("status") not in _ACTIVE_RUN_STATUSES]
    history_total = len(history_rows)
    if include_history:
        history_paths = []
        known = {str(row.get("run_id") or "") for row in memory_rows}
        for path in LOG_DIR.glob("*.jsonl"):
            if path.stem in known:
                continue
            history_total += 1
            history_paths.append(path)
        history_paths.sort(key=lambda item: item.stat().st_mtime if item.exists() else 0, reverse=True)
        for path in history_paths[:limit]:
            history_rows.append(_load_run_from_log(path.stem))
        history_rows.sort(
            key=lambda item: int(item.get("finished_at") or item.get("created_at") or item.get("started_at") or 0),
            reverse=True,
        )
    rows = active_rows + (history_rows[:limit] if include_history else [])
    rows.sort(
        key=lambda item: int(item.get("created_at") or item.get("started_at") or item.get("finished_at") or 0),
        reverse=True,
    )
    return jsonify({"runs": rows, "history_total": history_total})


@APP.get("/v1/runs/<run_id>")
def get_run(run_id: str):
    run_id = _safe_part(run_id, "run")
    with _RUNS_LOCK:
        if run_id in _RUNS:
            return jsonify(_RUNS[run_id])
    return jsonify(_load_run_from_log(run_id))


@APP.get("/v1/runs/<run_id>/artifact")
def get_run_artifact(run_id: str):
    run_id = _safe_part(run_id, "run")
    workspaces = _run_artifact_workspaces(run_id)
    if not workspaces:
        return jsonify({"error": "workspace not found"}), 404
    relative_path = request.args.get("path", "app.json")
    for workspace in workspaces:
        path = _safe_artifact_path(workspace, relative_path)
        if path:
            return send_file(path, mimetype="application/json", as_attachment=False)
    return jsonify({"error": "artifact not found"}), 404


def _abort_local_run(run_id: str) -> bool:
    run_id = _safe_part(run_id, "run")
    with _RUNS_LOCK:
        run = _RUNS.get(run_id) or {}
        if run:
            run["abort_requested"] = True
        else:
            _ABORT_MARKERS[run_id] = _now_ms() + _ABORT_MARKER_TTL_MS
    container = run.get("container")
    if not container:
        fallback_container = f"myapp-agent-{run_id}"
        removed = subprocess.run(
            ["docker", "rm", "-f", fallback_container],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if removed:
            _json_line(_run_log_path(run_id), {"type": "abort", "container": fallback_container, "ts": _now_ms()})
        else:
            _json_line(_run_log_path(run_id), {"type": "abort_requested", "reason": "container not found", "ts": _now_ms()})
        return removed
    subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _json_line(_run_log_path(run_id), {"type": "abort", "container": container, "ts": _now_ms()})
    return True


@APP.post("/v1/runs/<run_id>/abort")
def abort_run(run_id: str):
    run_id = _safe_part(run_id, "run")
    aborted = _abort_local_run(run_id)
    return jsonify({"run_id": run_id, "aborted": aborted, "abort_requested": True}), 200 if aborted else 202


@APP.get("/v1/runs/<run_id>/events")
def run_events(run_id: str):
    run_id = _safe_part(run_id, "run")
    follow = request.args.get("follow") in {"1", "true", "yes"}
    timeout = float(request.args.get("timeout", "0") or "0")
    log_path = _run_log_path(run_id)

    def generate():
        start = time.time()
        pos = 0
        while True:
            if log_path.exists():
                with log_path.open("r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                if chunk:
                    yield chunk
                    if any('"type":"stop"' in line or '"type": "stop"' in line for line in chunk.splitlines()):
                        break
            if not follow:
                break
            if timeout > 0 and time.time() - start > timeout:
                break
            time.sleep(0.25)

    return Response(stream_with_context(generate()), mimetype="application/x-ndjson")


def _pull_headers(content_type: str = "application/json") -> dict:
    headers = {"User-Agent": "myapp-agent-node/1"}
    if content_type:
        headers["Content-Type"] = content_type
    private_jwt = _private_pull_jwt()
    if private_jwt:
        headers["X-MyApp-Agent-JWT"] = private_jwt
        return headers
    if REGISTRATION_TOKEN:
        headers["Authorization"] = f"Bearer {REGISTRATION_TOKEN}"
    return headers


def _private_pull_jwt() -> str:
    if AUTH_MODE not in {"private", "user-private"}:
        return ""
    if not PRIVATE_KEY_PATH:
        return ""
    try:
        private_key = Path(PRIVATE_KEY_PATH).read_text(encoding="utf-8")
    except OSError as exc:
        _json_line(_run_log_path("agent-node-pull"), {"type": "private_key_read_error", "message": str(exc), "ts": _now_ms()})
        return ""
    now = int(time.time())
    claims = {
        "iss": "myapp-agent-node",
        "sub": NODE_ID,
        "owner_user_id": OWNER_USER_ID,
        "aud": "myapp-agent-pull",
        "iat": now,
        "exp": now + 120,
        "jti": uuid.uuid4().hex,
    }
    try:
        return jwt.encode(claims, private_key, algorithm="RS256")
    except Exception as exc:
        _json_line(_run_log_path("agent-node-pull"), {"type": "private_jwt_sign_error", "message": str(exc), "ts": _now_ms()})
        return ""


def _pull_labels() -> list[str]:
    labels = []
    raw = os.environ.get("AGENT_NODE_LABELS", "")
    for item in raw.split(","):
        item = item.strip()
        if item:
            labels.append(item)
    public_host = (os.environ.get("PUBLIC_HOST") or "").strip()
    if public_host:
        labels = [label for label in labels if not label.startswith("host=")]
    if not any(label.replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={PROVIDER_MODE or 'master'}")
    if AUTH_MODE in {"private", "user-private"} and not any(label.replace("_", "-").startswith("visibility=") for label in labels):
        labels.append("visibility=private")
    if not any(label.startswith("host=") for label in labels):
        labels.append(f"host={public_host or os.uname().nodename}")
    if not any(label.replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={NODE_NAME}")
    if not any(label.replace("_", "-").startswith("mode=") for label in labels):
        labels.append("mode=pull")
    return labels


def _pull_active_count() -> int:
    with _PULL_RUNS_LOCK:
        starting_runs = set(_PULL_STARTING_RUNS)
    with _RUNS_LOCK:
        active_run_ids = {
            run_id
            for run_id, run in _RUNS.items()
            if str(run.get("status") or "") in _ACTIVE_RUN_STATUSES
        }
    return max(len(active_run_ids | starting_runs), len(_docker_active_agent_containers()))


def _pull_mark_starting(run_id: str) -> None:
    if not run_id:
        return
    with _PULL_RUNS_LOCK:
        _PULL_STARTING_RUNS.add(run_id)


def _pull_unmark_starting(run_id: str) -> None:
    if not run_id:
        return
    with _PULL_RUNS_LOCK:
        _PULL_STARTING_RUNS.discard(run_id)


def _pull_post_events(run_id: str, events: list[dict], *, heartbeat: bool = False) -> bool:
    if not PULL_BACKEND_URL:
        return False
    payload = {"node_id": NODE_ID, "events": events}
    backoff = 1.0
    while True:
        try:
            response = requests.post(
                f"{PULL_BACKEND_URL}/api/ai/agent_pull/jobs/{run_id}/events",
                headers=_pull_headers(),
                json=payload,
                timeout=(5, 30),
            )
            if 200 <= response.status_code < 300:
                try:
                    data = response.json()
                except ValueError:
                    data = {}
                return bool(data.get("abort"))
            _json_line(
                _run_log_path(run_id),
                {
                    "type": "pull_event_upload_error",
                    "status_code": response.status_code,
                    "body": response.text[:300],
                    "ts": _now_ms(),
                },
            )
        except requests.RequestException as exc:
            _json_line(_run_log_path(run_id), {"type": "pull_event_upload_error", "message": str(exc), "ts": _now_ms()})
        if heartbeat and not events:
            return False
        time.sleep(backoff)
        backoff = min(PULL_ERROR_BACKOFF_MAX_SECONDS, backoff * 2)


def _pull_upload_artifact(run_id: str, relative_path: str = "app.json") -> None:
    workspaces = _run_artifact_workspaces(run_id)
    for workspace in workspaces:
        path = _safe_artifact_path(workspace, relative_path)
        if not path:
            continue
        data = path.read_bytes()
        backoff = 1.0
        while True:
            try:
                response = requests.post(
                    f"{PULL_BACKEND_URL}/api/ai/agent_pull/jobs/{run_id}/artifact",
                    headers=_pull_headers("application/octet-stream"),
                    params={"path": relative_path},
                    data=data,
                    timeout=(5, 60),
                )
                if 200 <= response.status_code < 300:
                    _json_line(
                        _run_log_path(run_id),
                        {"type": "pull_artifact_uploaded", "path": relative_path, "bytes": len(data), "ts": _now_ms()},
                    )
                    return
                message = f"http {response.status_code}: {response.text[:300]}"
            except requests.RequestException as exc:
                message = str(exc)
            _json_line(_run_log_path(run_id), {"type": "pull_artifact_upload_error", "message": message, "ts": _now_ms()})
            time.sleep(backoff)
            backoff = min(PULL_ERROR_BACKOFF_MAX_SECONDS, backoff * 2)
    _json_line(_run_log_path(run_id), {"type": "pull_artifact_missing", "path": relative_path, "ts": _now_ms()})


def _pull_stream_run_events(run_id: str) -> None:
    log_path = _run_log_path(run_id)
    pos = 0
    carry = ""
    batch: list[dict] = []
    last_flush = time.time()
    last_heartbeat = time.time()
    stop_seen = False
    flush_interval = max(0.05, PULL_EVENT_FLUSH_LIVE_SECONDS)
    while True:
        if log_path.exists():
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(pos)
                chunk = handle.read()
                pos = handle.tell()
            if chunk:
                text = carry + chunk
                if text.endswith("\n"):
                    lines = text.splitlines()
                    carry = ""
                else:
                    parts = text.splitlines()
                    lines = parts[:-1]
                    carry = parts[-1] if parts else text
                for line in lines:
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if item.get("type") == "stop":
                        _pull_upload_artifact(run_id, "app.json")
                        stop_seen = True
                    batch.append(item)
        now = time.time()
        if batch and (stop_seen or len(batch) >= PULL_EVENT_BATCH_MAX or now - last_flush >= flush_interval):
            abort = _pull_post_events(run_id, batch)
            batch = []
            last_flush = now
            last_heartbeat = now
            if abort and not stop_seen:
                _abort_local_run(run_id)
        if stop_seen:
            return
        if now - last_heartbeat >= max(1.0, min(PULL_EVENT_FLUSH_BACKGROUND_SECONDS, 5.0)):
            if _pull_post_events(run_id, [], heartbeat=True):
                _abort_local_run(run_id)
            last_heartbeat = now
        time.sleep(0.2)


def _pull_run_job(job: dict) -> None:
    run_id = str(job.get("run_id") or "")
    if not run_id:
        return
    try:
        actual_run_id = _create_local_run(job)
        _pull_stream_run_events(actual_run_id)
    except Exception as exc:
        _json_line(_run_log_path(run_id), {"type": "error", "message": str(exc), "ts": _now_ms()})
        _pull_post_events(run_id, [{"type": "error", "message": str(exc), "ts": _now_ms()}])
        _pull_post_events(run_id, [{"type": "stop", "status": "failed", "returncode": 1, "ts": _now_ms()}])
    finally:
        _pull_unmark_starting(run_id)


def _pull_loop() -> None:
    if not PULL_ENABLED:
        return
    if not PULL_BACKEND_URL:
        _json_line(_run_log_path("agent-node-pull"), {"type": "pull_disabled", "reason": "missing backend url", "ts": _now_ms()})
        return
    backoff = 1.0
    while True:
        try:
            active_runs = _pull_active_count()
            capacity = max(1, NODE_CAPACITY)
            accept_jobs = active_runs < capacity
            poll_timeout = PULL_TIMEOUT_SECONDS if accept_jobs else 0
            response = requests.post(
                f"{PULL_BACKEND_URL}/api/ai/agent_pull/acquire",
                headers=_pull_headers(),
                json={
                    "node_id": NODE_ID,
                    "name": NODE_NAME,
                    "capacity": capacity,
                    "queue_max": NODE_QUEUE_MAX,
                    "build_commit": BUILD_COMMIT,
                    "build_version": BUILD_VERSION,
                    "provider_mode": PROVIDER_MODE or "master",
                    "provider_ids": PROVIDER_IDS,
                    "agent_ids": AGENT_IDS,
                    "capabilities": CAPABILITIES,
                    "labels": _pull_labels(),
                    "url": os.environ.get("AGENT_NODE_SELF_REGISTER_URL") or f"pull://{NODE_ID}",
                    "timeout_seconds": poll_timeout,
                    "ttl_seconds": int(os.environ.get("AGENT_NODE_REGISTRATION_TTL_SECONDS", "120")),
                    "active_runs": active_runs,
                    "accept_jobs": accept_jobs,
                },
                timeout=(5, max(10, poll_timeout + 5)),
            )
            if response.status_code == 204:
                backoff = 1.0
                time.sleep(max(0.0, PULL_INTERVAL_SECONDS))
                continue
            if response.status_code == 401 or response.status_code == 403:
                _json_line(
                    _run_log_path("agent-node-pull"),
                    {"type": "pull_auth_error", "status_code": response.status_code, "ts": _now_ms()},
                )
                time.sleep(PULL_ERROR_BACKOFF_MAX_SECONDS)
                continue
            response.raise_for_status()
            data = response.json()
            job = data.get("job") if isinstance(data, dict) else None
            if not isinstance(job, dict):
                time.sleep(max(0.0, PULL_INTERVAL_SECONDS))
                continue
            backoff = 1.0
            run_id = str(job.get("run_id") or "")
            _pull_mark_starting(run_id)
            threading.Thread(target=_pull_run_job, args=(job,), name=f"agent-pull-{job.get('run_id', '')[:12]}", daemon=True).start()
        except Exception as exc:
            _json_line(_run_log_path("agent-node-pull"), {"type": "pull_loop_error", "message": str(exc), "ts": _now_ms()})
            time.sleep(backoff)
            backoff = min(PULL_ERROR_BACKOFF_MAX_SECONDS, backoff * 2)


def _start_pull_thread_once() -> None:
    if not PULL_ENABLED:
        return
    thread = threading.Thread(target=_pull_loop, name="agent-node-pull", daemon=True)
    thread.start()


def _cleanup_old_runs() -> None:
    cutoff = time.time() - RUN_RETENTION_SECONDS
    cutoff_ms = int(cutoff * 1000)
    with _RUNS_LOCK:
        expired_run_ids = [
            run_id
            for run_id, run in _RUNS.items()
            if run.get("status") not in _ACTIVE_RUN_STATUSES
            and int(run.get("finished_at") or run.get("created_at") or 0) < cutoff_ms
        ]
        for run_id in expired_run_ids:
            _RUNS.pop(run_id, None)
        now_ms = _now_ms()
        expired_abort_markers = [
            run_id for run_id, until_ms in _ABORT_MARKERS.items()
            if until_ms <= now_ms
        ]
        for run_id in expired_abort_markers:
            _ABORT_MARKERS.pop(run_id, None)
        active_session_paths = {
            Path(str(run.get("session_workspace_path")))
            for run in _RUNS.values()
            if run.get("status") in _ACTIVE_RUN_STATUSES and run.get("session_workspace_path")
        }
        active_run_paths = {
            Path(str(run.get("run_workspace_path")))
            for run in _RUNS.values()
            if run.get("status") in _ACTIVE_RUN_STATUSES and run.get("run_workspace_path")
        }
    for root in (LOG_DIR, WORKSPACE_ROOT / "_payloads"):
        if not root.exists():
            continue
        for path in root.glob("*"):
            try:
                if path.is_file() and path.stat().st_mtime < cutoff:
                    path.unlink()
            except OSError:
                pass
    if WORKSPACE_ROOT.exists():
        for user_dir in WORKSPACE_ROOT.iterdir():
            if not user_dir.is_dir() or user_dir.name == "_payloads":
                continue
            for session_dir in user_dir.iterdir():
                if not session_dir.is_dir():
                    continue
                runs_root = session_dir / "runs"
                if runs_root.exists():
                    for run_dir in runs_root.iterdir():
                        try:
                            if run_dir in active_run_paths:
                                continue
                            if run_dir.is_dir() and _newest_mtime(run_dir) < cutoff:
                                shutil.rmtree(run_dir)
                        except OSError:
                            pass
                try:
                    if session_dir not in active_session_paths and _newest_mtime(session_dir) < cutoff:
                        shutil.rmtree(session_dir)
                except OSError:
                    pass
            try:
                next(user_dir.iterdir())
            except StopIteration:
                try:
                    user_dir.rmdir()
                except OSError:
                    pass


def _cleanup_loop() -> None:
    while True:
        try:
            _cleanup_old_runs()
        except Exception as exc:
            _json_line(_run_log_path("agent-node-cleanup"), {"type": "cleanup_error", "message": str(exc), "ts": _now_ms()})
        time.sleep(max(60, min(RUN_RETENTION_SECONDS // 4, 3600)))


def _start_cleanup_thread_once() -> None:
    global _CLEANUP_THREAD_STARTED
    with _CLEANUP_THREAD_LOCK:
        if _CLEANUP_THREAD_STARTED:
            return
        _CLEANUP_THREAD_STARTED = True
        thread = threading.Thread(target=_cleanup_loop, name="agent-node-cleanup", daemon=True)
        thread.start()


_start_cleanup_thread_once()
_start_pull_thread_once()


if __name__ == "__main__":
    port = int(os.environ.get("AGENT_NODE_PORT", "5590"))
    APP.run(host=os.environ.get("AGENT_NODE_HOST", "0.0.0.0"), port=port, threaded=True)
