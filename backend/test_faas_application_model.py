#!/usr/bin/env python3
"""B1-G1: Application entity is the governance unit. Tests: deploy/ensure binds a
service to a (default per-owner) application; access_policy defaults to the
most-closed 'owner-only' (D3 ladder); ownership is enforced (no cross-owner
claim / policy change); the policy ladder validates its values."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024, "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-app-model", "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_SCRIPT": "", "FAAS_ENABLED": True, "FAAS_FILE_MAX_BYTES": 256 * 1024,
    "FAAS_FUNCTION_PREFIX": "myapp", "FAAS_GIT_AUTHOR_EMAIL": "x@localhost",
    "FAAS_GIT_AUTHOR_NAME": "x", "FAAS_GIT_BRANCH": "main", "FAAS_GIT_ENABLED": False,
    "FAAS_GIT_PUSH_ENABLED": False, "FAAS_GIT_REMOTE": "", "FAAS_GIT_SSH_KEY_PATH": "",
    "FAAS_GIT_KNOWN_HOSTS_PATH": "", "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_INJECT_SUPABASE_ANON_KEY": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default", "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False,
    "FAAS_HARDEN_CONTAINERS": True, "FAAS_LOCAL_DOCKER_MEM_LIMIT": "512m", "FAAS_LOCAL_DOCKER_PIDS_LIMIT": 256,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15, "FAAS_MAX_SERVICES_PER_USER": 5,
    "FAAS_NODE_PUBLIC_URL": "https://faas.example", "FAAS_PUBLIC_BASE_URL": "https://backend.example",
    "FAAS_REQUIREMENTS_MAX_LINES": 40, "FAAS_RUNTIME_BUNDLE_BASE_URL": "https://backend.example",
    "FAAS_RUNTIME_TOKEN": "rt", "SUPABASE_URL": "https://supabase.example", "SUPABASE_ANON_KEY": "k",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config


class _DB:
    def __init__(self):
        self.apps: dict[str, dict] = {}

    def execute(self, sql, params=None):
        params = list(params or [])
        n = " ".join(sql.lower().split())
        if n.startswith(("create ", "alter ")):
            return None
        if "insert into faas_applications" in n:
            if len(params) >= 5:
                a, o, appid, name, pol = params[:5]
                self.apps.setdefault(a, {"app_id": a, "owner_user_id": o, "appid": appid,
                                         "name": name, "access_policy": pol,
                                         "created_at": "c", "updated_at": "u"})
            return None
        if n.startswith("update faas_services set app_id"):
            return None
        if n.startswith("update faas_applications set access_policy"):
            if len(params) >= 2:
                pol, a = params[:2]
                if a in self.apps:
                    self.apps[a]["access_policy"] = pol
            else:
                # 服务组：param-less install-required→allowlist relabel migration
                for app in self.apps.values():
                    if app.get("access_policy") == "install-required":
                        app["access_policy"] = "allowlist"
            return None
        return None  # other ensure_tables DDL / backfill: no-op

    def query(self, sql, params=None, fetch_one=False, fetch_all=False):
        params = list(params or [])
        n = " ".join(sql.lower().split())
        if "from faas_applications where app_id = %s" in n:
            r = self.apps.get(params[0])
            return dict(r) if r else None
        if "from faas_applications where owner_user_id = %s" in n:
            return [dict(r) for r in self.apps.values() if r["owner_user_id"] == params[0]]
        return [] if fetch_all else None


_db = _DB()
_database = types.ModuleType("database")
_database.db_execute = _db.execute
_database.db_query = _db.query
sys.modules["database"] = _database

import faas_store  # noqa: E402
from faas_store import FaaSValidationError  # noqa: E402


def test_default_app_id_is_per_owner():
    assert faas_store._default_app_id("user-A") == "appd-user-A"


def test_resolve_app_id_new_service_is_own_group():
    # 服务组：新服务的 app_id 默认 = service_id（不再落 per-owner 默认组）
    assert faas_store._resolve_app_id("ownerX", "svc-new", {}) == ("svc-new", "")
    # 显式 meta.app_id 仍被尊重（高级/共享场景）
    assert faas_store._resolve_app_id("ownerX", "svc-new", {"app_id": "grp-1"}) == ("grp-1", "")


def test_resolve_app_id_rejects_reserved_appd_prefix():
    # SECURITY: a caller-supplied service_id / meta.app_id in the reserved 'appd-'
    # namespace would alias another tenant's shared schema → must be rejected.
    for sid, meta in [("appd-victim", {}), ("svc-x", {"app_id": "appd-victim"})]:
        try:
            faas_store._resolve_app_id("attacker", sid, meta)
            raise AssertionError(f"reserved 'appd-' prefix was NOT rejected: sid={sid} meta={meta}")
        except FaaSValidationError:
            pass


def test_ensure_application_defaults_owner_only():
    app = faas_store.ensure_application("appd-u1", "u1", name="svc1")
    assert app["access_policy"] == "owner-only", app
    assert app["owner_user_id"] == "u1"
    # idempotent
    again = faas_store.ensure_application("appd-u1", "u1")
    assert again["app_id"] == "appd-u1"


def test_cross_owner_claim_denied():
    faas_store.ensure_application("appd-shared", "owner1")
    try:
        faas_store.ensure_application("appd-shared", "owner2")
    except FaaSValidationError:
        return
    raise AssertionError("cross-owner app claim was NOT denied")


def test_invalid_policy_rejected():
    try:
        faas_store.ensure_application("appd-bad", "u9", access_policy="everyone")
    except FaaSValidationError:
        return
    raise AssertionError("invalid access_policy was NOT rejected")


def test_set_policy_enforces_ownership_and_ladder():
    faas_store.ensure_application("appd-u2", "u2")
    # wrong owner cannot change policy
    try:
        faas_store.set_application_policy("intruder", "appd-u2", "public")
        raise AssertionError("non-owner changed policy")
    except FaaSValidationError:
        pass
    # owner can move up the ladder
    updated = faas_store.set_application_policy("u2", "appd-u2", "allowlist")
    assert updated["access_policy"] == "allowlist"
    # invalid ladder value rejected
    try:
        faas_store.set_application_policy("u2", "appd-u2", "nope")
        raise AssertionError("invalid policy accepted")
    except FaaSValidationError:
        pass


def test_b3g2_serial_pk_rejected_uuid_ok():
    # B3-G2 (IDOR): SERIAL primary keys rejected; UUID accepted.
    for bad in ["CREATE TABLE t (id SERIAL PRIMARY KEY);",
                "create table t (id bigserial primary key, v text);"]:
        try:
            faas_store._lint_schema_sql(bad)
            raise AssertionError(f"SERIAL not rejected: {bad}")
        except FaaSValidationError:
            pass
    # UUID schema passes
    faas_store._lint_schema_sql("CREATE TABLE t (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), v text);")
    faas_store._lint_schema_sql("")  # empty ok


def test_b3g6_privacy_notice_present():
    assert faas_store.privacy_notice().strip()  # non-empty disclosure


def test_list_user_applications():
    faas_store.ensure_application("appd-list1", "lister")
    faas_store.ensure_application("appd-list2", "lister")
    apps = faas_store.list_user_applications("lister")
    ids = {a["app_id"] for a in apps}
    assert {"appd-list1", "appd-list2"} <= ids, ids


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
