#!/usr/bin/env python3
"""Backend-owned FaaS Git storage checks.

This uses a temporary local bare Git repository as the remote, so it verifies
commit/push behavior without needing GitHub credentials or network access.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-test",
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

_database = types.ModuleType("database")
_database.db_execute = lambda *args, **kwargs: None
_database.db_query = lambda *args, **kwargs: []
sys.modules["database"] = _database

import faas_store  # noqa: E402


def _git(args: list[str], *, cwd: Path) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip())
    return proc.stdout.strip()


def test_backend_git_commit_and_push_to_remote() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-git-") as raw:
        root = Path(raw)
        remote = root / "remote.git"
        repo = root / "code"
        _git(["init", "--bare", str(remote)], cwd=root)

        faas_store.FAAS_CODE_ROOT = str(repo)
        faas_store.FAAS_GIT_ENABLED = True
        faas_store.FAAS_GIT_PUSH_ENABLED = True
        faas_store.FAAS_GIT_REMOTE = str(remote)
        faas_store.FAAS_GIT_BRANCH = "main"
        faas_store.FAAS_GIT_AUTHOR_NAME = "myapp-faas-bot"
        faas_store.FAAS_GIT_AUTHOR_EMAIL = "myapp-faas-bot@localhost"
        faas_store.FAAS_GIT_SSH_KEY_PATH = ""
        faas_store.FAAS_GIT_KNOWN_HOSTS_PATH = ""

        service_dir = repo / "users" / "aa" / "bb" / "user-aabb" / "services" / "todo-api"
        service_dir.mkdir(parents=True)
        (service_dir / "app.py").write_text("from flask import Flask\napp = Flask(__name__)\n", encoding="utf-8")
        (service_dir / "requirements.txt").write_text("flask==3.0.3\n", encoding="utf-8")
        first = faas_store._git_commit_service(repo, service_dir.relative_to(repo), "todo-api")

        pushed = _git(["rev-parse", "refs/heads/main"], cwd=remote)
        assert pushed == first

        (service_dir / "app.py").write_text(
            "from flask import Flask, jsonify\napp = Flask(__name__)\n@app.get('/ping')\ndef ping():\n    return jsonify(ok=True)\n",
            encoding="utf-8",
        )
        second = faas_store._git_commit_service(repo, service_dir.relative_to(repo), "todo-api")
        pushed_second = _git(["rev-parse", "refs/heads/main"], cwd=remote)
        assert second != first
        assert pushed_second == second


if __name__ == "__main__":
    test_backend_git_commit_and_push_to_remote()
    print(json.dumps({"ok": True}, sort_keys=True))
