#!/usr/bin/env python3
"""Agent node registry endpoints.

This is deliberately small: registered nodes are heartbeat records in Redis.
Workers combine these dynamic nodes with static AGENT_NODE_URLS when choosing
where to run a session.
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
from ai_session import get_redis


def _safe_node_id(value: object) -> str:
    text = str(value or "").strip()
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("._")
    return text[:96] or "agent-node"


def _registry_key(node_id: str) -> str:
    return f"ai:agent_node:{_safe_node_id(node_id)}"


def _auth_ok() -> bool:
    if not AGENT_NODE_REGISTRATION_TOKEN:
        return True
    return request.headers.get("Authorization", "") == f"Bearer {AGENT_NODE_REGISTRATION_TOKEN}"


def _node_row(key, data: dict[Any, Any]) -> dict:
    def get(name: str, default: str = "") -> str:
        raw = data.get(name) if name in data else data.get(name.encode())
        if raw is None:
            return default
        if isinstance(raw, bytes):
            return raw.decode("utf-8", errors="replace")
        return str(raw)

    def get_int(name: str, default: int) -> int:
        try:
            return int(get(name, str(default)) or str(default))
        except (TypeError, ValueError):
            return default

    try:
        labels = json.loads(get("labels", "[]") or "[]")
    except json.JSONDecodeError:
        labels = []
    if not isinstance(labels, list):
        labels = []
    provider_mode = "master"
    for label in labels:
        text = str(label or "").strip().lower().replace("_", "-")
        if text in {"provider-mode=local", "mode=local", "local-provider=true"}:
            provider_mode = "local"
            break
    url = get("url")
    parsed = urlparse(url)
    return {
        "node_id": get("node_id", str(key).split(":")[-1]),
        "url": url,
        "host": parsed.hostname or "",
        "capacity": get_int("capacity", 1),
        "labels": labels,
        "provider_mode": provider_mode,
        "last_seen": get_int("last_seen", 0),
        "ttl_seconds": get_int("ttl_seconds", 120),
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
    elif row.get("reachable") is None:
        row["status"] = "registered"
    elif row.get("reachable") is False:
        row["status"] = "down"
    elif row.get("health") == "ok":
        row["status"] = "online"
    else:
        row["status"] = "unknown"
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
        ttl_seconds = max(30, int(body.get("ttl_seconds") or 120))
    except (TypeError, ValueError):
        ttl_seconds = 120
    labels = body.get("labels") if isinstance(body.get("labels"), list) else []
    now_ms = int(time.time() * 1000)
    data = {
        "node_id": node_id,
        "url": url,
        "capacity": str(capacity),
        "labels": json.dumps(labels, ensure_ascii=False),
        "last_seen": str(now_ms),
        "ttl_seconds": str(ttl_seconds),
    }
    r = get_redis()
    key = _registry_key(node_id)
    pipe = r.pipeline()
    pipe.hset(key, mapping=data)
    pipe.expire(key, ttl_seconds)
    pipe.execute()
    return jsonify({"ok": True, "node": _node_row(key, data)})


def list_agent_nodes():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    probe = request.args.get("probe", "1").lower() not in {"0", "false", "no"}
    r = get_redis()
    rows = []
    for key in r.scan_iter("ai:agent_node:*", count=100):
        data = r.hgetall(key)
        if data:
            rows.append(_decorate_node(_node_row(key, data), probe=probe))
    rows.sort(key=lambda item: item.get("node_id", ""))
    summary = {
        "total": len(rows),
        "online": sum(1 for row in rows if row.get("status") == "online"),
        "registered": sum(1 for row in rows if row.get("status") == "registered"),
        "down": sum(1 for row in rows if row.get("status") == "down"),
        "stale": sum(1 for row in rows if row.get("status") == "stale"),
        "active_runs": sum(int(row.get("active_runs") or 0) for row in rows),
        "capacity": sum(int(row.get("capacity") or 0) for row in rows),
    }
    return jsonify({"summary": summary, "nodes": rows})


def get_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    r = get_redis()
    key = _registry_key(node_id)
    data = r.hgetall(key)
    if not data:
        return jsonify({"error": "agent node not found", "node_id": _safe_node_id(node_id)}), 404
    include_runs = request.args.get("runs", "1").lower() not in {"0", "false", "no"}
    row = _decorate_node(_node_row(key, data), probe=True, include_runs=include_runs)
    return jsonify({"node": row})


def delete_agent_node(node_id: str):
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    r = get_redis()
    key = _registry_key(node_id)
    deleted = int(r.delete(key) or 0)
    return jsonify({"ok": True, "node_id": _safe_node_id(node_id), "deleted": deleted > 0})
