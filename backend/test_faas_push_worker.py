#!/usr/bin/env python3
"""Isolated FaaS push-worker checks.

Uses a temporary local bare Git repository as the remote, so it verifies the
per-user subtree commit, push, fault isolation, and retry/backoff behavior
without needing GitHub credentials, network, or a live database.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-pwtest",
    "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_SCRIPT": "",
    "FAAS_ENABLED": True,
    "FAAS_FILE_MAX_BYTES": 256 * 1024,
    "FAAS_FUNCTION_PREFIX": "myapp",
    "FAAS_GIT_AUTHOR_EMAIL": "myapp-faas-bot@localhost",
    "FAAS_GIT_AUTHOR_NAME": "myapp-faas-bot",
    "FAAS_GIT_BRANCH": "main",
    "FAAS_GIT_ENABLED": True,
    "FAAS_GIT_PUSH_ENABLED": True,
    "FAAS_GIT_REMOTE": "",
    "FAAS_GIT_SSH_KEY_PATH": "",
    "FAAS_GIT_KNOWN_HOSTS_PATH": "",
    "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": True,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 5,
    "FAAS_OPENFAAS_GATEWAY": "",
    "FAAS_DEFAULT_NODE_ID": "",
    "FAAS_OPENFAAS_NODES": {},
    "FAAS_OPENFAAS_MAX_REPLICAS": 1,
    "FAAS_OPENFAAS_MIN_REPLICAS": 0,
    "FAAS_OPENFAAS_PASSWORD": "",
    "FAAS_OPENFAAS_READ_TIMEOUT": "60s",
    "FAAS_OPENFAAS_RUNTIME_IMAGE": "example/faas-runtime:test",
    "FAAS_OPENFAAS_SCALE_ZERO": True,
    "FAAS_OPENFAAS_USERNAME": "admin",
    "FAAS_OPENFAAS_WRITE_TIMEOUT": "60s",
    "FAAS_PUBLIC_BASE_URL": "",
    "FAAS_REQUIREMENTS_MAX_LINES": 40,
    "FAAS_RUNTIME_BUNDLE_BASE_URL": "",
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

_DB_CALLS: list[tuple[str, list]] = []
_database = types.ModuleType("database")
_database.db_execute = lambda sql, params=None: _DB_CALLS.append((" ".join(sql.split()), list(params or [])))
_database.db_query = lambda *a, **k: []


def _no_db():
    raise RuntimeError("get_db_connection must not be called in this unit test")


_database.get_db_connection = _no_db
sys.modules["database"] = _database

import faas_store  # noqa: E402
import faas_push_worker as pw  # noqa: E402


def _git(args: list[str], *, cwd: Path) -> str:
    proc = subprocess.run(["git", *args], cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip())
    return proc.stdout.strip()


def _wire(repo: Path, remote: str) -> None:
    for mod in (faas_store, pw):
        mod.FAAS_CODE_ROOT = str(repo)
        mod.FAAS_GIT_ENABLED = True
        mod.FAAS_GIT_PUSH_ENABLED = True
        mod.FAAS_GIT_REMOTE = str(remote)
        mod.FAAS_GIT_BRANCH = "main"
    faas_store.FAAS_GIT_AUTHOR_NAME = "myapp-faas-bot"
    faas_store.FAAS_GIT_AUTHOR_EMAIL = "myapp-faas-bot@localhost"
    faas_store.FAAS_GIT_SSH_KEY_PATH = ""
    faas_store.FAAS_GIT_KNOWN_HOSTS_PATH = ""


def _job(uid: str, rel: str, files: dict, *, attempts: int = 1, max_attempts: int = 5) -> dict:
    return {
        "job_id": f"job-{uid}-{rel.rsplit('/', 1)[-1]}",
        "owner_user_id": uid,
        "service_id": rel.rsplit("/", 1)[-1],
        "service_rel": rel,
        "files": files,
        "commit_message": f"deploy {rel}",
        "attempts": attempts,
        "max_attempts": max_attempts,
    }


def _finish_call(job_id: str) -> dict | None:
    for sql, params in reversed(_DB_CALLS):
        if "faas_push_jobs SET status = %s" in sql and params and params[-1] == job_id:
            return {"status": params[0], "commit_sha": params[1], "pushed": params[2]}
    return None


def _retry_called(job_id: str) -> bool:
    return any(
        "faas_push_jobs SET status = 'pending'" in sql and params and params[-1] == job_id
        for sql, params in _DB_CALLS
    )


_APP = "from flask import Flask\napp = Flask(__name__)\n"


def test_process_job_commits_and_pushes_subtree() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-pw-") as raw:
        root = Path(raw)
        remote = root / "remote.git"
        repo = root / "code"
        _git(["init", "--bare", str(remote)], cwd=root)
        _wire(repo, str(remote))
        _DB_CALLS.clear()

        rel = "aa/bb/user-aabb/todo-api"
        pw.process_job(_job("user-aabb", rel, {"app.py": _APP, "requirements.txt": "flask==3.0.3\n"}))

        remote_head = _git(["rev-parse", "refs/heads/main"], cwd=remote)
        fin = _finish_call("job-user-aabb-todo-api")
        assert fin is not None, "finish not recorded"
        assert fin["status"] == "success", fin
        assert fin["pushed"] is True, fin
        assert fin["commit_sha"] == remote_head, (fin, remote_head)
        listing = _git(["ls-tree", "-r", "--name-only", "refs/heads/main"], cwd=remote)
        assert f"{rel}/app.py" in listing, listing


def test_per_user_subtree_isolation() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-pw-") as raw:
        root = Path(raw)
        remote = root / "remote.git"
        repo = root / "code"
        _git(["init", "--bare", str(remote)], cwd=root)
        _wire(repo, str(remote))
        _DB_CALLS.clear()

        rel_b = "cc/dd/user-ccdd/notes-api"
        pw.process_job(_job("user-ccdd", rel_b, {"app.py": _APP}))

        rel_a = "aa/bb/user-aabb/todo-api"
        pw.process_job(_job("user-aabb", rel_a, {"app.py": _APP, "requirements.txt": "flask==3.0.3\n"}))

        # The latest commit must touch ONLY user A's subtree.
        changed = _git(["show", "--name-only", "--format=", "HEAD"], cwd=repo)
        touched = [ln.strip() for ln in changed.splitlines() if ln.strip()]
        assert touched, "expected changed files"
        for path in touched:
            assert path.startswith(rel_a), f"commit leaked outside user A subtree: {path}"
        # User B's files are still present and intact.
        full = _git(["ls-tree", "-r", "--name-only", "HEAD"], cwd=repo)
        assert f"{rel_b}/app.py" in full, full
        assert f"{rel_a}/app.py" in full, full


def test_push_failure_retries_then_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-pw-") as raw:
        root = Path(raw)
        repo = root / "code"
        bad_remote = root / "does-not-exist.git"  # never created -> push fails
        _wire(repo, str(bad_remote))
        _DB_CALLS.clear()

        rel = "xx/yy/user-xxyy/s"
        files = {"app.py": _APP}
        # attempt 1 of 2 -> retry scheduled
        pw.process_job(_job("user-xxyy", rel, files, attempts=1, max_attempts=2))
        assert _retry_called("job-user-xxyy-s"), "expected retry on first push failure"
        assert _finish_call("job-user-xxyy-s") is None, "must not finish while retries remain"

        _DB_CALLS.clear()
        # attempt 2 of 2 -> permanent failure
        pw.process_job(_job("user-xxyy", rel, files, attempts=2, max_attempts=2))
        fin = _finish_call("job-user-xxyy-s")
        assert fin is not None and fin["status"] == "failed", fin


def test_runtime_bundle_serves_from_git_checkout_not_local_write() -> None:
    """Strict source-of-truth (D2): the runtime bundle must come from the
    GitHub-pulled checkout, so tampering the local write tree does not change it."""
    with tempfile.TemporaryDirectory(prefix="myapp-faas-pw-") as raw:
        root = Path(raw)
        remote = root / "remote.git"
        write = root / "code"
        serve = root / "serve"
        _git(["init", "--bare", str(remote)], cwd=root)
        _wire(write, str(remote))
        _DB_CALLS.clear()

        rel = "aa/bb/user-aabb/todo-api"
        pw.process_job(_job("user-aabb", rel, {"app.py": _APP, "requirements.txt": "flask==3.0.3\n"}))

        # The faas-node's read checkout, pulled from the same remote.
        _git(["clone", str(remote), str(serve)], cwd=root)
        faas_store.FAAS_BUNDLE_SERVE_ROOT = str(serve)
        faas_store.FAAS_CODE_ROOT = str(write)
        active_path = str(write / rel)
        faas_store.get_service = lambda sid: {
            "service_id": sid, "service_slug": "todo-api", "function_name": "fn",
            "active_commit": "", "active_path": active_path, "routes": [],
        }
        try:
            bundle = faas_store.runtime_bundle_for_service("todo-api")
            assert "app.py" in bundle["files"], bundle

            # Tamper the LOCAL WRITE tree; the served bundle must NOT reflect it.
            (write / rel / "app.py").write_text("# tampered\n" + _APP, encoding="utf-8")
            bundle2 = faas_store.runtime_bundle_for_service("todo-api")
            assert "# tampered" not in bundle2["files"]["app.py"], "served from local write, not git checkout"
        finally:
            faas_store.FAAS_BUNDLE_SERVE_ROOT = ""


if __name__ == "__main__":
    test_process_job_commits_and_pushes_subtree()
    test_per_user_subtree_isolation()
    test_push_failure_retries_then_fails()
    test_runtime_bundle_serves_from_git_checkout_not_local_write()
    print(json.dumps({"ok": True}, sort_keys=True))
