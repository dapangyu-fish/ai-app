#!/usr/bin/env python3
"""Smoke-test AI-session generated FaaS action resolution inside backend.

Run this inside the backend container. It writes the same artifacts an Agent is
expected to write (`faas_bundle.json` + `client_actions.json`), asks
ai_session to resolve the server-side deploy action, invokes the generated
service through the public HTTP proxy, and then cleans up.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile
from typing import Any

import requests


def _bundle(service_id: str) -> dict[str, Any]:
    app_py = """from flask import Flask, jsonify, request

app = Flask(__name__)

@app.get("/hello")
def hello():
    return jsonify({"ok": True, "message": "hello " + request.args.get("name", "ai-action")})
"""
    return {
        "service": {
            "service_id": service_id,
            "slug": "ai-action-smoke",
            "routes": [
                {"path": "/hello", "methods": ["GET"], "description": "AI action smoke endpoint"},
            ],
        },
        "files": {
            "app.py": app_py,
            "requirements.txt": "flask==3.0.3\n",
            "README.md": "# ai-action-smoke\n",
        },
    }


def _invalid_bundle(service_id: str) -> dict[str, Any]:
    app_py = """import time
from flask import Flask, jsonify

app = Flask(__name__)

@app.get("/hello")
def hello(seed=time.sleep(1)):
    return jsonify({"ok": True})
"""
    return {
        "service": {
            "service_id": service_id,
            "slug": "ai-action-invalid-smoke",
            "routes": [
                {"path": "/hello", "methods": ["GET"], "description": "invalid import-time side effect"},
            ],
        },
        "files": {
            "app.py": app_py,
            "requirements.txt": "flask==3.0.3\n",
        },
    }


def _request(method: str, url: str, **kwargs: Any) -> requests.Response:
    resp = requests.request(method, url, timeout=60, **kwargs)
    if resp.status_code >= 400:
        raise RuntimeError(f"{method} {url} failed {resp.status_code}: {resp.text[:1000]}")
    return resp


def _resolve_bundle_action(ai_session, *, bundle: dict[str, Any], session_id: str, owner_user_id: str) -> list[dict]:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-ai-action-") as raw:
        workspace = Path(raw)
        bundle_path = workspace / "faas_bundle.json"
        action_path = workspace / "client_actions.json"
        bundle_path.write_text(json.dumps(bundle, ensure_ascii=False), encoding="utf-8")
        action_path.write_text(
            json.dumps([{"type": "server_deploy_faas_service", "path": "faas_bundle.json"}], ensure_ascii=False),
            encoding="utf-8",
        )
        return ai_session._resolve_server_upload_actions(
            json.loads(action_path.read_text(encoding="utf-8")),
            session_id,
            workspace=str(workspace),
            owner_user_id=owner_user_id,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test AI-session FaaS deploy action resolution.")
    parser.add_argument("--base-url", default="http://127.0.0.1:5566", help="backend base URL")
    parser.add_argument("--user-id", default="ai-action-smoke-user", help="owner user id")
    parser.add_argument("--session-id", default="ai-action-smoke-session", help="test session id")
    parser.add_argument("--service-id", default="ai-action-smoke-api", help="test service id")
    parser.add_argument("--no-cleanup", action="store_true", help="leave generated service in place")
    parser.add_argument("--include-invalid", action="store_true", help="also verify an invalid generated bundle fails")
    args = parser.parse_args()

    backend_dir = Path(__file__).resolve().parent
    if backend_dir.name != "backend":
        # The script may be docker-copied into /tmp. Import backend modules from
        # the normal image path.
        sys.path.insert(0, "/app/backend")

    import ai_session  # noqa: WPS433
    from database import db_execute  # noqa: WPS433
    from faas_store import disable_service, service_code_root  # noqa: WPS433

    invalid_actions = None
    if args.include_invalid:
        invalid_service_id = f"{args.service_id}-invalid"
        invalid_actions = _resolve_bundle_action(
            ai_session,
            bundle=_invalid_bundle(invalid_service_id),
            session_id=f"{args.session_id}-invalid",
            owner_user_id=args.user_id,
        )
        invalid_ready = [item for item in invalid_actions if item.get("type") == "faas_service_ready"]
        invalid_failed = [item for item in invalid_actions if item.get("type") == "faas_service_failed"]
        if invalid_ready or not invalid_failed:
            raise RuntimeError(f"invalid FaaS AI action did not fail as expected: {invalid_actions}")
        error_text = str(invalid_failed[0].get("error") or "")
        if "default arguments" not in error_text:
            raise RuntimeError(f"invalid FaaS AI action failed for an unexpected reason: {invalid_actions}")

    service_root = service_code_root(args.user_id, args.service_id)
    actions = _resolve_bundle_action(
        ai_session,
        bundle=_bundle(args.service_id),
        session_id=args.session_id,
        owner_user_id=args.user_id,
    )

    ready = [item for item in actions if item.get("type") == "faas_service_ready"]
    failed = [item for item in actions if item.get("type") == "faas_service_failed"]
    if failed or not ready:
        raise RuntimeError(f"FaaS AI action did not resolve ready: {actions}")
    invoke_url = f"{args.base_url.rstrip()}/api/faas/invoke/{args.service_id}/hello?name=ai-action"
    invoke = _request("GET", invoke_url).json()
    if invoke.get("message") != "hello ai-action":
        raise RuntimeError(f"unexpected invoke payload: {invoke}")

    cleanup = None
    if not args.no_cleanup:
        cleanup = disable_service(args.user_id, args.service_id)
        db_execute("DELETE FROM faas_deployments WHERE service_id=%s", [args.service_id])
        db_execute("DELETE FROM faas_services WHERE service_id=%s", [args.service_id])
        shutil.rmtree(service_root, ignore_errors=True)

    print(json.dumps(
        {
            "ok": True,
            "actions": actions,
            "invoke": invoke,
            "invalid_actions": invalid_actions,
            "cleanup_status": cleanup.get("status") if isinstance(cleanup, dict) else None,
            "service_id": args.service_id,
            "user_id": args.user_id,
        },
        ensure_ascii=False,
        sort_keys=True,
    ))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
