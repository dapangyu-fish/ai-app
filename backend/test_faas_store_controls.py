#!/usr/bin/env python3
"""Core FaaS store controls that do not require Docker."""

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
    "FAAS_INJECT_SUPABASE_ANON_KEY": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_HARDEN_CONTAINERS": True,
    "FAAS_LOCAL_DOCKER_MEM_LIMIT": "512m",
    "FAAS_LOCAL_DOCKER_PIDS_LIMIT": 256,
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 2,
    "FAAS_PUBLIC_BASE_URL": "https://backend.example",
    "FAAS_NODE_PUBLIC_URL": "https://faas.example",
    "FAAS_REQUIREMENTS_MAX_LINES": 40,
    "FAAS_RUNTIME_BUNDLE_BASE_URL": "https://backend.example",
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
    "SUPABASE_URL": "https://supabase.example",
    "SUPABASE_ANON_KEY": "anon-key",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config


class _MemoryFaaSDB:
    def __init__(self) -> None:
        self.services: dict[str, dict] = {}
        self.deployments: dict[str, dict] = {}
        self.applications: dict[str, dict] = {}

    def execute(self, sql: str, params=None):
        params = list(params or [])
        normalized = " ".join(sql.lower().split())
        if normalized.startswith("create ") or normalized.startswith("alter ") or normalized.startswith("create index"):
            return None
        # B1-G1 applications: ensure_application inserts 5 params; the ensure_tables
        # backfill (INSERT ... SELECT DISTINCT) carries none → no-op.
        if "insert into faas_applications" in normalized:
            if len(params) >= 5:
                app_id, owner_user_id, appid, name, access_policy = params[:5]
                self.applications.setdefault(app_id, {
                    "app_id": app_id,
                    "owner_user_id": owner_user_id,
                    "appid": appid,
                    "name": name,
                    "access_policy": access_policy,
                    "created_at": "created",
                    "updated_at": "updated",
                })
            return None
        if normalized.startswith("update faas_services set app_id"):
            return None  # backfill no-op (deploy sets app_id explicitly)
        if normalized.startswith("update faas_applications set access_policy"):
            access_policy, app_id = params
            if app_id in self.applications:
                self.applications[app_id]["access_policy"] = access_policy
            return None
        if "insert into faas_services" in normalized:
            (
                service_id,
                owner_user_id,
                app_id,
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
                "app_id": app_id,
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
        if normalized.startswith("delete from faas_services"):
            service_id = params[0]
            row = self.services.get(service_id)
            # Mirror the WHERE ... AND status = 'deploying' guard.
            if row and row.get("status") == "deploying":
                self.services.pop(service_id, None)
            return None
        raise AssertionError(f"unhandled db_execute SQL: {sql}")

    def query(self, sql: str, params=None, fetch_one: bool = False, fetch_all: bool = False):
        params = list(params or [])
        normalized = " ".join(sql.lower().split())
        if "from faas_applications where app_id = %s" in normalized:
            row = self.applications.get(params[0])
            return dict(row) if row else None
        if "from faas_applications where owner_user_id = %s" in normalized:
            return [dict(r) for r in self.applications.values() if r["owner_user_id"] == params[0]]
        if "select count(*) as count from faas_services" in normalized:
            owner_user_id = params[0]
            count = sum(
                1
                for row in self.services.values()
                if row["owner_user_id"] == owner_user_id and row["status"] not in ("disabled", "failed")
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

    # path-param routes are matched by shape: a Flask converter (<int:item_id>)
    # or a renamed param (<id>) in app.py must NOT read as "not implemented",
    # mirroring the runtime invoke matcher. Methods union across decorators.
    try:
        param_ok = faas_store.validate_bundle(
            {
                "service": {
                    "service_id": "param-route-api",
                    "routes": [
                        {"path": "/items/<item_id>", "methods": ["GET", "PUT", "DELETE"]},
                    ],
                },
                "files": {
                    "app.py": (
                        "from flask import Flask, jsonify\n"
                        "app = Flask(__name__)\n"
                        "@app.route('/items/<int:item_id>', methods=['GET', 'PUT'])\n"
                        "def item(item_id):\n"
                        "    return jsonify(id=item_id)\n"
                        "@app.delete('/items/<id>')\n"
                        "def remove(id):\n"
                        "    return jsonify(ok=True)\n"
                    ),
                },
            }
        )
    except faas_store.FaaSValidationError as exc:
        raise AssertionError(
            f"declared /items/<item_id> should be satisfied by a converter/renamed param: {exc}"
        ) from exc
    assert param_ok["routes"][0]["path"] == "/items/<item_id>"

    # @app.options / @app.head are NOT real Flask decorators (Flask only ships
    # get/post/put/patch/delete); using them raises AttributeError at import and
    # 503s every route. Reject with guidance instead of shipping a broken backend.
    try:
        faas_store.validate_bundle(
            {
                "service": {"service_id": "opt-shortcut-api",
                            "routes": [{"path": "/caps", "methods": ["OPTIONS"]}]},
                "files": {"app.py": (
                    "from flask import Flask\n"
                    "app = Flask(__name__)\n"
                    "@app.options('/caps')\n"
                    "def caps():\n"
                    "    return ('', 204)\n"
                )},
            }
        )
    except faas_store.FaaSValidationError as exc:
        assert "Flask has no @app.options" in str(exc)
    else:
        raise AssertionError("@app.options bundle was accepted but Flask has no such decorator")

    # The correct OPTIONS form (@app.route methods=[...]) and HEAD as a method validate.
    try:
        opt_ok = faas_store.validate_bundle(
            {
                "service": {"service_id": "opt-route-api",
                            "routes": [{"path": "/caps", "methods": ["OPTIONS"]},
                                       {"path": "/h", "methods": ["GET", "HEAD"]}]},
                "files": {"app.py": (
                    "from flask import Flask, jsonify\n"
                    "app = Flask(__name__)\n"
                    "@app.route('/caps', methods=['OPTIONS'])\n"
                    "def caps():\n"
                    "    return ('', 204)\n"
                    "@app.route('/h', methods=['GET', 'HEAD'])\n"
                    "def h():\n"
                    "    return jsonify(ok=True)\n"
                )},
            }
        )
    except faas_store.FaaSValidationError as exc:
        raise AssertionError(f"OPTIONS via @app.route and HEAD method should validate: {exc}") from exc
    assert {r["path"] for r in opt_ok["routes"]} == {"/caps", "/h"}


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


def test_validation_supports_multi_file_service() -> None:
    helper = (
        "from datetime import datetime\n\n"
        "class Clock:\n"
        "    def now_iso(self) -> str:\n"
        "        return datetime(2020, 1, 1).isoformat()\n\n"
        "def greeting(name):\n"
        "    return 'hi ' + name\n"
    )
    app_py = (
        "from flask import Flask, jsonify\n"
        "from helpers import Clock, greeting\n"
        "from lib.util import VERSION\n"
        "app = Flask(__name__)\n"
        "@app.get('/hello')\n"
        "def hello():\n"
        "    return jsonify(msg=greeting('world'), at=Clock().now_iso(), v=VERSION)\n"
    )
    bundle = {
        "service": {
            "service_id": "multi-svc",
            "slug": "multi-svc",
            "routes": [{"path": "/hello", "methods": ["GET"]}],
        },
        "files": {
            "app.py": app_py,
            "helpers.py": helper,
            "lib/util.py": "VERSION = '1.0.0'\n",
            "templates/index.html": "<h1>hi</h1>\n",
            "requirements.txt": "flask==3.0.3\n",
        },
    }
    normalized = faas_store.validate_bundle(bundle)
    for path in ("app.py", "helpers.py", "lib/util.py", "templates/index.html"):
        assert path in normalized["files"], path


def test_validation_sandbox_applies_to_helper_modules() -> None:
    bundle = {
        "service": {
            "service_id": "bad-helper",
            "slug": "bad-helper",
            "routes": [{"path": "/hello", "methods": ["GET"]}],
        },
        "files": {
            "app.py": (
                "from flask import Flask, jsonify\nfrom helpers import x\n"
                "app = Flask(__name__)\n@app.get('/hello')\ndef hello():\n    return jsonify(x=x)\n"
            ),
            "helpers.py": "import os\nx = os.getcwd()\n",
            "requirements.txt": "flask==3.0.3\n",
        },
    }
    try:
        faas_store.validate_bundle(bundle)
    except faas_store.FaaSValidationError as exc:
        assert "import is not allowed" in str(exc) and "helpers.py" in str(exc)
    else:
        raise AssertionError("forbidden import in a helper module was accepted")


def test_validation_rejects_disallowed_file_type() -> None:
    bundle = {
        "service": {
            "service_id": "bad-file",
            "slug": "bad-file",
            "routes": [{"path": "/hello", "methods": ["GET"]}],
        },
        "files": {
            "app.py": (
                "from flask import Flask, jsonify\napp = Flask(__name__)\n"
                "@app.get('/hello')\ndef hello():\n    return jsonify(ok=True)\n"
            ),
            "evil.sh": "rm -rf /\n",
            "requirements.txt": "flask==3.0.3\n",
        },
    }
    try:
        faas_store.validate_bundle(bundle)
    except faas_store.FaaSValidationError as exc:
        assert "file type is not allowed" in str(exc)
    else:
        raise AssertionError("disallowed file type was accepted")


def test_load_bundle_zip_roundtrip() -> None:
    import io
    import zipfile

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr(
            "app.py",
            "from flask import Flask, jsonify\nfrom helpers import answer\n"
            "app = Flask(__name__)\n@app.get('/hello')\ndef hello():\n    return jsonify(v=answer())\n",
        )
        zf.writestr("helpers.py", "def answer():\n    return 42\n")
        zf.writestr(
            "service.json",
            json.dumps({"service_id": "zip-svc", "slug": "zip-svc", "routes": [{"path": "/hello", "methods": ["GET"]}]}),
        )
        zf.writestr("__MACOSX/._app.py", "junk")
        zf.writestr(".DS_Store", "junk")
    bundle = faas_store.load_bundle_zip(buf.getvalue())
    assert "app.py" in bundle["files"] and "helpers.py" in bundle["files"]
    assert "__MACOSX/._app.py" not in bundle["files"]
    assert ".DS_Store" not in bundle["files"]
    assert bundle["service"]["service_id"] == "zip-svc"
    normalized = faas_store.validate_bundle(bundle)
    assert normalized["service_id"] == "zip-svc"
    assert "helpers.py" in normalized["files"]


def test_build_service_archive_roundtrip() -> None:
    import io
    import zipfile

    with tempfile.TemporaryDirectory(prefix="myapp-faas-arch-") as raw:
        faas_store.FAAS_CODE_ROOT = raw
        faas_store.FAAS_DEPLOY_MODE = "metadata"
        faas_store.FAAS_GIT_ENABLED = False
        faas_store.FAAS_BUNDLE_SERVE_ROOT = ""
        faas_store.FAAS_MAX_SERVICES_PER_USER = 5
        _db.services.clear()
        _db.deployments.clear()

        bundle = _bundle("arch-svc")
        bundle["files"]["helpers.py"] = "def helper():\n    return 1\n"
        faas_store.deploy_bundle("user-a", bundle, source="test")

        data = faas_store.build_service_archive("arch-svc")
        names = set(zipfile.ZipFile(io.BytesIO(data)).namelist())
        assert {"app.py", "helpers.py", "service.json"} <= names

        # The downloaded archive round-trips back through the upload path.
        reloaded = faas_store.load_bundle_zip(data)
        assert reloaded["service"]["service_id"] == "arch-svc"
        assert "helpers.py" in reloaded["files"]


def test_load_bundle_zip_strips_wrapper_dir() -> None:
    import io
    import zipfile

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("zip-svc/app.py", "from flask import Flask\napp = Flask(__name__)\n")
        zf.writestr("zip-svc/helpers.py", "x = 1\n")
    bundle = faas_store.load_bundle_zip(buf.getvalue())
    assert "app.py" in bundle["files"]
    assert "helpers.py" in bundle["files"]


def test_validation_db_enabled_and_reserved_name() -> None:
    app_py = (
        "from flask import Flask, jsonify\nimport myapp_db\napp = Flask(__name__)\n"
        "@app.get('/items')\ndef items():\n    return jsonify(myapp_db.query('select 1 as x'))\n"
    )
    bundle = {
        "service": {"service_id": "db-svc", "slug": "db-svc", "routes": [{"path": "/items", "methods": ["GET"]}]},
        "files": {
            "app.py": app_py,
            "schema.sql": "CREATE TABLE IF NOT EXISTS t(id int);\n",
            "requirements.txt": "flask==3.0.3\n",
        },
    }
    n = faas_store.validate_bundle(bundle)
    assert n["db_enabled"] is True
    assert "CREATE TABLE" in n["schema_sql"]
    assert "schema.sql" in n["files"]

    # A bundle may not ship myapp_db.py (would shadow the platform helper).
    bad = {
        "service": {"service_id": "x", "slug": "x", "routes": []},
        "files": {
            "app.py": "from flask import Flask\napp = Flask(__name__)\n",
            "myapp_db.py": "x = 1\n",
            "requirements.txt": "flask==3.0.3\n",
        },
    }
    try:
        faas_store.validate_bundle(bad)
    except faas_store.FaaSValidationError as exc:
        assert "reserved" in str(exc)
    else:
        raise AssertionError("reserved myapp_db.py was accepted")


def test_failed_new_deploy_does_not_consume_quota() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-store-fail-") as raw:
        faas_store.FAAS_CODE_ROOT = raw
        faas_store.FAAS_DEPLOY_MODE = "metadata"
        faas_store.FAAS_GIT_ENABLED = False
        faas_store.FAAS_MAX_SERVICES_PER_USER = 2
        _db.services.clear()
        _db.deployments.clear()

        original_deploy = faas_store._deploy_service

        def _boom(*args, **kwargs):
            raise faas_store.FaaSError("deploy boom")

        faas_store._deploy_service = _boom
        try:
            for i in range(3):
                try:
                    faas_store.deploy_bundle("user-a", _bundle(f"flaky-{i}"), source="test")
                except faas_store.FaaSError as exc:
                    assert "deploy boom" in str(exc)
                else:
                    raise AssertionError("expected deploy failure")
            # Every failed brand-new deploy was removed, so none consumed a slot.
            assert faas_store._count_user_services("user-a") == 0
            assert "flaky-0" not in _db.services
        finally:
            faas_store._deploy_service = original_deploy

        # Quota fully reclaimed: two real services still deploy under the limit of 2.
        first = faas_store.deploy_bundle("user-a", _bundle("real-1"), source="test")
        second = faas_store.deploy_bundle("user-a", _bundle("real-2"), source="test")
        assert first.status == "ready"
        assert second.status == "ready"

        # A failed RE-deploy of an existing service keeps the row but marks it
        # failed (so it no longer counts toward quota).
        faas_store._deploy_service = _boom
        try:
            faas_store.deploy_bundle("user-a", _bundle("real-1"), source="test")
        except faas_store.FaaSError:
            pass
        else:
            raise AssertionError("expected re-deploy failure")
        finally:
            faas_store._deploy_service = original_deploy
        assert _db.services["real-1"]["status"] == "failed"
        assert faas_store._count_user_services("user-a") == 1


def test_local_docker_deploy_records_runtime_metadata() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-store-docker-") as raw:
        old_root = faas_store.FAAS_CODE_ROOT
        old_mode = faas_store.FAAS_DEPLOY_MODE
        old_start = faas_store.FAAS_LOCAL_DOCKER_START_ON_DEPLOY
        old_remove = faas_store._remove_local_docker_runtime
        try:
            faas_store.FAAS_CODE_ROOT = raw
            faas_store.FAAS_DEPLOY_MODE = "local-docker"
            # Don't actually touch docker: deferred deploy records metadata only.
            faas_store.FAAS_LOCAL_DOCKER_START_ON_DEPLOY = False
            faas_store._remove_local_docker_runtime = lambda *a, **k: None
            _db.services.clear()
            _db.deployments.clear()

            result = faas_store.deploy_bundle("user-docker", _bundle("api-docker"), source="test")
        finally:
            faas_store.FAAS_CODE_ROOT = old_root
            faas_store.FAAS_DEPLOY_MODE = old_mode
            faas_store.FAAS_LOCAL_DOCKER_START_ON_DEPLOY = old_start
            faas_store._remove_local_docker_runtime = old_remove

    assert result.status == "ready"
    deploy_meta = _db.services["api-docker"]["meta_json"]["deploy"]
    assert deploy_meta["mode"] == "local-docker"
    assert deploy_meta["runtime_image"] == faas_store.FAAS_LOCAL_DOCKER_IMAGE
    assert deploy_meta["network"] == faas_store.FAAS_LOCAL_DOCKER_NETWORK


def test_container_hardening_b2g2():
    h = faas_store._container_hardening()
    if faas_store.FAAS_HARDEN_CONTAINERS:
        assert h["cap_drop"] == ["ALL"]
        assert "no-new-privileges:true" in h["security_opt"]
        assert isinstance(h["pids_limit"], int) and h["pids_limit"] > 0
    # disabled → empty
    old = faas_store.FAAS_HARDEN_CONTAINERS
    try:
        faas_store.FAAS_HARDEN_CONTAINERS = False
        assert faas_store._container_hardening() == {}
    finally:
        faas_store.FAAS_HARDEN_CONTAINERS = old


def test_image_is_stale_xg3():
    import types as _t

    class _Img:
        def __init__(self, _id): self.id = _id

    class _Container:
        def __init__(self, image_id): self.image = _Img(image_id)

    class _Client:
        def __init__(self, desired): self.images = _t.SimpleNamespace(get=lambda name: _Img(desired))

    old = faas_store._docker_client
    try:
        faas_store._docker_client = lambda: _Client("img-new")
        assert faas_store._image_is_stale(_Container("img-old")) is True   # older image → stale
        assert faas_store._image_is_stale(_Container("img-new")) is False  # current → not stale
        # unresolvable image → fail-safe False (don't force recreate)
        def _boom():
            raise RuntimeError("no docker")
        faas_store._docker_client = _boom
        assert faas_store._image_is_stale(_Container("x")) is False
    finally:
        faas_store._docker_client = old


if __name__ == "__main__":
    test_image_is_stale_xg3()
    test_validation_rejects_dangerous_python_and_dependencies()
    test_validation_requires_declared_routes_to_match_flask_decorators()
    test_validation_rejects_reserved_runtime_routes()
    test_validation_restricts_top_level_runtime_shape()
    test_validation_supports_multi_file_service()
    test_validation_sandbox_applies_to_helper_modules()
    test_validation_rejects_disallowed_file_type()
    test_load_bundle_zip_roundtrip()
    test_build_service_archive_roundtrip()
    test_load_bundle_zip_strips_wrapper_dir()
    test_validation_db_enabled_and_reserved_name()
    test_deploy_quota_conflict_disable_and_runtime_bundle()
    test_failed_new_deploy_does_not_consume_quota()
    test_local_docker_deploy_records_runtime_metadata()
    print(json.dumps({"ok": True}, sort_keys=True))
