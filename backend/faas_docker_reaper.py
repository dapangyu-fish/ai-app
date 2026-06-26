"""Self-managed scale-to-zero reaper for the Docker FaaS.

Stops FaaS service containers that have been idle past FAAS_DOCKER_IDLE_SECONDS;
the invoke proxy cold-wakes them again on the next request (container.start, so
the env — including the scoped DB DSN — is preserved). Single-instance via an
flock, so it is safe to start from every gunicorn worker (only one reaps).

Run in-process (started from app.py) or standalone: `python3 faas_docker_reaper.py`.
"""
from __future__ import annotations

import fcntl
import os
import time
from datetime import datetime, timezone

try:
    from faas_store import (
        FAAS_DOCKER_IDLE_SECONDS,
        FAAS_DOCKER_SCALE_ZERO,
        _docker_client,
        service_last_active,
    )
except ModuleNotFoundError:  # pragma: no cover
    from backend.faas_store import (
        FAAS_DOCKER_IDLE_SECONDS,
        FAAS_DOCKER_SCALE_ZERO,
        _docker_client,
        service_last_active,
    )

INTERVAL = int(os.environ.get("FAAS_DOCKER_REAPER_INTERVAL", "60"))
LOCK_PATH = os.environ.get("FAAS_DOCKER_REAPER_LOCK", "/tmp/faas_docker_reaper.lock")


def _started_ts(container) -> float:
    try:
        s = (container.attrs.get("State") or {}).get("StartedAt", "") or ""
        s = s.split(".")[0].rstrip("Z")
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0.0


def reap_once() -> int:
    try:
        client = _docker_client()
        containers = client.containers.list(filters={"label": "myapp.faas=1", "status": "running"})
    except Exception as exc:  # docker not reachable
        print(f"[faas-reaper] list failed: {exc}", flush=True)
        return 0
    now = time.time()
    reaped = 0
    for c in containers:
        sid = (c.labels or {}).get("myapp.faas.service_id") or ""
        last = service_last_active(sid) if sid else 0.0
        if last <= 0:
            last = _started_ts(c) or now  # no activity recorded yet -> use start time
        idle = now - last
        if idle >= FAAS_DOCKER_IDLE_SECONDS:
            try:
                c.stop(timeout=10)
                reaped += 1
                print(f"[faas-reaper] scaled to zero: {c.name} (idle {int(idle)}s)", flush=True)
            except Exception as exc:
                print(f"[faas-reaper] stop failed {c.name}: {exc}", flush=True)
    return reaped


def run_loop() -> None:
    if not FAAS_DOCKER_SCALE_ZERO:
        return
    try:
        lockf = open(LOCK_PATH, "w")
    except Exception:
        return
    holding = False
    while True:
        if not holding:
            try:
                fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                holding = True
                print(f"[faas-reaper] active: every {INTERVAL}s, idle>={FAAS_DOCKER_IDLE_SECONDS}s", flush=True)
            except OSError:
                holding = False
        if holding:
            try:
                reap_once()
            except Exception as exc:
                print(f"[faas-reaper] cycle error: {exc}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    run_loop()
