#!/usr/bin/env python3
"""Baked into the FaaS runtime image as ``myapp_data`` (see Dockerfile.faas-runtime).

B3-G1: backend-MEDIATED, owner-scoped CRUD. The function NEVER holds a DB DSN.
Each call forwards the backend-injected, non-forgeable ``X-MyApp-Data-Token`` to
the backend data gateway, which runs the op scoped to the verified caller (owner =
caller pseudonym) — so function (owner) code cannot read or write another
consumer's rows, and there is no DSN to exfiltrate.

Tables addressed here must have a text ``owner`` column (set/filtered by the
platform automatically). Example:

    import myapp_data
    rows = myapp_data.find("notes", {"pinned": True}, limit=50)
    note = myapp_data.insert("notes", {"text": "hi"})
    myapp_data.update("notes", {"id": note["id"]}, {"text": "edited"})
    myapp_data.delete("notes", {"id": note["id"]})
"""
from __future__ import annotations

import json
import os
import urllib.request

try:
    from flask import request as _request
except Exception:  # pragma: no cover
    _request = None

_BACKEND = (
    os.environ.get("MYAPP_CFG_BACKEND_BASE_URL", "").rstrip("/")
    or os.environ.get("MYAPP_CFG_FAAS_PUBLIC_BASE_URL", "").rstrip("/")
)


class DataError(RuntimeError):
    pass


def _call(op, resource, where=None, values=None, limit=100):
    if _request is None:
        raise DataError("myapp_data requires a request context")
    token = _request.headers.get("X-MyApp-Data-Token", "")
    if not token:
        raise DataError("no data token (is the caller authenticated?)")
    if not _BACKEND:
        raise DataError("backend base url not configured")
    payload = json.dumps({
        "op": op, "resource": resource,
        "where": where or {}, "values": values or {}, "limit": limit,
    }).encode("utf-8")
    req = urllib.request.Request(
        _BACKEND + "/api/faas/data", data=payload, method="POST",
        headers={"Content-Type": "application/json", "X-MyApp-Data-Token": token},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            out = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            msg = json.loads(exc.read().decode("utf-8")).get("error", str(exc))
        except Exception:
            msg = str(exc)
        raise DataError(msg) from exc
    return out.get("result")


def find(resource, where=None, limit=100):
    return _call("find", resource, where=where, limit=limit)


def insert(resource, values):
    return _call("insert", resource, values=values)


def update(resource, where, values):
    return _call("update", resource, where=where, values=values)


def delete(resource, where):
    return _call("delete", resource, where=where)


def current_user():
    """The app-scoped caller pseudonym (same value the platform scopes rows by)."""
    try:
        import myapp_auth
        return myapp_auth.current_user()
    except Exception:
        return None
