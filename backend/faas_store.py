"""User-generated FaaS service storage and deployment helpers.

This module is deliberately backend-owned. Agent runtimes may generate a
structured bundle, but they never receive GitHub/OpenFaaS credentials and never
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
from urllib.parse import quote

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
        FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT,
        FAAS_LOCAL_DOCKER_HOST_CODE_ROOT,
        FAAS_LOCAL_DOCKER_IMAGE,
        FAAS_LOCAL_DOCKER_NETWORK,
        FAAS_LOCAL_DOCKER_START_ON_DEPLOY,
        FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS,
        FAAS_MAX_SERVICES_PER_USER,
        FAAS_DEFAULT_NODE_ID,
        FAAS_OPENFAAS_GATEWAY,
        FAAS_OPENFAAS_MAX_REPLICAS,
        FAAS_OPENFAAS_NODES,
        FAAS_OPENFAAS_MIN_REPLICAS,
        FAAS_OPENFAAS_PASSWORD,
        FAAS_OPENFAAS_READ_TIMEOUT,
        FAAS_OPENFAAS_RUNTIME_IMAGE,
        FAAS_OPENFAAS_SCALE_ZERO,
        FAAS_OPENFAAS_USERNAME,
        FAAS_OPENFAAS_WRITE_TIMEOUT,
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
        FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT,
        FAAS_LOCAL_DOCKER_HOST_CODE_ROOT,
        FAAS_LOCAL_DOCKER_IMAGE,
        FAAS_LOCAL_DOCKER_NETWORK,
        FAAS_LOCAL_DOCKER_START_ON_DEPLOY,
        FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS,
        FAAS_MAX_SERVICES_PER_USER,
        FAAS_DEFAULT_NODE_ID,
        FAAS_OPENFAAS_GATEWAY,
        FAAS_OPENFAAS_MAX_REPLICAS,
        FAAS_OPENFAAS_NODES,
        FAAS_OPENFAAS_MIN_REPLICAS,
        FAAS_OPENFAAS_PASSWORD,
        FAAS_OPENFAAS_READ_TIMEOUT,
        FAAS_OPENFAAS_RUNTIME_IMAGE,
        FAAS_OPENFAAS_SCALE_ZERO,
        FAAS_OPENFAAS_USERNAME,
        FAAS_OPENFAAS_WRITE_TIMEOUT,
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
}
_MAX_BUNDLE_FILES = 60
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
}
_FORBIDDEN_CALLS = {
    "__import__",
    "compile",
    "eval",
    "exec",
    "input",
    "open",
}
_FORBIDDEN_NAMES = {
    "__builtins__",
    "__dict__",
    "__globals__",
    "__subclasses__",
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
    if mode == "openfaas":
        meta.update(
            {
                "openfaas_gateway": str(FAAS_OPENFAAS_GATEWAY or "").rstrip("/"),
                "runtime_image": FAAS_OPENFAAS_RUNTIME_IMAGE,
                "bundle_base_url": FAAS_RUNTIME_BUNDLE_BASE_URL or FAAS_PUBLIC_BASE_URL,
            }
        )
        # Pin the service to a faas-node when multi-node routing is configured; the
        # invoke proxy resolves node_id -> gateway URL via FAAS_OPENFAAS_NODES.
        if FAAS_DEFAULT_NODE_ID:
            meta["node_id"] = FAAS_DEFAULT_NODE_ID
    elif mode in _LOCAL_DOCKER_MODES:
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


def openfaas_gateway_for_service(service: dict[str, Any] | None) -> str:
    """Resolve which faasd gateway a service is invoked through.

    Priority: meta_json.deploy.node_id (resolved via FAAS_OPENFAAS_NODES) ->
    the service's pinned meta_json.deploy.openfaas_gateway -> the global
    FAAS_OPENFAAS_GATEWAY. A node_id that is set but absent from the registry is a
    misconfiguration we surface loudly rather than silently routing to the wrong
    (or global) node."""
    if service:
        meta = _json_object(service.get("meta_json"))
        deploy = _json_object(meta.get("deploy"))
        node_id = str(deploy.get("node_id") or "").strip()
        if node_id:
            url = FAAS_OPENFAAS_NODES.get(node_id)
            if not url:
                raise FaaSError(
                    f"faas node '{node_id}' for this service is not in FAAS_OPENFAAS_NODES"
                )
            return str(url).strip().rstrip("/")
        gateway = str(deploy.get("openfaas_gateway") or "").strip().rstrip("/")
        if gateway:
            return gateway
    return str(FAAS_OPENFAAS_GATEWAY or "").strip().rstrip("/")


def list_services(
    user_id: str,
    *,
    include_disabled: bool = False,
    all_services: bool = False,
) -> list[dict[str, Any]]:
    ensure_tables()
    disabled_clause = "" if include_disabled else "AND status <> 'disabled'"
    cols = (
        "service_id, owner_user_id, service_slug, function_name, status, "
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
        SELECT service_id, owner_user_id, service_slug, function_name, status,
               active_commit, active_path, public_base_url, routes, meta_json,
               created_at, updated_at
        FROM faas_services
        WHERE service_id = %s
        """,
        [service_id],
        fetch_one=True,
    )


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
        elif isinstance(node, ast.Attribute) and node.attr.startswith("__"):
            raise FaaSValidationError(f"dunder attribute is not allowed ({filename}): {node.attr}")


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

    return {
        "service_id": service_id,
        "service_slug": service_slug,
        "routes": routes,
        "files": normalized_files,
        "meta": raw_service.get("meta") if isinstance(raw_service.get("meta"), dict) else {},
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


def _remove_local_docker_runtime(function_name: str) -> None:
    client = _docker_client()
    name = _local_container_name(function_name)
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
        raise FaaSError(f"cannot remove old FaaS container {name}: {exc}") from exc


def _wait_local_docker_runtime(function_name: str) -> None:
    import requests

    url = f"{_local_upstream_url(function_name)}/__myapp_faas_health"
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


def _start_local_docker_runtime(root: Path, *, function_name: str, service_id: str, commit_sha: str) -> str:
    client = _docker_client()
    name = _local_container_name(function_name)
    container_code_root = Path(FAAS_CODE_ROOT).resolve()
    host_code_root = Path(FAAS_LOCAL_DOCKER_HOST_CODE_ROOT).resolve()
    if not container_code_root.exists():
        raise FaaSError(f"FaaS code root does not exist in backend container: {container_code_root}")
    service_dir = _local_runtime_service_dir(root)
    _remove_local_docker_runtime(function_name)
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
                "PYTHONUNBUFFERED": "1",
                **_platform_runtime_env(),
            },
            labels={
                "myapp.component": "faas-runtime",
                "myapp.faas": "1",
                "myapp.faas.service_id": service_id,
                "myapp.faas.function_name": function_name,
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
    _wait_local_docker_runtime(function_name)
    return f"local-docker container={name} upstream={_local_upstream_url(function_name)}"


def local_docker_upstream_for_service(service: dict[str, Any]) -> str:
    function_name = str(service.get("function_name") or "").strip()
    if not function_name:
        raise FaaSError("service function name is missing")
    return _local_upstream_url(function_name)


def ensure_local_docker_runtime_for_service(service: dict[str, Any]) -> str:
    function_name = str(service.get("function_name") or "").strip()
    service_id = str(service.get("service_id") or "").strip()
    active_path = str(service.get("active_path") or "").strip()
    commit_sha = str(service.get("active_commit") or "").strip()
    if not function_name or not service_id or not active_path:
        raise FaaSError("service is missing runtime metadata")
    root = Path(active_path)
    name = _local_container_name(function_name)
    client = _docker_client()
    try:
        container = client.containers.get(name)
        container.reload()
        if container.status == "running":
            return _local_upstream_url(function_name)
        container.remove(force=True)
    except Exception as exc:
        not_found = _docker_not_found_type()
        if not_found and not isinstance(exc, not_found):
            raise FaaSError(f"cannot inspect FaaS container {name}: {exc}") from exc
    _start_local_docker_runtime(root, function_name=function_name, service_id=service_id, commit_sha=commit_sha)
    return _local_upstream_url(function_name)


def _runtime_bundle_url(service_id: str) -> str:
    base = FAAS_RUNTIME_BUNDLE_BASE_URL or FAAS_PUBLIC_BASE_URL
    if not base:
        raise FaaSError("FAAS_RUNTIME_BUNDLE_BASE_URL or FAAS_PUBLIC_BASE_URL is required for OpenFaaS runtime")
    return f"{base.rstrip('/')}/api/faas/runtime_bundle/{service_id}"


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
        "MYAPP_CFG_SUPABASE_ANON_KEY": SUPABASE_ANON_KEY or "",
        "MYAPP_CFG_BACKEND_BASE_URL": (FAAS_PUBLIC_BASE_URL or "").rstrip("/"),
        "MYAPP_CFG_FAAS_PUBLIC_BASE_URL": (FAAS_NODE_PUBLIC_URL or "").rstrip("/"),
    }
    return {key: value for key, value in values.items() if value}


