"""Pure, dependency-free helpers for the unified admin dashboard.

Kept free of Flask / network / env so they can be unit-tested with bare
``python3 config_center/test_dashboard_helpers.py``. The HTTP/proxy wiring lives
in app.py; this module only shapes/derives data the dashboard renders.
"""
from __future__ import annotations

from typing import Any


# ───────────────────────── users (Supabase GoTrue rows) ─────────────────────────

def shape_user(u: dict[str, Any]) -> dict[str, Any]:
    """Reduce a raw Supabase GoTrue admin user object to the fields the UI needs."""
    app_meta = u.get("app_metadata") or {}
    user_meta = u.get("user_metadata") or {}
    banned_until = u.get("banned_until")
    banned = bool(banned_until) and str(banned_until).lower() != "none"
    quota = app_meta.get("quota_limit_override")
    try:
        quota = int(quota) if quota not in (None, "") else None
    except (TypeError, ValueError):
        quota = None
    return {
        "id": u.get("id"),
        "email": u.get("email"),
        "username": user_meta.get("username"),
        "role": app_meta.get("role") or "user",
        "quota_override": quota,
        "banned": banned,
        "banned_until": banned_until if banned else None,
        "email_confirmed": bool(u.get("email_confirmed_at")),
        "created_at": u.get("created_at"),
        "last_sign_in_at": u.get("last_sign_in_at"),
    }


def shape_users_page(payload: dict[str, Any]) -> dict[str, Any]:
    users = payload.get("users") if isinstance(payload, dict) else None
    rows = [shape_user(u) for u in (users or []) if isinstance(u, dict)]
    return {"users": rows, "count": len(rows)}


# ───────────────────────── faas (4 required metrics) ─────────────────────────

# status values that mean "the function is up / serving"
_FAAS_RUNNING = {"active", "running", "ready", "deployed", "ok", "healthy"}
_FAAS_DOWN = {"disabled", "deleted", "failed", "error", "stopped", "removed", ""}


def faas_is_running(status: Any) -> bool:
    s = str(status or "").strip().lower()
    if s in _FAAS_DOWN:
        return False
    if s in _FAAS_RUNNING:
        return True
    # unknown but non-empty, non-down status → treat as up (UI still shows raw status)
    return True


def compute_faas_view(
    service: dict[str, Any],
    deploy_mode: str = "local-docker",
    cap_min: int = 0,
    cap_max: int = 1,
) -> dict[str, Any]:
    """Derive the 4 required metrics from an existing /api/faas/services row.

    On host-77 (local-docker, no OpenFaaS autoscaler) replicas/current-capacity are
    status-derived (0/1) and capacity range is the configured min..max (default 0..1).
    启动时间 uses updated_at (last deploy) with created_at as first-created.
    """
    meta = service.get("meta_json") or {}
    if isinstance(meta, str):
        meta = {}
    deploy_meta = (meta.get("deploy") or {}) if isinstance(meta, dict) else {}
    routes = service.get("routes") or []
    if not isinstance(routes, list):
        routes = []
    running = faas_is_running(service.get("status"))
    # per-service override of capacity range if the bundle declared it
    try:
        smin = int(deploy_meta.get("scale_min", cap_min))
        smax = int(deploy_meta.get("scale_max", cap_max))
    except (TypeError, ValueError):
        smin, smax = cap_min, cap_max
    replicas = 1 if running else 0
    return {
        "service_id": service.get("service_id"),
        "name": service.get("service_slug") or service.get("function_name"),
        "function_name": service.get("function_name"),
        "owner_user_id": service.get("owner_user_id"),
        "status": service.get("status"),
        "running": running,
        "deploy_mode": deploy_meta.get("mode") or deploy_mode,
        "node_id": deploy_meta.get("node_id"),
        "public_base_url": service.get("public_base_url"),
        "routes_count": len(routes),
        "active_commit": service.get("active_commit"),
        "created_at": service.get("created_at"),       # first created
        "deployed_at": service.get("updated_at"),      # 启动/部署时间 (last deploy)
        "instances": replicas,                          # 实例数量
        "current_capacity": replicas,                   # 当前容量
        "capacity_min": smin,                           # 服务容量范围 (下限)
        "capacity_max": smax,                           # 服务容量范围 (上限)
    }


def compute_faas_overview(views: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(views)
    running = sum(1 for v in views if v.get("running"))
    instances = sum(int(v.get("instances") or 0) for v in views)
    return {
        "total": total,
        "running": running,
        "stopped": total - running,
        "total_instances": instances,
    }


# ───────────────────────── agents (backend aggregate passthrough) ─────────────────────────

def shape_agents(payload: dict[str, Any]) -> dict[str, Any]:
    """Normalize the backend /api/ai/agent_nodes {summary, nodes} envelope."""
    if not isinstance(payload, dict):
        return {"summary": {}, "nodes": []}
    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        nodes = []
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        # derive a minimal summary if the backend didn't supply one
        online = sum(1 for n in nodes if str(n.get("status", "")).lower() == "online")
        summary = {"total": len(nodes), "online": online}
    return {"summary": summary, "nodes": nodes}
