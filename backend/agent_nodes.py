#!/usr/bin/env python3
"""Agent node registry endpoints.

Agent host configuration is persisted in Postgres so a Redis restart does not
erase the cluster registry. Redis heartbeat records are still written as a
short-lived compatibility cache, but workers and management commands should
treat the database as the source of truth.
"""

from __future__ import annotations

import json
import re
import time
from typing import Any
from urllib.parse import urlparse

import requests
from flask import jsonify, request

from config import AGENT_NODE_REGISTRATION_TOKEN, AGENT_NODE_TOKEN
import agent_node_registry
from ai_session import get_redis


def _safe_node_id(value: object) -> str:
    text = str(value or "").strip()
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("._")
    return text[:96] or "agent-node"


def _safe_build_text(value: object) -> str:
    return str(value or "").strip()[:128]


def _registry_key(node_id: str) -> str:
    return f"ai:agent_node:{_safe_node_id(node_id)}"


def _auth_ok() -> bool:
    if not AGENT_NODE_REGISTRATION_TOKEN:
        return True
    return request.headers.get("Authorization", "") == f"Bearer {AGENT_NODE_REGISTRATION_TOKEN}"


def _node_row(key, data: dict[Any, Any]) -> dict:
    def raw(name: str):
        return data.get(name) if name in data else data.get(name.encode())

    def get(name: str, default: str = "") -> str:
        value = raw(name)
        if value is None:
            return default
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return str(value)

    def get_int(name: str, default: int) -> int:
        try:
            return int(get(name, str(default)) or str(default))
        except (TypeError, ValueError):
            return default

    def get_bool(name: str, default: bool = False) -> bool:
        value = raw(name)
        if value is None:
            return default
        if isinstance(value, bool):
            return value
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    raw_labels = raw("labels")
    if isinstance(raw_labels, list):
        labels = raw_labels
    else:
        try:
            labels = json.loads(get("labels", "[]") or "[]")
        except json.JSONDecodeError:
            labels = []
    if not isinstance(labels, list):
        labels = []
    provider_mode = "master"
    label_host = ""
    label_build_commit = ""
    label_build_version = ""
    for label in labels:
        text = str(label or "").strip().lower().replace("_", "-")
        if text in {"provider-mode=local", "mode=local", "local-provider=true"}:
            provider_mode = "local"
        if text.startswith("host="):
            label_host = str(label).split("=", 1)[1].strip()
        if text.startswith("build-commit="):
            label_build_commit = str(label).split("=", 1)[1].strip()
        if text.startswith("build-version="):
            label_build_version = str(label).split("=", 1)[1].strip()
    url = get("url")
    parsed = urlparse(url)
    build_commit = _safe_build_text(get("build_commit") or label_build_commit)
    build_version = _safe_build_text(get("build_version") or get("version") or label_build_version or build_commit)
    return {
        "node_id": get("node_id", str(key).split(":")[-1]),
        "url": url,
        "host": label_host or parsed.hostname or "",
        "capacity": get_int("capacity", 1),
        "queue_max": get_int("queue_max", 0),
        "build_commit": build_commit,
        "build_version": build_version,
        "version": build_version or build_commit,
        "labels": labels,
        "provider_mode": provider_mode,
        "last_seen": get_int("last_seen", 0),
        "ttl_seconds": get_int("ttl_seconds", 120),
        "paused": get_bool("paused", False),
        "pause_reason": get("pause_reason", ""),
        "paused_at": get_int("paused_at", 0),
    }


def _agent_node_headers() -> dict[str, str]:
    headers = {"User-Agent": "myapp-backend/agent-node-registry"}
    if AGENT_NODE_TOKEN:
        headers["Authorization"] = f"Bearer {AGENT_NODE_TOKEN}"
    return headers


def _node_expires_in(row: dict, now_ms: int) -> int:
    last_seen = int(row.get("last_seen") or 0)
    ttl_ms = max(0, int(row.get("ttl_seconds") or 0) * 1000)
    if not last_seen or not ttl_ms:
        return 0
    return max(0, int((last_seen + ttl_ms - now_ms) / 1000))


