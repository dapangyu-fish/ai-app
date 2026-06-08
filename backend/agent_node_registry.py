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
                display_name TEXT NOT NULL DEFAULT '',
                url TEXT NOT NULL,
                capacity INTEGER NOT NULL DEFAULT 1,
                queue_max INTEGER NOT NULL DEFAULT 0,
                build_commit TEXT NOT NULL DEFAULT '',
                build_version TEXT NOT NULL DEFAULT '',
                labels JSONB NOT NULL DEFAULT '[]'::jsonb,
                owner_user_id TEXT NOT NULL DEFAULT '',
                visibility TEXT NOT NULL DEFAULT 'public',
                auth_public_key TEXT NOT NULL DEFAULT '',
                auth_key_id TEXT NOT NULL DEFAULT '',
                provider_mode TEXT NOT NULL DEFAULT '',
                provider_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
                agent_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
                capabilities JSONB NOT NULL DEFAULT '[]'::jsonb,
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
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS queue_max INTEGER NOT NULL DEFAULT 0")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS build_commit TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS build_version TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS owner_user_id TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'public'")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS auth_public_key TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS auth_key_id TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS provider_mode TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS provider_ids JSONB NOT NULL DEFAULT '[]'::jsonb")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS agent_ids JSONB NOT NULL DEFAULT '[]'::jsonb")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS capabilities JSONB NOT NULL DEFAULT '[]'::jsonb")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS paused BOOLEAN NOT NULL DEFAULT FALSE")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS pause_reason TEXT NOT NULL DEFAULT ''")
        db_execute("ALTER TABLE agent_nodes ADD COLUMN IF NOT EXISTS paused_at_ms BIGINT NOT NULL DEFAULT 0")
        db_execute("CREATE INDEX IF NOT EXISTS idx_agent_nodes_owner_visibility ON agent_nodes (owner_user_id, visibility)")
        _SCHEMA_READY = True


def _json_list(value) -> list:
    if isinstance(value, str):
        try:
            value = json.loads(value or "[]")
        except json.JSONDecodeError:
            value = []
    if not isinstance(value, list):
        return []
    return [str(item).strip() for item in value if str(item or "").strip()]


def _json_bool(value, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off", "disabled"}
    return bool(value)


def _json_capabilities(value) -> list:
    if isinstance(value, str):
        try:
            value = json.loads(value or "[]")
        except json.JSONDecodeError:
            value = []
    if not isinstance(value, list):
        return []
    out = []
    seen = set()
    for raw in value:
        if not isinstance(raw, dict):
            continue
        provider_id = str(raw.get("provider_id") or raw.get("provider") or "").strip().lower().replace("_", "-")
        agent_id = str(raw.get("agent_id") or raw.get("agent") or "").strip().lower().replace("_", "-")
        if not provider_id or not agent_id:
            continue
        adapter_kind = str(raw.get("adapter_kind") or raw.get("adapter") or "").strip().lower().replace("_", "-")
        if not adapter_kind:
            if agent_id == "claude":
                adapter_kind = "anthropic"
            elif agent_id == "opencode":
                adapter_kind = "opencode"
            else:
                adapter_kind = "openai-responses"
        key = (provider_id, agent_id, adapter_kind)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "provider_id": provider_id[:64],
                "agent_id": agent_id[:64],
                "adapter_kind": adapter_kind[:64],
                "status": str(raw.get("status") or "configured").strip().lower().replace("_", "-")[:64],
                "enabled": _json_bool(raw.get("enabled"), True),
            }
        )
    return out


def _normalize_row(row: dict | None) -> dict | None:
    if not row:
        return None
    labels = _json_list(row.get("labels"))
    label_map = {}
    for label in labels:
        if not isinstance(label, str) or "=" not in label:
            continue
        key, value = label.split("=", 1)
        label_map[key.strip().lower().replace("_", "-")] = value.strip()
    return {
        "node_id": row.get("node_id") or "",
        "name": row.get("display_name") or label_map.get("name", ""),
        "display_name": row.get("display_name") or label_map.get("name", ""),
        "url": row.get("url") or "",
        "capacity": int(row.get("capacity") or 1),
        "queue_max": int(row.get("queue_max") or 0),
        "build_commit": row.get("build_commit") or label_map.get("build-commit", ""),
        "build_version": row.get("build_version") or label_map.get("build-version", ""),
        "labels": labels,
        "owner_user_id": row.get("owner_user_id") or label_map.get("owner-user-id", ""),
        "visibility": (row.get("visibility") or label_map.get("visibility", "public") or "public"),
        "auth_public_key": row.get("auth_public_key") or "",
        "auth_key_id": row.get("auth_key_id") or "",
        "provider_mode": row.get("provider_mode") or label_map.get("provider-mode", ""),
        "provider_ids": _json_list(row.get("provider_ids")),
        "agent_ids": _json_list(row.get("agent_ids")),
        "capabilities": _json_capabilities(row.get("capabilities")),
        "last_seen": int(row.get("last_seen") or row.get("last_seen_ms") or 0),
        "ttl_seconds": int(row.get("ttl_seconds") or 120),
        "paused": bool(row.get("paused") or False),
        "pause_reason": row.get("pause_reason") or "",
        "paused_at": int(row.get("paused_at") or row.get("paused_at_ms") or 0),
    }


