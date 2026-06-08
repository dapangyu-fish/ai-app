#!/usr/bin/env python3
"""Agent node registry endpoints.

Agent host configuration is persisted in Postgres so a Redis restart does not
erase the cluster registry. Redis heartbeat records are still written as a
short-lived compatibility cache, but workers and management commands should
treat the database as the source of truth.
"""

from __future__ import annotations

import json
import hashlib
import re
import secrets
import shlex
import time
from typing import Any
from urllib.parse import urlparse

import requests
from flask import current_app, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from config import AGENT_NODE_REGISTRATION_TOKEN, AGENT_NODE_TOKEN
import auth
import agent_node_registry
from ai_session import get_redis


_PRIVATE_JOIN_TOKEN_SALT = "myapp-private-agent-join"
_PRIVATE_JOIN_TOKEN_MAX_AGE_SECONDS = 3600


def _safe_node_id(value: object) -> str:
    text = str(value or "").strip()
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("._")
    return text[:96] or "agent-node"


def _safe_build_text(value: object) -> str:
    return str(value or "").strip()[:128]


def _safe_list(value: object, *, limit: int = 32) -> list[str]:
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("["):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = []
            items = [str(item or "").strip() for item in parsed] if isinstance(parsed, list) else []
        else:
            items = [item.strip() for item in text.split(",")]
    elif isinstance(value, list):
        items = [str(item or "").strip() for item in value]
    else:
        items = []
    out: list[str] = []
    seen: set[str] = set()
    for item in items:
        normalized = item.lower().replace("_", "-")
        if not normalized or normalized in seen:
            continue
        out.append(normalized[:64])
        seen.add(normalized)
        if len(out) >= limit:
            break
    return out


def _default_adapter_kind(agent_id: str) -> str:
    normalized = str(agent_id or "").strip().lower().replace("_", "-")
    if normalized == "claude":
        return "anthropic"
    if normalized == "codex":
        return "openai-responses"
    if normalized == "opencode":
        return "opencode"
    return normalized or "unknown"


def _safe_capabilities(value: object, *, limit: int = 64) -> list[dict]:
    if isinstance(value, str):
        text = value.strip()
        if not text:
            raw_items = []
        else:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = []
            raw_items = parsed if isinstance(parsed, list) else []
    elif isinstance(value, list):
        raw_items = value
    else:
        raw_items = []
    out: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        provider_id = str(raw.get("provider_id") or raw.get("provider") or "").strip().lower().replace("_", "-")
        agent_id = str(raw.get("agent_id") or raw.get("agent") or "").strip().lower().replace("_", "-")
        if not provider_id or not agent_id:
            continue
        adapter_kind = str(raw.get("adapter_kind") or raw.get("adapter") or _default_adapter_kind(agent_id)).strip().lower().replace("_", "-")
        key = (provider_id, agent_id, adapter_kind)
        if key in seen:
            continue
        seen.add(key)
        enabled_raw = raw.get("enabled", True)
        if isinstance(enabled_raw, str):
            enabled = enabled_raw.strip().lower() not in {"0", "false", "no", "off", "disabled"}
        else:
            enabled = bool(enabled_raw)
        out.append(
            {
                "provider_id": provider_id[:64],
                "agent_id": agent_id[:64],
                "adapter_kind": adapter_kind[:64],
                "status": str(raw.get("status") or "configured").strip().lower().replace("_", "-")[:64],
                "enabled": enabled,
            }
        )
        if len(out) >= limit:
            break
    return out


def _public_key_id(public_key: str) -> str:
    digest = hashlib.sha256(public_key.encode("utf-8")).hexdigest()
    return digest[:24]


def _private_join_token_serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"])


def _private_join_token_key(jti: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(jti or "")).strip("._")
    return f"ai:private_agent_join_token:{safe}"


def _consume_private_join_token(jti: str, expected_user_id: str = "") -> bool:
    if not jti:
        return False
    key = _private_join_token_key(jti)
    try:
        raw = get_redis().execute_command("GETDEL", key)
    except Exception:
        try:
            raw = get_redis().get(key)
            get_redis().delete(key)
        except Exception:
            return False
    if isinstance(raw, bytes):
        value = raw.decode("utf-8", errors="replace")
    else:
        value = str(raw or "")
    return bool(value and (not expected_user_id or value == expected_user_id))


