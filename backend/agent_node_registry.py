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
                labels JSONB NOT NULL DEFAULT '[]'::jsonb,
                last_seen_ms BIGINT NOT NULL DEFAULT 0,
                ttl_seconds INTEGER NOT NULL DEFAULT 120,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
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
    return {
        "node_id": row.get("node_id") or "",
        "url": row.get("url") or "",
        "capacity": int(row.get("capacity") or 1),
        "labels": labels,
        "last_seen": int(row.get("last_seen") or row.get("last_seen_ms") or 0),
        "ttl_seconds": int(row.get("ttl_seconds") or 120),
    }


def upsert_node(*, node_id: str, url: str, capacity: int, labels: list, ttl_seconds: int) -> dict:
    ensure_agent_nodes_table()
    now_ms = int(time.time() * 1000)
    labels_json = json.dumps(labels if isinstance(labels, list) else [], ensure_ascii=False)
    db_execute(
        """
        INSERT INTO agent_nodes (node_id, url, capacity, labels, last_seen_ms, ttl_seconds)
        VALUES (%s, %s, %s, %s::jsonb, %s, %s)
        ON CONFLICT (node_id) DO UPDATE SET
            url = EXCLUDED.url,
            capacity = EXCLUDED.capacity,
            labels = EXCLUDED.labels,
            last_seen_ms = EXCLUDED.last_seen_ms,
            ttl_seconds = EXCLUDED.ttl_seconds,
            updated_at = NOW()
        """,
        [node_id, url, capacity, labels_json, now_ms, ttl_seconds],
    )
    return {
        "node_id": node_id,
        "url": url,
        "capacity": capacity,
        "labels": labels if isinstance(labels, list) else [],
        "last_seen": now_ms,
        "ttl_seconds": ttl_seconds,
    }


def list_nodes() -> list[dict]:
    ensure_agent_nodes_table()
    rows = db_query(
        """
        SELECT node_id, url, capacity, labels::text AS labels, last_seen_ms AS last_seen, ttl_seconds
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
        SELECT node_id, url, capacity, labels::text AS labels, last_seen_ms AS last_seen, ttl_seconds
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
