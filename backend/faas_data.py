#!/usr/bin/env python3
"""B3-G1: backend-mediated data-access executor for the FaaS platform.

Runs owner-scoped CRUD against a tenant's per-app schema on behalf of a function.
The function NEVER holds the DB DSN; it calls the backend gateway with a
non-forgeable data-token and this module:
  - validates identifiers (table/column names) to prevent SQL injection,
  - FORCES `owner = <caller_pseudonym>` on every row (the function cannot read or
    write another consumer's rows — the pseudonym comes from the signed token, not
    from function-controlled input),
  - parametrizes all values.

Tables addressed through this layer MUST have a text ``owner`` column.
"""
from __future__ import annotations

import datetime
import decimal
import re
import uuid
from typing import Any

_IDENT_RE = re.compile(r"^[a-z_][a-z0-9_]*$")
_MAX_LIMIT = 500


class DataOpError(RuntimeError):
    pass


def _ident(name: str) -> str:
    n = str(name or "")
    if not _IDENT_RE.match(n) or len(n) > 63:
        raise DataOpError(f"invalid identifier: {name!r}")
    return n


def _jsonable(v: Any) -> Any:
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, decimal.Decimal):
        return float(v)
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).decode("utf-8", "replace")
    return v


def _row(d: dict) -> dict:
    return {k: _jsonable(v) for k, v in d.items()}


def run_data_op(dsn: str, owner: str, op: str, resource: str,
                where: dict | None = None, values: dict | None = None,
                limit: int = 100) -> Any:
    """Execute one owner-scoped CRUD op against the tenant DSN. `owner` is the
    authoritative caller pseudonym (from the verified data-token) and is forced on
    every WHERE/INSERT — the function cannot override it."""
    if not dsn:
        raise DataOpError("no database for this app")
    owner = str(owner or "")
    if not owner:
        raise DataOpError("no caller identity")
    table = _ident(resource)
    where = dict(where or {})
    values = dict(values or {})
    try:
        import psycopg2
        import psycopg2.extras
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise DataOpError("psycopg2 unavailable") from exc

    conn = psycopg2.connect(dsn, connect_timeout=5)
    conn.autocommit = True
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if op == "find":
                clauses = ["owner = %s"]
                params: list[Any] = [owner]
                for k, v in where.items():
                    clauses.append(f'"{_ident(k)}" = %s')
                    params.append(v)
                params.append(min(int(limit or 100), _MAX_LIMIT))
                cur.execute(
                    f'SELECT * FROM "{table}" WHERE ' + " AND ".join(clauses) + " LIMIT %s",
                    params,
                )
                return [_row(dict(r)) for r in cur.fetchall()]

            if op == "insert":
                values["owner"] = owner  # force ownership
                cols = [_ident(k) for k in values]
                cur.execute(
                    f'INSERT INTO "{table}" (' + ", ".join(f'"{c}"' for c in cols) + ") VALUES (" +
                    ", ".join(["%s"] * len(cols)) + ") RETURNING *",
                    list(values.values()),
                )
                return _row(dict(cur.fetchone()))

            if op == "update":
                values.pop("owner", None)  # cannot reassign ownership
                if not values:
                    raise DataOpError("update requires values")
                set_cols = [f'"{_ident(k)}" = %s' for k in values]
                params = list(values.values())
                clauses = ["owner = %s"]
                params.append(owner)
                for k, v in where.items():
                    clauses.append(f'"{_ident(k)}" = %s')
                    params.append(v)
                cur.execute(
                    f'UPDATE "{table}" SET ' + ", ".join(set_cols) + " WHERE " +
                    " AND ".join(clauses) + " RETURNING *",
                    params,
                )
                return [_row(dict(r)) for r in cur.fetchall()]

            if op == "delete":
                clauses = ["owner = %s"]
                params = [owner]
                for k, v in where.items():
                    clauses.append(f'"{_ident(k)}" = %s')
                    params.append(v)
                cur.execute(
                    f'DELETE FROM "{table}" WHERE ' + " AND ".join(clauses),
                    params,
                )
                return {"deleted": cur.rowcount}

            raise DataOpError(f"unknown op: {op!r}")
    finally:
        conn.close()
