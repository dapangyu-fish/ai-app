#!/usr/bin/env python3
"""B1-G2: trusted, app-scoped caller identity.
- pseudonym = HMAC(server_secret, app_id||uid): deterministic, app-scoped, and
  carries no raw uid/token (owner can't reverse or cross-app-correlate).
- the invoke proxy prefix-strips ALL client x-myapp-*/auth and injects only the
  backend-derived pseudonym.
- the baked runtime helper myapp_auth.current_user() reads that injected header."""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# --- stub flask (not installed locally) with a swappable fake request ---
flask = types.ModuleType("flask")


class _Headers:
    def __init__(self, d):
        self._d = dict(d or {})

    def items(self):
        return self._d.items()

    def get(self, key, default=None):
        for k, v in self._d.items():
            if k.lower() == str(key).lower():
                return v
        return default


class _Req:
    def __init__(self, headers=None):
        self.headers = _Headers(headers or {})


flask.Response = type("Response", (), {})
flask.jsonify = lambda *a, **k: None
flask.request = _Req()
flask.stream_with_context = lambda g: g
sys.modules["flask"] = flask

_auth = types.ModuleType("auth")
_auth.verify_access_token = lambda tok: ({"id": "uid-remote"} if tok == "good" else None)
sys.modules["auth"] = _auth

_database = types.ModuleType("database")
_database.db_execute = lambda *a, **k: None
_database.db_query = lambda *a, **k: None
sys.modules["database"] = _database

