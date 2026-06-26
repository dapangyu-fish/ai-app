"""Scoped per-user Postgres helper for generated FaaS code (`import myapp_db`).

Baked into the faas-runtime image as ``myapp_db``. The platform injects
``MYAPP_DB_DSN`` — a least-privilege role whose ``search_path`` and
``statement_timeout`` are pinned (at the role level) to the user's OWN schema in
the dedicated ``userdata`` database. Generated ``app.py`` imports this module and
calls ``query`` / ``queryone`` / ``execute`` / ``tx``; it never sees the raw DSN
(it cannot read env — ``os`` is not importable in validated app code), and the
role cannot reach any other schema or the platform database.

API:
    myapp_db.query(sql, params=None)    -> list[dict]
    myapp_db.queryone(sql, params=None) -> dict | None
    myapp_db.execute(sql, params=None)  -> int   (rowcount)
    with myapp_db.tx() as cur: ...                (multi-statement transaction)
    myapp_db.enabled()                  -> bool
Always pass values as ``params`` (%s placeholders), never string-format SQL.
"""
from __future__ import annotations

import os
import threading

import psycopg2
from psycopg2.extras import RealDictCursor

_DSN = os.environ.get("MYAPP_DB_DSN", "").strip()
_local = threading.local()


class DBNotConfigured(RuntimeError):
    pass


def enabled() -> bool:
    return bool(_DSN)


def _conn():
    if not _DSN:
        raise DBNotConfigured(
            "this service has no database. Ship a schema.sql (or set service.db=true) so the "
            "platform provisions your schema, then redeploy."
        )
    conn = getattr(_local, "conn", None)
    if conn is not None and conn.closed == 0:
        return conn
    conn = psycopg2.connect(_DSN, connect_timeout=5)
    conn.autocommit = True
    _local.conn = conn
    return conn


def query(sql: str, params=None) -> list[dict]:
    with _conn().cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(sql, params or ())
        if cur.description is None:
            return []
        return [dict(row) for row in cur.fetchall()]


def queryone(sql: str, params=None):
    rows = query(sql, params)
    return rows[0] if rows else None


def execute(sql: str, params=None) -> int:
    with _conn().cursor() as cur:
        cur.execute(sql, params or ())
        return cur.rowcount


class _Tx:
    def __enter__(self):
        self._conn = _conn()
        self._conn.autocommit = False
        self._cur = self._conn.cursor(cursor_factory=RealDictCursor)
        return self._cur

    def __exit__(self, exc_type, exc, tb):
        try:
            if exc_type is None:
                self._conn.commit()
            else:
                self._conn.rollback()
        finally:
            self._cur.close()
            self._conn.autocommit = True
        return False


def tx() -> _Tx:
    """Transaction context manager: ``with myapp_db.tx() as cur: cur.execute(...)``."""
    return _Tx()
