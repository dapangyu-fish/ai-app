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
from flask import Flask, Response, jsonify, request, send_file, stream_with_context


APP = Flask(__name__)

NODE_ID = os.environ.get("AGENT_NODE_ID", os.uname().nodename)
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
NODE_TOKEN = os.environ.get("AGENT_NODE_TOKEN", "")
RUN_RETENTION_SECONDS = int(os.environ.get("AGENT_NODE_RUN_RETENTION_SECONDS", "604800"))

_RUNS: dict[str, dict] = {}
_RUNS_LOCK = threading.Lock()
_PROXY_TOKENS: dict[str, dict] = {}
_PROXY_LOCK = threading.Lock()
_CLEANUP_THREAD_STARTED = False
_CLEANUP_THREAD_LOCK = threading.Lock()
_ACTIVE_RUN_STATUSES = {"starting", "running"}


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
    return {
        "claude": session_root / "claude",
        "claude_config": session_root / ".claude.json",
        "codex": session_root / "codex",
        "workspace": WORKSPACE_ROOT / safe_session / safe_job,
    }


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


def _pump_stream(log_path: Path, kind: str, stream) -> None:
    assert stream is not None
    for raw in iter(stream.readline, b""):
        line = raw.decode("utf-8", errors="replace")
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
) -> None:
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
            threads = [
                threading.Thread(target=_pump_stream, args=(log_path, "stdout", proc.stdout), daemon=True),
                threading.Thread(target=_pump_stream, args=(log_path, "stderr", proc.stderr), daemon=True),
            ]
            for thread in threads:
                thread.start()
            returncode = proc.wait()
            for thread in threads:
                thread.join(timeout=1)
            status = "done" if returncode == 0 else "failed"
        except Exception as exc:
            _json_line(log_path, {"type": "error", "message": str(exc), "ts": _now_ms()})
            status = "failed"
        finally:
            _revoke_proxy_tokens(proxy_tokens)
            try:
                _emit_client_actions(log_path, paths["workspace"])
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


def _run_workspace(run_id: str) -> Optional[Path]:
    with _RUNS_LOCK:
        run = _RUNS.get(run_id) or {}
    raw = run.get("workspace_path")
    return Path(str(raw)) if raw else None


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


@APP.get("/health")
def health():
    with _RUNS_LOCK:
        running = sum(1 for run in _RUNS.values() if run.get("status") == "running")
    _cleanup_proxy_tokens()
    with _PROXY_LOCK:
        proxy_tokens = len(_PROXY_TOKENS)
    return jsonify({"ok": True, "node_id": NODE_ID, "image": RUNTIME_IMAGE, "running": running, "proxy_tokens": proxy_tokens})


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
    session_id = str(data.get("session_id") or "").strip()
    prompt = str(data.get("prompt") or "")
    if not session_id or not prompt:
        return jsonify({"error": "session_id and prompt are required"}), 400
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
        "prompt": prompt,
        "system_prompt": str(data.get("system_prompt") or ""),
        "env": data.get("env") or {},
        "codex": data.get("codex") or {},
    }
    paths = _session_paths(user_id, session_id, job_id)
    payload_path = _run_payload_path(run_id)
    proxy_tokens = _prepare_provider_proxy(payload)
    cmd, docker_env = _docker_cmd(run_id, payload, payload_path, paths)
    log_path = _run_log_path(run_id)
    _json_line(log_path, _redacted_start_payload(payload, cmd))
    with _RUNS_LOCK:
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
            "workspace_path": str(paths["workspace"]),
            "proxy_tokens": len(proxy_tokens),
        }
    _start_run_thread(run_id, payload, cmd, docker_env, log_path, paths, proxy_tokens)
    return jsonify({"run_id": run_id, "status": "starting", "events_url": f"/v1/runs/{run_id}/events"}), 202


@APP.get("/v1/runs")
def list_runs():
    include_history = request.args.get("history") in {"1", "true", "yes"}
    try:
        limit = int(request.args.get("limit", "20") or "20")
    except ValueError:
        limit = 20
    limit = max(1, min(limit, 500))
    with _RUNS_LOCK:
        memory_rows = [dict(row) for row in _RUNS.values()]
    active_rows = [row for row in memory_rows if row.get("status") in _ACTIVE_RUN_STATUSES]
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
    workspace = _run_workspace(run_id)
    if not workspace:
        return jsonify({"error": "workspace not found"}), 404
    path = _safe_artifact_path(workspace, request.args.get("path", "app.json"))
    if not path:
        return jsonify({"error": "artifact not found"}), 404
    return send_file(path, mimetype="application/json", as_attachment=False)


@APP.post("/v1/runs/<run_id>/abort")
def abort_run(run_id: str):
    run_id = _safe_part(run_id, "run")
    with _RUNS_LOCK:
        run = _RUNS.get(run_id) or {}
    container = run.get("container")
    if not container:
        return jsonify({"run_id": run_id, "aborted": False, "reason": "container not found"}), 404
    subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _json_line(_run_log_path(run_id), {"type": "abort", "container": container, "ts": _now_ms()})
    return jsonify({"run_id": run_id, "aborted": True})


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
        for session_dir in WORKSPACE_ROOT.iterdir():
            if not session_dir.is_dir() or session_dir.name == "_payloads":
                continue
            for job_dir in session_dir.iterdir():
                try:
                    if job_dir.is_dir() and job_dir.stat().st_mtime < cutoff:
                        shutil.rmtree(job_dir)
                except OSError:
                    pass
            try:
                next(session_dir.iterdir())
            except StopIteration:
                try:
                    session_dir.rmdir()
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


if __name__ == "__main__":
    port = int(os.environ.get("AGENT_NODE_PORT", "5590"))
    APP.run(host=os.environ.get("AGENT_NODE_HOST", "0.0.0.0"), port=port, threaded=True)