def _probe_agent_node(row: dict) -> dict:
    url = str(row.get("url") or "").rstrip("/")
    node_id = str(row.get("node_id") or "")
    if url.startswith("pull://"):
        try:
            active_runs = int(get_redis().scard(f"ai:agent_pull:node_running:{node_id}") or 0)
        except Exception:
            active_runs = 0
        return {
            "reachable": True,
            "health": "pull",
            "active_runs": active_runs,
            "build_commit": row.get("build_commit") or "",
            "build_version": row.get("build_version") or row.get("version") or "",
            "version": row.get("build_version") or row.get("version") or row.get("build_commit") or "",
            "detail": "",
        }
    if not url:
        return {
            "reachable": False,
            "health": "missing-url",
            "active_runs": 0,
            "detail": "missing url",
        }
    try:
        resp = requests.get(
            f"{url}/health",
            headers=_agent_node_headers(),
            timeout=(1.2, 2.5),
        )
        text = resp.text[:240]
        if resp.status_code >= 400:
            return {
                "reachable": False,
                "health": f"http-{resp.status_code}",
                "active_runs": 0,
                "detail": text,
            }
        try:
            payload = resp.json()
        except ValueError:
            payload = {}
        return {
            "reachable": True,
            "health": "ok" if payload.get("ok", True) else "error",
            "active_runs": int(payload.get("running") or 0),
            "capacity": int(payload.get("capacity") or row.get("capacity") or 1),
            "queue_max": int(payload.get("queue_max") or row.get("queue_max") or 0),
            "build_commit": _safe_build_text(payload.get("build_commit") or row.get("build_commit")),
            "build_version": _safe_build_text(
                payload.get("build_version")
                or payload.get("version")
                or row.get("build_version")
                or row.get("version")
                or row.get("build_commit")
            ),
            "version": _safe_build_text(
                payload.get("build_version")
                or payload.get("version")
                or row.get("build_version")
                or row.get("version")
                or row.get("build_commit")
            ),
            "runtime_image": payload.get("image", ""),
            "proxy_tokens": int(payload.get("proxy_tokens") or 0),
            "detail": "",
        }
    except requests.RequestException as exc:
        return {
            "reachable": False,
            "health": "down",
            "active_runs": 0,
            "detail": str(exc),
        }


def _agent_pull_queue_depth() -> int:
    try:
        return int(get_redis().llen("ai:agent_pull:pending") or 0)
    except Exception:
        return 0


def _with_queue_depth(row: dict, queued: int | None = None) -> dict:
    row = dict(row)
    if queued is None:
        queued = _agent_pull_queue_depth()
    row["queue_depth"] = queued if str(row.get("url") or "").startswith("pull://") and row.get("status") == "online" else 0
    return row


def _decorate_node(row: dict, *, probe: bool, include_runs: bool = False) -> dict:
    now_ms = int(time.time() * 1000)
    row = dict(row)
    expires_in = _node_expires_in(row, now_ms)
    row["expires_in_seconds"] = expires_in
    row["registry_active"] = expires_in > 0
    if probe:
        row.update(_probe_agent_node(row))
    else:
        row.setdefault("reachable", None)
        row.setdefault("health", "not-probed")
        row.setdefault("active_runs", None)
        row.setdefault("detail", "")
    if not row["registry_active"]:
        row["status"] = "stale"
    elif row.get("paused"):
        row["status"] = "paused"
    elif row.get("reachable") is None:
        row["status"] = "registered"
    elif row.get("reachable") is False:
        row["status"] = "down"
    elif row.get("health") in {"ok", "pull"}:
        row["status"] = "online"
    else:
        row["status"] = "unknown"
    build_commit = _safe_build_text(row.get("build_commit"))
    build_version = _safe_build_text(row.get("build_version") or row.get("version") or build_commit)
    row["build_commit"] = build_commit
    row["build_version"] = build_version
    row["version"] = build_version or build_commit
    if include_runs:
        row["runs"] = _fetch_agent_node_runs(str(row.get("url") or ""))
    return row


def _fetch_agent_node_runs(url: str) -> list[dict]:
    url = url.rstrip("/")
    if not url:
        return []
    try:
        resp = requests.get(
            f"{url}/v1/runs",
            params={"history": "0", "limit": "100"},
            headers=_agent_node_headers(),
            timeout=(1.2, 3.0),
        )
        resp.raise_for_status()
        payload = resp.json()
    except requests.RequestException:
        return []
    except ValueError:
        return []
    runs = payload.get("runs")
    return runs if isinstance(runs, list) else []


