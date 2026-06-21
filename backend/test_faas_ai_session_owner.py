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


def test_server_deploy_faas_action_is_deprecated_and_dropped() -> None:
    # FaaS deploy is now agent-driven IN-RUN via backend/faas_deploy.sh, so the
    # legacy server_deploy_faas_service action is dropped during resolution: it
    # must never trigger a server-side deploy nor emit a faas action (which also
    # means a client-supplied user_id can never drive a deploy this way).
    calls: list[dict] = []

    fake_faas_store = types.ModuleType("faas_store")
    fake_faas_store.load_bundle_bytes = lambda raw: json.loads(raw.decode("utf-8"))

    def deploy_bundle(owner_user_id: str, bundle: dict, *, source: str):
        calls.append({"owner_user_id": owner_user_id, "bundle": bundle, "source": source})
        return _DeployResult()

    fake_faas_store.deploy_bundle = deploy_bundle
    sys.modules["faas_store"] = fake_faas_store

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

    assert calls == []
    assert all(a.get("type") not in {"faas_service_ready", "faas_service_failed"} for a in actions)


def test_faas_prompt_note_mentions_route_enforcement() -> None:
    note = ai_session._build_faas_backend_prompt_note(workspace="/tmp/workspace")
    assert "service.routes" in note
    assert "404" in note
    assert "405" in note
    assert "/items/<item_id>" in note
    assert "faas_deploy.sh" in note
    assert "faas_pull.sh" in note


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
            "archive_path": "services/todo-api/archive",
            "active_commit": "abc123",
            "updated_at": "updated",
            "source": {"app.py": "from flask import Flask\napp = Flask(__name__)\n"},
        }
    ]
    assert "reuse its service_id" in manifest["note"]
    assert "faas_pull.sh" in manifest["note"]


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


def test_rewrite_faas_invoke_service_id_uses_real_id() -> None:
    app = (
        b'{"u1":"/api/faas/invoke/todo-api/todos",'
        b'"u2":"/api/faas/invoke/todo-api/todos/{{ global.id }}"}'
    )
    out = ai_session._rewrite_faas_invoke_service_id(
        app, [({"todo-api"}, "svc-abc123")]
    ).decode()
    assert "/api/faas/invoke/svc-abc123/todos" in out
    assert "todo-api" not in out
    assert "{{ global.id }}" in out  # 模板原样保留
    # 幂等：已是真实 id 不再变
    assert (
        ai_session._rewrite_faas_invoke_service_id(
            out.encode(), [({"todo-api"}, "svc-abc123")]
        ).decode()
        == out
    )
    # 单服务：AI 用任何别的名字也兜得住（全部改成唯一的真实 id）
    out2 = ai_session._rewrite_faas_invoke_service_id(
        b'{"u":"/api/faas/invoke/whatever-name/x"}', [(set(), "svc-only")]
    ).decode()
    assert "/api/faas/invoke/svc-only/x" in out2
    # 多服务：按别名映射，未命中保持原样
    out3 = ai_session._rewrite_faas_invoke_service_id(
        b'{"a":"/api/faas/invoke/todo-api/x","b":"/api/faas/invoke/note-api/y"}',
        [({"todo-api"}, "svc-a"), ({"note-api"}, "svc-b")],
    ).decode()
    assert "/api/faas/invoke/svc-a/x" in out3 and "/api/faas/invoke/svc-b/y" in out3
    # 无部署：原样返回
    assert ai_session._rewrite_faas_invoke_service_id(app, []) == app


if __name__ == "__main__":
    test_server_deploy_faas_action_is_deprecated_and_dropped()
    test_faas_prompt_note_mentions_route_enforcement()
    test_faas_manifest_initial_file_lists_user_services()
    test_client_action_compaction_keeps_app_upload_and_faas_deploys()
    test_rewrite_faas_invoke_service_id_uses_real_id()
    print(json.dumps({"ok": True}, sort_keys=True))