_config = types.ModuleType("config")
for _name, _value in {
    "AGENT_NODE_TOKEN": "node-tok", "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER": True, "FAAS_REQUIRE_AUTH": False, "FAAS_REQUIRE_RUN_TOKEN": False, "FAAS_RUN_TOKEN_SECRET": "",
    "FAAS_RUNTIME_TOKEN": "rt", "FAAS_CALLER_PSEUDONYM_SECRET": "server-secret-xyz",
    "SUPABASE_JWT_SECRET": "", "FAAS_ENFORCE_ACCESS_POLICY": False, "FAAS_INVOKE_RATE_PER_MIN": 0,
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024, "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/x", "FAAS_DEPLOY_SCRIPT": "", "FAAS_ENABLED": True,
    "FAAS_FILE_MAX_BYTES": 256 * 1024, "FAAS_FUNCTION_PREFIX": "myapp",
    "FAAS_GIT_AUTHOR_EMAIL": "x@l", "FAAS_GIT_AUTHOR_NAME": "x", "FAAS_GIT_BRANCH": "main",
    "FAAS_GIT_ENABLED": False, "FAAS_GIT_PUSH_ENABLED": False, "FAAS_GIT_REMOTE": "",
    "FAAS_GIT_SSH_KEY_PATH": "", "FAAS_GIT_KNOWN_HOSTS_PATH": "", "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_INJECT_SUPABASE_ANON_KEY": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/x", "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/x",
    "FAAS_LOCAL_DOCKER_IMAGE": "img", "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False, "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 5, "FAAS_NODE_PUBLIC_URL": "", "FAAS_PUBLIC_BASE_URL": "",
    "FAAS_REQUIREMENTS_MAX_LINES": 40, "FAAS_RUNTIME_BUNDLE_BASE_URL": "",
    "SUPABASE_URL": "https://s.example", "SUPABASE_ANON_KEY": "anon",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

import faas  # noqa: E402
import faas_runtime_auth as myapp_auth  # noqa: E402


def _with_headers(h):
    req = _Req(h)
    faas.request = req
    myapp_auth._request = req
    return req


def test_pseudonym_deterministic_and_app_scoped():
    p1 = faas._caller_pseudonym("appA", "user1")
    p2 = faas._caller_pseudonym("appA", "user1")
    p3 = faas._caller_pseudonym("appB", "user1")
    p4 = faas._caller_pseudonym("appA", "user2")
    assert p1 and p1 == p2, (p1, p2)
    assert p1 != p3, "must differ across apps (no cross-app correlation)"
    assert p1 != p4
    assert p1.startswith("c_")
    assert "user1" not in p1 and "appA" not in p1


def test_pseudonym_empty_when_missing_inputs():
    assert faas._caller_pseudonym("appA", "") == ""
    assert faas._caller_pseudonym("", "user1") == ""


def test_proxy_headers_strip_client_identity_and_inject_pseudonym():
    _with_headers({
        "Authorization": "Bearer good",
        "X-MyApp-Caller-Pseudonym": "c_ATTACKER",
        "X-MyApp-User-Id": "victim",
        "Cookie": "s=1",
        "X-Custom": "keep-me",
        "Content-Type": "application/json",
    })
    out = faas._build_proxy_headers("c_REALPSEUDO")
    assert out.get("X-MyApp-Caller-Pseudonym") == "c_REALPSEUDO"
    assert "c_ATTACKER" not in out.values()
    assert not any(k.lower() == "x-myapp-user-id" for k in out)
    assert "Authorization" not in out and "Cookie" not in out
    assert out.get("X-Custom") == "keep-me"
    assert out.get("Content-Type") == "application/json"
    assert out.get("X-MyApp-Caller-Authed") == "1"


def test_proxy_headers_anonymous_injects_nothing():
    _with_headers({"X-Custom": "v"})
    out = faas._build_proxy_headers("")
    assert "X-MyApp-Caller-Pseudonym" not in out
    assert "X-MyApp-Caller-Authed" not in out
    assert out.get("X-Custom") == "v"


def test_verify_caller_uid_remote_fallback():
    assert faas._verify_caller_uid("good") == "uid-remote"
    assert faas._verify_caller_uid("bad") is None
    assert faas._verify_caller_uid("") is None


def test_runtime_helper_reads_injected_header():
    _with_headers({"X-MyApp-Caller-Pseudonym": "c_ME"})
    assert myapp_auth.current_user() == "c_ME"
    assert myapp_auth.is_authenticated() is True
    _with_headers({})
    assert myapp_auth.current_user() is None
    assert myapp_auth.is_authenticated() is False


def test_rate_limit_fixed_window():
    # B3-G7: with a fake redis, the (limit+1)-th call in a window is limited; fail-open.
    class _R:
        def __init__(self): self.d = {}
        def incr(self, k): self.d[k] = self.d.get(k, 0) + 1; return self.d[k]
        def expire(self, k, s): pass
    fake = _R()
    fake_ai = types.ModuleType("ai_session"); fake_ai.get_redis = lambda: fake
    sys.modules["ai_session"] = fake_ai
    try:
        faas.FAAS_INVOKE_RATE_PER_MIN = 0
        assert faas._rate_limited("appR", "c1") is False  # disabled → never limited
        faas.FAAS_INVOKE_RATE_PER_MIN = 2
        assert faas._rate_limited("appR", "c1") is False   # 1
        assert faas._rate_limited("appR", "c1") is False   # 2
        assert faas._rate_limited("appR", "c1") is True    # 3 > limit
        assert faas._rate_limited("appR", "c2") is False   # different caller ok
    finally:
        faas.FAAS_INVOKE_RATE_PER_MIN = 0
        sys.modules.pop("ai_session", None)


def test_rate_limit_fails_open_on_redis_error():
    fake_ai = types.ModuleType("ai_session")
    def _boom(): raise RuntimeError("redis down")
    fake_ai.get_redis = _boom
    sys.modules["ai_session"] = fake_ai
    try:
        faas.FAAS_INVOKE_RATE_PER_MIN = 1
        assert faas._rate_limited("appR", "c1") is False  # fail-open
    finally:
        faas.FAAS_INVOKE_RATE_PER_MIN = 0
        sys.modules.pop("ai_session", None)


def test_data_token_mint_verify_tamper_expiry():
    # B3-G1: data-token round-trips, and tamper/expiry/garbage are rejected.
    tok = faas._mint_data_token("svc-1", "c_me")
    claims = faas._verify_data_token(tok)
    assert claims and claims["s"] == "svc-1" and claims["p"] == "c_me"
    # tampered signature → None
    raw, sig = tok.split(".", 1)
    assert faas._verify_data_token(raw + "." + ("0" * len(sig))) is None
    # garbage → None
    assert faas._verify_data_token("not-a-token") is None
    assert faas._verify_data_token("") is None
    # expired → None
    expired = faas._mint_data_token("svc-1", "c_me", ttl=-1)
    assert faas._verify_data_token(expired) is None
    # a function CANNOT forge a different pseudonym (it has no secret) — only the
    # backend can mint; verify confirms the bound pseudonym, not a function-supplied one.


def test_run_token_mint_verify_and_gate():
    # X-G2 binding: run-token is authoritative; agent-node can't forge it.
    faas.FAAS_RUN_TOKEN_SECRET = "rt-secret"
    try:
        tok = faas.mint_run_token("ownerX", "run1")
        c = faas._verify_run_token(tok)
        assert c and c["o"] == "ownerX"
        raw, sig = tok.split(".", 1)
        assert faas._verify_run_token(raw + "." + "0" * len(sig)) is None
        assert faas._verify_run_token("") is None
        assert faas._verify_run_token(faas.mint_run_token("o", "r", ttl=-1)) is None
        # _request_user_id: run-token wins over a spoofed free-text owner
        _with_headers({"X-MyApp-Faas-Run-Token": tok, "X-MyApp-Agent-Node-Token": "node-tok",
                       "X-MyApp-Owner-User-Id": "spoofed"})
        assert faas._request_user_id(trusted_only=True) == "ownerX"
        # require-run-token gate: node-token + free-text owner alone is REJECTED
        faas.FAAS_REQUIRE_RUN_TOKEN = True
        _with_headers({"X-MyApp-Agent-Node-Token": "node-tok", "X-MyApp-Owner-User-Id": "spoofed"})
        assert faas._request_user_id(trusted_only=True) is None
        # gate off → free-text owner accepted (back-compat)
        faas.FAAS_REQUIRE_RUN_TOKEN = False
        _with_headers({"X-MyApp-Agent-Node-Token": "node-tok", "X-MyApp-Owner-User-Id": "o2"})
        assert faas._request_user_id(trusted_only=True) == "o2"
    finally:
        faas.FAAS_RUN_TOKEN_SECRET = ""
        faas.FAAS_REQUIRE_RUN_TOKEN = False


def test_access_policy_enforcement_matrix():
    # B3-G3: drive _access_denied_reason with controlled app policy + grant/owner.
    svc = {"owner_user_id": "ownerO", "app_id": "appP"}
    faas.can_manage_service = lambda uid, s: uid == s.get("owner_user_id")
    faas.is_consumer_granted = lambda app_id, uid: uid == "grantedUser"

    # enforcement OFF → always allowed
    faas.FAAS_ENFORCE_ACCESS_POLICY = False
    faas.get_application = lambda a: {"app_id": a, "access_policy": "owner-only"}
    assert faas._access_denied_reason(svc, None) is None

    faas.FAAS_ENFORCE_ACCESS_POLICY = True
    # owner-only: owner allowed, stranger + anon denied
    faas.get_application = lambda a: {"app_id": a, "access_policy": "owner-only"}
    assert faas._access_denied_reason(svc, "ownerO") is None
    assert faas._access_denied_reason(svc, "stranger") is not None
    assert faas._access_denied_reason(svc, None) is not None
    # public: any authed allowed, anon denied
    faas.get_application = lambda a: {"app_id": a, "access_policy": "public"}
    assert faas._access_denied_reason(svc, "anyone") is None
    assert faas._access_denied_reason(svc, None) is not None
    # install-required: only granted consumer (or owner) allowed
    faas.get_application = lambda a: {"app_id": a, "access_policy": "install-required"}
    assert faas._access_denied_reason(svc, "grantedUser") is None
    assert faas._access_denied_reason(svc, "ownerO") is None
    assert faas._access_denied_reason(svc, "ungranted") is not None
    faas.FAAS_ENFORCE_ACCESS_POLICY = False  # reset


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