def register_agent_node():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    body = request.get_json(silent=True) or {}
    node_id = _safe_node_id(body.get("node_id"))
    url = str(body.get("url") or "").strip().rstrip("/")
    if not url:
        return jsonify({"error": "url is required"}), 400
    try:
        capacity = max(1, int(body.get("capacity") or 1))
    except (TypeError, ValueError):
        capacity = 1
    try:
        queue_max = max(0, min(10000, int(body.get("queue_max") if body.get("queue_max") is not None else capacity)))
    except (TypeError, ValueError):
        queue_max = capacity
    try:
        ttl_seconds = max(30, int(body.get("ttl_seconds") or 120))
    except (TypeError, ValueError):
        ttl_seconds = 120
    labels = body.get("labels") if isinstance(body.get("labels"), list) else []
    build_commit = _safe_build_text(body.get("build_commit") or body.get("commit"))
    build_version = _safe_build_text(body.get("build_version") or body.get("version") or build_commit)
    now_ms = int(time.time() * 1000)
    data = {
        "node_id": node_id,
        "url": url,
        "capacity": capacity,
        "queue_max": queue_max,
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": labels,
        "last_seen": now_ms,
        "ttl_seconds": ttl_seconds,
    }
    agent_node_registry.upsert_node(
        node_id=node_id,
        url=url,
        capacity=capacity,
        queue_max=queue_max,
        build_commit=build_commit,
        build_version=build_version,
        labels=labels,
        ttl_seconds=ttl_seconds,
    )
    redis_data = {
        "node_id": node_id,
        "url": url,
        "capacity": str(capacity),
        "queue_max": str(queue_max),
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": json.dumps(labels, ensure_ascii=False),
        "last_seen": str(now_ms),
        "ttl_seconds": str(ttl_seconds),
    }
    key = _registry_key(node_id)
    try:
        r = get_redis()
        pipe = r.pipeline()
        pipe.hset(key, mapping=redis_data)
        pipe.expire(key, ttl_seconds)
        pipe.execute()
    except Exception:
        pass
    return jsonify({"ok": True, "node": _node_row(key, data)})


def list_agent_nodes():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    probe = request.args.get("probe", "1").lower() not in {"0", "false", "no"}
    rows = []
    for item in agent_node_registry.list_nodes():
        rows.append(_decorate_node(_node_row(item.get("node_id"), item), probe=probe))
    rows.sort(key=lambda item: item.get("node_id", ""))
    queued = _agent_pull_queue_depth()
    for row in rows:
        row.update(_with_queue_depth(row, queued))
    summary = {
        "total": len(rows),
        "online": sum(1 for row in rows if row.get("status") == "online"),
        "paused": sum(1 for row in rows if row.get("status") == "paused"),
        "registered": sum(1 for row in rows if row.get("status") == "registered"),
        "down": sum(1 for row in rows if row.get("status") == "down"),
        "stale": sum(1 for row in rows if row.get("status") == "stale"),
        "queued": queued,
        "active_runs": sum(int(row.get("active_runs") or 0) for row in rows),
        "capacity": sum(int(row.get("capacity") or 0) for row in rows),
        "queue_max": sum(int(row.get("queue_max") or 0) for row in rows),
        "available_capacity": sum(
            int(row.get("capacity") or 0)
            for row in rows
            if row.get("status") == "online"
        ),
        "available_queue_max": sum(
            int(row.get("queue_max") or 0)
            for row in rows
            if row.get("status") == "online"
        ),
    }
    return jsonify({"summary": summary, "nodes": rows})


def get_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    safe_node_id = _safe_node_id(node_id)
    data = agent_node_registry.get_node(safe_node_id)
    if not data:
        return jsonify({"error": "agent node not found", "node_id": safe_node_id}), 404
    include_runs = request.args.get("runs", "1").lower() not in {"0", "false", "no"}
    row = _with_queue_depth(_decorate_node(_node_row(safe_node_id, data), probe=True, include_runs=include_runs))
    return jsonify({"node": row})


def delete_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    safe_node_id = _safe_node_id(node_id)
    deleted = agent_node_registry.delete_node(safe_node_id)
    try:
        get_redis().delete(_registry_key(safe_node_id))
    except Exception:
        pass
    return jsonify({"ok": True, "node_id": safe_node_id, "deleted": deleted})


def pause_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    safe_node_id = _safe_node_id(node_id)
    body = request.get_json(silent=True) or {}
    reason = str(body.get("reason") or "").strip()
    data = agent_node_registry.set_node_paused(safe_node_id, paused=True, reason=reason)
    if not data:
        return jsonify({"error": "agent node not found", "node_id": safe_node_id}), 404
    try:
        get_redis().hset(_registry_key(safe_node_id), mapping={"paused": "1", "pause_reason": reason})
    except Exception:
        pass
    return jsonify({"ok": True, "node": _with_queue_depth(_decorate_node(_node_row(safe_node_id, data), probe=True))})


def resume_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    safe_node_id = _safe_node_id(node_id)
    data = agent_node_registry.set_node_paused(safe_node_id, paused=False)
    if not data:
        return jsonify({"error": "agent node not found", "node_id": safe_node_id}), 404
    try:
        get_redis().hset(_registry_key(safe_node_id), mapping={"paused": "0", "pause_reason": ""})
    except Exception:
        pass
    return jsonify({"ok": True, "node": _with_queue_depth(_decorate_node(_node_row(safe_node_id, data), probe=True))})