def upsert_node(
    *,
    node_id: str,
    name: str = "",
    url: str,
    capacity: int,
    labels: list,
    ttl_seconds: int,
    queue_max: int = 0,
    build_commit: str = "",
    build_version: str = "",
    owner_user_id: str = "",
    visibility: str = "public",
    auth_public_key: str = "",
    auth_key_id: str = "",
    provider_mode: str = "",
    provider_ids: list | None = None,
    agent_ids: list | None = None,
    capabilities: list | None = None,
    touch_seen: bool = True,
) -> dict:
    ensure_agent_nodes_table()
    now_ms = int(time.time() * 1000) if touch_seen else 0
    labels_json = json.dumps(labels if isinstance(labels, list) else [], ensure_ascii=False)
    name = str(name or "").strip()[:128]
    queue_max = max(0, int(queue_max or 0))
    build_commit = str(build_commit or "").strip()[:128]
    build_version = str(build_version or build_commit or "").strip()[:128]
    owner_user_id = str(owner_user_id or "").strip()
    visibility = str(visibility or "public").strip().lower()
    if visibility not in {"public", "private"}:
        visibility = "public"
    auth_public_key = str(auth_public_key or "").strip()
    auth_key_id = str(auth_key_id or "").strip()[:128]
    provider_mode = str(provider_mode or "").strip().lower().replace("_", "-")
    provider_ids = _json_list(provider_ids)
    agent_ids = _json_list(agent_ids)
    capabilities = _json_capabilities(capabilities)
    db_execute(
        """
        INSERT INTO agent_nodes (
            node_id, display_name, url, capacity, queue_max, build_commit, build_version, labels,
            owner_user_id, visibility, auth_public_key, auth_key_id, provider_mode,
            provider_ids, agent_ids, capabilities, last_seen_ms, ttl_seconds
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s::jsonb, %s, %s)
        ON CONFLICT (node_id) DO UPDATE SET
            display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), agent_nodes.display_name),
            url = EXCLUDED.url,
            capacity = EXCLUDED.capacity,
            queue_max = EXCLUDED.queue_max,
            build_commit = COALESCE(NULLIF(EXCLUDED.build_commit, ''), agent_nodes.build_commit),
            build_version = COALESCE(NULLIF(EXCLUDED.build_version, ''), agent_nodes.build_version),
            labels = EXCLUDED.labels,
            owner_user_id = COALESCE(NULLIF(EXCLUDED.owner_user_id, ''), agent_nodes.owner_user_id),
            visibility = COALESCE(NULLIF(EXCLUDED.visibility, ''), agent_nodes.visibility),
            auth_public_key = COALESCE(NULLIF(EXCLUDED.auth_public_key, ''), agent_nodes.auth_public_key),
            auth_key_id = COALESCE(NULLIF(EXCLUDED.auth_key_id, ''), agent_nodes.auth_key_id),
            provider_mode = COALESCE(NULLIF(EXCLUDED.provider_mode, ''), agent_nodes.provider_mode),
            provider_ids = CASE WHEN EXCLUDED.provider_ids = '[]'::jsonb THEN agent_nodes.provider_ids ELSE EXCLUDED.provider_ids END,
            agent_ids = CASE WHEN EXCLUDED.agent_ids = '[]'::jsonb THEN agent_nodes.agent_ids ELSE EXCLUDED.agent_ids END,
            capabilities = CASE WHEN EXCLUDED.capabilities = '[]'::jsonb THEN agent_nodes.capabilities ELSE EXCLUDED.capabilities END,
            last_seen_ms = CASE WHEN EXCLUDED.last_seen_ms > 0 THEN EXCLUDED.last_seen_ms ELSE agent_nodes.last_seen_ms END,
            ttl_seconds = EXCLUDED.ttl_seconds,
            updated_at = NOW()
        """,
        [
            node_id,
            name,
            url,
            capacity,
            queue_max,
            build_commit,
            build_version,
            labels_json,
            owner_user_id,
            visibility,
            auth_public_key,
            auth_key_id,
            provider_mode,
            json.dumps(provider_ids, ensure_ascii=False),
            json.dumps(agent_ids, ensure_ascii=False),
            json.dumps(capabilities, ensure_ascii=False),
            now_ms,
            ttl_seconds,
        ],
    )
    return {
        "node_id": node_id,
        "name": name,
        "display_name": name,
        "url": url,
        "capacity": capacity,
        "queue_max": queue_max,
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": labels if isinstance(labels, list) else [],
        "owner_user_id": owner_user_id,
        "visibility": visibility,
        "auth_public_key": auth_public_key,
        "auth_key_id": auth_key_id,
        "provider_mode": provider_mode,
        "provider_ids": provider_ids,
        "agent_ids": agent_ids,
        "capabilities": capabilities,
        "last_seen": now_ms,
        "ttl_seconds": ttl_seconds,
    }


def list_nodes() -> list[dict]:
    ensure_agent_nodes_table()
    rows = db_query(
        """
        SELECT node_id, display_name, url, capacity, queue_max, build_commit, build_version, labels::text AS labels,
               owner_user_id, visibility, auth_public_key, auth_key_id, provider_mode,
               provider_ids::text AS provider_ids, agent_ids::text AS agent_ids, capabilities::text AS capabilities,
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
        SELECT node_id, display_name, url, capacity, queue_max, build_commit, build_version, labels::text AS labels,
               owner_user_id, visibility, auth_public_key, auth_key_id, provider_mode,
               provider_ids::text AS provider_ids, agent_ids::text AS agent_ids, capabilities::text AS capabilities,
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
