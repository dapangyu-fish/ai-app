#!/usr/bin/env python3
"""Core FaaS store controls that do not require Docker or OpenFaaS."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-store-controls",
    "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_SCRIPT": "",
    "FAAS_ENABLED": True,
    "FAAS_FILE_MAX_BYTES": 256 * 1024,
    "FAAS_FUNCTION_PREFIX": "myapp",
    "FAAS_GIT_AUTHOR_EMAIL": "myapp-faas-bot@localhost",
    "FAAS_GIT_AUTHOR_NAME": "myapp-faas-bot",
    "FAAS_GIT_BRANCH": "main",
    "FAAS_GIT_ENABLED": False,
    "FAAS_GIT_PUSH_ENABLED": False,
    "FAAS_GIT_REMOTE": "",
    "FAAS_GIT_SSH_KEY_PATH": "",
    "FAAS_GIT_KNOWN_HOSTS_PATH": "",
    "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 2,
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
    "FAAS_PUBLIC_BASE_URL": "https://backend.example",
    "FAAS_REQUIREMENTS_MAX_LINES": 40,
    "FAAS_RUNTIME_BUNDLE_BASE_URL": "https://backend.example",
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config


class _MemoryFaaSDB:
    def __init__(self) -> None:
        self.services: dict[str, dict] = {}
        self.deployments: dict[str, dict] = {}

    def execute(self, sql: str, params=None):
        params = list(params or [])
        normalized = " ".join(sql.lower().split())
        if normalized.startswith("create ") or normalized.startswith("alter ") or normalized.startswith("create index"):
            return None
        if "insert into faas_services" in normalized:
            (
                service_id,
                owner_user_id,
                service_slug,
                function_name,
                active_path,
                public_base_url,
                routes_json,
                meta_json,
            ) = params
            existing = self.services.get(service_id, {})
            created_at = existing.get("created_at", "created")
            self.services[service_id] = {
                **existing,
                "service_id": service_id,
                "owner_user_id": owner_user_id,
                "service_slug": service_slug,
                "function_name": existing.get("function_name") or function_name,
                "status": "deploying",
                "active_commit": existing.get("active_commit", ""),
                "active_path": active_path,
                "public_base_url": public_base_url,
                "routes": json.loads(routes_json),
                "meta_json": json.loads(meta_json),
                "created_at": created_at,
                "updated_at": "updated",
            }
            return None
        if "insert into faas_deployments" in normalized:
            deployment_id, service_id, owner_user_id, summary_json = params
            self.deployments[deployment_id] = {
                "deployment_id": deployment_id,
                "service_id": service_id,
                "owner_user_id": owner_user_id,
                "commit_sha": "",
                "status": "pending",
                "error": "",
                "bundle_summary": json.loads(summary_json),
            }
            return None
        if "update faas_services set status = %s, active_commit" in normalized:
            status, commit_sha, active_path, public_base_url, service_id = params
            self.services[service_id].update({
                "status": status,
                "active_commit": commit_sha,
                "active_path": active_path,
                "public_base_url": public_base_url,
                "updated_at": "updated",
            })
            return None
        if "update faas_deployments set status = 'success'" in normalized:
            commit_sha, deploy_output_json, deployment_id = params
            self.deployments[deployment_id].update({
                "status": "success",
                "commit_sha": commit_sha,
                "bundle_summary": {
                    **self.deployments[deployment_id]["bundle_summary"],
                    **json.loads(deploy_output_json),
                },
                "finished_at": "finished",
            })
            return None
        if "update faas_services set status = 'failed'" in normalized:
            service_id = params[0]
            self.services[service_id]["status"] = "failed"
            return None
        if "update faas_deployments set status = 'failed'" in normalized:
            error, deployment_id = params
            self.deployments[deployment_id].update({"status": "failed", "error": error})
            return None
        if "update faas_services set status = 'disabled'" in normalized:
            service_id = params[0]
            self.services[service_id]["status"] = "disabled"
            return None
        raise AssertionError(f"unhandled db_execute SQL: {sql}")

    def query(self, sql: str, params=None, fetch_one: bool = False, fetch_all: bool = False):
        params = list(params or [])
        normalized = " ".join(sql.lower().split())
        if "select count(*) as count from faas_services" in normalized:
            owner_user_id = params[0]
            count = sum(
                1
                for row in self.services.values()
                if row["owner_user_id"] == owner_user_id and row["status"] != "disabled"
            )
            return {"count": count}
        if "from faas_services where service_id = %s" in normalized:
            row = self.services.get(params[0])
            return dict(row) if row else None
        if "from faas_services where owner_user_id = %s" in normalized:
            owner_user_id = params[0]
            include_disabled = "status <> 'disabled'" not in normalized
            rows = [
                dict(row)
                for row in self.services.values()
                if row["owner_user_id"] == owner_user_id
                and (include_disabled or row["status"] != "disabled")
            ]
            return rows
        raise AssertionError(f"unhandled db_query SQL: {sql}")


_db = _MemoryFaaSDB()
_database = types.ModuleType("database")
_database.db_execute = _db.execute
_database.db_query = _db.query
sys.modules["database"] = _database

import faas_store  # noqa: E402


def _bundle(service_id: str, *, app_py: str | None = None, requirements: str = "flask==3.0.3\n") -> dict:
    return {
        "service": {
            "service_id": service_id,
            "slug": service_id,
            "routes": [{"path": "/hello", "methods": ["GET"]}],
        },
        "files": {
            "app.py": app_py
            or "from flask import Flask, jsonify\napp = Flask(__name__)\n@app.get('/hello')\ndef hello():\n    return jsonify(ok=True)\n",
            "requirements.txt": requirements,
        },
    }


def test_validation_rejects_dangerous_python_and_dependencies() -> None:
    try:
        faas_store.validate_bundle(_bundle("bad-import", app_py="import os\nfrom flask import Flask\napp = Flask(__name__)\n"))
    except faas_store.FaaSValidationError as exc:
        assert "import is not allowed" in str(exc)
    else:
        raise AssertionError("dangerous import was accepted")

    try:
        faas_store.validate_bundle(_bundle("bad-dependency", requirements="flask==3.0.3\nrequests==2.32.0\n"))
    except faas_store.FaaSValidationError as exc:
        assert "dependency is not allowed" in str(exc)
    else:
        raise AssertionError("unsupported dependency was accepted")

    valid = faas_store.validate_bundle(
        _bundle(
            "allowed-pydantic-api",
            requirements="flask==3.0.3\npydantic==2.8.2\n",
            app_py=(
                "from __future__ import annotations\n"
                "from flask import Flask, jsonify\n"
                "from pydantic import BaseModel\n"
                "app = Flask(__name__)\n"
                "class Item(BaseModel):\n"
                "    title: str\n"
                "@app.get('/hello')\n"
                "def hello():\n"
                "    return jsonify(title=Item(title='demo').title)\n"
            ),
        )
    )
    assert valid["service_id"] == "allowed-pydantic-api"


def test_validation_requires_declared_routes_to_match_flask_decorators() -> None:
    valid = faas_store.validate_bundle(
        {
            "service": {
                "service_id": "route-api",
                "slug": "route-api",
                "routes": [
                    {"path": "/items", "methods": ["GET", "POST"]},
                    {"path": "/items/<item_id>", "methods": ["DELETE"]},
                ],
            },
            "files": {
                "app.py": (
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "@app.route('/items', methods=['GET', 'POST'])\n"
                    "def items():\n"
                    "    return jsonify(ok=True)\n"
                    "@app.delete('/items/<item_id>')\n"
                    "def delete_item(item_id):\n"
                    "    return jsonify(ok=True)\n"
                ),
            },
        }
    )
    assert valid["routes"][0]["path"] == "/items"

    try:
        faas_store.validate_bundle(_bundle("missing-route"))
    except faas_store.FaaSValidationError as exc:
        raise AssertionError(f"default bundle should still be valid: {exc}") from exc

    try:
        faas_store.validate_bundle(
            {
                "service": {
                    "service_id": "not-implemented-api",
                    "routes": [{"path": "/items", "methods": ["GET"]}],
                },
                "files": {
                    "app.py": (
                        "from flask import Flask, jsonify\n"
                        "app = Flask(__name__)\n"
                        "@app.get('/other')\n"
                        "def other():\n"
                        "    return jsonify(ok=True)\n"
                    ),
                },
            }
        )
    except faas_store.FaaSValidationError as exc:
        assert "declared route is not implemented" in str(exc)
    else:
        raise AssertionError("bundle with an unimplemented declared route was accepted")

    try:
        faas_store.validate_bundle(
            {
                "service": {
                    "service_id": "missing-method-api",
                    "routes": [{"path": "/items", "methods": ["GET", "POST"]}],
                },
                "files": {
                    "app.py": (
                        "from flask import Flask, jsonify\n"
                        "app = Flask(__name__)\n"
                        "@app.get('/items')\n"
                        "def items():\n"
                        "    return jsonify(ok=True)\n"
                    ),
                },
            }
        )
    except faas_store.FaaSValidationError as exc:
        assert "declared route methods are not implemented" in str(exc)
        assert "POST" in str(exc)
    else:
        raise AssertionError("bundle with an unimplemented declared method was accepted")


def test_validation_rejects_reserved_runtime_routes() -> None:
    try:
        faas_store.validate_bundle(
            {
                "service": {
                    "service_id": "reserved-declared-api",
                    "routes": [{"path": "/__myapp_faas_health", "methods": ["GET"]}],
                },
                "files": {
                    "app.py": (
                        "from flask import Flask, jsonify\n"
                        "app = Flask(__name__)\n"
                        "@app.get('/__myapp_faas_health')\n"
                        "def health():\n"
                        "    return jsonify(ok=True)\n"
                    ),
                },
            }
        )
    except faas_store.FaaSValidationError as exc:
        assert "reserved" in str(exc)
    else:
        raise AssertionError("bundle declaring the runtime health route was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "reserved-implemented-api",
                app_py=(
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                    "@app.get('/__myapp_faas_health')\n"
                    "def health():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "reserved" in str(exc)
    else:
        raise AssertionError("bundle implementing the runtime health route was accepted")


def test_validation_restricts_top_level_runtime_shape() -> None:
    seeded = faas_store.validate_bundle(
        _bundle(
            "seeded-state-api",
            app_py=(
                "from flask import Flask, jsonify\n"
                "app = Flask(__name__)\n"
                "ITEMS = [{'id': 1, 'title': 'demo'}]\n"
                "@app.get('/hello')\n"
                "def hello():\n"
                "    return jsonify(items=ITEMS)\n"
                "if __name__ == '__main__':\n"
                "    app.run()\n"
            ),
        )
    )
    assert seeded["service_id"] == "seeded-state-api"

    try:
        faas_store.validate_bundle(
            _bundle(
                "fake-flask-app",
                app_py=(
                    "from flask import jsonify\n"
                    "app = object()\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "Flask" in str(exc)
    else:
        raise AssertionError("bundle with fake Flask app was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "top-level-loop",
                app_py=(
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "while True:\n"
                    "    pass\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "top-level code is restricted" in str(exc)
    else:
        raise AssertionError("bundle with top-level loop was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "top-level-call",
                app_py=(
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "ITEMS = list()\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(items=ITEMS)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "top-level code is restricted" in str(exc)
    else:
        raise AssertionError("bundle with top-level call assignment was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "constructor-call",
                app_py=(
                    "import time\n"
                    "from flask import Flask, jsonify\n"
                    "app = Flask(time.sleep(1))\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "Flask" in str(exc)
    else:
        raise AssertionError("bundle with side-effecting Flask constructor was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "decorator-call",
                app_py=(
                    "import time\n"
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "@time.sleep(1)\n"
                    "def bad():\n"
                    "    return None\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "decorators" in str(exc)
    else:
        raise AssertionError("bundle with side-effecting decorator was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "default-call",
                app_py=(
                    "import time\n"
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "@app.get('/hello')\n"
                    "def hello(seed=time.sleep(1)):\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "default arguments" in str(exc)
    else:
        raise AssertionError("bundle with side-effecting default argument was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "class-decorator-call",
                app_py=(
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "def decorate(cls):\n"
                    "    return cls\n"
                    "@decorate\n"
                    "class Item:\n"
                    "    title: str\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "class decorators" in str(exc)
    else:
        raise AssertionError("bundle with class decorator was accepted")

    try:
        faas_store.validate_bundle(
            _bundle(
                "class-base-call",
                app_py=(
                    "import time\n"
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "class Item(time.sleep(1)):\n"
                    "    title: str\n"
                    "@app.get('/hello')\n"
                    "def hello():\n"
                    "    return jsonify(ok=True)\n"
                ),
            )
        )
    except faas_store.FaaSValidationError as exc:
        assert "class bases" in str(exc) or "import is not allowed" in str(exc)
    else:
        raise AssertionError("bundle with side-effecting class base was accepted")


def test_deploy_quota_conflict_disable_and_runtime_bundle() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-store-") as raw:
        faas_store.FAAS_CODE_ROOT = raw
        faas_store.FAAS_DEPLOY_MODE = "metadata"
        faas_store.FAAS_GIT_ENABLED = False
        faas_store.FAAS_MAX_SERVICES_PER_USER = 2
        _db.services.clear()
        _db.deployments.clear()

        first = faas_store.deploy_bundle("user-a", _bundle("notes-api"), source="test")
        second = faas_store.deploy_bundle("user-a", _bundle("todo-api"), source="test")
        assert first.status == "ready"
        assert second.status == "ready"

        try:
            faas_store.deploy_bundle("user-a", _bundle("third-api"), source="test")
        except faas_store.FaaSValidationError as exc:
            assert "service limit exceeded" in str(exc)
        else:
            raise AssertionError("third active service was accepted")

        try:
            faas_store.deploy_bundle("user-b", _bundle("notes-api"), source="test")
        except faas_store.FaaSValidationError as exc:
            assert "already belongs to another user" in str(exc)
        else:
            raise AssertionError("cross-user service_id conflict was accepted")

        runtime_bundle = faas_store.runtime_bundle_for_service("notes-api")
        assert runtime_bundle["service"]["service_id"] == "notes-api"
        assert "app.py" in runtime_bundle["files"]
        assert runtime_bundle["files"]["service.json"].strip().startswith("{")

        disabled = faas_store.disable_service("user-a", "notes-api")
        assert disabled["status"] == "disabled"
        replacement = faas_store.deploy_bundle("user-a", _bundle("third-api"), source="test")
        assert replacement.status == "ready"


def test_openfaas_deploy_records_gateway_metadata() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-store-openfaas-") as raw:
        old_root = faas_store.FAAS_CODE_ROOT
        old_mode = faas_store.FAAS_DEPLOY_MODE
        old_gateway = faas_store.FAAS_OPENFAAS_GATEWAY
        old_image = faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE
        old_bundle_base = faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL
        old_deploy = faas_store._deploy_openfaas_function
        try:
            faas_store.FAAS_CODE_ROOT = raw
            faas_store.FAAS_DEPLOY_MODE = "openfaas"
            faas_store.FAAS_OPENFAAS_GATEWAY = "http://openfaas-a:8080"
            faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = "example/faas-runtime:openfaas"
            faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = "https://backend.example"
            faas_store._deploy_openfaas_function = (
                lambda *, function_name, service_id, commit_sha: "openfaas method=POST status=202"
            )
            _db.services.clear()
            _db.deployments.clear()

            result = faas_store.deploy_bundle("user-openfaas", _bundle("api-openfaas"), source="test")
        finally:
            faas_store.FAAS_CODE_ROOT = old_root
            faas_store.FAAS_DEPLOY_MODE = old_mode
            faas_store.FAAS_OPENFAAS_GATEWAY = old_gateway
            faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = old_image
            faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = old_bundle_base
            faas_store._deploy_openfaas_function = old_deploy

    assert result.status == "ready"
    deploy_meta = _db.services["api-openfaas"]["meta_json"]["deploy"]
    assert deploy_meta["mode"] == "openfaas"
    assert deploy_meta["openfaas_gateway"] == "http://openfaas-a:8080"
    assert deploy_meta["runtime_image"] == "example/faas-runtime:openfaas"
    assert deploy_meta["bundle_base_url"] == "https://backend.example"


if __name__ == "__main__":
    test_validation_rejects_dangerous_python_and_dependencies()
    test_validation_requires_declared_routes_to_match_flask_decorators()
    test_validation_rejects_reserved_runtime_routes()
    test_validation_restricts_top_level_runtime_shape()
    test_deploy_quota_conflict_disable_and_runtime_bundle()
    test_openfaas_deploy_records_gateway_metadata()
    print(json.dumps({"ok": True}, sort_keys=True))
