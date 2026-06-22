#!/usr/bin/env python3
"""B3-G1: backend-mediated data layer forces owner-scoping. The CRUD executor must
ALWAYS constrain rows to the caller pseudonym (owner=%s on every find/update/delete;
owner forced on insert; owner cannot be reassigned), and reject unsafe identifiers —
so owner (function) code cannot read/write another consumer's rows."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# ── fake psycopg2 capturing executed SQL ──
_LAST = {}


class _Cur:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def execute(self, sql, params=None):
        _LAST["sql"] = " ".join(str(sql).split())
        _LAST["params"] = list(params or [])
    def fetchall(self): return [{"id": "r1", "owner": "c_me", "v": 1}]
    def fetchone(self): return {"id": "r1", "owner": "c_me"}
    @property
    def rowcount(self): return 1


class _Conn:
    def __init__(self): self.autocommit = False
    def cursor(self, cursor_factory=None): return _Cur()
    def close(self): pass


_pg = types.ModuleType("psycopg2")
_pg.connect = lambda dsn, connect_timeout=5: _Conn()
_extras = types.ModuleType("psycopg2.extras")
_extras.RealDictCursor = object
_pg.extras = _extras
sys.modules["psycopg2"] = _pg
sys.modules["psycopg2.extras"] = _extras

import faas_data  # noqa: E402

DSN = "postgresql://u_x:pw@h:5432/userdata"
OWNER = "c_me"


def test_find_is_owner_scoped():
    faas_data.run_data_op(DSN, OWNER, "find", "notes", where={"pinned": True}, limit=10)
    assert _LAST["sql"].startswith('SELECT * FROM "notes" WHERE owner = %s'), _LAST["sql"]
    assert '"pinned" = %s' in _LAST["sql"]
    assert _LAST["params"][0] == OWNER and True in _LAST["params"]


def test_insert_forces_owner():
    faas_data.run_data_op(DSN, OWNER, "insert", "notes", values={"text": "hi", "owner": "c_ATTACKER"})
    assert _LAST["sql"].startswith('INSERT INTO "notes"')
    # owner forced to the caller, NOT the attacker-supplied value
    assert OWNER in _LAST["params"] and "c_ATTACKER" not in _LAST["params"]


def test_update_is_owner_scoped_and_cannot_reassign_owner():
    faas_data.run_data_op(DSN, OWNER, "update", "notes", where={"id": "r1"},
                          values={"text": "x", "owner": "c_ATTACKER"})
    assert "WHERE owner = %s" in _LAST["sql"]
    # owner not in the SET clause (can't reassign ownership)
    assert '"owner" = %s' not in _LAST["sql"].split("WHERE")[0]
    assert "c_ATTACKER" not in _LAST["params"]
    assert OWNER in _LAST["params"]


def test_delete_is_owner_scoped():
    faas_data.run_data_op(DSN, OWNER, "delete", "notes", where={"id": "r1"})
    assert _LAST["sql"].startswith('DELETE FROM "notes" WHERE owner = %s')
    assert _LAST["params"][0] == OWNER


def test_rejects_unsafe_identifiers():
    for bad in ["notes; DROP TABLE x", "Notes", "1tbl", "a b"]:
        try:
            faas_data.run_data_op(DSN, OWNER, "find", bad)
            raise AssertionError(f"unsafe table accepted: {bad}")
        except faas_data.DataOpError:
            pass
    # bad column name in where
    try:
        faas_data.run_data_op(DSN, OWNER, "find", "notes", where={"bad col": 1})
        raise AssertionError("unsafe column accepted")
    except faas_data.DataOpError:
        pass


def test_requires_owner_and_dsn():
    for kw in ({"dsn": ""}, {"owner": ""}):
        try:
            faas_data.run_data_op(kw.get("dsn", DSN), kw.get("owner", OWNER), "find", "notes")
            raise AssertionError(f"missing {kw} accepted")
        except faas_data.DataOpError:
            pass


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
