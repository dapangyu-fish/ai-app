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

from flask import jsonify, request

from config import AGENT_NODE_REGISTRATION_TOKEN
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

    return {
        "node_id": get("node_id", str(key).split(":")[-1]),
        "url": get("url"),
        "capacity": int(get("capacity", "1") or "1"),
        "labels": json.loads(get("labels", "[]") or "[]"),
        "last_seen": int(get("last_seen", "0") or "0"),
        "ttl_seconds": int(get("ttl_seconds", "120") or "120"),
    }


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
    r = get_redis()
    rows = []
    for key in r.scan_iter("ai:agent_node:*", count=100):
        data = r.hgetall(key)
        if data:
            rows.append(_node_row(key, data))
    rows.sort(key=lambda item: item.get("node_id", ""))
    return jsonify({"nodes": rows})