def _verify_private_join_token(token: str) -> tuple[str, str, str]:
    text = str(token or "").strip()
    if not text:
        return "", "", "missing join token"
    try:
        data = _private_join_token_serializer().loads(
            text,
            salt=_PRIVATE_JOIN_TOKEN_SALT,
            max_age=_PRIVATE_JOIN_TOKEN_MAX_AGE_SECONDS,
        )
    except SignatureExpired:
        return "", "", "join token expired"
    except BadSignature:
        return "", "", "invalid join token"
    if not isinstance(data, dict):
        return "", "", "invalid join token"
    user_id = str(data.get("uid") or "").strip()
    jti = str(data.get("jti") or "").strip()
    if not user_id or not jti:
        return "", "", "invalid join token"
    if not _consume_private_join_token(jti, user_id):
        return "", "", "join token expired or already used"
    return user_id, jti, ""


def _private_registration_identity() -> tuple[str, str, tuple[dict, int] | None]:
    body = request.get_json(silent=True) or {}
    join_token = (
        request.headers.get("X-MyApp-Private-Agent-Join-Token", "")
        or str(body.get("join_token") or "")
    ).strip()
    auth_header = request.headers.get("Authorization", "")
    if not join_token and auth_header.startswith("Private-Agent-Join "):
        join_token = auth_header[len("Private-Agent-Join "):].strip()
    if not join_token and auth_header.startswith("Bearer "):
        bearer = auth_header[7:].strip()
        user_id, jti, error = _verify_private_join_token(bearer)
        if user_id:
            return user_id, jti, None
        user = auth.verify_access_token(bearer)
        if user is not None:
            request.supabase_user = user
            request.supabase_token = bearer
            return str(user.get("id") or ""), "", None
        return "", "", ({"error": error or "token 无效或已过期"}, 401)
    if join_token:
        user_id, jti, error = _verify_private_join_token(join_token)
        if not user_id:
            return "", "", ({"error": error}, 401)
        return user_id, jti, None
    return "", "", ({"error": "未提供认证 token 或私有节点加入令牌"}, 401)


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
    if data.get("provider_mode"):
        provider_mode = str(data.get("provider_mode")).strip().lower().replace("_", "-") or provider_mode
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
    node_id = get("node_id", str(key).split(":")[-1])
    visibility = get("visibility", "public") or "public"
    display_name = get("name") or get("display_name") or node_id
    return {
        "node_id": node_id,
        "name": display_name,
        "display_name": display_name,
        "url": url,
        "host": label_host or parsed.hostname or "",
        "capacity": get_int("capacity", 1),
        "queue_max": get_int("queue_max", 0),
        "build_commit": build_commit,
        "build_version": build_version,
        "version": build_version or build_commit,
        "labels": labels,
        "provider_mode": provider_mode,
        "visibility": visibility,
        "owner_user_id": get("owner_user_id", ""),
        "namespace": "public" if visibility == "public" else get("owner_user_id", ""),
        "auth_key_id": get("auth_key_id", ""),
        "provider_ids": _safe_list(raw("provider_ids")),
        "agent_ids": _safe_list(raw("agent_ids")),
        "capabilities": _safe_capabilities(raw("capabilities")),
        "has_auth_public_key": bool(get("auth_public_key", "")),
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


def _agent_pull_private_queue_depth(owner_user_id: str) -> int:
    safe_user = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(owner_user_id or "user")).strip("._") or "user"
    try:
        return int(get_redis().llen(f"ai:agent_pull:pending:user:{safe_user}") or 0)
    except Exception:
        return 0


