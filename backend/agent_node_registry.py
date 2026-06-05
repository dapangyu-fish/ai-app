#!/usr/bin/env python3
"""Persistent registry for agent-node hosts."""

from __future__ import annotations

import json
import threading
import time

from database import db_execute, db_query


_SCHEMA_READY = False
_SCHEMA_LOCK = threading.Lock()


def ensure_agent_nodes_table() -> None:
    global _SCHEMA_READY
    if _SCHEMA_READY:
        return
    with _SCHEMA_LOCK:
        if _SCHEMA_READY:
            return
        db_execute(
            """
            CREATE TABLE IF NOT EXISTS agent_nodes (
                node_id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                capacity INTEGER NOT NULL DEFAULT 1,
                queue_max INTEGER NOT NULL DEFAULT 0,
                build_commit TEXT NOT NULL DEFAULT '',
                build_version TEXT NOT NULL DEFAULT '',
                labels JSONB NOT NULL DEFAULT '[]'::jsonb,
                last_seen_ms BIGINT NOT NULL DEFAULT 0,
                ttl_seconds INTEGER NOT NULL DEFAULT 120,
                paused BOOLEAN NOT NULL DEFAULT FALSE,
                pause_reason TEXT NOT NULL DEFAULT '',
                paused_at_ms BIGINT NOT NULL DEFAULT 0,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS queue_max INTEGER NOT NULL DEFAULT 0")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS build_commit TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS build_version TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS paused BOOLEAN NOT NULL DEFAULT FALSE")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS pause_reason TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS paused_at_ms BIGINT NOT NULL DEFAULT 0")
        _SCHEMA_READY = True


def _normalize_row(row: dict | None) -> dict | None:
    if not row:
        return None
    labels = row.get("labels")
    if isinstance(labels, str):
        try:
            labels = json.loads(labels or "[]")
        except json.JSONDecodeError:
            labels = []
    if not isinstance(labels, list):
        labels = []
    label_map = {}
    for label in labels:
        if not isinstance(label, str) or "=" not in label:
            continue
        key, value = label.split("=", 1)
        label_map[key.strip().lower().replace("_", "-")] = value.strip()
    return {
        "node_id": row.get("node_id") or "",
        "url": row.get("url") or "",
        "capacity": int(row.get("capacity") or 1),
        "queue_max": int(row.get("queue_max") or 0),
        "build_commit": row.get("build_commit") or label_map.get("build-commit", ""),
        "build_version": row.get("build_version") or label_map.get("build-version", ""),
        "labels": labels,
        "last_seen": int(row.get("last_seen") or row.get("last_seen_ms") or 0),
        "ttl_seconds": int(row.get("ttl_seconds") or 120),
        "paused": bool(row.get("paused") or False),
        "pause_reason": row.get("pause_reason") or "",
        "paused_at": int(row.get("paused_at") or row.get("paused_at_ms") or 0),
    }


def upsert_node(
    *,
    node_id: str,
    url: str,
    capacity: int,
    labels: list,
    ttl_seconds: int,
    queue_max: int = 0,
    build_commit: str = "",
    build_version: str = "",
) -> dict:
    ensure_agent_nodes_table()
    now_ms = int(time.time() * 1000)
    labels_json = json.dumps(labels if isinstance(labels, list) else [], ensure_ascii=False)
    queue_max = max(0, int(queue_max or 0))
    build_commit = str(build_commit or "").strip()[:128]
    build_version = str(build_version or build_commit or "").strip()[:128]
    db_execute(
        """
        INSERT INTO agent_nodes (node_id, url, capacity, queue_max, build_commit, build_version, labels, last_seen_ms, ttl_seconds)
        VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb, %s, %s)
        ON CONFLICT (node_id) DO UPDATE SET
            url = EXCLUDED.url,
            capacity = EXCLUDED.capacity,
            queue_max = EXCLUDED.queue_max,
            build_commit = COALESCE(NULLIF(EXCLUDED.build_commit, ''), agent_nodes.build_commit),
            build_version = COALESCE(NULLIF(EXCLUDED.build_version, ''), agent_nodes.build_version),
            labels = EXCLUDED.labels,
            last_seen_ms = EXCLUDED.last_seen_ms,
            ttl_seconds = EXCLUDED.ttl_seconds,
            updated_at = NOW()
        """,
        [node_id, url, capacity, queue_max, build_commit, build_version, labels_json, now_ms, ttl_seconds],
    )
    return {
        "node_id": node_id,
        "url": url,
        "capacity": capacity,
        "queue_max": queue_max,
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": labels if isinstance(labels, list) else [],
        "last_seen": now_ms,
        "ttl_seconds": ttl_seconds,
    }


def list_nodes() -> list[dict]:
    ensure_agent_nodes_table()
    rows = db_query(
        """
        SELECT node_id, url, capacity, queue_max, build_commit, build_version, labels::text AS labels,
               last_seen_ms AS last_seen, ttl_seconds,
               paused, pause_reason, paused_at_ms AS paused_at
        FROM agent_nodes
        ORDER BY node_id
        """,
        fetch_all=True,
    )
    normalized = []
    for row in rows or []:
        item = _normalize_row(row)
        if item:
            normalized.append(item)
    return normalized


def get_node(node_id: str) -> dict | None:
    ensure_agent_nodes_table()
    row = db_query(
        """
        SELECT node_id, url, capacity, queue_max, build_commit, build_version, labels::text AS labels,
               last_seen_ms AS last_seen, ttl_seconds,
               paused, pause_reason, paused_at_ms AS paused_at
        FROM agent_nodes
        WHERE node_id = %s
        """,
        [node_id],
        fetch_one=True,
    )
    return _normalize_row(row)


def delete_node(node_id: str) -> bool:
    ensure_agent_nodes_table()
    existed = get_node(node_id) is not None
    db_execute("DELETE FROM agent_nodes WHERE node_id = %s", [node_id])
    return existed


def set_node_paused(node_id: str, *, paused: bool, reason: str = "") -> dict | None:
    ensure_agent_nodes_table()
    existing = get_node(node_id)
    if not existing:
        return None
    pause_reason = str(reason or "").strip()[:500] if paused else ""
    paused_at_ms = int(time.time() * 1000) if paused else 0
    db_execute(
        """
        UPDATE agent_nodes
        SET paused = %s,
            pause_reason = %s,
            paused_at_ms = %s,
            updated_at = NOW()
        WHERE node_id = %s
        """,
        [paused, pause_reason, paused_at_ms, node_id],
    )
    return get_node(node_id)
