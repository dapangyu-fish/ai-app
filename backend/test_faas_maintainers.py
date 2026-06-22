#!/usr/bin/env python3
"""X-G1 + B2-G4: app maintainers (deploy/scale, not own) + actor/owner split.
add/remove are owner-only; can_manage_service grants the owner OR a maintainer of
the service's app; resource ownership is never the acting user."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _n, _v in {
    "FAAS_BUNDLE_MAX_BYTES": 1, "FAAS_BUNDLE_SERVE_ROOT": "", "FAAS_CODE_ROOT": "/tmp/x",
    "FAAS_DEPLOY_MODE": "metadata", "FAAS_DEPLOY_SCRIPT": "", "FAAS_ENABLED": True,
    "FAAS_FILE_MAX_BYTES": 1, "FAAS_FUNCTION_PREFIX": "myapp", "FAAS_GIT_AUTHOR_EMAIL": "x@l",
    "FAAS_GIT_AUTHOR_NAME": "x", "FAAS_GIT_BRANCH": "main", "FAAS_GIT_ENABLED": False,
    "FAAS_GIT_PUSH_ENABLED": False, "FAAS_GIT_REMOTE": "", "FAAS_GIT_SSH_KEY_PATH": "",
    "FAAS_GIT_KNOWN_HOSTS_PATH": "", "FAAS_GIT_ASYNC_PUSH": False, "FAAS_INJECT_SUPABASE_ANON_KEY": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/x", "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/x",
    "FAAS_LOCAL_DOCKER_IMAGE": "img", "FAAS_LOCAL_DOCKER_NETWORK": "n",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False, "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 1,
    "FAAS_MAX_SERVICES_PER_USER": 5, "FAAS_NODE_PUBLIC_URL": "", "FAAS_PUBLIC_BASE_URL": "",
    "FAAS_REQUIREMENTS_MAX_LINES": 1, "FAAS_RUNTIME_BUNDLE_BASE_URL": "", "FAAS_RUNTIME_TOKEN": "",
    "SUPABASE_URL": "https://s", "SUPABASE_ANON_KEY": "k",
}.items():
    setattr(_config, _n, _v)
sys.modules["config"] = _config


class _DB:
    def __init__(self):
        self.apps = {}
        self.maint = {}  # (app_id,user_id) -> row
        self.grants = {}  # (app_id,user_id) -> revoked(bool)

    def execute(self, sql, params=None):
        params = list(params or [])
        n = " ".join(sql.lower().split())
        if n.startswith(("create ", "alter ")):
            return None
        if "insert into faas_applications" in n and len(params) >= 5:
            a, o, appid, name, pol = params[:5]
            self.apps.setdefault(a, {"app_id": a, "owner_user_id": o, "appid": appid,
                                     "name": name, "access_policy": pol})
            return None
        if "insert into faas_app_maintainers" in n:
            app_id, user_id, added_by = params[:3]
            self.maint[(app_id, user_id)] = {"app_id": app_id, "user_id": user_id,
                                             "added_by": added_by, "created_at": "c"}
            return None
        if n.startswith("delete from faas_app_maintainers"):
            app_id, user_id = params
            self.maint.pop((app_id, user_id), None)
            return None
        if "insert into faas_app_consumer_grants" in n:
            app_id, user_id = params[0], params[1]
            self.grants[(app_id, user_id)] = False  # not revoked
            return None
        if n.startswith("update faas_app_consumer_grants set revoked_at"):
            app_id, user_id = params
            if (app_id, user_id) in self.grants:
                self.grants[(app_id, user_id)] = True  # revoked
            return None
        return None

    def query(self, sql, params=None, fetch_one=False, fetch_all=False):
        params = list(params or [])
        n = " ".join(sql.lower().split())
        if "from faas_applications where app_id = %s" in n:
            r = self.apps.get(params[0]); return dict(r) if r else None
        if "from faas_app_maintainers where app_id = %s and user_id = %s" in n:
            return {"ok": 1} if (params[0], params[1]) in self.maint else None
        if "from faas_app_maintainers where app_id = %s" in n:
            return [dict(v) for (a, u), v in self.maint.items() if a == params[0]]
        if "from faas_app_consumer_grants where app_id = %s and user_id = %s and revoked_at is null" in n:
            k = (params[0], params[1])
            return {"ok": 1} if (k in self.grants and not self.grants[k]) else None
        return [] if fetch_all else None


_db = _DB()
_database = types.ModuleType("database")
_database.db_execute = _db.execute
_database.db_query = _db.query
sys.modules["database"] = _database

import faas_store as F  # noqa: E402
from faas_store import FaaSValidationError  # noqa: E402


def setup_app():
    F.ensure_application("appM", "owner1", name="svc")


def test_add_maintainer_owner_only():
    setup_app()
    try:
        F.add_maintainer("intruder", "appM", "mUser")
        raise AssertionError("non-owner added a maintainer")
    except FaaSValidationError:
        pass
    F.add_maintainer("owner1", "appM", "mUser")
    assert F.is_maintainer("appM", "mUser")


def test_cannot_add_owner_as_maintainer():
    setup_app()
    try:
        F.add_maintainer("owner1", "appM", "owner1")
    except FaaSValidationError:
        return
    raise AssertionError("owner was added as maintainer")


def test_remove_maintainer_owner_only_and_works():
    setup_app()
    F.add_maintainer("owner1", "appM", "mUser2")
    assert F.is_maintainer("appM", "mUser2")
    try:
        F.remove_maintainer("intruder", "appM", "mUser2")
        raise AssertionError("non-owner removed a maintainer")
    except FaaSValidationError:
        pass
    F.remove_maintainer("owner1", "appM", "mUser2")
    assert not F.is_maintainer("appM", "mUser2")


def test_can_manage_service_owner_maintainer_stranger():
    setup_app()
    F.add_maintainer("owner1", "appM", "mUser3")
    svc = {"owner_user_id": "owner1", "app_id": "appM"}
    assert F.can_manage_service("owner1", svc) is True       # owner
    assert F.can_manage_service("mUser3", svc) is True       # maintainer
    assert F.can_manage_service("stranger", svc) is False    # neither
    assert F.can_manage_service("", svc) is False


def test_consumer_grant_revoke_live():
    setup_app()
    # owner-only enforcement on grant
    try:
        F.grant_consumer("intruder", "appM", "cUser")
        raise AssertionError("non-owner granted access")
    except FaaSValidationError:
        pass
    assert not F.is_consumer_granted("appM", "cUser")
    F.grant_consumer("owner1", "appM", "cUser")
    assert F.is_consumer_granted("appM", "cUser") is True
    # revoke takes effect immediately (live check)
    F.revoke_consumer("owner1", "appM", "cUser")
    assert F.is_consumer_granted("appM", "cUser") is False


def test_maintainer_can_grant():
    setup_app()
    F.add_maintainer("owner1", "appM", "mGrant")
    F.grant_consumer("mGrant", "appM", "cUser2")  # maintainer may grant
    assert F.is_consumer_granted("appM", "cUser2")


def test_db_tenant_key_per_app():
    # B2-G3: default per-owner app reuses the owner's existing schema (no migration)
    assert F._db_tenant_key("appd-owner1", "owner1") == "owner1"
    # a custom app gets its OWN tenant key (separate schema from the owner default)
    assert F._db_tenant_key("myapp2", "owner1") == "myapp2"
    assert F._db_tenant_key("myapp2", "owner1") != F._db_tenant_key("appd-owner1", "owner1")
    # empty app falls back to owner
    assert F._db_tenant_key("", "owner1") == "owner1"


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
