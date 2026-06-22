"""User-generated FaaS service storage and deployment helpers.

This module is deliberately backend-owned. Agent runtimes may generate a
structured bundle, but they never receive GitHub credentials and never
write directly to the durable repository.
"""

from __future__ import annotations

import ast
import hashlib
import hmac
import json
import os
import re
import shlex
import shutil
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

try:
    from config import (
        FAAS_BUNDLE_MAX_BYTES,
        FAAS_BUNDLE_SERVE_ROOT,
        FAAS_CODE_ROOT,
        FAAS_DEPLOY_MODE,
        FAAS_DEPLOY_SCRIPT,
        FAAS_ENABLED,
        FAAS_FILE_MAX_BYTES,
        FAAS_FUNCTION_PREFIX,
        FAAS_GIT_AUTHOR_EMAIL,
        FAAS_GIT_AUTHOR_NAME,
        FAAS_GIT_ASYNC_PUSH,
        FAAS_GIT_BRANCH,
        FAAS_GIT_ENABLED,
        FAAS_GIT_PUSH_ENABLED,
        FAAS_GIT_REMOTE,
        FAAS_GIT_KNOWN_HOSTS_PATH,
        FAAS_GIT_SSH_KEY_PATH,
        FAAS_INJECT_SUPABASE_ANON_KEY,
        FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT,
        FAAS_LOCAL_DOCKER_HOST_CODE_ROOT,
        FAAS_LOCAL_DOCKER_IMAGE,
        FAAS_LOCAL_DOCKER_NETWORK,
        FAAS_LOCAL_DOCKER_START_ON_DEPLOY,
        FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS,
        FAAS_MAX_SERVICES_PER_USER,
        FAAS_NODE_PUBLIC_URL,
        FAAS_PUBLIC_BASE_URL,
        FAAS_REQUIREMENTS_MAX_LINES,
        FAAS_RUNTIME_BUNDLE_BASE_URL,
        FAAS_RUNTIME_TOKEN,
        SUPABASE_ANON_KEY,
        SUPABASE_URL,
    )
    from database import db_execute, db_query
except ModuleNotFoundError:
    from backend.config import (
        FAAS_BUNDLE_MAX_BYTES,
        FAAS_BUNDLE_SERVE_ROOT,
        FAAS_CODE_ROOT,
        FAAS_DEPLOY_MODE,
        FAAS_DEPLOY_SCRIPT,
        FAAS_ENABLED,
        FAAS_FILE_MAX_BYTES,
        FAAS_FUNCTION_PREFIX,
        FAAS_GIT_AUTHOR_EMAIL,
        FAAS_GIT_AUTHOR_NAME,
        FAAS_GIT_ASYNC_PUSH,
        FAAS_GIT_BRANCH,
        FAAS_GIT_ENABLED,
        FAAS_GIT_PUSH_ENABLED,
        FAAS_GIT_REMOTE,
        FAAS_GIT_KNOWN_HOSTS_PATH,
        FAAS_GIT_SSH_KEY_PATH,
        FAAS_INJECT_SUPABASE_ANON_KEY,
        FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT,
        FAAS_LOCAL_DOCKER_HOST_CODE_ROOT,
        FAAS_LOCAL_DOCKER_IMAGE,
        FAAS_LOCAL_DOCKER_NETWORK,
        FAAS_LOCAL_DOCKER_START_ON_DEPLOY,
        FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS,
        FAAS_MAX_SERVICES_PER_USER,
        FAAS_NODE_PUBLIC_URL,
        FAAS_PUBLIC_BASE_URL,
        FAAS_REQUIREMENTS_MAX_LINES,
        FAAS_RUNTIME_BUNDLE_BASE_URL,
        FAAS_RUNTIME_TOKEN,
        SUPABASE_ANON_KEY,
        SUPABASE_URL,
    )
    from backend.database import db_execute, db_query


class FaaSError(RuntimeError):
    pass


class FaaSValidationError(FaaSError):
    pass


@dataclass(frozen=True)
class FaaSDeployResult:
    service_id: str
    function_name: str
    status: str
    commit_sha: str
    code_path: str
    public_base_url: str
    routes: list[dict[str, Any]]
    deployment_id: str
    error: str = ""


_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()
_SAFE_FILE_RE = re.compile(r"^[A-Za-z0-9_.\-/]+$")
_SAFE_SLUG_RE = re.compile(r"[^a-z0-9-]+")

_ALLOWED_FILES = {
    "app.py",
    "requirements.txt",
    "service.json",
    "README.md",
}
_ALLOWED_PREFIXES = (
    "tests/",
)
# A FaaS service may now ship multiple files (modules, packages, templates,
# static assets, data) so a service can be a real multi-file app rather than a
# single app.py. Any path with one of these extensions is accepted (subject to
# the path-safety + size + count limits); app.py stays the required entrypoint.
_ALLOWED_EXTENSIONS = {
    ".py",
    ".txt",
    ".json",
    ".md",
    ".html",
    ".css",
    ".js",
    ".csv",
    ".yaml",
    ".yml",
    ".sql",
}
_MAX_BUNDLE_FILES = 60
# Name of the user's DDL/migration file (run into their schema on deploy).
_SCHEMA_SQL_FILE = "schema.sql"
# Filenames a user bundle may NOT ship — they would shadow platform-provided
# runtime modules (myapp_db is the scoped DB helper baked into the image).
_RESERVED_FILE_NAMES = {"myapp_db.py"}
_ALLOWED_IMPORT_ROOTS = {
    "__future__",
    "base64",
    "collections",
    "dateutil",
    "datetime",
    "decimal",
    "flask",
    "functools",
    "hashlib",
    "hmac",
    "itertools",
    "json",
    "math",
    "pydantic",
    "random",
    "re",
    "statistics",
    "string",
    "time",
    "typing",
    "urllib",
    "uuid",
    # Platform-provided DB helper baked into the runtime image. It is the ONLY
    # way generated code touches Postgres (it reads the scoped DSN from env, which
    # generated code cannot — os is not importable). The DSN is least-privilege
    # (own schema only), so this is safe to expose.
    "myapp_db",
    # B1-G2: caller-identity helper baked into the runtime. current_user() returns
    # the backend-injected app-scoped pseudonym; exposes no token/uid.
    "myapp_auth",
}
_FORBIDDEN_CALLS = {
    "__import__",
    "compile",
    "eval",
    "exec",
    "input",
    "open",
    # B0-G2 / R21: reflection primitives are the master key that turns a
    # whitelist sandbox into RCE (e.g. getattr(random, "_" + "os") to reach the
    # real os, or vars()/globals() to walk module internals). Banned outright —
    # declarative CRUD code does not need them. NOTE: this AST sandbox is
    # DEFENSE-IN-DEPTH, not the security boundary; the real isolation is "no
    # secrets in the container + locked network" (design §0.0, goal B0-G2).
    "getattr",
    "setattr",
    "delattr",
    "vars",
    "globals",
    "locals",
    "breakpoint",
}
# B0-G2 / R21: str.format()/%-style attribute traversal — e.g.
# "{0.__class__.__init__.__globals__}".format(x) — performs attribute access
# INSIDE the format string at runtime, so it never appears as an ast.Attribute
# node and bypasses the dunder/private rules. Heuristic: reject string literals
# whose format field does attribute access onto a private/dunder name. The
# quote-exclusion ([^{}"']) avoids false-positiving JSON like {"__typename": 1}.
_FORMAT_DUNDER_RE = re.compile(r"\{[^{}\"']*\._")
_FORBIDDEN_NAMES = {
    "__builtins__",
    "__dict__",
    "__globals__",
    "__subclasses__",
}
# B0-G2 / R21: attribute names that re-expose os/process/FFI capability even when
# imported indirectly through a whitelisted module (e.g. random._os.environ,
# uuid.os, urllib.request.os.system). Blocked regardless of leading-underscore.
# Combined with the leading-underscore rule below this closes the known
# "single-underscore attribute" escape from the feasibility audit.
_FORBIDDEN_ATTR_NAMES = {
    "os",
    "sys",
    "subprocess",
    "socket",
    "ctypes",
    "importlib",
    "builtins",
    "posix",
    "nt",
    "pty",
    "signal",
    "resource",
    "multiprocessing",
    "environ",
    "popen",
    "system",
    "getenv",
    "putenv",
    "fork",
    "execv",
    "execve",
    "execvp",
    "spawnl",
    "spawnv",
}
_LOCAL_DOCKER_MODES = {"local-docker", "docker", "docker-local"}
_RESERVED_ROUTE_PATHS = {
    "/__myapp_faas_health",
}
_FLASK_METHOD_DECORATORS = {
    "get": "GET",
    "post": "POST",
    "put": "PUT",
    "patch": "PATCH",
    "delete": "DELETE",
}
# Flask only ships get/post/put/patch/delete method shortcuts (2.0+). @app.head /
# @app.options / @app.trace / @app.connect do NOT exist — using them raises
# "'Flask' object has no attribute ..." at app.py import, so the whole function
# 503s at runtime. The validator must reject them (it previously accepted
# @app.options and shipped a backend that crashed) and steer the agent to
# @app.route(path, methods=[...]).
_INVALID_METHOD_DECORATORS = {"head", "options", "trace", "connect"}


