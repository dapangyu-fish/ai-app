#!/usr/bin/env python3
"""B2-G1 / R15: FaaS DB passwords must be RANDOM (never derived from user_id) and
stored ENCRYPTED at rest; the plaintext DSN column is no longer written; decryption
fails CLOSED. Closes 'one leaked global secret => every tenant's DB password'."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

_exec_log: list[tuple] = []
_database = types.ModuleType("database")
_database.db_execute = lambda sql, params=None: _exec_log.append((" ".join(str(sql).split()), list(params or [])))
_database.db_query = lambda *a, **k: None
sys.modules["database"] = _database

import faas_userdb as U  # noqa: E402

U.ENC_KEY = "unit-test-enc-key"  # ensure a key is present


class _FakeCursor:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def execute(self, sql, params=None): pass
    def fetchone(self): return None


class _FakeConn:
    def __init__(self): self.autocommit = True
    def cursor(self): return _FakeCursor()
    def commit(self): pass
    def rollback(self): pass
    def close(self): pass


def test_encrypt_decrypt_roundtrip():
    tok = U._encrypt("super-secret-pw")
    assert tok != "super-secret-pw" and tok
    assert U._decrypt(tok) == "super-secret-pw"


def test_decrypt_fails_closed():
    try:
        U._decrypt("not-a-valid-token")
    except U.UserDBError:
        return
    raise AssertionError("decrypt did NOT fail closed on garbage")


def test_password_is_random_not_derived_from_uid():
    p1 = U._resolve_password("user-1", None)
    p2 = U._resolve_password("user-1", None)
    assert p1 != p2, "password must be random per call when no stored cred (not uid-derived)"
    assert len(p1) >= 24


def test_password_reused_from_encrypted_store():
    enc = U._encrypt("stable-pw-xyz")
    got = U._resolve_password("user-1", {"pw_enc": enc})
    assert got == "stable-pw-xyz"


def test_legacy_plaintext_dsn_migrated():
    legacy = {"dsn": "postgresql://u_x:legacypw@172.18.0.1:5432/userdata", "pw_enc": ""}
    assert U._resolve_password("user-1", legacy) == "legacypw"


def test_provision_stores_encrypted_not_plaintext():
    _exec_log.clear()
    U.ensure_userdata_db = lambda: None
    U.ensure_tables = lambda: None
    U.get_user_db = lambda _u: None
    U._admin_conn = lambda _db: _FakeConn()
    res = U.provision_user_db("user-Z")
    # find the mapping upsert
    ins = [(s, p) for (s, p) in _exec_log if "insert into faas_user_databases" in s.lower()]
    assert ins, "no mapping upsert emitted"
    sql, params = ins[-1]
    assert "dsn, pw_enc" in sql and "VALUES (%s, %s, %s, %s, '', %s)" in sql, sql
    pw_enc = params[-1]
    # the runtime password (in the returned DSN) must NOT be stored in the clear
    from urllib.parse import urlsplit, unquote
    runtime_pw = unquote(urlsplit(res["dsn"]).password or "")
    assert runtime_pw and runtime_pw not in pw_enc, "plaintext password leaked into stored row"
    assert U._decrypt(pw_enc) == runtime_pw, "pw_enc must decrypt to the runtime password"


def test_dsn_for_user_reconstructs_from_encrypted():
    enc = U._encrypt("recon-pw")
    U.get_user_db = lambda _u: {"role_name": "u_abc", "pw_enc": enc, "dsn": ""}
    dsn = U.dsn_for_user("user-1", provision=False)
    assert "recon-pw" in dsn and "u_abc" in dsn, dsn


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
