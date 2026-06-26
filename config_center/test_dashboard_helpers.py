"""Bare-python unit tests for dashboard_helpers (run: python3 test_dashboard_helpers.py).

No pytest/flask/network needed — pure-function coverage for the dashboard glue.
"""
import sys

from dashboard_helpers import (
    shape_user,
    shape_users_page,
    faas_is_running,
    compute_faas_view,
    compute_faas_overview,
    shape_agents,
)

_failures: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"  ok  {name}")
    else:
        _failures.append(name)
        print(f"FAIL  {name}")


# ── users ──
u_admin = {
    "id": "u1", "email": "a@x.com", "created_at": "2026-01-01T00:00:00Z",
    "email_confirmed_at": "2026-01-02T00:00:00Z",
    "user_metadata": {"username": "alice"},
    "app_metadata": {"role": "admin", "quota_limit_override": "50"},
    "banned_until": None,
}
s = shape_user(u_admin)
check("user role surfaced", s["role"] == "admin")
check("user username from user_metadata", s["username"] == "alice")
check("user quota coerced to int", s["quota_override"] == 50)
check("user email_confirmed true", s["email_confirmed"] is True)
check("user not banned when banned_until null", s["banned"] is False)

u_banned = {"id": "u2", "email": "b@x.com", "banned_until": "2125-01-01T00:00:00Z",
            "app_metadata": {}, "user_metadata": {}}
sb = shape_user(u_banned)
check("user banned when far-future banned_until", sb["banned"] is True)
check("default role is user", sb["role"] == "user")
check("quota None when absent", sb["quota_override"] is None)

page = shape_users_page({"users": [u_admin, u_banned, "junk"]})
check("users page count ignores junk", page["count"] == 2)
check("users page empty-safe", shape_users_page({})["count"] == 0)

# ── faas running heuristic ──
check("faas active is running", faas_is_running("active") is True)
check("faas disabled not running", faas_is_running("disabled") is False)
check("faas empty not running", faas_is_running("") is False)
check("faas unknown treated up", faas_is_running("weird") is True)

# ── faas view: the 4 required metrics ──
svc = {
    "service_id": "svc-1", "service_slug": "shop", "function_name": "fn-shop",
    "owner_user_id": "u1", "status": "active",
    "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-06-01T00:00:00Z",
    "routes": [{"path": "/a"}, {"path": "/b"}], "public_base_url": "https://x/shop",
    "meta_json": {"deploy": {"mode": "local-docker"}},
}
v = compute_faas_view(svc, deploy_mode="local-docker", cap_min=0, cap_max=1)
check("faas 启动时间 = updated_at", v["deployed_at"] == "2026-06-01T00:00:00Z")
check("faas created_at kept", v["created_at"] == "2026-01-01T00:00:00Z")
check("faas 实例数量 = 1 when active", v["instances"] == 1)
check("faas 当前容量 = 1 when active", v["current_capacity"] == 1)
check("faas 容量范围 min", v["capacity_min"] == 0)
check("faas 容量范围 max", v["capacity_max"] == 1)
check("faas routes_count", v["routes_count"] == 2)
check("faas deploy_mode from meta", v["deploy_mode"] == "local-docker")

svc_off = dict(svc, service_id="svc-2", status="disabled")
v2 = compute_faas_view(svc_off)
check("faas disabled → 0 instances", v2["instances"] == 0)
check("faas disabled → 0 current", v2["current_capacity"] == 0)

# per-service scale override from bundle meta
svc_scaled = dict(svc, service_id="svc-3",
                  meta_json={"deploy": {"mode": "local-docker", "scale_min": 1, "scale_max": 5}})
v3 = compute_faas_view(svc_scaled)
check("faas per-service capacity override min", v3["capacity_min"] == 1)
check("faas per-service capacity override max", v3["capacity_max"] == 5)

# real running_replicas from backend overrides status-derived instances
# (the bug: a ready-but-scaled-to-zero service must show 0, matching `faas ls`).
svc_zero = dict(svc, service_id="svc-z", status="active", running_replicas=0)
vz = compute_faas_view(svc_zero)
check("faas scaled-to-zero → 0 instances (not status-derived 1)", vz["instances"] == 0)
check("faas scaled-to-zero → 0 current_capacity", vz["current_capacity"] == 0)

svc_multi = dict(svc, service_id="svc-m", status="active", running_replicas=3)
vm = compute_faas_view(svc_multi)
check("faas real running_replicas → instances=3", vm["instances"] == 3)
check("faas real running_replicas → current_capacity=3", vm["current_capacity"] == 3)

ov = compute_faas_overview([v, v2, v3])
check("faas overview total", ov["total"] == 3)
check("faas overview running", ov["running"] == 2)
check("faas overview stopped", ov["stopped"] == 1)

ov2 = compute_faas_overview([vz, vm])
check("faas overview total_instances = sum real", ov2["total_instances"] == 3)

# ── agents ──
ag = shape_agents({"summary": {"total": 2, "online": 1}, "nodes": [{"node_id": "n1"}, {"node_id": "n2"}]})
check("agents summary passthrough", ag["summary"]["online"] == 1)
check("agents nodes passthrough", len(ag["nodes"]) == 2)
ag2 = shape_agents({"nodes": [{"status": "online"}, {"status": "down"}]})
check("agents summary derived when missing", ag2["summary"]["online"] == 1)
check("agents empty-safe", shape_agents(None)["nodes"] == [])

print()
if _failures:
    print(f"{len(_failures)} FAILED: {_failures}")
    sys.exit(1)
print("ALL DASHBOARD-HELPER TESTS PASSED")