def ensure_tables() -> None:
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_services (
            service_id TEXT PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            service_slug TEXT NOT NULL,
            function_name TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft', 'deploying', 'ready', 'failed', 'disabled')),
            active_commit TEXT NOT NULL DEFAULT '',
            active_path TEXT NOT NULL DEFAULT '',
            public_base_url TEXT NOT NULL DEFAULT '',
            routes JSONB NOT NULL DEFAULT '[]'::jsonb,
            meta_json JSONB NOT NULL DEFAULT '{}'::jsonb,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_deployments (
            deployment_id TEXT PRIMARY KEY,
            service_id TEXT NOT NULL REFERENCES faas_services(service_id) ON DELETE CASCADE,
            owner_user_id TEXT NOT NULL,
            commit_sha TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'success', 'failed')),
            error TEXT NOT NULL DEFAULT '',
            bundle_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            finished_at TIMESTAMPTZ
        )
        """
    )
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_services_owner ON faas_services(owner_user_id)")
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_services_status ON faas_services(status)")
    db_execute(
        "CREATE INDEX IF NOT EXISTS idx_faas_deployments_service_created "
        "ON faas_deployments(service_id, created_at DESC)"
    )
    # B1-G1: Application = the governance unit grouping {json-app, faas service(s),
    # db, owner, access_policy}. access_policy is the D3 ladder; default owner-only
    # (most-closed) — the Owner opens it up via the client management UI (B3-G8).
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_applications (
            app_id TEXT PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            appid TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            access_policy TEXT NOT NULL DEFAULT 'owner-only'
                CHECK (access_policy IN ('owner-only', 'allowlist', 'install-required', 'public')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_applications_owner ON faas_applications(owner_user_id)")
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_applications_appid ON faas_applications(appid)")
    # X-G1: app-level maintainers (can deploy/scale/migrate, NOT transfer/delete/manage-members).
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_app_maintainers (
            app_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            added_by TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (app_id, user_id)
        )
        """
    )
    # X-G2: audit trail for every privileged FaaS mutation (deploy/scale/disable/
    # delete/grant/member). Makes trusted-token (AGENT_NODE_TOKEN) abuse detectable
    # even before a full backend-minted run-scoped token lands (INV-9).
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_audit_log (
            id BIGSERIAL PRIMARY KEY,
            action TEXT NOT NULL,
            service_id TEXT NOT NULL DEFAULT '',
            app_id TEXT NOT NULL DEFAULT '',
            owner_user_id TEXT NOT NULL DEFAULT '',
            acting_user TEXT NOT NULL DEFAULT '',
            via TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_audit_created ON faas_audit_log(created_at DESC)")
    # B3-G3: per-app CONSUMER grants (server-verified — NOT the anonymous-writable
    # registry install telemetry). revoked_at set => revoked (checked live per call).
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_app_consumer_grants (
            app_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            granted_by TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            revoked_at TIMESTAMPTZ,
            PRIMARY KEY (app_id, user_id)
        )
        """
    )
    # B1-G1: bind each service to its application (additive; nullable→'' default so
    # existing rows migrate cleanly, then backfilled below to a per-owner default app).
    db_execute("ALTER TABLE faas_services ADD COLUMN IF NOT EXISTS app_id TEXT NOT NULL DEFAULT ''")
    db_execute("CREATE INDEX IF NOT EXISTS idx_faas_services_app ON faas_services(app_id)")
    # Backfill: every existing service without an app gets a per-owner default app
    # (app_id = 'appd-<owner>'). Idempotent — after the first run the WHERE matches
    # nothing. (Per-app schema migration is B2-G3; here we only establish the model.)
    db_execute(
        """
        INSERT INTO faas_applications (app_id, owner_user_id, name)
        SELECT DISTINCT 'appd-' || owner_user_id, owner_user_id, 'default'
        FROM faas_services
        WHERE app_id IS NULL OR app_id = ''
        ON CONFLICT (app_id) DO NOTHING
        """
    )
    db_execute("UPDATE faas_services SET app_id = 'appd-' || owner_user_id WHERE app_id IS NULL OR app_id = ''")


def _service_lock(service_id: str) -> threading.Lock:
    with _LOCKS_GUARD:
        lock = _LOCKS.get(service_id)
        if lock is None:
            lock = threading.Lock()
            _LOCKS[service_id] = lock
        return lock


def _safe_slug(value: str, fallback: str = "service") -> str:
    text = str(value or "").strip().lower().replace("_", "-")
    text = _SAFE_SLUG_RE.sub("-", text).strip("-")
    return (text or fallback)[:48]


def _safe_id(value: str, fallback: str) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9_.-]+", "-", text).strip(".-")
    return (text or fallback)[:80]


def _uid_shard(user_id: str) -> Path:
    # Repo-layout contract (see myapp-faas-services/LAYOUT.md):
    #   <uid[0:2]>/<uid[2:4]>/<uid>/<service_id>/
    # uid is path-sanitized; non-path-safe ids fall back to a deterministic hash.
    raw = str(user_id or "").strip()
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    compact = re.sub(r"[^A-Za-z0-9-]+", "", raw) or digest
    a = compact[:2].lower() if len(compact) >= 2 else digest[:2]
    b = compact[2:4].lower() if len(compact) >= 4 else digest[2:4]
    return Path(a) / b / compact


def user_code_root(user_id: str) -> Path:
    return Path(FAAS_CODE_ROOT) / _uid_shard(user_id)


def service_code_root(user_id: str, service_id: str) -> Path:
    return user_code_root(user_id) / _safe_id(service_id, "service")


def _function_name(user_id: str, service_id: str) -> str:
    uid_hash = hashlib.sha256(str(user_id).encode("utf-8")).hexdigest()[:12]
    svc = _safe_id(service_id, "svc").replace("_", "-").replace(".", "-")
    prefix = _safe_slug(FAAS_FUNCTION_PREFIX, "myapp")
    return f"{prefix}-u{uid_hash}-s{svc[:32]}"


def _local_container_name(function_name: str) -> str:
    base = re.sub(r"[^a-zA-Z0-9_.-]+", "-", function_name).strip(".-").lower() or "service"
    digest = hashlib.sha256(function_name.encode("utf-8")).hexdigest()[:10]
    return f"myapp-faas-{base[:40]}-{digest}"


def _local_runtime_service_dir(root: Path) -> str:
    rel = root.resolve().relative_to(Path(FAAS_CODE_ROOT).resolve())
    return str(Path(FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT) / rel)


def _local_upstream_url(function_name: str) -> str:
    return f"http://{_local_container_name(function_name)}:8080"


# ── multi-replica (扩容/缩容) ─────────────────────────────────────────────────
# Replica 0 keeps the base name (back-compat + cold-wake target); replicas 1..N
# get a "-r<i>" suffix. The invoke proxy load-balances across running replicas.
def _replica_name(function_name: str, replica: int) -> str:
    base = _local_container_name(function_name)
    return base if replica <= 0 else f"{base}-r{replica}"


def _replica_upstream(function_name: str, replica: int) -> str:
    return f"http://{_replica_name(function_name, replica)}:8080"


def _running_replicas(function_name: str) -> list[int]:
    """Indices of currently-running replica containers for a service."""
    client = _docker_client()
    names = {_replica_name(function_name, 0): 0}
    # Map every possible replica container name -> index by scanning by label.
    out: list[int] = []
    try:
        containers = client.containers.list(
            filters={"label": f"myapp.faas.function_name={function_name}", "status": "running"}
        )
    except Exception:
        return out
    base = _local_container_name(function_name)
    for c in containers:
        nm = c.name
        if nm == base:
            out.append(0)
        elif nm.startswith(base + "-r"):
            try:
                out.append(int(nm[len(base) + 2:]))
            except ValueError:
                continue
    return sorted(set(out))


# ── self-managed Docker FaaS: scale-to-zero state ────────────────────────────
# The invoke path touches a per-service activity file; the reaper
# (faas_docker_reaper.py) stops containers idle past the threshold, and the
# invoke path cold-wakes them (container.start, env preserved).
FAAS_DOCKER_SCALE_ZERO = os.environ.get("FAAS_DOCKER_SCALE_ZERO", "1").strip().lower() in {"1", "true", "yes", "on"}
FAAS_DOCKER_IDLE_SECONDS = int(os.environ.get("FAAS_DOCKER_IDLE_SECONDS", "600"))
FAAS_DOCKER_STATE_DIR = os.environ.get("FAAS_DOCKER_STATE_DIR", "/mnt/myapp/faas/state").rstrip("/")
FAAS_DOCKER_MAX_REPLICAS = int(os.environ.get("FAAS_DOCKER_MAX_REPLICAS", "5"))
_RR_COUNTER: dict[str, int] = {}


def _activity_path(service_id: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(service_id or "")).strip("-")[:80] or "svc"
    return Path(FAAS_DOCKER_STATE_DIR) / safe


def touch_service_activity(service_id: str) -> None:
    """Record last-invoke for a Docker FaaS service (read by the reaper)."""
    try:
        p = _activity_path(service_id)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch()
    except Exception:
        pass


def service_last_active(service_id: str) -> float:
    try:
        return _activity_path(service_id).stat().st_mtime
    except Exception:
        return 0.0


def _count_user_services(user_id: str) -> int:
    # Count only services that actually occupy a slot. 'disabled' is an explicit
    # delete; 'failed' is a deploy that never became live — neither should consume
    # the user's quota (a brand-new failed deploy is also removed outright, see
    # deploy_bundle), so a string of failed attempts can't lock a user out.
    row = db_query(
        "SELECT COUNT(*) AS count FROM faas_services WHERE owner_user_id = %s AND status NOT IN ('disabled', 'failed')",
        [user_id],
        fetch_one=True,
    )
    return int(row["count"] if row else 0)


def _json_object(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return {}
        if isinstance(parsed, dict):
            return dict(parsed)
    return {}


def _current_deploy_meta() -> dict[str, Any]:
    mode = str(FAAS_DEPLOY_MODE or "").strip()
    meta: dict[str, Any] = {"mode": mode}
    if mode in _LOCAL_DOCKER_MODES:
        meta.update(
            {
                "runtime_image": FAAS_LOCAL_DOCKER_IMAGE,
                "network": FAAS_LOCAL_DOCKER_NETWORK,
                "start_on_deploy": FAAS_LOCAL_DOCKER_START_ON_DEPLOY,
            }
        )
    return meta


def _meta_with_current_deploy(bundle_meta: Any) -> dict[str, Any]:
    meta = _json_object(bundle_meta)
    deploy = _json_object(meta.get("deploy"))
    deploy.update(_current_deploy_meta())
    meta["deploy"] = deploy
    return meta


def service_deploy_mode(service: dict[str, Any] | None) -> str:
    """Per-service deploy mode (meta_json.deploy.mode) with the global
    FAAS_DEPLOY_MODE as fallback. The only real runtime is the self-managed
    Docker FaaS (local-docker); 'metadata'/'none' are no-op modes for tests/dev."""
    if service:
        meta = _json_object(service.get("meta_json"))
        deploy = _json_object(meta.get("deploy"))
        mode = str(deploy.get("mode") or "").strip()
        if mode:
            return mode
    return str(FAAS_DEPLOY_MODE or "").strip()


def list_services(
    user_id: str,
    *,
    include_disabled: bool = False,
    all_services: bool = False,
) -> list[dict[str, Any]]:
    ensure_tables()
    disabled_clause = "" if include_disabled else "AND status <> 'disabled'"
    cols = (
        "service_id, owner_user_id, app_id, service_slug, function_name, status, "
        "active_commit, active_path, public_base_url, routes, meta_json, "
        "created_at, updated_at"
    )
    if all_services:
        # Host/operator view: every owner's services (no owner filter).
        rows = db_query(
            f"SELECT {cols} FROM faas_services WHERE TRUE {disabled_clause} ORDER BY updated_at DESC",
            [],
            fetch_all=True,
        )
    else:
        rows = db_query(
            f"SELECT {cols} FROM faas_services WHERE owner_user_id = %s {disabled_clause} ORDER BY updated_at DESC",
            [user_id],
            fetch_all=True,
        )
    return rows or []


def get_service(service_id: str) -> dict[str, Any] | None:
    ensure_tables()
    return db_query(
        """
        SELECT service_id, owner_user_id, app_id, service_slug, function_name, status,
               active_commit, active_path, public_base_url, routes, meta_json,
               created_at, updated_at
        FROM faas_services
        WHERE service_id = %s
        """,
        [service_id],
        fetch_one=True,
    )


# ── B1-G1: Application entity (governance unit grouping services + db + policy) ──

_VALID_ACCESS_POLICIES = {"owner-only", "allowlist", "install-required", "public"}


def _default_app_id(owner_user_id: str) -> str:
    """Per-owner default application id. Until the JSON-App declares its own app
    (and per-app schema lands in B2-G3), an owner's services group under one
    default app — which is 1:1 with the current per-user DB schema."""
    return "appd-" + str(owner_user_id or "").strip()


def ensure_application(
    app_id: str,
    owner_user_id: str,
    *,
    appid: str = "",
    name: str = "",
    access_policy: str = "owner-only",
) -> dict[str, Any]:
    """Idempotently create (or fetch) an application. Never reassigns owner: if the
    app already exists under a different owner this raises (an app_id is owned)."""
    ensure_tables()
    app_id = str(app_id or "").strip()
    owner_user_id = str(owner_user_id or "").strip()
    if not app_id or not owner_user_id:
        raise FaaSValidationError("app_id and owner_user_id are required")
    if access_policy not in _VALID_ACCESS_POLICIES:
        raise FaaSValidationError(f"invalid access_policy: {access_policy}")
    existing = get_application(app_id)
    if existing:
        if existing.get("owner_user_id") != owner_user_id:
            raise FaaSValidationError("app_id already belongs to another user")
        return existing
    db_execute(
        """
        INSERT INTO faas_applications (app_id, owner_user_id, appid, name, access_policy)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (app_id) DO NOTHING
        """,
        [app_id, owner_user_id, str(appid or ""), str(name or ""), access_policy],
    )
    return get_application(app_id) or {
        "app_id": app_id,
        "owner_user_id": owner_user_id,
        "appid": appid,
        "name": name,
        "access_policy": access_policy,
    }


def get_application(app_id: str) -> dict[str, Any] | None:
    ensure_tables()
    return db_query(
        "SELECT app_id, owner_user_id, appid, name, access_policy, created_at, updated_at "
        "FROM faas_applications WHERE app_id = %s",
        [str(app_id or "").strip()],
        fetch_one=True,
    )


def list_user_applications(owner_user_id: str) -> list[dict[str, Any]]:
    ensure_tables()
    rows = db_query(
        "SELECT app_id, owner_user_id, appid, name, access_policy, created_at, updated_at "
        "FROM faas_applications WHERE owner_user_id = %s ORDER BY created_at DESC",
        [str(owner_user_id or "").strip()],
        fetch_all=True,
    )
    return rows or []


def set_application_policy(owner_user_id: str, app_id: str, access_policy: str) -> dict[str, Any]:
    """Owner-only: move the app up/down the D3 access ladder. Ownership enforced."""
    ensure_tables()
    if access_policy not in _VALID_ACCESS_POLICIES:
        raise FaaSValidationError(f"invalid access_policy: {access_policy}")
    app = get_application(app_id)
    if not app or app.get("owner_user_id") != str(owner_user_id or "").strip():
        raise FaaSValidationError("application not found")
    db_execute(
        "UPDATE faas_applications SET access_policy = %s, updated_at = NOW() WHERE app_id = %s",
        [access_policy, app_id],
    )
    return get_application(app_id) or app


# ── X-G1: maintainers (collaborators who can deploy/scale, not own) ──

def is_maintainer(app_id: str, user_id: str) -> bool:
    app_id = str(app_id or "").strip()
    user_id = str(user_id or "").strip()
    if not app_id or not user_id:
        return False
    row = db_query(
        "SELECT 1 AS ok FROM faas_app_maintainers WHERE app_id = %s AND user_id = %s",
        [app_id, user_id],
        fetch_one=True,
    )
    return bool(row)


def list_maintainers(app_id: str) -> list[dict[str, Any]]:
    ensure_tables()
    rows = db_query(
        "SELECT app_id, user_id, added_by, created_at FROM faas_app_maintainers "
        "WHERE app_id = %s ORDER BY created_at",
        [str(app_id or "").strip()],
        fetch_all=True,
    )
    return rows or []


def add_maintainer(owner_user_id: str, app_id: str, user_id: str) -> dict[str, Any]:
    """Owner-only: add a maintainer to an app. Ownership enforced."""
    ensure_tables()
    app = get_application(app_id)
    if not app or app.get("owner_user_id") != str(owner_user_id or "").strip():
        raise FaaSValidationError("application not found")
    user_id = str(user_id or "").strip()
    if not user_id:
        raise FaaSValidationError("user_id is required")
    if user_id == app.get("owner_user_id"):
        raise FaaSValidationError("owner is already implicitly a maintainer")
    db_execute(
        "INSERT INTO faas_app_maintainers (app_id, user_id, added_by) VALUES (%s, %s, %s) "
        "ON CONFLICT (app_id, user_id) DO NOTHING",
        [app_id, user_id, owner_user_id],
    )
    return {"app_id": app_id, "user_id": user_id}


def remove_maintainer(owner_user_id: str, app_id: str, user_id: str) -> None:
    """Owner-only: remove a maintainer. Ownership enforced."""
    ensure_tables()
    app = get_application(app_id)
    if not app or app.get("owner_user_id") != str(owner_user_id or "").strip():
        raise FaaSValidationError("application not found")
    db_execute(
        "DELETE FROM faas_app_maintainers WHERE app_id = %s AND user_id = %s",
        [app_id, str(user_id or "").strip()],
    )


# ── B3-G3: per-app consumer access grants (server-verified) ──

def grant_consumer(owner_user_id: str, app_id: str, user_id: str) -> dict[str, Any]:
    """Owner/maintainer grants a consumer access to an app (for allowlist/
    install-required policies). Ownership/maintainer enforced."""
    ensure_tables()
    app = get_application(app_id)
    owner_user_id = str(owner_user_id or "").strip()
    if not app or (app.get("owner_user_id") != owner_user_id and not is_maintainer(app_id, owner_user_id)):
        raise FaaSValidationError("application not found")
    user_id = str(user_id or "").strip()
    if not user_id:
        raise FaaSValidationError("user_id is required")
    db_execute(
        "INSERT INTO faas_app_consumer_grants (app_id, user_id, granted_by, revoked_at) "
        "VALUES (%s, %s, %s, NULL) "
        "ON CONFLICT (app_id, user_id) DO UPDATE SET revoked_at = NULL, granted_by = EXCLUDED.granted_by",
        [app_id, user_id, owner_user_id],
    )
    return {"app_id": app_id, "user_id": user_id}


def revoke_consumer(owner_user_id: str, app_id: str, user_id: str) -> None:
    """Owner/maintainer revokes a consumer's access (takes effect on the next call)."""
    ensure_tables()
    app = get_application(app_id)
    owner_user_id = str(owner_user_id or "").strip()
    if not app or (app.get("owner_user_id") != owner_user_id and not is_maintainer(app_id, owner_user_id)):
        raise FaaSValidationError("application not found")
    db_execute(
        "UPDATE faas_app_consumer_grants SET revoked_at = NOW() WHERE app_id = %s AND user_id = %s",
        [app_id, str(user_id or "").strip()],
    )


def is_consumer_granted(app_id: str, user_id: str) -> bool:
    """Live grant check (per invoke) — a revoked grant returns False immediately."""
    app_id = str(app_id or "").strip()
    user_id = str(user_id or "").strip()
    if not app_id or not user_id:
        return False
    row = db_query(
        "SELECT 1 AS ok FROM faas_app_consumer_grants "
        "WHERE app_id = %s AND user_id = %s AND revoked_at IS NULL",
        [app_id, user_id],
        fetch_one=True,
    )
    return bool(row)


def list_consumers(app_id: str) -> list[dict[str, Any]]:
    ensure_tables()
    rows = db_query(
        "SELECT app_id, user_id, granted_by, created_at, revoked_at FROM faas_app_consumer_grants "
        "WHERE app_id = %s AND revoked_at IS NULL ORDER BY created_at",
        [str(app_id or "").strip()],
        fetch_all=True,
    )
    return rows or []


def audit_log(action: str, *, service_id: str = "", app_id: str = "", owner_user_id: str = "",
              acting_user: str = "", via: str = "", detail: str = "") -> None:
    """X-G2: record a privileged FaaS mutation. Best-effort — never breaks the
    operation it audits."""
    try:
        ensure_tables()
        db_execute(
            "INSERT INTO faas_audit_log (action, service_id, app_id, owner_user_id, acting_user, via, detail) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            [str(action or ""), str(service_id or ""), str(app_id or ""),
             str(owner_user_id or ""), str(acting_user or ""), str(via or ""), str(detail or "")[:500]],
        )
    except Exception:
        pass


