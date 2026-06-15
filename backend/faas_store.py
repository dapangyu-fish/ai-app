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
        FAAS_CODE_ROOT,
        FAAS_DEPLOY_MODE,
        FAAS_DEPLOY_SCRIPT,
        FAAS_ENABLED,
        FAAS_FILE_MAX_BYTES,
        FAAS_FUNCTION_PREFIX,
        FAAS_GIT_AUTHOR_EMAIL,
        FAAS_GIT_AUTHOR_NAME,
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
        FAAS_OPENFAAS_GATEWAY,
        FAAS_OPENFAAS_MAX_REPLICAS,
        FAAS_OPENFAAS_MIN_REPLICAS,
        FAAS_OPENFAAS_PASSWORD,
        FAAS_OPENFAAS_READ_TIMEOUT,
        FAAS_OPENFAAS_RUNTIME_IMAGE,
        FAAS_OPENFAAS_SCALE_ZERO,
        FAAS_OPENFAAS_USERNAME,
        FAAS_OPENFAAS_WRITE_TIMEOUT,
        FAAS_PUBLIC_BASE_URL,
        FAAS_REQUIREMENTS_MAX_LINES,
        FAAS_RUNTIME_BUNDLE_BASE_URL,
        FAAS_RUNTIME_TOKEN,
    )
    from database import db_execute, db_query