def _openfaas_auth():
    if not FAAS_OPENFAAS_PASSWORD:
        return None
    return (FAAS_OPENFAAS_USERNAME or "admin", FAAS_OPENFAAS_PASSWORD)


def _openfaas_function_exists(function_name: str, *, gateway: str | None = None) -> bool:
    gateway = str(gateway or FAAS_OPENFAAS_GATEWAY or "").rstrip("/")
    if not gateway:
        raise FaaSError("FAAS_OPENFAAS_GATEWAY is required for FAAS_DEPLOY_MODE=openfaas")
    try:
        resp = requests.get(
            f"{gateway}/system/function/{quote(function_name, safe='')}",
            auth=_openfaas_auth(),
            timeout=(5, 30),
        )
    except requests.RequestException as exc:
        raise FaaSError(f"OpenFaaS status request failed: {exc}") from exc
    if resp.status_code == 200:
        return True
    if resp.status_code == 404:
        return False
    raise FaaSError(f"OpenFaaS status failed status={resp.status_code}: {resp.text[:1000]}")


def _openfaas_deploy_request(method: str, payload: dict[str, Any], *, gateway: str | None = None) -> requests.Response:
    gateway = str(gateway or FAAS_OPENFAAS_GATEWAY or "").rstrip("/")
    if not gateway:
        raise FaaSError("FAAS_OPENFAAS_GATEWAY is required for FAAS_DEPLOY_MODE=openfaas")
    if method == "POST":
        return requests.post(
            f"{gateway}/system/functions",
            json=payload,
            auth=_openfaas_auth(),
            timeout=(5, 60),
        )
    if method == "PUT":
        return requests.put(
            f"{gateway}/system/functions",
            json=payload,
            auth=_openfaas_auth(),
            timeout=(5, 60),
        )
    raise ValueError(f"unsupported OpenFaaS deploy method: {method}")


