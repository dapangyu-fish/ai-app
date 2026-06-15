#!/usr/bin/env python3
"""FaaS invoke route contract checks."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

flask = types.ModuleType("flask")
flask.Response = object
flask.jsonify = lambda payload=None, *args, **kwargs: payload if payload is not None else {}
flask.request = object()
flask.stream_with_context = lambda generator: generator
sys.modules["flask"] = flask

auth = types.ModuleType("auth")
auth.verify_access_token = lambda token: None
sys.modules["auth"] = auth

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_OPENFAAS_GATEWAY": "",
    "FAAS_REQUIRE_AUTH": False,
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

faas_store = types.ModuleType("faas_store")
faas_store.FaaSError = type("FaaSError", (RuntimeError,), {})
faas_store.FaaSValidationError = type("FaaSValidationError", (RuntimeError,), {})
faas_store.deploy_bundle = lambda *args, **kwargs: None
faas_store.disable_service = lambda *args, **kwargs: None
faas_store.ensure_local_docker_runtime_for_service = lambda *args, **kwargs: None
faas_store.ensure_tables = lambda *args, **kwargs: None
faas_store.get_service = lambda *args, **kwargs: None
faas_store.list_services = lambda *args, **kwargs: []
faas_store.load_bundle_bytes = lambda *args, **kwargs: {}
faas_store.runtime_bundle_for_service = lambda *args, **kwargs: {}
faas_store.runtime_token_for_service = lambda *args, **kwargs: "runtime-token"
sys.modules["faas_store"] = faas_store

import faas  # noqa: E402


def _service(routes):
    return {"routes": routes}


def test_route_allowlist_contract() -> None:
    assert faas._route_allowed(_service([]), "/anything", "POST") == (True, 200, "")
    assert faas._route_allowed(_service([{"path": "/items", "methods": ["GET", "POST"]}]), "/items", "GET") == (True, 200, "")
    assert faas._route_allowed(_service([{"path": "/items", "methods": ["GET"]}]), "/items", "HEAD") == (True, 200, "")
    assert faas._route_allowed(_service([{"path": "/items", "methods": ["GET"]}]), "/items", "POST") == (
        False,
        405,
        "method is not allowed for this FaaS route",
    )
    assert faas._route_allowed(_service([{"path": "/items", "methods": ["GET"]}]), "/admin", "GET") == (
        False,
        404,
        "route is not declared by this FaaS service",
    )


def test_flask_style_route_patterns() -> None:
    routes = [
        {"path": "/items/<item_id>", "methods": ["GET"]},
        {"path": "/typed/<int:item_id>", "methods": ["DELETE"]},
        {"path": "/files/<path:tail>", "methods": ["GET"]},
    ]
    assert faas._route_allowed(_service(routes), "/items/abc", "GET") == (True, 200, "")
    assert faas._route_allowed(_service(routes), "/typed/42", "DELETE") == (True, 200, "")
    assert faas._route_allowed(_service(routes), "/files/a/b/c", "GET") == (True, 200, "")
    assert faas._route_allowed(_service(routes), "/files", "GET")[0] is False


def test_rejected_route_does_not_start_runtime() -> None:
    class _Request:
        method = "GET"
        query_string = b""
        headers = {}

        @staticmethod
        def get_data():
            return b""

    called = {"runtime": False}
    old_request = faas.request
    old_get_service = faas.get_service
    old_ensure = faas.ensure_local_docker_runtime_for_service
    old_mode = faas.FAAS_DEPLOY_MODE
    try:
        faas.request = _Request()
        faas.FAAS_DEPLOY_MODE = "local-docker"
        faas.get_service = lambda service_id: {
            "service_id": service_id,
            "status": "ready",
            "routes": [{"path": "/hello", "methods": ["GET"]}],
        }

        def fail_if_called(service):
            called["runtime"] = True
            raise AssertionError("runtime should not start for a rejected route")

        faas.ensure_local_docker_runtime_for_service = fail_if_called
        body, status = faas.invoke_service("svc", "admin")
    finally:
        faas.request = old_request
        faas.get_service = old_get_service
        faas.ensure_local_docker_runtime_for_service = old_ensure
        faas.FAAS_DEPLOY_MODE = old_mode

    assert status == 404
    assert body["code"] == "FAAS_ROUTE_NOT_ALLOWED"
    assert called["runtime"] is False


if __name__ == "__main__":
    test_route_allowlist_contract()
    test_flask_style_route_patterns()
    test_rejected_route_does_not_start_runtime()
    print(json.dumps({"ok": True}, sort_keys=True))
