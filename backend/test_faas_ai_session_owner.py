#!/usr/bin/env python3
"""AI-session FaaS action ownership checks.

The generated client action may come from an Agent artifact, so ownership must
come from the authenticated chat session, not from any client-supplied field.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

flask = types.ModuleType("flask")
flask.jsonify = lambda *args, **kwargs: None
flask.request = object()
sys.modules["flask"] = flask

redis = types.ModuleType("redis")
redis.Redis = object
sys.modules["redis"] = redis

minio = types.ModuleType("minio")
minio.Minio = type("Minio", (), {})
sys.modules["minio"] = minio

dotenv = types.ModuleType("dotenv")
dotenv.load_dotenv = lambda *args, **kwargs: None
sys.modules["dotenv"] = dotenv

for _name in ("jwt", "requests"):
    sys.modules[_name] = types.ModuleType(_name)

import ai_session  # noqa: E402


class _DeployResult:
    service_id = "notes-api"
    function_name = "myapp-notes-api"
    status = "ready"
    commit_sha = "abc123"
    routes = [{"path": "/notes", "methods": ["GET"]}]


def test_faas_action_owner_comes_from_authenticated_session() -> None:
    calls: list[dict] = []

    fake_faas_store = types.ModuleType("faas_store")
    fake_faas_store.load_bundle_bytes = lambda raw: json.loads(raw.decode("utf-8"))

    def deploy_bundle(owner_user_id: str, bundle: dict, *, source: str):
        calls.append({"owner_user_id": owner_user_id, "bundle": bundle, "source": source})
        return _DeployResult()

    fake_faas_store.deploy_bundle = deploy_bundle
    sys.modules["faas_store"] = fake_faas_store

    class _SessionStoreMustNotBeUsed:
        def get_meta(self, session_id: str) -> dict:
            raise AssertionError("owner_user_id should be supplied by the worker")

    original_session_store = ai_session.SessionStore
    ai_session.SessionStore = _SessionStoreMustNotBeUsed
    try:
        with tempfile.TemporaryDirectory(prefix="myapp-faas-owner-") as raw:
            workspace = Path(raw)
            (workspace / "faas_bundle.json").write_text(
                json.dumps({"service_id": "notes-api", "files": {"app.py": "print('ok')"}}),
                encoding="utf-8",
            )
            actions = ai_session._resolve_server_upload_actions(
                [{
                    "type": "server_deploy_faas_service",
                    "path": "faas_bundle.json",
                    "user_id": "attacker-controlled",
                }],
                "session-123",
                workspace=str(workspace),
                owner_user_id="auth-user-123",
            )
    finally:
        ai_session.SessionStore = original_session_store

    assert calls == [{
        "owner_user_id": "auth-user-123",
        "bundle": {"service_id": "notes-api", "files": {"app.py": "print('ok')"}},
        "source": "ai-session:session-123",
    }]
    assert actions == [{
        "type": "faas_service_ready",
        "service_id": "notes-api",
        "function_name": "myapp-notes-api",
        "status": "ready",
        "commit_sha": "abc123",
        "invoke_url": "/api/faas/invoke/notes-api",
        "routes": [{"path": "/notes", "methods": ["GET"]}],
    }]


def test_faas_action_can_deploy_agent_pull_artifact() -> None:
    calls: list[dict] = []

    fake_faas_store = types.ModuleType("faas_store")
    fake_faas_store.load_bundle_bytes = lambda raw: json.loads(raw.decode("utf-8"))

    def deploy_bundle(owner_user_id: str, bundle: dict, *, source: str):
        calls.append({"owner_user_id": owner_user_id, "bundle": bundle, "source": source})
        return _DeployResult()

    fake_faas_store.deploy_bundle = deploy_bundle
    sys.modules["faas_store"] = fake_faas_store

    original_artifact_from_agent_pull = ai_session._artifact_from_agent_pull
    ai_session._artifact_from_agent_pull = lambda run_id, path: json.dumps({
        "service_id": "notes-api",
        "files": {"app.py": "print('ok')"},
        "run_id": run_id,
        "path": path,
    }).encode("utf-8")
    try:
        actions = ai_session._resolve_server_upload_actions(
            [{"type": "server_deploy_faas_service", "path": "faas_bundle.json"}],
            "session-456",
            workspace=None,
            agent_pull_run_id="pull-run-1",
            owner_user_id="auth-user-456",
        )
    finally:
        ai_session._artifact_from_agent_pull = original_artifact_from_agent_pull

    assert calls == [{
        "owner_user_id": "auth-user-456",
        "bundle": {
            "service_id": "notes-api",
            "files": {"app.py": "print('ok')"},
            "run_id": "pull-run-1",
            "path": "faas_bundle.json",
        },
        "source": "ai-session:session-456",
    }]
    assert actions[0]["type"] == "faas_service_ready"
    assert actions[0]["invoke_url"] == "/api/faas/invoke/notes-api"


def test_faas_validation_failure_returns_failed_action_without_exception_log() -> None:
    class FaaSValidationError(RuntimeError):
        pass

    fake_faas_store = types.ModuleType("faas_store")
    fake_faas_store.FaaSValidationError = FaaSValidationError
    fake_faas_store.load_bundle_bytes = lambda raw: json.loads(raw.decode("utf-8"))

    def deploy_bundle(owner_user_id: str, bundle: dict, *, source: str):
        raise FaaSValidationError("function default arguments must be literal values")

    fake_faas_store.deploy_bundle = deploy_bundle
    sys.modules["faas_store"] = fake_faas_store

    exception_calls: list[tuple] = []
    warning_calls: list[tuple] = []
    original_exception = ai_session.logger.exception
    original_warning = ai_session.logger.warning
    ai_session.logger.exception = lambda *args, **kwargs: exception_calls.append((args, kwargs))
    ai_session.logger.warning = lambda *args, **kwargs: warning_calls.append((args, kwargs))
    try:
        with tempfile.TemporaryDirectory(prefix="myapp-faas-validation-failed-") as raw:
            workspace = Path(raw)
            (workspace / "faas_bundle.json").write_text(
                json.dumps({"service_id": "bad-api", "files": {"app.py": "bad"}}),
                encoding="utf-8",
            )
            actions = ai_session._resolve_server_upload_actions(
                [{"type": "server_deploy_faas_service", "path": "faas_bundle.json"}],
                "session-validation",
                workspace=str(workspace),
                owner_user_id="auth-user-validation",
            )
    finally:
        ai_session.logger.exception = original_exception
        ai_session.logger.warning = original_warning

    assert actions == [{
        "type": "faas_service_failed",
        "path": "faas_bundle.json",
        "error": "function default arguments must be literal values",
    }]
    assert warning_calls
    assert exception_calls == []


def test_faas_prompt_note_mentions_route_enforcement() -> None:
    note = ai_session._build_faas_backend_prompt_note(workspace="/tmp/workspace")
    assert "service.routes" in note
    assert "404" in note
    assert "405" in note
    assert "/items/<item_id>" in note
    assert "server_deploy_faas_service" in note


def test_faas_manifest_initial_file_lists_user_services() -> None:
    fake_faas_store = types.ModuleType("faas_store")
    fake_faas_store.FAAS_MAX_SERVICES_PER_USER = 5
    fake_faas_store.read_service_source = lambda *a, **k: {"app.py": "from flask import Flask\napp = Flask(__name__)\n"}
    fake_faas_store.list_services = lambda user_id: [
        {
            "service_id": "todo-api",
            "service_slug": "todo-api",
            "status": "ready",
            "routes": [{"path": "/items", "methods": ["GET", "POST"]}],
            "active_commit": "abc123",
            "updated_at": "updated",
        }
    ]
    sys.modules["faas_store"] = fake_faas_store

    with tempfile.TemporaryDirectory(prefix="myapp-faas-manifest-") as raw:
        ai_session._write_faas_manifest(raw, "auth-user-789")
        manifest = json.loads((Path(raw) / "faas_services.json").read_text(encoding="utf-8"))

    assert manifest["owner_user_id"] == "auth-user-789"
    assert manifest["max_services"] == 5
    assert manifest["services"] == [
        {
            "service_id": "todo-api",
            "slug": "todo-api",
            "status": "ready",
            "routes": [{"path": "/items", "methods": ["GET", "POST"]}],
            "invoke_url": "/api/faas/invoke/todo-api",
            "active_commit": "abc123",
            "updated_at": "updated",
            "source": {"app.py": "from flask import Flask\napp = Flask(__name__)\n"},
        }
    ]
    assert "reuse its service_id" in manifest["note"]


def test_client_action_compaction_keeps_app_upload_and_faas_deploys() -> None:
    actions = ai_session._compact_client_actions(
        [
            {"type": "server_deploy_faas_service", "path": "first_bundle.json"},
            {"type": "server_upload_app_json", "path": "draft.json"},
            {"type": "server_upload_app_json", "path": "app.json"},
            {"type": "server_deploy_faas_service", "path": "faas_bundle.json"},
        ],
        "session-compact",
    )

    assert actions == [
        {"type": "server_upload_app_json", "path": "app.json"},
        {"type": "server_deploy_faas_service", "path": "first_bundle.json"},
        {"type": "server_deploy_faas_service", "path": "faas_bundle.json"},
    ]


if __name__ == "__main__":
    test_faas_action_owner_comes_from_authenticated_session()
    test_faas_action_can_deploy_agent_pull_artifact()
    test_faas_validation_failure_returns_failed_action_without_exception_log()
    test_faas_prompt_note_mentions_route_enforcement()
    test_faas_manifest_initial_file_lists_user_services()
    test_client_action_compaction_keeps_app_upload_and_faas_deploys()
    print(json.dumps({"ok": True}, sort_keys=True))
