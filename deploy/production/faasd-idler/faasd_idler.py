#!/usr/bin/env python3
"""faasd idle-to-zero reaper.

Community faasd ships the gateway (with ``scale_from_zero=true``) but **not** the
OpenFaaS Pro autoscaler / faas-idler. As a result functions deployed with the
``com.openfaas.scale.zero=true`` label never actually scale down — the label is
set at deploy time but nothing ever consumes it, so every function sits at one
replica forever (``myapp-ctl faas ls`` shows ``INST=1`` for everything).

This daemon fills that one missing gap: the scale-DOWN trigger. Wake-up is
already handled natively — when a function's containerd task is stopped, the
faasd gateway's built-in ``scale_from_zero`` restarts it on the next request
(verified: cold start ~0.8s, works for both direct-invoke and control-plane
proxy traffic). So all we have to do is stop the task of an idle function.

Each tick the reaper:
  1. polls the gateway ``/system/functions`` for per-function ``invocationCount``
     and current ``replicas``;
  2. tracks, per function, the timestamp of the last invocation-count change;
  3. for any function whose count has not moved for longer than its idle window
     (``com.openfaas.scale.zero.duration`` label, default 10m), stops its
     containerd task via ``ctr -n <ns> task kill`` — i.e. scales it to zero.

It respects the same OpenFaaS labels the control plane already sets, so opting a
function out is done the native way (``com.openfaas.scale.zero=false`` or
``com.openfaas.scale.min>=1``), not via a separate config.

Run modes:
  faasd_idler.py            run forever (systemd service)
  faasd_idler.py --once     run a single tick and exit (cron / testing)
  faasd_idler.py --status   print tracked state + idle ages, reap nothing
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

GATEWAY = os.environ.get("FAASD_IDLER_GATEWAY", "http://172.18.0.1:8731").rstrip("/")
SECRETS_DIR = os.environ.get("FAASD_IDLER_SECRETS_DIR", "/var/lib/faasd/secrets")
NAMESPACE = os.environ.get("FAASD_IDLER_NAMESPACE", "openfaas-fn")
DEFAULT_IDLE_SECONDS = int(os.environ.get("FAASD_IDLER_DEFAULT_IDLE_SECONDS", "600"))
POLL_SECONDS = int(os.environ.get("FAASD_IDLER_POLL_SECONDS", "60"))
STATE_PATH = os.environ.get("FAASD_IDLER_STATE", "/var/lib/faasd-idler/state.json")
CTR_BIN = os.environ.get("FAASD_IDLER_CTR", "ctr")
KILL_SIGNAL = os.environ.get("FAASD_IDLER_SIGNAL", "SIGKILL")
DRY_RUN = os.environ.get("FAASD_IDLER_DRY_RUN", "0").strip().lower() in {"1", "true", "yes", "on"}
HTTP_TIMEOUT = float(os.environ.get("FAASD_IDLER_HTTP_TIMEOUT", "8"))
# Optional name filters. ONLY (allowlist) restricts reaping to the listed
# functions — leave unset in production; handy for staged rollout / testing.
# EXCLUDE (denylist) pins always-on functions that must never scale to zero.
ONLY = {x.strip() for x in os.environ.get("FAASD_IDLER_ONLY", "").split(",") if x.strip()}
EXCLUDE = {x.strip() for x in os.environ.get("FAASD_IDLER_EXCLUDE", "").split(",") if x.strip()}


def log(msg: str) -> None:
    print(f"[faasd-idler] {msg}", flush=True)


def _read_secret(name: str, fallback: str = "") -> str:
    path = os.path.join(SECRETS_DIR, name)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return fallback


def _auth_header() -> dict[str, str]:
    user = _read_secret("basic-auth-user", "admin")
    password = _read_secret("basic-auth-password", "")
    if not password:
        return {}
    token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    return {"Authorization": f"Basic {token}"}


def fetch_functions() -> list[dict]:
    req = urllib.request.Request(f"{GATEWAY}/system/functions", headers=_auth_header())
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        body = resp.read().decode("utf-8")
    data = json.loads(body)
    return [f for f in data if isinstance(f, dict) and f.get("name")]


_DURATION_RE = re.compile(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$")


def parse_duration(value: str | None, default: int) -> int:
    """Parse a Go-style duration ('10m', '1h30m', '90s') or bare seconds."""
    if not value:
        return default
    value = str(value).strip()
    if value.isdigit():
        return int(value)
    match = _DURATION_RE.fullmatch(value)
    if not match or not any(match.groups()):
        return default
    hours, minutes, seconds = (int(g) if g else 0 for g in match.groups())
    total = hours * 3600 + minutes * 60 + seconds
    return total if total > 0 else default


def _label(labels: dict, key: str) -> str:
    return str((labels or {}).get(key, "")).strip()


def scale_zero_enabled(labels: dict) -> bool:
    raw = _label(labels, "com.openfaas.scale.zero").lower()
    # Default ON: faas_store deploys with the label set; absence means "use default".
    return raw in {"", "1", "true", "yes", "on"}


def min_replicas(labels: dict) -> int:
    raw = _label(labels, "com.openfaas.scale.min")
    try:
        return int(raw) if raw else 0
    except ValueError:
        return 0


def idle_window(labels: dict) -> int:
    return parse_duration(_label(labels, "com.openfaas.scale.zero.duration"), DEFAULT_IDLE_SECONDS)


def reap_eligible(name: str, labels: dict) -> bool:
    if EXCLUDE and name in EXCLUDE:
        return False
    if ONLY and name not in ONLY:
        return False
    return scale_zero_enabled(labels) and min_replicas(labels) < 1


def running_replicas(fn: dict) -> int:
    rep = fn.get("replicas")
    if rep is None:
        rep = fn.get("availableReplicas")
    try:
        return int(rep) if rep is not None else 0
    except (TypeError, ValueError):
        return 0


def stop_task(name: str) -> bool:
    cmd = [CTR_BIN, "-n", NAMESPACE, "task", "kill", "-s", KILL_SIGNAL, name]
    if DRY_RUN:
        log(f"DRY_RUN would scale to zero: {' '.join(cmd)}")
        return True
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 0:
        return True
    err = (proc.stderr or proc.stdout or "").strip()
    # A racing wake / already-stopped task is not an error worth alarming on.
    if "not found" in err.lower() or "no running task" in err.lower():
        log(f"skip {name}: {err}")
        return False
    log(f"failed to stop {name}: rc={proc.returncode} {err}")
    return False


def load_state() -> dict:
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_PATH) or ".", exist_ok=True)
    tmp = f"{STATE_PATH}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(tmp, STATE_PATH)


def tick(now: float, state: dict) -> dict:
    try:
        functions = fetch_functions()
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log(f"poll failed: {exc}")
        return state

    seen = set()
    reaped = 0
    for fn in functions:
        name = str(fn["name"])
        seen.add(name)
        inv = float(fn.get("invocationCount") or 0)
        labels = fn.get("labels") or {}
        prev = state.get(name)
        if prev is None:
            state[name] = {"inv": inv, "since": now}
            continue
        if inv != prev.get("inv"):
            # Any change (up = invoked, down = counter reset after a wake) is activity.
            state[name] = {"inv": inv, "since": now}
            continue
        # No invocation activity since prev["since"].
        if running_replicas(fn) <= 0:
            continue  # already scaled to zero; nothing to do
        if not reap_eligible(name, labels):
            continue  # opted out via labels or name filter
        idle_for = now - float(prev.get("since", now))
        window = idle_window(labels)
        if idle_for >= window:
            if stop_task(name):
                reaped += 1
                log(f"scaled to zero: {name} (idle {int(idle_for)}s >= {window}s)")

    # Forget functions that no longer exist.
    pruned = {k: v for k, v in state.items() if k in seen}
    if reaped:
        log(f"tick: {len(functions)} functions, {reaped} scaled to zero")
    return pruned


def cmd_status() -> int:
    now = time.time()
    state = load_state()
    try:
        functions = {f["name"]: f for f in fetch_functions()}
    except Exception as exc:  # noqa: BLE001 - status is best-effort
        log(f"gateway unreachable: {exc}")
        functions = {}
    print(f"gateway={GATEWAY} ns={NAMESPACE} default_idle={DEFAULT_IDLE_SECONDS}s dry_run={DRY_RUN}")
    print(f"{'FUNCTION':40} {'REPL':>4} {'INV':>8} {'IDLE(s)':>8} {'WINDOW':>7} {'ZERO?':>6}")
    for name in sorted(set(functions) | set(state)):
        fn = functions.get(name, {})
        st = state.get(name, {})
        repl = running_replicas(fn) if fn else 0
        inv = int(float(fn.get("invocationCount") or 0)) if fn else "-"
        idle = int(now - float(st.get("since", now))) if st else "-"
        labels = fn.get("labels") or {}
        window = idle_window(labels) if fn else DEFAULT_IDLE_SECONDS
        enabled = "yes" if (fn and reap_eligible(name, labels)) else "no"
        print(f"{name:40} {repl:>4} {str(inv):>8} {str(idle):>8} {window:>7} {enabled:>6}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="faasd idle-to-zero reaper")
    parser.add_argument("--once", action="store_true", help="run a single tick and exit")
    parser.add_argument("--status", action="store_true", help="print tracked state, reap nothing")
    args = parser.parse_args()

    if args.status:
        return cmd_status()

    log(
        f"start gateway={GATEWAY} ns={NAMESPACE} default_idle={DEFAULT_IDLE_SECONDS}s "
        f"poll={POLL_SECONDS}s dry_run={DRY_RUN} state={STATE_PATH}"
    )
    state = load_state()
    if args.once:
        state = tick(time.time(), state)
        save_state(state)
        return 0

    while True:
        state = tick(time.time(), state)
        save_state(state)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