def list_audit_log(*, owner_user_id: str = "", limit: int = 100) -> list[dict[str, Any]]:
    ensure_tables()
    limit = max(1, min(int(limit or 100), 1000))
    if owner_user_id:
        rows = db_query(
            "SELECT action, service_id, app_id, owner_user_id, acting_user, via, detail, created_at "
            "FROM faas_audit_log WHERE owner_user_id = %s ORDER BY created_at DESC LIMIT %s",
            [str(owner_user_id).strip(), limit], fetch_all=True,
        )
    else:
        rows = db_query(
            "SELECT action, service_id, app_id, owner_user_id, acting_user, via, detail, created_at "
            "FROM faas_audit_log ORDER BY created_at DESC LIMIT %s",
            [limit], fetch_all=True,
        )
    return rows or []


def can_manage_service(acting_user: str, service: dict[str, Any]) -> bool:
    """B2-G4 + X-G1: may `acting_user` deploy/scale this service? True if they are
    the service's OWNER or a MAINTAINER of its application. Resource ownership is
    always the service's own owner_user_id — never the acting user."""
    acting_user = str(acting_user or "").strip()
    if not acting_user or not isinstance(service, dict):
        return False
    if service.get("owner_user_id") == acting_user:
        return True
    return is_maintainer(service.get("app_id", ""), acting_user)


def _db_tenant_key(app_id: str, owner_user_id: str) -> str:
    """B2-G3: which DB tenant a service's data lives under. The per-owner DEFAULT app
    ('appd-<owner>') maps to the owner's EXISTING per-user schema (zero migration);
    a custom app (its own app_id) gets its OWN app-keyed schema, so an owner's
    multiple apps do not share one database. Provisioning is keyed on this string."""
    app_id = str(app_id or "").strip()
    owner = str(owner_user_id or "").strip()
    if app_id.startswith("appd-"):
        return app_id[len("appd-"):] or owner
    return app_id or owner


def _resolve_app_id(owner_user_id: str, meta: dict[str, Any]) -> tuple[str, str]:
    """Pick the application a deploy binds to. A bundle may declare meta.app_id (or
    carry meta.appid for JSON-App binding); otherwise it falls under the owner's
    default app. Returns (app_id, appid)."""
    meta = meta if isinstance(meta, dict) else {}
    declared = str(meta.get("app_id") or "").strip()
    appid = str(meta.get("appid") or "").strip()
    app_id = declared or _default_app_id(owner_user_id)
    return app_id, appid


def _pull_bundle_serve_root() -> None:
    """Reconcile the strict bundle-serving checkout from GitHub (fetch + hard reset).

    Self-heals: if the serve root is missing or is not a git checkout (e.g. wiped
    or lost), re-clone it from the remote instead of silently serving nothing and
    returning 404 for every bundle.
    """
    if not FAAS_BUNDLE_SERVE_ROOT:
        return
    serve_root = Path(FAAS_BUNDLE_SERVE_ROOT)
    if not (serve_root / ".git").exists():
        if not FAAS_GIT_REMOTE:
            return
        if serve_root.exists():
            shutil.rmtree(serve_root, ignore_errors=True)
        serve_root.parent.mkdir(parents=True, exist_ok=True)
        _run_git(
            ["clone", "--branch", FAAS_GIT_BRANCH, FAAS_GIT_REMOTE, str(serve_root)],
            cwd=serve_root.parent,
            check=True,
        )
        return
    _run_git(["fetch", "origin", FAAS_GIT_BRANCH], cwd=serve_root)
    _run_git(["reset", "--hard", f"origin/{FAAS_GIT_BRANCH}"], cwd=serve_root, check=True)