def _with_queue_depth(row: dict, queued: int | None = None) -> dict:
    row = dict(row)
    if queued is None:
        queued = (
            _agent_pull_private_queue_depth(str(row.get("owner_user_id") or ""))
            if row.get("visibility") == "private"
            else _agent_pull_queue_depth()
        )
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
    name = str(body.get("name") or body.get("display_name") or node_id).strip()[:128]
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
    capabilities = _safe_capabilities(body.get("capabilities"))
    provider_ids = _safe_list(body.get("provider_ids") or body.get("providers"))
    agent_ids = _safe_list(body.get("agent_ids") or body.get("agents"))
    if capabilities:
        provider_ids = sorted({item["provider_id"] for item in capabilities})
        agent_ids = sorted({item["agent_id"] for item in capabilities})
    existing = agent_node_registry.get_node(node_id)
    if existing and existing.get("visibility") == "private":
        return jsonify({"error": "node_id belongs to a private agent node"}), 403
    now_ms = int(time.time() * 1000)
    data = {
        "node_id": node_id,
        "name": name,
        "display_name": name,
        "url": url,
        "capacity": capacity,
        "queue_max": queue_max,
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": labels,
        "visibility": "public",
        "owner_user_id": "",
        "provider_mode": "",
        "provider_ids": provider_ids,
        "agent_ids": agent_ids,
        "capabilities": capabilities,
        "last_seen": now_ms,
        "ttl_seconds": ttl_seconds,
    }
    agent_node_registry.upsert_node(
        node_id=node_id,
        name=name,
        url=url,
        capacity=capacity,
        queue_max=queue_max,
        build_commit=build_commit,
        build_version=build_version,
        labels=labels,
        ttl_seconds=ttl_seconds,
        visibility="public",
        provider_ids=provider_ids,
        agent_ids=agent_ids,
        capabilities=capabilities,
    )
    redis_data = {
        "node_id": node_id,
        "name": name,
        "display_name": name,
        "url": url,
        "capacity": str(capacity),
        "queue_max": str(queue_max),
        "build_commit": build_commit,
        "build_version": build_version,
        "labels": json.dumps(labels, ensure_ascii=False),
        "visibility": "public",
        "owner_user_id": "",
        "provider_ids": json.dumps(provider_ids, ensure_ascii=False),
        "agent_ids": json.dumps(agent_ids, ensure_ascii=False),
        "capabilities": json.dumps(capabilities, ensure_ascii=False),
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


def _private_node_response(row: dict, *, probe: bool = True) -> dict:
    decorated = _with_queue_depth(_decorate_node(_node_row(row.get("node_id"), row), probe=probe))
    decorated.pop("owner_user_id", None)
    decorated.pop("auth_public_key", None)
    return decorated


@auth.require_auth
def list_private_agent_nodes():
    user_id = str(request.supabase_user.get("id") or "")
    probe = request.args.get("probe", "1").lower() not in {"0", "false", "no"}
    rows = [
        _private_node_response(row, probe=probe)
        for row in agent_node_registry.list_nodes()
        if row.get("visibility") == "private" and row.get("owner_user_id") == user_id
    ]
    rows.sort(key=lambda item: item.get("node_id", ""))
    queued = _agent_pull_private_queue_depth(user_id)
    return jsonify({"nodes": rows, "summary": _private_nodes_summary(rows, queued)})


def _private_nodes_summary(rows: list[dict], queued: int) -> dict:
    return {
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


def get_private_agent_node_self():
    from ai_session import _agent_pull_auth_context

    auth_ctx = _agent_pull_auth_context()
    if not auth_ctx.get("ok") or auth_ctx.get("kind") != "private":
        return jsonify({"error": "unauthorized"}), 401
    node_id = str(auth_ctx.get("node_id") or "")
    owner_user_id = str(auth_ctx.get("owner_user_id") or "")
    row = agent_node_registry.get_node(node_id)
    if not row or row.get("visibility") != "private" or row.get("owner_user_id") != owner_user_id:
        return jsonify({"error": "agent node not found"}), 404
    probe = request.args.get("probe", "1").lower() not in {"0", "false", "no"}
    rows = [_private_node_response(row, probe=probe)]
    queued = _agent_pull_private_queue_depth(owner_user_id)
    return jsonify({"nodes": rows, "summary": _private_nodes_summary(rows, queued)})


@auth.require_auth
def create_private_agent_join_token():
    user_id = str(request.supabase_user.get("id") or "")
    body = request.get_json(silent=True) or {}
    try:
        ttl_seconds = int(body.get("ttl_seconds") or body.get("expires_in_seconds") or 900)
    except (TypeError, ValueError):
        ttl_seconds = 900
    ttl_seconds = max(60, min(_PRIVATE_JOIN_TOKEN_MAX_AGE_SECONDS, ttl_seconds))
    jti = secrets.token_urlsafe(18)
    token = _private_join_token_serializer().dumps(
        {
            "uid": user_id,
            "jti": jti,
            "iat": int(time.time()),
            "scope": "private-agent-node-join",
        },
        salt=_PRIVATE_JOIN_TOKEN_SALT,
    )
    try:
        get_redis().setex(_private_join_token_key(jti), ttl_seconds, user_id)
    except Exception:
        return jsonify({"error": "无法创建私有节点加入令牌"}), 500
    backend_url = str(body.get("backend_url") or request.host_url.rstrip("/") or "").strip().rstrip("/")
    node_id = _safe_node_id(
        body.get("node_id") or f"private-agent-{int(time.time())}-{jti[:6]}"
    )
    name = str(body.get("name") or node_id).strip()[:128] or node_id
    capabilities = _safe_capabilities(body.get("capabilities"), limit=16)
    providers = _safe_list(body.get("provider_ids") or body.get("providers"), limit=8)
    agents = _safe_list(body.get("agent_ids") or body.get("agents"), limit=8)
    image_mode = str(
        body.get("image_mode")
        or body.get("deploy_image_mode")
        or body.get("deploy_mode")
        or "pull"
    ).strip().lower().replace("_", "-")
    if image_mode not in {"pull", "build", "none", "local"}:
        image_mode = "pull"
    provider_args = " ".join(f"--provider {shlex.quote(item)}" for item in providers)
    agent_args = " ".join(f"--agent {shlex.quote(item)}" for item in agents)
    capability_args = " ".join(
        "--capability "
        + shlex.quote(f"{item['provider_id']}:{item['agent_id']}:{item['adapter_kind']}")
        for item in capabilities
        if item.get("enabled", True)
    )
    image_args = ""
    if image_mode == "pull":
        image_args = " --pull"
    elif image_mode in {"build", "local"}:
        image_args = " --build"
    join_command = (
        f"MYAPP_PRIVATE_AGENT_JOIN_TOKEN={shlex.quote(token)} "
        f"myapp-ctl agent-node private join "
        f"--backend {shlex.quote(backend_url)} "
        f"--node-id {shlex.quote(node_id)} "
        f"--name {shlex.quote(name)} "
        f"{provider_args} {agent_args} {capability_args}{image_args}"
    )
    return jsonify({
        "ok": True,
        "join_token": token,
        "token_type": "private-agent-join",
        "expires_in_seconds": ttl_seconds,
        "image_mode": "build" if image_mode == "local" else image_mode,
        "name": name,
        "capabilities": capabilities,
        "join_command": join_command,
    })


def create_private_agent_node():
    user_id, _join_jti, error = _private_registration_identity()
    if error:
        body, status = error
        return jsonify(body), status
    if not user_id:
        return jsonify({"error": "无法确认私有节点归属用户"}), 401
    body = request.get_json(silent=True) or {}
    public_key = str(body.get("public_key") or body.get("auth_public_key") or "").strip()
    if "BEGIN PUBLIC KEY" not in public_key:
        return jsonify({"error": "public_key is required"}), 400
    node_id = _safe_node_id(body.get("node_id") or f"private-{user_id[:8]}-{int(time.time())}")
    name = str(body.get("name") or node_id).strip()[:80]
    try:
        capacity = max(1, min(20, int(body.get("capacity") or 1)))
    except (TypeError, ValueError):
        capacity = 1
    try:
        queue_max = max(0, min(200, int(body.get("queue_max") if body.get("queue_max") is not None else capacity)))
    except (TypeError, ValueError):
        queue_max = capacity
    provider_ids = _safe_list(body.get("provider_ids") or body.get("providers"))
    agent_ids = _safe_list(body.get("agent_ids") or body.get("agents")) or ["claude"]
    capabilities = _safe_capabilities(body.get("capabilities"))
    if capabilities:
        provider_ids = sorted({item["provider_id"] for item in capabilities})
        agent_ids = sorted({item["agent_id"] for item in capabilities})
    labels = _safe_list(body.get("labels"), limit=64)
    if not any(label.startswith("name=") for label in labels):
        labels.append(f"name={name}")
    labels.extend(["visibility=private", "provider_mode=local", "mode=pull"])
    auth_key_id = str(body.get("auth_key_id") or _public_key_id(public_key)).strip()[:128]
    existing = agent_node_registry.get_node(node_id)
    if existing and (existing.get("visibility") != "private" or existing.get("owner_user_id") != user_id):
        return jsonify({"error": "node_id is already used"}), 409
    row = agent_node_registry.upsert_node(
        node_id=node_id,
        name=name,
        url=f"pull://{node_id}",
        capacity=capacity,
        queue_max=queue_max,
        labels=labels,
        ttl_seconds=max(30, int(body.get("ttl_seconds") or 120)),
        owner_user_id=user_id,
        visibility="private",
        auth_public_key=public_key,
        auth_key_id=auth_key_id,
        provider_mode="local",
        provider_ids=provider_ids,
        agent_ids=agent_ids,
        capabilities=capabilities,
        touch_seen=False,
    )
    return jsonify({
        "ok": True,
        "owner_user_id": user_id,
        "node": _private_node_response(row, probe=False),
    })


def _private_node_for_user(node_id: str, user_id: str) -> dict | None:
    row = agent_node_registry.get_node(_safe_node_id(node_id))
    if not row or row.get("visibility") != "private" or row.get("owner_user_id") != user_id:
        return None
    return row


@auth.require_auth
def delete_private_agent_node(node_id: str):
    user_id = str(request.supabase_user.get("id") or "")
    row = _private_node_for_user(node_id, user_id)
    if not row:
        return jsonify({"error": "agent node not found"}), 404
    deleted = agent_node_registry.delete_node(_safe_node_id(node_id))
    try:
        get_redis().delete(_registry_key(node_id))
    except Exception:
        pass
    return jsonify({"ok": True, "node_id": _safe_node_id(node_id), "deleted": deleted})


@auth.require_auth
def pause_private_agent_node(node_id: str):
    user_id = str(request.supabase_user.get("id") or "")
    row = _private_node_for_user(node_id, user_id)
    if not row:
        return jsonify({"error": "agent node not found"}), 404
    body = request.get_json(silent=True) or {}
    data = agent_node_registry.set_node_paused(_safe_node_id(node_id), paused=True, reason=str(body.get("reason") or "").strip())
    return jsonify({"ok": True, "node": _private_node_response(data, probe=True)})


@auth.require_auth
def resume_private_agent_node(node_id: str):
    user_id = str(request.supabase_user.get("id") or "")
    row = _private_node_for_user(node_id, user_id)
    if not row:
        return jsonify({"error": "agent node not found"}), 404
    data = agent_node_registry.set_node_paused(_safe_node_id(node_id), paused=False)
    return jsonify({"ok": True, "node": _private_node_response(data, probe=True)})


@auth.require_auth
def set_private_agent_node_limits(node_id: str):
    user_id = str(request.supabase_user.get("id") or "")
    row = _private_node_for_user(node_id, user_id)
    if not row:
        return jsonify({"error": "agent node not found"}), 404
    body = request.get_json(silent=True) or {}
    try:
        capacity = max(1, min(20, int(body.get("capacity") or row.get("capacity") or 1)))
        queue_max = max(0, min(200, int(body.get("queue_max") if body.get("queue_max") is not None else row.get("queue_max") or capacity)))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid capacity or queue_max"}), 400
    agent_node_registry.upsert_node(
        node_id=row["node_id"],
        name=row.get("name") or row.get("display_name") or "",
        url=row["url"],
        capacity=capacity,
        queue_max=queue_max,
        labels=row.get("labels") or [],
        ttl_seconds=int(row.get("ttl_seconds") or 120),
        owner_user_id=user_id,
        visibility="private",
        provider_mode="local",
        touch_seen=False,
    )
    data = agent_node_registry.get_node(row["node_id"]) or row
    return jsonify({"ok": True, "node": _private_node_response(data, probe=True)})


def list_agent_nodes():
    if not _auth_ok():
        return jsonify({"error": "unauthorized"}), 401
    probe = request.args.get("probe", "1").lower() not in {"0", "false", "no"}
    namespace = str(request.args.get("namespace") or "public").strip()
    namespace_norm = namespace.lower()
    rows = []
    for item in agent_node_registry.list_nodes():
        visibility = str(item.get("visibility") or "public").strip().lower()
        owner_user_id = str(item.get("owner_user_id") or "")
        if namespace_norm in {"", "public", "global"}:
            if visibility != "public":
                continue
        elif namespace_norm in {"all", "*"}:
            pass
        else:
            if visibility != "private" or owner_user_id != namespace:
                continue
        rows.append(_decorate_node(_node_row(item.get("node_id"), item), probe=probe))
    rows.sort(key=lambda item: item.get("node_id", ""))
    public_queued = _agent_pull_queue_depth()
    private_queued_by_user: dict[str, int] = {}
    for row in rows:
        if row.get("visibility") == "private":
            owner = str(row.get("owner_user_id") or "")
            if owner not in private_queued_by_user:
                private_queued_by_user[owner] = _agent_pull_private_queue_depth(owner)
    for row in rows:
        if row.get("visibility") == "private":
            row.update(_with_queue_depth(row, private_queued_by_user.get(str(row.get("owner_user_id") or ""), 0)))
        else:
            row.update(_with_queue_depth(row, public_queued))
    if namespace_norm in {"", "public", "global"}:
        queued = public_queued
    elif namespace_norm in {"all", "*"}:
        queued = public_queued + sum(private_queued_by_user.values())
    else:
        queued = private_queued_by_user.get(namespace, 0)
    summary = {
        "namespace": namespace or "public",
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