def _deploy_openfaas_function(*, function_name: str, service_id: str, commit_sha: str) -> str:
    gateway = str(FAAS_OPENFAAS_GATEWAY or "").rstrip("/")
    if not gateway:
        raise FaaSError("FAAS_OPENFAAS_GATEWAY is required for FAAS_DEPLOY_MODE=openfaas")
    if not FAAS_OPENFAAS_RUNTIME_IMAGE:
        raise FaaSError("FAAS_OPENFAAS_RUNTIME_IMAGE is required for FAAS_DEPLOY_MODE=openfaas")
    runtime_token = runtime_token_for_service(service_id)
    if not runtime_token:
        raise FaaSError("FAAS_RUNTIME_TOKEN is required for FAAS_DEPLOY_MODE=openfaas")

    labels: dict[str, str] = {
        "myapp.faas": "1",
        "myapp.faas.service_id": service_id,
    }
    if FAAS_OPENFAAS_SCALE_ZERO:
        labels.update({
            "com.openfaas.scale.zero": "true",
            # Idle duration before scaling a function to zero (default 10 minutes).
            "com.openfaas.scale.zero.duration": (os.environ.get("FAAS_OPENFAAS_SCALE_ZERO_DURATION", "").strip() or "10m"),
            "com.openfaas.scale.min": str(max(0, FAAS_OPENFAAS_MIN_REPLICAS)),
            "com.openfaas.scale.max": str(max(1, FAAS_OPENFAAS_MAX_REPLICAS)),
        })

    payload = {
        "service": function_name,
        "image": FAAS_OPENFAAS_RUNTIME_IMAGE,
        "envVars": {
            "PORT": "8080",
            "MYAPP_FAAS_SERVICE_ID": service_id,
            "MYAPP_FAAS_FUNCTION_NAME": function_name,
            "MYAPP_FAAS_COMMIT": commit_sha,
            "MYAPP_FAAS_BUNDLE_URL": _runtime_bundle_url(service_id),
            "MYAPP_FAAS_RUNTIME_TOKEN": runtime_token,
            "PYTHONUNBUFFERED": "1",
            **_platform_runtime_env(),
        },
        "labels": labels,
        "annotations": {
            "com.openfaas.health.http.path": "/__myapp_faas_health",
            "com.openfaas.health.http.initialDelay": "2s",
            "com.openfaas.health.http.periodSeconds": "5",
            "com.openfaas.timeouts.read": FAAS_OPENFAAS_READ_TIMEOUT,
            "com.openfaas.timeouts.write": FAAS_OPENFAAS_WRITE_TIMEOUT,
        },
    }
    method = "PUT" if _openfaas_function_exists(function_name, gateway=gateway) else "POST"
    try:
        resp = _openfaas_deploy_request(method, payload, gateway=gateway)
        if method == "PUT" and resp.status_code == 404:
            method = "POST"
            resp = _openfaas_deploy_request(method, payload, gateway=gateway)
        elif method == "POST" and resp.status_code in {409}:
            method = "PUT"
            resp = _openfaas_deploy_request(method, payload, gateway=gateway)
    except requests.RequestException as exc:
        raise FaaSError(f"OpenFaaS deploy request failed: {exc}") from exc
    if resp.status_code not in {200, 201, 202}:
        raise FaaSError(f"OpenFaaS deploy failed status={resp.status_code}: {resp.text[:1000]}")
    return f"openfaas method={method} function={function_name} image={FAAS_OPENFAAS_RUNTIME_IMAGE} status={resp.status_code}"


