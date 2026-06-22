#!/usr/bin/env python3
"""B1-G3 / R6: the runtime DB role must be NON-OWNING. Provisioning must create a
NOLOGIN owner role that owns the schema+tables, transfer existing ownership
(ALTER SCHEMA OWNER + REASSIGN OWNED), REVOKE CREATE from the runtime role, grant
it only DML, and set default privileges; migrations must run AS the owner role.
This test captures the emitted SQL (no real Postgres) and asserts those invariants
so a runtime connection cannot ALTER/DROP/TRUNCATE/DISABLE-RLS."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# db_execute (mapping upsert) stub
_database = types.ModuleType("database")
_database.db_execute = lambda *a, **k: None
_database.db_query = lambda *a, **k: None
sys.modules["database"] = _database

import faas_userdb as U  # noqa: E402


class _FakeCursor:
    def __init__(self, log):
        self.log = log

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=None):
        self.log.append(" ".join(str(sql).split()))

    def fetchone(self):
        return None  # role/​schema "does not exist" → exercise the create paths


class _FakeConn:
    def __init__(self, log):
        self.log = log
        self.autocommit = True

    def cursor(self):
        return _FakeCursor(self.log)

    def commit(self):
        pass

    def rollback(self):
        pass

    def close(self):
        pass


def _capture_provision(uid="user-X"):
    log: list[str] = []
    U.ensure_userdata_db = lambda: None
    U.ensure_tables = lambda: None
    U.get_user_db = lambda _u: None
    U._admin_conn = lambda _db: _FakeConn(log)
    U.provision_user_db(uid)
    return " | ".join(log), uid


def test_owner_role_created_nologin():
    sql, uid = _capture_provision()
    o = U.owner_role_name(uid)
    assert f'CREATE ROLE "{o}" NOLOGIN' in sql, sql


def test_schema_owned_by_owner_and_reassigned():
    sql, uid = _capture_provision()
    o, r, s = U.owner_role_name(uid), U.role_name(uid), U.schema_name(uid)
    assert f'CREATE SCHEMA IF NOT EXISTS "{s}" AUTHORIZATION "{o}"' in sql, sql
    assert f'ALTER SCHEMA "{s}" OWNER TO "{o}"' in sql, sql
    assert f'REASSIGN OWNED BY "{r}" TO "{o}"' in sql, sql


def test_runtime_role_loses_create_gets_only_dml():
    sql, uid = _capture_provision()
    r, s = U.role_name(uid), U.schema_name(uid)
    assert f'REVOKE CREATE ON SCHEMA "{s}" FROM "{r}"' in sql, sql
    assert f'GRANT USAGE ON SCHEMA "{s}" TO "{r}"' in sql, sql
    assert f'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "{s}" TO "{r}"' in sql, sql
    # must NOT grant CREATE on the schema to the runtime role
    assert f'GRANT USAGE, CREATE ON SCHEMA "{s}" TO "{r}"' not in sql, sql


def test_default_privileges_for_owner_grant_dml_to_runtime():
    sql, uid = _capture_provision()
    o, r, s = U.owner_role_name(uid), U.role_name(uid), U.schema_name(uid)
    assert (f'ALTER DEFAULT PRIVILEGES FOR ROLE "{o}" IN SCHEMA "{s}" '
            f'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{r}"') in sql, sql


def test_migration_runs_as_owner_role():
    log: list[str] = []
    U.ensure_userdata_db = lambda: None
    U.ensure_tables = lambda: None
    U.get_user_db = lambda _u: None
    U._admin_conn = lambda _db: _FakeConn(log)
    uid = "user-Y"
    U.run_user_migration(uid, "CREATE TABLE t (id uuid primary key);")
    joined = " | ".join(log)
    o = U.owner_role_name(uid)
    assert f'SET ROLE "{o}"' in joined, joined
    # must NOT set role to the runtime login role for DDL
    assert f'SET ROLE "{U.role_name(uid)}"' not in joined, joined


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
