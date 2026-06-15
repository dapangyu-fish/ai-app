#!/usr/bin/env python3
"""HTTP-level OpenFaaS gateway compatibility check.

This starts a tiny stdlib HTTP server that implements the OpenFaaS endpoints
used by MyApp. It verifies the adapter's request methods and payload without
requiring a real faasd host.
"""

from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
import types
from urllib.parse import unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-test",
    "FAAS_DEPLOY_MODE": "openfaas",
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
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": True,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 5,
    "FAAS_OPENFAAS_GATEWAY": "",
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

_database = types.ModuleType("database")
_database.db_execute = lambda *args, **kwargs: None
_database.db_query = lambda *args, **kwargs: []
sys.modules["database"] = _database

import faas_store  # noqa: E402


class _GatewayState:
    def __init__(self) -> None:
        self.functions: dict[str, dict] = {}
        self.calls: list[tuple[str, str, dict | None]] = []


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict | list | None = None) -> None:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)


def _read_json(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length") or "0")
    raw = handler.rfile.read(length) if length > 0 else b"{}"
    return json.loads(raw.decode("utf-8")) if raw else {}


def _handler(state: _GatewayState):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            return

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/healthz":
                state.calls.append(("GET", path, None))
                _json_response(self, 200, {"ok": True})
                return
            if path.startswith("/system/function/"):
                name = unquote(path.rsplit("/", 1)[-1])
                state.calls.append(("GET", path, None))
                item = state.functions.get(name)
                _json_response(self, 200, item) if item else _json_response(self, 404, {"error": "not found"})
                return
            if path == "/system/functions":
                state.calls.append(("GET", path, None))
                _json_response(self, 200, list(state.functions.values()))
                return
            if path.startswith("/function/"):
                name = unquote(path.split("/", 3)[2])
                state.calls.append(("GET", path, None))
                item = state.functions.get(name)
                if not item:
                    _json_response(self, 404, {"error": "not found"})
                    return
                _json_response(self, 200, {"ok": True, "service": name, "envVars": item.get("envVars") or {}})
                return
            _json_response(self, 404, {"error": "not found"})

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            payload = _read_json(self)
            state.calls.append(("POST", path, payload))
            if path != "/system/functions":
                _json_response(self, 404, {"error": "not found"})
                return
            name = str(payload.get("service") or "")
            if not name:
                _json_response(self, 400, {"error": "missing service"})
                return
            if name in state.functions:
                _json_response(self, 409, {"error": "already exists"})
                return
            state.functions[name] = payload
            _json_response(self, 202, {"status": "accepted"})

        def do_PUT(self) -> None:
            path = urlparse(self.path).path
            payload = _read_json(self)
            state.calls.append(("PUT", path, payload))
            if path != "/system/functions":
                _json_response(self, 404, {"error": "not found"})
                return
            name = str(payload.get("service") or "")
            if not name:
                _json_response(self, 400, {"error": "missing service"})
                return
            if name not in state.functions:
                _json_response(self, 404, {"error": "not found"})
                return
            state.functions[name] = payload
            _json_response(self, 200, {"status": "updated"})

        def do_DELETE(self) -> None:
            path = urlparse(self.path).path
            payload = _read_json(self)
            state.calls.append(("DELETE", path, payload))
            if path != "/system/functions":
                _json_response(self, 404, {"error": "not found"})
                return
            name = str(payload.get("functionName") or "")
            state.functions.pop(name, None)
            _json_response(self, 202, {"status": "deleted"})

    return Handler


def main() -> int:
    state = _GatewayState()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    gateway = f"http://127.0.0.1:{server.server_address[1]}"
    faas_store.FAAS_OPENFAAS_GATEWAY = gateway
    faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = "example/faas-runtime:test"
    faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = "https://backend.example"
    faas_store.FAAS_RUNTIME_TOKEN = "runtime-master-token"

    try:
        first = faas_store._deploy_openfaas_function(
            function_name="myapp-gateway-api",
            service_id="gateway-api",
            commit_sha="abc123",
        )
        second = faas_store._deploy_openfaas_function(
            function_name="myapp-gateway-api",
            service_id="gateway-api",
            commit_sha="def456",
        )
        deleted = faas_store._delete_openfaas_function("myapp-gateway-api")
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()

    methods = [item[0] for item in state.calls if item[1].startswith("/system/")]
    assert methods == ["GET", "POST", "GET", "PUT", "DELETE"], methods
    assert "method=POST" in first, first
    assert "method=PUT" in second, second
    assert "status=202" in deleted, deleted

    payload = state.calls[3][2] or {}
    assert payload["service"] == "myapp-gateway-api"
    assert payload["image"] == "example/faas-runtime:test"
    assert payload["envVars"]["MYAPP_FAAS_SERVICE_ID"] == "gateway-api"
    assert payload["envVars"]["MYAPP_FAAS_COMMIT"] == "def456"
    assert payload["envVars"]["MYAPP_FAAS_BUNDLE_URL"] == "https://backend.example/api/faas/runtime_bundle/gateway-api"
    assert payload["envVars"]["MYAPP_FAAS_RUNTIME_TOKEN"] == faas_store.runtime_token_for_service("gateway-api")
    assert payload["labels"]["com.openfaas.scale.zero"] == "true"
    assert payload["labels"]["myapp.faas.service_id"] == "gateway-api"

    print(json.dumps({"ok": True, "gateway": gateway, "calls": methods}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