def _delete_openfaas_function(function_name: str, *, gateway: str | None = None) -> str:
    gateway = str(gateway or FAAS_OPENFAAS_GATEWAY or "").rstrip("/")
    if not gateway:
        return ""
    try:
        resp = requests.delete(
            f"{gateway}/system/functions",
            json={"functionName": function_name},
            auth=_openfaas_auth(),
            timeout=(5, 60),
        )
    except requests.RequestException as exc:
        raise FaaSError(f"OpenFaaS delete request failed: {exc}") from exc
    if resp.status_code in {200, 202, 204, 404}:
        return f"openfaas delete function={function_name} status={resp.status_code}"
    raise FaaSError(f"OpenFaaS delete failed status={resp.status_code}: {resp.text[:1000]}")


def _deploy_service(root: Path, *, function_name: str, service_id: str, commit_sha: str) -> tuple[str, str]:
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
    if mode == "openfaas":
        return "ready", _deploy_openfaas_function(function_name=function_name, service_id=service_id, commit_sha=commit_sha)
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
    if function_name:
        if FAAS_DEPLOY_MODE in _LOCAL_DOCKER_MODES:
            try:
                _remove_local_docker_runtime(function_name)
            except FaaSError as exc:
                warnings.append(str(exc))
        openfaas_gateway = openfaas_gateway_for_service(service)
        if openfaas_gateway and FAAS_DEPLOY_MODE == "openfaas":
            try:
                _delete_openfaas_function(function_name, gateway=openfaas_gateway)
            except FaaSError as exc:
                warnings.append(str(exc))
    db_execute(
        "UPDATE faas_services SET status = 'disabled', updated_at = NOW() WHERE service_id = %s",
        [service_id],
    )
    service["status"] = "disabled"
    service["warnings"] = warnings
    return service


def deploy_bundle(owner_user_id: str, bundle: dict[str, Any], *, source: str = "agent") -> FaaSDeployResult:
    if not owner_user_id:
        raise FaaSValidationError("owner_user_id is required")
    ensure_tables()
    normalized = validate_bundle(bundle)
    service_id = normalized["service_id"]
    lock = _service_lock(f"{owner_user_id}:{service_id}")
    with lock:
        existing = get_service(service_id)
        if existing and existing.get("owner_user_id") != owner_user_id:
            raise FaaSValidationError("service_id already belongs to another user")
        if not existing and _count_user_services(owner_user_id) >= max(1, FAAS_MAX_SERVICES_PER_USER):
            raise FaaSValidationError(f"service limit exceeded: max {FAAS_MAX_SERVICES_PER_USER}")

        function_name = existing.get("function_name") if existing else _function_name(owner_user_id, service_id)
        root = service_code_root(owner_user_id, service_id)
        repo_root = Path(FAAS_CODE_ROOT)
        service_rel = root.relative_to(repo_root)
        deployment_id = f"dep-{uuid.uuid4().hex}"
        routes = normalized["routes"]
        meta_json = _meta_with_current_deploy(normalized["meta"])
        summary = {
            "source": source,
            "service_slug": normalized["service_slug"],
            "route_count": len(routes),
            "files": sorted(normalized["files"]),
        }
        db_execute(
            """
            INSERT INTO faas_services (
                service_id, owner_user_id, service_slug, function_name, status,
                active_path, public_base_url, routes, meta_json
            )
            VALUES (%s, %s, %s, %s, 'deploying', %s, %s, %s::jsonb, %s::jsonb)
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
                normalized["service_slug"],
                function_name,
                str(root),
                FAAS_PUBLIC_BASE_URL or FAAS_OPENFAAS_GATEWAY,
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
            )
            db_execute(
                """
                UPDATE faas_services
                SET status = %s, active_commit = %s, active_path = %s,
                    public_base_url = %s, updated_at = NOW()
                WHERE service_id = %s
                """,
                [status, commit_sha, str(root), FAAS_PUBLIC_BASE_URL or FAAS_OPENFAAS_GATEWAY, service_id],
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
                public_base_url=FAAS_PUBLIC_BASE_URL or FAAS_OPENFAAS_GATEWAY,
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