def runtime_bundle_for_service(service_id: str) -> dict[str, Any]:
    service = get_service(service_id)
    if not service:
        raise FaaSValidationError("service not found")
    active_path = str(service.get("active_path") or "").strip()
    if not active_path:
        raise FaaSValidationError("service has no active code path")
    if FAAS_BUNDLE_SERVE_ROOT:
        # Strict source-of-truth: serve from the GitHub-pulled checkout, so the
        # code that runs provably came from git rather than a backend-local write.
        try:
            rel = Path(active_path).resolve().relative_to(Path(FAAS_CODE_ROOT).resolve())
        except ValueError as exc:
            raise FaaSValidationError("service path is outside the FaaS code root") from exc
        root = Path(FAAS_BUNDLE_SERVE_ROOT) / rel
        # Reconcile from git, retrying briefly so a just-deployed service whose
        # async push is still in flight resolves once its commit lands. A transient
        # pull failure must not break an in-flight runtime fetch.
        for _attempt in range(6):
            try:
                _pull_bundle_serve_root()
            except Exception:
                pass
            if (root / "app.py").is_file():
                break
            time.sleep(2)
    else:
        root = Path(active_path)
    if not root.is_dir():
        raise FaaSValidationError("service code path is missing")
    files: dict[str, str] = {}
    for item in sorted(root.rglob("*")):
        if not item.is_file():
            continue
        rel = item.relative_to(root).as_posix()
        _validate_file_path(rel)
        files[rel] = item.read_text(encoding="utf-8")
    if "app.py" not in files:
        raise FaaSValidationError("service bundle is missing app.py")
    return {
        "service": {
            "service_id": service.get("service_id"),
            "slug": service.get("service_slug"),
            "function_name": service.get("function_name"),
            "commit": service.get("active_commit"),
            "routes": service.get("routes") or [],
        },
        "files": files,
    }


def build_service_archive(service_id: str) -> bytes:
    """Zip the service's entire current folder so the agent can pull it, edit any
    files, and repack/upload (the download half of the multi-file edit flow).
    Sourced from runtime_bundle_for_service so it is exactly the code that runs
    (git-backed when FAAS_BUNDLE_SERVE_ROOT is set)."""
    import io
    import zipfile

    bundle = runtime_bundle_for_service(service_id)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
        for rel, content in sorted(bundle["files"].items()):
            archive.writestr(rel, content)
    return buf.getvalue()


def read_service_source(
    service_id: str,
    *,
    names: tuple[str, ...] = ("app.py", "requirements.txt"),
    max_bytes: int = 60_000,
) -> dict[str, str]:
    """Best-effort read of an existing service's source so the generator can
    APPEND routes to it instead of regenerating from route descriptions. Returns
    {} if the service or its code is unavailable."""
    service = get_service(service_id)
    if not service:
        return {}
    active_path = str(service.get("active_path") or "").strip()
    if not active_path:
        return {}
    root = Path(active_path)
    out: dict[str, str] = {}
    for name in names:
        candidate = root / name
        try:
            if candidate.is_file():
                text = candidate.read_text(encoding="utf-8")
                out[name] = text if len(text.encode("utf-8")) <= max_bytes else text[:max_bytes] + "\n# ...truncated...\n"
        except Exception:
            continue
    return out


def runtime_token_for_service(service_id: str) -> str:
    if not FAAS_RUNTIME_TOKEN:
        return ""
    normalized = str(service_id or "").strip()
    if not normalized:
        return ""
    return hmac.new(
        FAAS_RUNTIME_TOKEN.encode("utf-8"),
        normalized.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _validate_file_path(path: str) -> str:
    normalized = os.path.normpath(str(path or "").strip()).replace("\\", "/")
    if normalized in {"", ".", ".."} or normalized.startswith("../") or os.path.isabs(normalized):
        raise FaaSValidationError(f"invalid file path: {path}")
    if not _SAFE_FILE_RE.fullmatch(normalized):
        raise FaaSValidationError(f"file path contains unsupported characters: {path}")
    segments = normalized.split("/")
    if len(segments) > 6:
        raise FaaSValidationError(f"file path is too deep: {normalized}")
    for seg in segments:
        if seg.startswith(".") or seg == "__pycache__":
            raise FaaSValidationError(f"file path segment is not allowed: {seg}")
    if segments[-1] in _RESERVED_FILE_NAMES:
        raise FaaSValidationError(f"file name is reserved by the platform: {segments[-1]}")
    if normalized in _ALLOWED_FILES:
        return normalized
    if any(normalized.startswith(prefix) for prefix in _ALLOWED_PREFIXES):
        return normalized
    ext = os.path.splitext(normalized)[1].lower()
    if ext not in _ALLOWED_EXTENSIONS:
        raise FaaSValidationError(f"file type is not allowed in FaaS bundle: {normalized}")
    return normalized


def _validate_requirements(text: str) -> None:
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    if len(lines) > FAAS_REQUIREMENTS_MAX_LINES:
        raise FaaSValidationError(f"requirements.txt has too many dependencies: {len(lines)}")
    allowed = {"flask", "pydantic", "python-dateutil"}
    for line in lines:
        name = re.split(r"[<>=!~\[]", line, maxsplit=1)[0].strip().lower().replace("_", "-")
        if name and name not in allowed:
            raise FaaSValidationError(f"dependency is not allowed yet: {name}")


def _literal_string(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _literal_methods(node: ast.AST) -> set[str] | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value.strip().upper()}
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        out: set[str] = set()
        for item in node.elts:
            value = _literal_string(item)
            if value is None:
                return None
            if value.strip():
                out.add(value.strip().upper())
        return out
    return None


def _is_literal_value(node: ast.AST) -> bool:
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub, ast.Not)):
        return _is_literal_value(node.operand)
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return all(_is_literal_value(item) for item in node.elts)
    if isinstance(node, ast.Dict):
        return all(
            (key is None or _is_literal_value(key)) and _is_literal_value(value)
            for key, value in zip(node.keys, node.values)
        )
    return False


def _is_safe_flask_constructor_arg(node: ast.AST) -> bool:
    return _is_literal_value(node) or (isinstance(node, ast.Name) and node.id == "__name__")


def _is_flask_constructor(node: ast.AST) -> bool:
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    is_flask = False
    if isinstance(func, ast.Name):
        is_flask = func.id == "Flask"
    elif isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
        is_flask = func.value.id == "flask" and func.attr == "Flask"
    if not is_flask:
        return False
    return all(_is_safe_flask_constructor_arg(arg) for arg in node.args) and all(
        _is_safe_flask_constructor_arg(keyword.value) for keyword in node.keywords
    )


def _is_app_target(node: ast.AST) -> bool:
    return isinstance(node, ast.Name) and node.id in {"app", "application"}


def _is_name_target(node: ast.AST) -> bool:
    if isinstance(node, ast.Name):
        return True
    if isinstance(node, (ast.Tuple, ast.List)):
        return all(_is_name_target(item) for item in node.elts)
    return False


def _is_main_guard(node: ast.AST) -> bool:
    if not isinstance(node, ast.If):
        return False
    test = node.test
    if not isinstance(test, ast.Compare) or len(test.ops) != 1 or len(test.comparators) != 1:
        return False
    if not isinstance(test.ops[0], ast.Eq):
        return False
    left = test.left
    right = test.comparators[0]
    return (
        isinstance(left, ast.Name)
        and left.id == "__name__"
        and isinstance(right, ast.Constant)
        and right.value == "__main__"
    )


def _validate_safe_route_decorator(decorator: ast.AST) -> bool:
    if not isinstance(decorator, ast.Call):
        return False
    func = decorator.func
    if not isinstance(func, ast.Attribute):
        return False
    value = func.value
    if not isinstance(value, ast.Name) or value.id not in {"app", "application"}:
        return False
    decorator_name = func.attr
    if decorator_name in _INVALID_METHOD_DECORATORS:
        raise FaaSValidationError(
            f"Flask has no @app.{decorator_name} decorator; "
            f'use @app.route(path, methods=["{decorator_name.upper()}"]) instead'
        )
    if decorator_name not in _FLASK_METHOD_DECORATORS and decorator_name != "route":
        return False
    if not decorator.args:
        raise FaaSValidationError("Flask route decorator must include a literal path")
    if _literal_string(decorator.args[0]) is None:
        raise FaaSValidationError("Flask route path must be a string literal")
    for extra_arg in decorator.args[1:]:
        if not _is_literal_value(extra_arg):
            raise FaaSValidationError("Flask route decorator arguments must be literal values")
    for keyword in decorator.keywords:
        if keyword.arg == "methods":
            if _literal_methods(keyword.value) is None:
                raise FaaSValidationError("Flask route methods must be a string literal list")
            continue
        if not _is_literal_value(keyword.value):
            raise FaaSValidationError("Flask route decorator keyword arguments must be literal values")
    return True


def _annotation_is_safe(node: ast.AST | None) -> bool:
    if node is None:
        return True
    return not any(isinstance(child, ast.Call) for child in ast.walk(node))


