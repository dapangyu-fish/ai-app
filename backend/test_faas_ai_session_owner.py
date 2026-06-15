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


if __name__ == "__main__":
    test_faas_action_owner_comes_from_authenticated_session()
    print(json.dumps({"ok": True}, sort_keys=True))
