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
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from flask import Flask, Response, jsonify, request, stream_with_context


APP = Flask(__name__)

NODE_ID = os.environ.get("AGENT_NODE_ID", os.uname().nodename)
RUNTIME_IMAGE = os.environ.get("AGENT_NODE_RUNTIME_IMAGE", "dapangyufish/myapp-agent-runtime:latest")
STATE_ROOT = Path(os.environ.get("AGENT_NODE_STATE_ROOT", "/var/lib/myapp/agent-node/state"))
WORKSPACE_ROOT = Path(os.environ.get("AGENT_NODE_WORKSPACE_ROOT", "/var/lib/myapp/agent-node/workspaces"))
LOG_DIR = Path(os.environ.get("AGENT_NODE_LOG_DIR", "/var/log/myapp/agent-node"))
PROJECT_ROOT = os.environ.get("AGENT_NODE_PROJECT_ROOT", "/app")
CONTAINER_CPUS = os.environ.get("AGENT_NODE_CONTAINER_CPUS", "2")
CONTAINER_MEMORY = os.environ.get("AGENT_NODE_CONTAINER_MEMORY", "2g")
CONTAINER_PIDS_LIMIT = os.environ.get("AGENT_NODE_CONTAINER_PIDS_LIMIT", "512")
DOCKER_NETWORK = os.environ.get("AGENT_NODE_DOCKER_NETWORK", "none")
NODE_TOKEN = os.environ.get("AGENT_NODE_TOKEN", "")
RUN_RETENTION_SECONDS = int(os.environ.get("AGENT_NODE_RUN_RETENTION_SECONDS", "604800"))

_RUNS: dict[str, dict] = {}
_RUNS_LOCK = threading.Lock()


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
    if request.path == "/health":
        return None
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    return None


def _run_log_path(run_id: str) -> Path:
    return LOG_DIR / f"{_safe_part(run_id, 'run')}.jsonl"


def _run_payload_path(run_id: str) -> Path:
    return WORKSPACE_ROOT / "_payloads" / f"{_safe_part(run_id, 'run')}.json"


def _session_paths(user_id: str, session_id: str, job_id: str) -> dict[str, Path]:
    safe_user = _safe_part(user_id, "user")
    safe_session = _safe_part(session_id, "session")
    safe_job = _safe_part(job_id, "job")
    session_root = STATE_ROOT / safe_user / safe_session
    return {
        "claude": session_root / "claude",
        "codex": session_root / "codex",
        "workspace": WORKSPACE_ROOT / safe_session / safe_job,
    }


def _docker_cmd(run_id: str, payload: dict, payload_path: Path, paths: dict[str, Path]) -> tuple[list[str], dict]:
    container_name = f"myapp-agent-{_safe_part(run_id, uuid.uuid4().hex)}"
    for path in paths.values():
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
        f"{paths['claude']}:/home/agent/.claude:rw",
        "-v",
        f"{paths['codex']}:/home/agent/.codex:rw",
        "-v",
        f"{paths['workspace']}:/workspace:rw",
        "-v",
        f"{payload_path}:/run/myapp-agent/payload.json:ro",
        "-e",
        "AI_APP_WORKSPACE=/workspace",
        "-e",
        f"AI_APP_PROJECT_ROOT={PROJECT_ROOT}",
    ]
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


@APP.get("/health")
def health():
    with _RUNS_LOCK:
        running = sum(1 for run in _RUNS.values() if run.get("status") == "running")
    return jsonify({"ok": True, "node_id": NODE_ID, "image": RUNTIME_IMAGE, "running": running})


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
        }
    _start_run_thread(run_id, payload, cmd, docker_env, log_path, paths)
    return jsonify({"run_id": run_id, "status": "starting", "events_url": f"/v1/runs/{run_id}/events"}), 202


@APP.get("/v1/runs")
def list_runs():
    rows = []
    with _RUNS_LOCK:
        rows.extend(_RUNS.values())
    known = {row["run_id"] for row in rows}
    for path in sorted(LOG_DIR.glob("*.jsonl")):
        if path.stem not in known:
            rows.append(_load_run_from_log(path.stem))
    rows.sort(key=lambda item: str(item.get("created_at") or item.get("started_at") or ""), reverse=True)
    return jsonify({"runs": rows[:200]})


@APP.get("/v1/runs/<run_id>")
def get_run(run_id: str):
    run_id = _safe_part(run_id, "run")
    with _RUNS_LOCK:
        if run_id in _RUNS:
            return jsonify(_RUNS[run_id])
    return jsonify(_load_run_from_log(run_id))


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


def _cleanup_old_logs() -> None:
    cutoff = time.time() - RUN_RETENTION_SECONDS
    for root in (LOG_DIR, WORKSPACE_ROOT / "_payloads"):
        if not root.exists():
            continue
        for path in root.glob("*"):
            try:
                if path.is_file() and path.stat().st_mtime < cutoff:
                    path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    _cleanup_old_logs()
    port = int(os.environ.get("AGENT_NODE_PORT", "5590"))
    APP.run(host=os.environ.get("AGENT_NODE_HOST", "0.0.0.0"), port=port, threaded=True)
