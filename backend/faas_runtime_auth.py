#!/usr/bin/env python3
"""Baked into the FaaS runtime image as ``myapp_auth`` (see Dockerfile.faas-runtime).

B1-G2: this is the ONLY way generated function code learns "who is calling".
``current_user()`` returns the backend-injected, **app-scoped pseudonym** of the
verified caller — NOT the platform user id, and NEVER a platform token. The
backend verifies the caller's JWT at the edge (D6), derives
``HMAC(server_secret, app_id || uid)``, strips any client-supplied identity
headers, and injects the result as ``X-MyApp-Caller-Pseudonym``. Owner code thus
cannot reverse the pseudonym to a platform account or correlate the same consumer
across apps (the secret is server-only), and there is no raw token to exfiltrate.

Usage in a generated app:
    import myapp_auth
    uid = myapp_auth.current_user()      # stable per (this app, this consumer); None if anonymous
    if not myapp_auth.is_authenticated():
        return {"error": "login required"}, 401
"""
from __future__ import annotations

try:  # available inside a Flask request context in the runtime
    from flask import request as _request
except Exception:  # pragma: no cover - defensive
    _request = None

# The backend injects exactly this header; client-supplied x-myapp-* are prefix-
# stripped before injection, so this value is trustworthy on the backend→function
# hop. (Sibling-container direct-connect forgery is closed separately by network
# isolation, B2-G2.)
_PSEUDONYM_HEADER = "X-MyApp-Caller-Pseudonym"


def current_user() -> str | None:
    """Return the app-scoped pseudonym of the verified caller, or None if the
    request is anonymous / no identity was injected."""
    if _request is None:
        return None
    try:
        value = _request.headers.get(_PSEUDONYM_HEADER, "")
    except Exception:
        return None
    value = (value or "").strip()
    return value or None


def is_authenticated() -> bool:
    return current_user() is not None