def _validate_top_level_function_shape(node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
    for decorator in node.decorator_list:
        if not _validate_safe_route_decorator(decorator):
            raise FaaSValidationError("function decorators must be literal Flask route decorators")
    for default in [*node.args.defaults, *[item for item in node.args.kw_defaults if item is not None]]:
        if not _is_literal_value(default):
            raise FaaSValidationError("function default arguments must be literal values")
    if not _annotation_is_safe(node.returns):
        raise FaaSValidationError("function annotations must not call runtime code")
    for arg in [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs]:
        if not _annotation_is_safe(arg.annotation):
            raise FaaSValidationError("function annotations must not call runtime code")
    if node.args.vararg and not _annotation_is_safe(node.args.vararg.annotation):
        raise FaaSValidationError("function annotations must not call runtime code")
    if node.args.kwarg and not _annotation_is_safe(node.args.kwarg.annotation):
        raise FaaSValidationError("function annotations must not call runtime code")


def _validate_top_level_class_shape(node: ast.ClassDef) -> None:
    if node.decorator_list:
        raise FaaSValidationError("class decorators are not allowed in FaaS app.py")
    if any(isinstance(child, ast.Call) for base in [*node.bases, *[kw.value for kw in node.keywords]] for child in ast.walk(base)):
        raise FaaSValidationError("class bases must not call runtime code")
    for item in node.body:
        if isinstance(item, ast.Pass):
            continue
        if isinstance(item, ast.Expr) and isinstance(item.value, ast.Constant):
            continue
        if isinstance(item, ast.AnnAssign):
            if not _is_name_target(item.target):
                raise FaaSValidationError("class fields must use simple names")
            if not _annotation_is_safe(item.annotation):
                raise FaaSValidationError("class annotations must not call runtime code")
            if item.value is not None and not _is_literal_value(item.value):
                raise FaaSValidationError("class field defaults must be literal values")
            continue
        if isinstance(item, ast.Assign):
            if all(_is_name_target(target) for target in item.targets) and _is_literal_value(item.value):
                continue
        raise FaaSValidationError(
            "classes in FaaS app.py are restricted to simple model fields and literal defaults"
        )


def _validate_top_level_shape(tree: ast.Module) -> bool:
    has_flask_app = False
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            continue
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            _validate_top_level_function_shape(node)
            continue
        if isinstance(node, ast.ClassDef):
            _validate_top_level_class_shape(node)
            continue
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
            continue
        if isinstance(node, ast.Assign):
            if any(_is_app_target(target) for target in node.targets):
                if not _is_flask_constructor(node.value):
                    raise FaaSValidationError("app.py must initialize app/application with Flask(...)")
                has_flask_app = True
                continue
            if all(_is_name_target(target) for target in node.targets) and _is_literal_value(node.value):
                continue
        if isinstance(node, ast.AnnAssign):
            if _is_app_target(node.target):
                if not _is_flask_constructor(node.value):
                    raise FaaSValidationError("app.py must initialize app/application with Flask(...)")
                has_flask_app = True
                continue
            if _is_name_target(node.target) and (node.value is None or _is_literal_value(node.value)):
                continue
        if _is_main_guard(node):
            continue
        raise FaaSValidationError(
            "app.py top-level code is restricted to imports, Flask app initialization, "
            "literal constants, route functions, and an optional __main__ guard"
        )
    return has_flask_app


def _canonical_route_path(path: str) -> str:
    """Canonicalize a Flask route path for declared-vs-implemented comparison.

    Path params are matched by shape, ignoring the variable name and any Flask
    converter, so ``/items/<item_id>``, ``/items/<int:item_id>`` and
    ``/items/<id>`` are treated as the same route. A ``<path:...>`` catch-all
    stays distinct from a single-segment param because it consumes multiple
    segments. This mirrors the runtime invoke matcher
    (``faas._route_pattern_matches``) so the deploy gate never rejects a declared
    route that app.py will in fact serve only because the param name or converter
    differs between the declaration and the decorator.
    """
    parts = []
    for seg in path.strip("/").split("/"):
        if seg.startswith("<") and seg.endswith(">"):
            inner = seg[1:-1]
            parts.append("<path>" if inner.startswith("path:") else "<var>")
        else:
            parts.append(seg)
    return "/" + "/".join(parts)


def _extract_flask_routes(tree: ast.AST) -> dict[str, set[str]]:
    routes: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for decorator in node.decorator_list:
            if not isinstance(decorator, ast.Call):
                continue
            func = decorator.func
            if not isinstance(func, ast.Attribute):
                continue
            value = func.value
            # Accept app/application AND blueprint-style objects (e.g. @bp.route,
            # @api.get) so routes declared across modules in a multi-file service
            # still satisfy the declared-vs-implemented gate.
            if not isinstance(value, ast.Name):
                continue
            decorator_name = func.attr
            if decorator_name in _INVALID_METHOD_DECORATORS:
                raise FaaSValidationError(
                    f"Flask has no @app.{decorator_name} decorator; "
                    f'use @app.route(path, methods=["{decorator_name.upper()}"]) instead'
                )
            if decorator_name not in _FLASK_METHOD_DECORATORS and decorator_name != "route":
                continue
            if not decorator.args:
                raise FaaSValidationError("Flask route decorator must include a literal path")
            route_path = _literal_string(decorator.args[0])
            if not route_path:
                raise FaaSValidationError("Flask route path must be a string literal")
            if not route_path.startswith("/"):
                route_path = "/" + route_path
            if route_path in _RESERVED_ROUTE_PATHS:
                raise FaaSValidationError(f"route path is reserved by MyApp FaaS runtime: {route_path}")
            if decorator_name == "route":
                methods: set[str] | None = None
                for keyword in decorator.keywords:
                    if keyword.arg == "methods":
                        methods = _literal_methods(keyword.value)
                        if methods is None:
                            raise FaaSValidationError("Flask route methods must be a string literal list")
                        break
                if not methods:
                    methods = {"GET"}
            else:
                methods = {_FLASK_METHOD_DECORATORS[decorator_name]}
            routes.setdefault(_canonical_route_path(route_path), set()).update(methods)
    return routes


def _validate_declared_routes_implemented(routes: list[dict[str, Any]], implemented: dict[str, set[str]]) -> None:
    if not routes:
        return
    for route in routes:
        path = str(route.get("path") or "/")
        methods = {str(method).strip().upper() for method in (route.get("methods") or ["GET"])}
        actual = implemented.get(_canonical_route_path(path))
        if actual is None:
            raise FaaSValidationError(f"declared route is not implemented in app.py: {path}")
        missing = sorted(methods - actual)
        if missing:
            raise FaaSValidationError(
                f"declared route methods are not implemented in app.py: {path} {','.join(missing)}"
            )


def _local_module_roots(files: dict[str, str]) -> set[str]:
    """Top-level importable names the bundle itself defines, so a multi-file
    service can import its own sibling modules/packages (``from helpers import
    x``, ``import lib.util``). app.py is the entrypoint, not an importable name."""
    roots: set[str] = set()
    for path in files:
        if not path.endswith(".py"):
            continue
        head = path.split("/", 1)[0]
        roots.add(head[:-3] if head == path else head)
    roots.discard("app")
    return {root for root in roots if root}


def _check_safe_python(tree: ast.AST, *, filename: str, local_modules: set[str]) -> None:
    """Capability sandbox enforced on EVERY .py file in a bundle: imports limited
    to the stdlib/framework whitelist plus the bundle's own modules, and no
    dangerous builtins (eval/exec/open/__import__), forbidden names, or dunder
    attribute access. This is the real security boundary; it applies to helper
    modules exactly as it does to app.py."""
    allowed_imports = _ALLOWED_IMPORT_ROOTS | local_modules
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root = alias.name.split(".", 1)[0]
                if root not in allowed_imports:
                    raise FaaSValidationError(f"import is not allowed ({filename}): {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.level > 0:
                continue  # relative import of a sibling module within this bundle
            root = (node.module or "").split(".", 1)[0]
            if root and root not in allowed_imports:
                raise FaaSValidationError(f"import is not allowed ({filename}): {node.module}")
        elif isinstance(node, ast.Call):
            target = node.func
            name = target.id if isinstance(target, ast.Name) else ""
            if name in _FORBIDDEN_CALLS:
                raise FaaSValidationError(f"call is not allowed ({filename}): {name}")
        elif isinstance(node, ast.Name) and node.id in _FORBIDDEN_NAMES:
            raise FaaSValidationError(f"name is not allowed ({filename}): {node.id}")
        elif isinstance(node, ast.Attribute):
            attr = node.attr
            # Block ALL leading-underscore attributes (covers dunder traversal like
            # __class__/__bases__ AND the single-underscore escape random._os/uuid._os).
            if attr.startswith("_"):
                raise FaaSValidationError(f"private/dunder attribute is not allowed ({filename}): {attr}")
            # Block os/process/FFI re-exposure even via public attribute names
            # (e.g. urllib.request.os, uuid.os).
            if attr in _FORBIDDEN_ATTR_NAMES:
                raise FaaSValidationError(f"attribute is not allowed ({filename}): {attr}")
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            # str.format()-based attribute traversal escape (see _FORMAT_DUNDER_RE).
            if _FORMAT_DUNDER_RE.search(node.value):
                raise FaaSValidationError(
                    f"format-string attribute traversal is not allowed ({filename})"
                )


def _validate_app_py_shape(text: str) -> ast.AST:
    """app.py-only: must be a declarative Flask entrypoint exposing app/application.
    Helper modules are NOT shape-restricted (they can hold real classes/functions),
    they only pass the capability sandbox above."""
    try:
        tree = ast.parse(text, filename="app.py")
    except SyntaxError as exc:
        raise FaaSValidationError(f"app.py syntax error: {exc}") from exc
    if not _validate_top_level_shape(tree):
        raise FaaSValidationError("app.py must expose a Flask instance named app or application")
    return tree


def _validate_bundle_python(files: dict[str, str], routes: list[dict[str, Any]]) -> None:
    """Validate every .py file in a (possibly multi-file) bundle: app.py shape +
    capability sandbox on all modules, with declared routes checked against the
    decorators found across ALL modules (so blueprints in helper files count)."""
    local_modules = _local_module_roots(files)
    implemented: dict[str, set[str]] = {}
    for path, content in files.items():
        if not path.endswith(".py"):
            continue
        if path == "app.py":
            tree = _validate_app_py_shape(content)
        else:
            try:
                tree = ast.parse(content, filename=path)
            except SyntaxError as exc:
                raise FaaSValidationError(f"{path} syntax error: {exc}") from exc
        _check_safe_python(tree, filename=path, local_modules=local_modules)
        for route_path, methods in _extract_flask_routes(tree).items():
            implemented.setdefault(route_path, set()).update(methods)
    _validate_declared_routes_implemented(routes or [], implemented)


def _normalize_routes(raw: Any) -> list[dict[str, Any]]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise FaaSValidationError("routes must be a list")
    out: list[dict[str, Any]] = []
    for item in raw[:50]:
        if not isinstance(item, dict):
            raise FaaSValidationError("route item must be an object")
        path = str(item.get("path") or "/").strip()
        if not path.startswith("/"):
            path = "/" + path
        if path in _RESERVED_ROUTE_PATHS:
            raise FaaSValidationError(f"route path is reserved by MyApp FaaS runtime: {path}")
        if ".." in path or len(path) > 160:
            raise FaaSValidationError(f"invalid route path: {path}")
        methods_raw = item.get("methods") or item.get("method") or ["GET"]
        if isinstance(methods_raw, str):
            methods = [methods_raw]
        elif isinstance(methods_raw, list):
            methods = methods_raw
        else:
            raise FaaSValidationError(f"invalid methods for route: {path}")
        clean_methods = []
        for method in methods:
            value = str(method).strip().upper()
            if value not in {"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"}:
                raise FaaSValidationError(f"unsupported route method: {value}")
            if value not in clean_methods:
                clean_methods.append(value)
        out.append({
            "path": path,
            "methods": clean_methods,
            "description": str(item.get("description") or "")[:300],
        })
    return out


def validate_bundle(bundle: dict[str, Any], *, default_slug: str = "") -> dict[str, Any]:
    if not FAAS_ENABLED:
        raise FaaSValidationError("FaaS backend generation is disabled")
    if not isinstance(bundle, dict):
        raise FaaSValidationError("FaaS bundle must be a JSON object")
    encoded = json.dumps(bundle, ensure_ascii=False).encode("utf-8")
    if len(encoded) > FAAS_BUNDLE_MAX_BYTES:
        raise FaaSValidationError(f"FaaS bundle too large: {len(encoded)} bytes")

    raw_service = bundle.get("service") or {}
    if not isinstance(raw_service, dict):
        raise FaaSValidationError("bundle.service must be an object")
    service_slug = _safe_slug(str(raw_service.get("slug") or bundle.get("slug") or default_slug), "service")
    requested_id = str(raw_service.get("service_id") or bundle.get("service_id") or "").strip()
    service_id = _safe_id(requested_id, f"svc-{uuid.uuid4().hex[:12]}")
    routes = _normalize_routes(raw_service.get("routes") or bundle.get("routes") or [])

    files = bundle.get("files")
    if not isinstance(files, dict):
        raise FaaSValidationError("bundle.files must be an object")
    if len(files) > _MAX_BUNDLE_FILES:
        raise FaaSValidationError(f"too many files in bundle: {len(files)} (max {_MAX_BUNDLE_FILES})")
    normalized_files: dict[str, str] = {}
    for raw_path, raw_content in files.items():
        path = _validate_file_path(str(raw_path))
        if not isinstance(raw_content, str):
            raise FaaSValidationError(f"file content must be a string: {path}")
        data = raw_content.encode("utf-8")
        if len(data) > FAAS_FILE_MAX_BYTES:
            raise FaaSValidationError(f"file too large: {path}")
        normalized_files[path] = raw_content.replace("\r\n", "\n")
    if "app.py" not in normalized_files:
        raise FaaSValidationError("bundle must include app.py")
    if "requirements.txt" in normalized_files:
        _validate_requirements(normalized_files["requirements.txt"])
    else:
        normalized_files["requirements.txt"] = "flask==3.0.3\n"
    _validate_bundle_python(normalized_files, routes)

    service_json = {
        "service_id": service_id,
        "slug": service_slug,
        "runtime": "python-flask",
        "routes": routes,
        "updated_at_ms": int(time.time() * 1000),
    }
    normalized_files["service.json"] = json.dumps(service_json, indent=2, ensure_ascii=False) + "\n"
    if "README.md" not in normalized_files:
        normalized_files["README.md"] = f"# {service_slug}\n\nGenerated MyApp FaaS service.\n"

    # A service uses the per-user database if it ships a schema.sql, opts in via
    # service.db, or imports the myapp_db helper in any module. That triggers
    # provisioning + DSN injection at deploy time.
    schema_sql = normalized_files.get(_SCHEMA_SQL_FILE, "")
    uses_helper = any(
        path.endswith(".py") and "myapp_db" in content
        for path, content in normalized_files.items()
    )
    db_enabled = bool(schema_sql) or bool(raw_service.get("db")) or uses_helper

    return {
        "service_id": service_id,
        "service_slug": service_slug,
        "routes": routes,
        "files": normalized_files,
        "meta": raw_service.get("meta") if isinstance(raw_service.get("meta"), dict) else {},
        "db_enabled": db_enabled,
        "schema_sql": schema_sql,
    }


def _write_service_files(root: Path, files: dict[str, str]) -> None:
    tmp = root.with_name(root.name + f".tmp-{uuid.uuid4().hex[:8]}")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True, exist_ok=True)
    for rel, content in files.items():
        target = tmp / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    if root.exists():
        backup = root.with_name(root.name + f".bak-{uuid.uuid4().hex[:8]}")
        root.rename(backup)
    else:
        backup = None
    try:
        tmp.rename(root)
        if backup:
            shutil.rmtree(backup, ignore_errors=True)
    except Exception:
        if root.exists():
            shutil.rmtree(root, ignore_errors=True)
        if backup:
            backup.rename(root)
        raise


def _run_git(args: list[str], *, cwd: Path, check: bool = False) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.update({
        "GIT_AUTHOR_NAME": FAAS_GIT_AUTHOR_NAME,
        "GIT_AUTHOR_EMAIL": FAAS_GIT_AUTHOR_EMAIL,
        "GIT_COMMITTER_NAME": FAAS_GIT_AUTHOR_NAME,
        "GIT_COMMITTER_EMAIL": FAAS_GIT_AUTHOR_EMAIL,
    })
    if FAAS_GIT_SSH_KEY_PATH:
        ssh_parts = [
            "ssh",
            "-i",
            FAAS_GIT_SSH_KEY_PATH,
            "-o",
            "IdentitiesOnly=yes",
        ]
        if FAAS_GIT_KNOWN_HOSTS_PATH:
            ssh_parts.extend([
                "-o",
                f"UserKnownHostsFile={FAAS_GIT_KNOWN_HOSTS_PATH}",
                "-o",
                "StrictHostKeyChecking=yes",
            ])
        else:
            ssh_parts.extend(["-o", "StrictHostKeyChecking=accept-new"])
        env["GIT_SSH_COMMAND"] = " ".join(shlex.quote(part) for part in ssh_parts)
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    if check and proc.returncode != 0:
        raise FaaSError((proc.stderr or proc.stdout or "git command failed").strip())
    return proc


def _ensure_git_repo(root: Path) -> None:
    if not FAAS_GIT_ENABLED:
        return
    root.mkdir(parents=True, exist_ok=True)
    if not (root / ".git").exists():
        _run_git(["init", "-b", FAAS_GIT_BRANCH], cwd=root, check=True)
    if FAAS_GIT_REMOTE:
        remote = _run_git(["remote", "get-url", "origin"], cwd=root)
        if remote.returncode != 0:
            _run_git(["remote", "add", "origin", FAAS_GIT_REMOTE], cwd=root, check=True)
        elif remote.stdout.strip() != FAAS_GIT_REMOTE:
            _run_git(["remote", "set-url", "origin", FAAS_GIT_REMOTE], cwd=root, check=True)


def _git_commit_service(repo_root: Path, service_rel: Path, service_id: str) -> str:
    if not FAAS_GIT_ENABLED:
        return ""
    _ensure_git_repo(repo_root)
    _run_git(["add", str(service_rel)], cwd=repo_root, check=True)
    diff = _run_git(["diff", "--cached", "--quiet"], cwd=repo_root)
    if diff.returncode == 0:
        head = _run_git(["rev-parse", "--verify", "HEAD"], cwd=repo_root)
        return head.stdout.strip() if head.returncode == 0 else ""
    _run_git(["commit", "-m", f"deploy faas service {service_id}"], cwd=repo_root, check=True)
    head = _run_git(["rev-parse", "--verify", "HEAD"], cwd=repo_root, check=True).stdout.strip()
    if FAAS_GIT_PUSH_ENABLED:
        _run_git(["push", "-u", "origin", f"HEAD:{FAAS_GIT_BRANCH}"], cwd=repo_root, check=True)
    return head


def _docker_client():
    try:
        import docker
    except ModuleNotFoundError as exc:
        raise FaaSError("python docker package is required for FAAS_DEPLOY_MODE=local-docker") from exc
    try:
        return docker.from_env()
    except Exception as exc:
        raise FaaSError(f"cannot connect to Docker daemon for FaaS runtime: {exc}") from exc


def _docker_not_found_type():
    try:
        import docker
        return getattr(docker.errors, "NotFound", None)
    except Exception:
        return None


def _remove_replica(function_name: str, replica: int) -> None:
    client = _docker_client()
    name = _replica_name(function_name, replica)
    try:
        container = client.containers.get(name)
    except Exception as exc:
        not_found = _docker_not_found_type()
        if not_found and isinstance(exc, not_found):
            return
        raise FaaSError(f"cannot inspect FaaS container {name}: {exc}") from exc
    try:
        container.remove(force=True)
    except Exception as exc:
        raise FaaSError(f"cannot remove FaaS container {name}: {exc}") from exc


def _remove_local_docker_runtime(function_name: str) -> None:
    """Remove ALL replica containers of a service (running or stopped) — destroy."""
    client = _docker_client()
    base = _local_container_name(function_name)
    try:
        containers = client.containers.list(
            all=True, filters={"label": f"myapp.faas.function_name={function_name}"}
        )
    except Exception:
        containers = []
    found = False
    for c in containers:
        if c.name == base or c.name.startswith(base + "-r"):
            found = True
            try:
                c.remove(force=True)
            except Exception as exc:
                raise FaaSError(f"cannot remove FaaS container {c.name}: {exc}") from exc
    if not found:
        _remove_replica(function_name, 0)


def _wait_local_docker_runtime(function_name: str, replica: int = 0) -> None:
    import requests

    url = f"{_replica_upstream(function_name, replica)}/__myapp_faas_health"
    deadline = time.time() + max(1, FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS)
    last_error = ""
    while time.time() < deadline:
        try:
            resp = requests.get(url, timeout=1.0)
            if resp.status_code == 200:
                return
            last_error = f"status={resp.status_code} body={resp.text[:200]}"
        except Exception as exc:
            last_error = str(exc)
        time.sleep(0.3)
    raise FaaSError(f"FaaS runtime did not become healthy: {last_error}")


def _start_local_docker_runtime(root: Path, *, function_name: str, service_id: str, commit_sha: str, db_dsn: str = "", replica: int = 0) -> str:
    client = _docker_client()
    name = _replica_name(function_name, replica)
    container_code_root = Path(FAAS_CODE_ROOT).resolve()
    host_code_root = Path(FAAS_LOCAL_DOCKER_HOST_CODE_ROOT).resolve()
    if not container_code_root.exists():
        raise FaaSError(f"FaaS code root does not exist in backend container: {container_code_root}")
    service_dir = _local_runtime_service_dir(root)
    _remove_replica(function_name, replica)
    try:
        client.containers.run(
            FAAS_LOCAL_DOCKER_IMAGE,
            command=["python", "/app/backend/faas_runtime_server.py"],
            name=name,
            detach=True,
            network=FAAS_LOCAL_DOCKER_NETWORK,
            environment={
                "PORT": "8080",
                "MYAPP_FAAS_SERVICE_ID": service_id,
                "MYAPP_FAAS_SERVICE_DIR": service_dir,
                "MYAPP_FAAS_FUNCTION_NAME": function_name,
                "MYAPP_FAAS_COMMIT": commit_sha,
                "MYAPP_FAAS_REPLICA": str(replica),
                "PYTHONUNBUFFERED": "1",
                # Scoped per-user DB DSN (internal; read only by the myapp_db
                # helper, never bridged into the public app config).
                **({"MYAPP_DB_DSN": db_dsn} if db_dsn else {}),
                **_platform_runtime_env(),
            },
            labels={
                "myapp.component": "faas-runtime",
                "myapp.faas": "1",
                "myapp.faas.service_id": service_id,
                "myapp.faas.function_name": function_name,
                "myapp.faas.replica": str(replica),
            },
            volumes={
                str(host_code_root): {
                    "bind": FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT,
                    "mode": "ro",
                }
            },
            restart_policy={"Name": "unless-stopped"},
        )
    except Exception as exc:
        raise FaaSError(f"cannot start FaaS runtime container {name}: {exc}") from exc
    _wait_local_docker_runtime(function_name, replica)
    touch_service_activity(service_id)
    return f"local-docker container={name} upstream={_replica_upstream(function_name, replica)}"


def local_docker_upstream_for_service(service: dict[str, Any]) -> str:
    function_name = str(service.get("function_name") or "").strip()
    if not function_name:
        raise FaaSError("service function name is missing")
    return _local_upstream_url(function_name)


def _owner_db_dsn(service: dict[str, Any]) -> str:
    # B2-G3: key the DSN on the service's app tenant (default app → owner schema).
    tenant = _db_tenant_key(service.get("app_id", ""), service.get("owner_user_id", ""))
    if not tenant:
        return ""
    try:
        from faas_userdb import dsn_for_user
    except ModuleNotFoundError:
        from backend.faas_userdb import dsn_for_user
    # B2-G1: do NOT swallow errors — a decryption failure must FAIL CLOSED (abort
    # cold-wake) rather than start a container with an empty/wrong DSN.
    return dsn_for_user(tenant, provision=False) or ""


def _wake_replica_zero(service: dict[str, Any], function_name: str, root: Path, service_id: str, commit_sha: str) -> str:
    """Start replica 0 (fast start() if it exists; recreate with DSN otherwise)."""
    client = _docker_client()
    name = _replica_name(function_name, 0)
    try:
        container = client.containers.get(name)
        container.reload()
        if container.status == "running":
            return _replica_upstream(function_name, 0)
        try:
            container.start()  # env (incl. MYAPP_DB_DSN) preserved
            _wait_local_docker_runtime(function_name, 0)
            return _replica_upstream(function_name, 0)
        except Exception:
            try:
                container.remove(force=True)
            except Exception:
                pass
    except Exception as exc:
        not_found = _docker_not_found_type()
        if not_found and not isinstance(exc, not_found):
            raise FaaSError(f"cannot inspect FaaS container {name}: {exc}") from exc
    _start_local_docker_runtime(
        root, function_name=function_name, service_id=service_id,
        commit_sha=commit_sha, db_dsn=_owner_db_dsn(service), replica=0,
    )
    return _replica_upstream(function_name, 0)


def ensure_local_docker_runtime_for_service(service: dict[str, Any]) -> str:
    """Cold-wake + load-balanced route for the self-managed Docker FaaS. Single
    front door (invoke proxy): route round-robin across running replicas; if none
    are running (scaled to zero), wake replica 0 (start() preserves the DB DSN, or
    recreate re-injecting it). Records activity so the reaper knows it is live."""
    function_name = str(service.get("function_name") or "").strip()
    service_id = str(service.get("service_id") or "").strip()
    active_path = str(service.get("active_path") or "").strip()
    commit_sha = str(service.get("active_commit") or "").strip()
    if not function_name or not service_id or not active_path:
        raise FaaSError("service is missing runtime metadata")
    touch_service_activity(service_id)
    running = _running_replicas(function_name)
    if running:
        idx = _RR_COUNTER.get(function_name, 0)
        _RR_COUNTER[function_name] = idx + 1
        return _replica_upstream(function_name, running[idx % len(running)])
    return _wake_replica_zero(service, function_name, Path(active_path), service_id, commit_sha)


def _set_service_replicas(service_id: str, replicas: int) -> None:
    try:
        db_execute(
            "UPDATE faas_services SET meta_json = jsonb_set(coalesce(meta_json, '{}')::jsonb, "
            "'{deploy,replicas}', %s::jsonb, true), updated_at = NOW() WHERE service_id = %s",
            [json.dumps(int(replicas)), service_id],
        )
    except Exception:
        pass


def scale_service(owner_user_id: str, service_id: str, replicas: int, *, acting_user: str = "") -> dict[str, Any]:
    """扩容/缩容: set the number of running replica containers for a docker-mode
    service. replicas=0 scales to zero (kept warm-recreatable); >1 runs multiple
    load-balanced replicas. Capped at FAAS_DOCKER_MAX_REPLICAS.

    X-G1: the owner OR a maintainer of the service's app may scale."""
    if not owner_user_id:
        raise FaaSValidationError("owner_user_id is required")
    acting_user = str(acting_user or "").strip() or owner_user_id
    replicas = max(0, min(int(replicas), FAAS_DOCKER_MAX_REPLICAS))
    ensure_tables()
    service = get_service(service_id)
    if not service or service.get("owner_user_id") != owner_user_id:
        raise FaaSValidationError("service not found")
    if not can_manage_service(acting_user, service):
        raise FaaSValidationError("not authorized to scale this service")
    if service_deploy_mode(service) not in _LOCAL_DOCKER_MODES:
        raise FaaSValidationError("scaling is only supported for docker-mode services")
    function_name = str(service.get("function_name") or "").strip()
    root = Path(str(service.get("active_path") or "").strip())
    commit_sha = str(service.get("active_commit") or "").strip()
    db_dsn = _owner_db_dsn(service)
    touch_service_activity(service_id)
    client = _docker_client()
    # Bring up replicas 0..replicas-1
    for i in range(replicas):
        name = _replica_name(function_name, i)
        started = False
        try:
            c = client.containers.get(name)
            c.reload()
            if c.status == "running":
                started = True
            else:
                try:
                    c.start()
                    _wait_local_docker_runtime(function_name, i)
                    started = True
                except Exception:
                    try:
                        c.remove(force=True)
                    except Exception:
                        pass
        except Exception:
            pass
        if not started:
            _start_local_docker_runtime(
                root, function_name=function_name, service_id=service_id,
                commit_sha=commit_sha, db_dsn=db_dsn, replica=i,
            )
    # Remove replicas >= the new count (scale down / clean stopped extras). Always
    # reconcile the recorded count to what is actually running — even if a removal
    # throws mid-loop — so meta_json.deploy.replicas never contradicts reality.
    try:
        for i in range(replicas, FAAS_DOCKER_MAX_REPLICAS + 1):
            _remove_replica(function_name, i)
    finally:
        _set_service_replicas(service_id, len(_running_replicas(function_name)))
    return {"service_id": service_id, "replicas": replicas, "running": _running_replicas(function_name)}


def _platform_runtime_env() -> dict[str, str]:
    """Public, NON-SECRET platform config injected into every FaaS function.

    The runtime (faas_runtime_server.py) bridges these MYAPP_CFG_* env vars into
    the generated app's ``app.config["MYAPP"]``; user code reads
    ``current_app.config["MYAPP"]["supabase_url"]`` etc. and builds URLs from
    config instead of hardcoding domains — so changing a domain is a redeploy,
    not a code edit. Only public/non-secret values go here (the anon key is a
    public client key); NEVER inject service-role keys, the runtime token, or the
    bundle URL. Empty values are dropped so a missing config key is absent rather
    than an empty string.
    """
    values = {
        "MYAPP_CFG_SUPABASE_URL": (SUPABASE_URL or "").rstrip("/"),
        # B0-G1 (R13): anon key is NOT injected by default. Although it is a public
        # client key, pairing it with the function's egress lets owner code drive
        # GoTrue's public auth surface (signup/recovery/OTP/anon-RLS). Opt in via
        # FAAS_INJECT_SUPABASE_ANON_KEY=1 only for services that provably need it.
        "MYAPP_CFG_SUPABASE_ANON_KEY": (SUPABASE_ANON_KEY or "") if FAAS_INJECT_SUPABASE_ANON_KEY else "",
        "MYAPP_CFG_BACKEND_BASE_URL": (FAAS_PUBLIC_BASE_URL or "").rstrip("/"),
        "MYAPP_CFG_FAAS_PUBLIC_BASE_URL": (FAAS_NODE_PUBLIC_URL or "").rstrip("/"),
    }
    return {key: value for key, value in values.items() if value}


def _deploy_service(root: Path, *, function_name: str, service_id: str, commit_sha: str, db_dsn: str = "") -> tuple[str, str]:
    mode = FAAS_DEPLOY_MODE
    if mode in {"", "metadata", "none", "disabled"}:
        return "ready", ""
    if mode in _LOCAL_DOCKER_MODES:
        if FAAS_LOCAL_DOCKER_START_ON_DEPLOY:
            return "ready", _start_local_docker_runtime(
                root,
                function_name=function_name,
                service_id=service_id,
                commit_sha=commit_sha,
                db_dsn=db_dsn,
            )
        _remove_local_docker_runtime(function_name)
        return "ready", f"local-docker deferred upstream={_local_upstream_url(function_name)}"
    if mode == "script":
        if not FAAS_DEPLOY_SCRIPT:
            raise FaaSError("FAAS_DEPLOY_SCRIPT is required for FAAS_DEPLOY_MODE=script")
        proc = subprocess.run(
            [FAAS_DEPLOY_SCRIPT, str(root), function_name, service_id, commit_sha],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=300,
            check=False,
        )
        if proc.returncode != 0:
            raise FaaSError((proc.stderr or proc.stdout or "FaaS deploy script failed").strip())
        return "ready", (proc.stdout or "").strip()[:2000]
    raise FaaSError(f"unsupported FaaS deploy mode: {mode}")


def disable_service(owner_user_id: str, service_id: str) -> dict[str, Any]:
    if not owner_user_id:
        raise FaaSValidationError("owner_user_id is required")
    ensure_tables()
    service = get_service(service_id)
    if not service or service.get("owner_user_id") != owner_user_id:
        raise FaaSValidationError("service not found")
    function_name = str(service.get("function_name") or "").strip()
    warnings: list[str] = []
    svc_mode = service_deploy_mode(service)
    if function_name and svc_mode in _LOCAL_DOCKER_MODES:
        try:
            _remove_local_docker_runtime(function_name)
        except FaaSError as exc:
            warnings.append(str(exc))
    db_execute(
        "UPDATE faas_services SET status = 'disabled', updated_at = NOW() WHERE service_id = %s",
        [service_id],
    )
    service["status"] = "disabled"
    service["warnings"] = warnings
    return service


def delete_service(owner_user_id: str, service_id: str) -> dict[str, Any]:
    """Hard-delete a service: remove ALL replica containers, drop the DB row, and
    clean its activity + code. Works on any status, INCLUDING 'disabled' — this is
    how a disabled/orphaned service is permanently removed."""
    if not owner_user_id:
        raise FaaSValidationError("owner_user_id is required")
    ensure_tables()
    service = get_service(service_id)
    if not service or service.get("owner_user_id") != owner_user_id:
        raise FaaSValidationError("service not found")
    function_name = str(service.get("function_name") or "").strip()
    warnings: list[str] = []
    if function_name and service_deploy_mode(service) in _LOCAL_DOCKER_MODES:
        try:
            _remove_local_docker_runtime(function_name)
        except FaaSError as exc:
            warnings.append(str(exc))
    db_execute("DELETE FROM faas_services WHERE service_id = %s", [service_id])
    try:
        _activity_path(service_id).unlink()
    except Exception:
        pass
    try:
        code_root = service_code_root(owner_user_id, service_id)
        if code_root.exists():
            shutil.rmtree(code_root, ignore_errors=True)
    except Exception as exc:
        warnings.append(f"code cleanup: {exc}")
    return {"service_id": service_id, "deleted": True, "warnings": warnings}


def running_replica_counts() -> dict[str, int]:
    """Real running-container count per function_name in ONE docker query — the
    single source of truth for instance counts (0 = scaled to zero / stopped).
    Returns {} on any docker error or non-docker host."""
    counts: dict[str, int] = {}
    try:
        client = _docker_client()
        containers = client.containers.list(
            filters={"label": "myapp.faas=1", "status": "running"}
        )
    except Exception:
        return counts
    for c in containers:
        try:
            fn = (c.labels or {}).get("myapp.faas.function_name", "")
        except Exception:
            fn = ""
        if fn:
            counts[fn] = counts.get(fn, 0) + 1
    return counts


def deploy_bundle(owner_user_id: str, bundle: dict[str, Any], *, source: str = "agent", acting_user: str = "") -> FaaSDeployResult:
    if not owner_user_id:
        raise FaaSValidationError("owner_user_id is required")
    # B2-G4: separate the ACTING user (the human performing the deploy) from the
    # RESOURCE owner. All resource keying (schema, code root, owner column) uses
    # owner_user_id; acting_user is only for authz + audit. Defaults to the owner.
    acting_user = str(acting_user or "").strip() or owner_user_id
    ensure_tables()
    normalized = validate_bundle(bundle)
    service_id = normalized["service_id"]
    lock = _service_lock(f"{owner_user_id}:{service_id}")
    with lock:
        existing = get_service(service_id)
        if existing:
            if existing.get("owner_user_id") != owner_user_id:
                raise FaaSValidationError("service_id already belongs to another user")
            # X-G1: the owner OR a maintainer of the service's app may redeploy.
            if not can_manage_service(acting_user, existing):
                raise FaaSValidationError("not authorized to modify this service")
        else:
            # A new service can only be created as one's OWN (maintainers act on
            # existing apps they were added to, never create services for others).
            if acting_user != owner_user_id:
                raise FaaSValidationError("cannot create a service owned by another user")
            if _count_user_services(owner_user_id) >= max(1, FAAS_MAX_SERVICES_PER_USER):
                raise FaaSValidationError(f"service limit exceeded: max {FAAS_MAX_SERVICES_PER_USER}")

        function_name = existing.get("function_name") if existing else _function_name(owner_user_id, service_id)
        root = service_code_root(owner_user_id, service_id)
        repo_root = Path(FAAS_CODE_ROOT)
        service_rel = root.relative_to(repo_root)
        deployment_id = f"dep-{uuid.uuid4().hex}"
        routes = normalized["routes"]
        meta_json = _meta_with_current_deploy(normalized["meta"])
        # B1-G1: bind the service to its application (default per-owner app unless
        # the bundle declares meta.app_id). On redeploy, keep the existing binding.
        app_id = existing.get("app_id") if (existing and existing.get("app_id")) else None
        if not app_id:
            app_id, app_appid = _resolve_app_id(owner_user_id, normalized["meta"])
            ensure_application(app_id, owner_user_id, appid=app_appid,
                               name=normalized.get("service_slug", ""))
        summary = {
            "source": source,
            "acting_user": acting_user,  # B2-G4 audit: who performed this deploy
            "service_slug": normalized["service_slug"],
            "route_count": len(routes),
            "files": sorted(normalized["files"]),
        }
        db_execute(
            """
            INSERT INTO faas_services (
                service_id, owner_user_id, app_id, service_slug, function_name, status,
                active_path, public_base_url, routes, meta_json
            )
            VALUES (%s, %s, %s, %s, %s, 'deploying', %s, %s, %s::jsonb, %s::jsonb)
            ON CONFLICT (service_id)
            DO UPDATE SET
                service_slug = EXCLUDED.service_slug,
                status = 'deploying',
                active_path = EXCLUDED.active_path,
                public_base_url = EXCLUDED.public_base_url,
                routes = EXCLUDED.routes,
                meta_json = EXCLUDED.meta_json,
                updated_at = NOW()
            """,
            [
                service_id,
                owner_user_id,
                app_id,
                normalized["service_slug"],
                function_name,
                str(root),
                FAAS_PUBLIC_BASE_URL,
                json.dumps(routes, ensure_ascii=False),
                json.dumps(meta_json, ensure_ascii=False),
            ],
        )
        db_execute(
            """
            INSERT INTO faas_deployments
                (deployment_id, service_id, owner_user_id, status, bundle_summary)
            VALUES (%s, %s, %s, 'pending', %s::jsonb)
            """,
            [deployment_id, service_id, owner_user_id, json.dumps(summary, ensure_ascii=False)],
        )
        try:
            _write_service_files(root, normalized["files"])
            # Per-user database: provision the owner's schema+role (idempotent),
            # run the declared schema.sql migration into it, and obtain the scoped
            # DSN to inject into the runtime. B2-G3: provision is keyed on the app
            # TENANT (default app → owner's existing schema; custom app → its own),
            # so an owner's distinct apps don't share a database.
            db_dsn = ""
            if normalized.get("db_enabled"):
                try:
                    from faas_userdb import provision_user_db, run_user_migration
                except ModuleNotFoundError:
                    from backend.faas_userdb import provision_user_db, run_user_migration
                db_tenant = _db_tenant_key(app_id, owner_user_id)
                db_info = provision_user_db(db_tenant)
                db_dsn = db_info["dsn"]
                if normalized.get("schema_sql"):
                    run_user_migration(db_tenant, normalized["schema_sql"])
            if FAAS_GIT_ENABLED and FAAS_GIT_ASYNC_PUSH:
                # Hand the commit+push to the isolated worker (outside the request
                # path). The runtime still gets code from the local write above /
                # the runtime-bundle endpoint, so the deploy does not block on git.
                try:
                    from faas_push_worker import enqueue_push_job, ensure_tables as _ensure_push_tables
                except ModuleNotFoundError:
                    from backend.faas_push_worker import enqueue_push_job, ensure_tables as _ensure_push_tables
                _ensure_push_tables()
                enqueue_push_job(
                    owner_user_id,
                    service_id,
                    str(service_rel),
                    normalized["files"],
                    f"deploy faas service {service_id}",
                )
                commit_sha = ""
            else:
                commit_sha = _git_commit_service(repo_root, service_rel, service_id)
            status, deploy_output = _deploy_service(
                root,
                function_name=function_name,
                service_id=service_id,
                commit_sha=commit_sha,
                db_dsn=db_dsn,
            )
            db_execute(
                """
                UPDATE faas_services
                SET status = %s, active_commit = %s, active_path = %s,
                    public_base_url = %s, updated_at = NOW()
                WHERE service_id = %s
                """,
                [status, commit_sha, str(root), FAAS_PUBLIC_BASE_URL, service_id],
            )
            db_execute(
                """
                UPDATE faas_deployments
                SET status = 'success', commit_sha = %s,
                    bundle_summary = bundle_summary || %s::jsonb,
                    finished_at = NOW()
                WHERE deployment_id = %s
                """,
                [commit_sha, json.dumps({"deploy_output": deploy_output}, ensure_ascii=False), deployment_id],
            )
            return FaaSDeployResult(
                service_id=service_id,
                function_name=function_name,
                status=status,
                commit_sha=commit_sha,
                code_path=str(root),
                public_base_url=FAAS_PUBLIC_BASE_URL,
                routes=routes,
                deployment_id=deployment_id,
            )
        except Exception as exc:
            error = str(exc)[-4000:]
            if existing is None:
                # Brand-new service that never reached a live state: remove the row
                # so a failed first deploy does not permanently consume the user's
                # quota. The 'deploying' guard avoids racing a concurrent success.
                db_execute(
                    "DELETE FROM faas_services WHERE service_id = %s AND status = 'deploying'",
                    [service_id],
                )
            else:
                # Re-deploy of an existing service failed: keep the row but mark it
                # failed (it no longer counts toward quota, and the operator can see
                # the failure). The previously-running function may still be live.
                db_execute(
                    "UPDATE faas_services SET status = 'failed', updated_at = NOW() WHERE service_id = %s",
                    [service_id],
                )
            db_execute(
                "UPDATE faas_deployments SET status = 'failed', error = %s, finished_at = NOW() WHERE deployment_id = %s",
                [error, deployment_id],
            )
            raise


def load_bundle_bytes(data: bytes) -> dict[str, Any]:
    if len(data) > FAAS_BUNDLE_MAX_BYTES:
        raise FaaSValidationError(f"FaaS bundle too large: {len(data)} bytes")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FaaSValidationError(f"invalid FaaS bundle JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise FaaSValidationError("FaaS bundle root must be an object")
    return payload


def _strip_archive_root(files: dict[str, str]) -> dict[str, str]:
    """Tolerate archives created with a single wrapping folder (``zip -r out svc/``
    yields ``svc/app.py``): if app.py is not at the root but exactly one top-level
    directory contains it, strip that prefix so the bundle is root-relative."""
    if "app.py" in files:
        return files
    tops = {name.split("/", 1)[0] for name in files if "/" in name}
    candidates = [top for top in tops if f"{top}/app.py" in files]
    if len(candidates) != 1:
        return files
    prefix = candidates[0] + "/"
    return {name[len(prefix):]: content for name, content in files.items() if name.startswith(prefix)}


def load_bundle_zip(data: bytes) -> dict[str, Any]:
    """Build a deploy bundle from a zip archive of a service folder.

    This is the upload half of the multi-file edit flow: the agent pulls the
    whole svc folder (see build_service_archive), edits any files, repacks, and
    uploads the zip. The backend unpacks it here into the same {service, files}
    shape that validate_bundle + deploy_bundle already consume, so the git +
    deploy pipeline downstream is unchanged. Service metadata (service_id, slug,
    routes) is read from the archive's service.json — reusing the same service_id
    updates the existing service in place.
    """
    import io
    import zipfile

    if len(data) > FAAS_BUNDLE_MAX_BYTES:
        raise FaaSValidationError(f"FaaS archive too large: {len(data)} bytes")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise FaaSValidationError(f"invalid FaaS archive (not a zip): {exc}") from exc

    files: dict[str, str] = {}
    total = 0
    infos = archive.infolist()
    if len(infos) > _MAX_BUNDLE_FILES * 3:
        raise FaaSValidationError(f"archive has too many entries: {len(infos)}")
    for info in infos:
        if info.is_dir():
            continue
        name = info.filename.replace("\\", "/").strip()
        first = name.split("/", 1)[0]
        base = name.rsplit("/", 1)[-1]
        # Skip editor/OS cruft so a zip made on a laptop still validates.
        if first in {"__MACOSX", "__pycache__"} or base in {".DS_Store", ""} or base.startswith("."):
            continue
        if info.file_size > FAAS_FILE_MAX_BYTES:
            raise FaaSValidationError(f"file too large in archive: {name}")
        total += info.file_size
        if total > FAAS_BUNDLE_MAX_BYTES:
            raise FaaSValidationError("archive contents too large")
        raw = archive.read(info)
        try:
            files[name] = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise FaaSValidationError(f"file is not utf-8 text: {name}") from exc

    files = _strip_archive_root(files)
    if "app.py" not in files:
        raise FaaSValidationError("archive must contain app.py at its root")

    service: dict[str, Any] = {}
    raw_service_json = files.get("service.json")
    if raw_service_json:
        try:
            parsed = json.loads(raw_service_json)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            service = {
                "service_id": parsed.get("service_id"),
                "slug": parsed.get("slug"),
                "routes": parsed.get("routes") or [],
            }
    return {"service": service, "files": files}