except ModuleNotFoundError:
    from backend.config import (
        FAAS_BUNDLE_MAX_BYTES,
        FAAS_CODE_ROOT,
        FAAS_DEPLOY_MODE,
        FAAS_DEPLOY_SCRIPT,
        FAAS_ENABLED,
        FAAS_FILE_MAX_BYTES,
        FAAS_FUNCTION_PREFIX,
        FAAS_GIT_AUTHOR_EMAIL,
        FAAS_GIT_AUTHOR_NAME,
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
        FAAS_OPENFAAS_GATEWAY,
        FAAS_OPENFAAS_MAX_REPLICAS,
        FAAS_OPENFAAS_MIN_REPLICAS,
        FAAS_OPENFAAS_PASSWORD,
        FAAS_OPENFAAS_READ_TIMEOUT,
        FAAS_OPENFAAS_RUNTIME_IMAGE,
        FAAS_OPENFAAS_SCALE_ZERO,
        FAAS_OPENFAAS_USERNAME,
        FAAS_OPENFAAS_WRITE_TIMEOUT,
        FAAS_PUBLIC_BASE_URL,
        FAAS_REQUIREMENTS_MAX_LINES,
        FAAS_RUNTIME_BUNDLE_BASE_URL,
        FAAS_RUNTIME_TOKEN,
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
_ALLOWED_IMPORT_ROOTS = {
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
    "random",
    "re",
    "statistics",
    "string",
    "time",
    "typing",
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
    raw = str(user_id or "").strip()
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    compact = re.sub(r"[^A-Za-z0-9-]+", "", raw) or digest
    a = compact[:2].lower() if len(compact) >= 2 else digest[:2]
    b = compact[2:4].lower() if len(compact) >= 4 else digest[2:4]
    return Path("users") / a / b / compact


def user_code_root(user_id: str) -> Path:
    return Path(FAAS_CODE_ROOT) / _uid_shard(user_id)


def service_code_root(user_id: str, service_id: str) -> Path:
    return user_code_root(user_id) / "services" / _safe_id(service_id, "service")


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
    row = db_query(
        "SELECT COUNT(*) AS count FROM faas_services WHERE owner_user_id = %s AND status <> 'disabled'",
        [user_id],
        fetch_one=True,
    )
    return int(row["count"] if row else 0)


def list_services(user_id: str, *, include_disabled: bool = False) -> list[dict[str, Any]]:
    ensure_tables()
    disabled_clause = "" if include_disabled else "AND status <> 'disabled'"
    rows = db_query(
        f"""
        SELECT service_id, owner_user_id, service_slug, function_name, status,
               active_commit, active_path, public_base_url, routes, meta_json,
               created_at, updated_at
        FROM faas_services
        WHERE owner_user_id = %s
          {disabled_clause}
        ORDER BY updated_at DESC
        """,
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


def runtime_bundle_for_service(service_id: str) -> dict[str, Any]:
    service = get_service(service_id)
    if not service:
        raise FaaSValidationError("service not found")
    active_path = str(service.get("active_path") or "").strip()
    if not active_path:
        raise FaaSValidationError("service has no active code path")
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
    if normalized not in _ALLOWED_FILES and not any(normalized.startswith(prefix) for prefix in _ALLOWED_PREFIXES):
        raise FaaSValidationError(f"file is not allowed in FaaS bundle: {normalized}")
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


def _validate_python_ast(text: str) -> None:
    try:
        tree = ast.parse(text, filename="app.py")
    except SyntaxError as exc:
        raise FaaSValidationError(f"app.py syntax error: {exc}") from exc
    has_flask_app = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root = alias.name.split(".", 1)[0]
                if root not in _ALLOWED_IMPORT_ROOTS:
                    raise FaaSValidationError(f"import is not allowed: {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            root = (node.module or "").split(".", 1)[0]
            if root not in _ALLOWED_IMPORT_ROOTS:
                raise FaaSValidationError(f"import is not allowed: {node.module}")
        elif isinstance(node, ast.Call):
            target = node.func
            name = target.id if isinstance(target, ast.Name) else ""
            if name in _FORBIDDEN_CALLS:
                raise FaaSValidationError(f"call is not allowed: {name}")
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in {"app", "application"}:
                    has_flask_app = True
        elif isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name) and node.target.id in {"app", "application"}:
                has_flask_app = True
        elif isinstance(node, ast.Name) and node.id in _FORBIDDEN_NAMES:
            raise FaaSValidationError(f"name is not allowed: {node.id}")
        elif isinstance(node, ast.Attribute) and node.attr.startswith("__"):
            raise FaaSValidationError(f"dunder attribute is not allowed: {node.attr}")
    if not has_flask_app:
        raise FaaSValidationError("app.py must expose a Flask instance named app or application")


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
            if value not in {"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}:
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
    _validate_python_ast(normalized_files["app.py"])

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


def _openfaas_auth():
    if not FAAS_OPENFAAS_PASSWORD:
        return None
    return (FAAS_OPENFAAS_USERNAME or "admin", FAAS_OPENFAAS_PASSWORD)


def _openfaas_function_exists(function_name: str) -> bool:
    gateway = FAAS_OPENFAAS_GATEWAY.rstrip("/")
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


def _openfaas_deploy_request(method: str, payload: dict[str, Any]) -> requests.Response:
    gateway = FAAS_OPENFAAS_GATEWAY.rstrip("/")
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
    gateway = FAAS_OPENFAAS_GATEWAY.rstrip("/")
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
    method = "PUT" if _openfaas_function_exists(function_name) else "POST"
    try:
        resp = _openfaas_deploy_request(method, payload)
        if method == "PUT" and resp.status_code == 404:
            method = "POST"
            resp = _openfaas_deploy_request(method, payload)
        elif method == "POST" and resp.status_code in {409}:
            method = "PUT"
            resp = _openfaas_deploy_request(method, payload)
    except requests.RequestException as exc:
        raise FaaSError(f"OpenFaaS deploy request failed: {exc}") from exc
    if resp.status_code not in {200, 201, 202}:
        raise FaaSError(f"OpenFaaS deploy failed status={resp.status_code}: {resp.text[:1000]}")
    return f"openfaas method={method} function={function_name} image={FAAS_OPENFAAS_RUNTIME_IMAGE} status={resp.status_code}"


def _delete_openfaas_function(function_name: str) -> str:
    gateway = FAAS_OPENFAAS_GATEWAY.rstrip("/")
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
        if FAAS_OPENFAAS_GATEWAY and FAAS_DEPLOY_MODE == "openfaas":
            try:
                _delete_openfaas_function(function_name)
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
                json.dumps(normalized["meta"], ensure_ascii=False),
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
