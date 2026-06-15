#!/usr/bin/env python3
"""OpenFaaS gateway preflight script checks."""

from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
from urllib.parse import urlparse


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict | list | None = None) -> None:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)


class _Handler(BaseHTTPRequestHandler):
    password = "openfaas-password"

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/healthz":
            _json_response(self, 200, {"ok": True})
            return
        if path == "/system/functions":
            auth = self.headers.get("Authorization", "")
            expected = "Basic " + base64.b64encode(f"admin:{self.password}".encode("utf-8")).decode("ascii")
            if auth != expected:
                _json_response(self, 401, {"error": "unauthorized", "token": "bad-secret-token"})
                return
            _json_response(
                self,
                200,
                [
                    {
                        "name": "existing-faas",
                        "envVars": {
                            "MYAPP_FAAS_RUNTIME_TOKEN": "runtime-token-should-not-leak",
                            "PASSWORD": "password-should-not-leak",
                        },
                    }
                ],
            )
            return
        if path == "/api/faas/health":
            _json_response(self, 200, {"ok": True, "deploy_mode": "local-docker"})
            return
        _json_response(self, 404, {"error": "not found"})


def test_gateway_check_success_and_auth_failure() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    script = Path(__file__).resolve().parents[1] / "scripts" / "faas_openfaas_gateway_check.py"
    try:
        good = subprocess.run(
            [
                sys.executable,
                str(script),
                "--gateway",
                base,
                "--bundle-base-url",
                base,
                "--password-env",
                "OPENFAAS_TEST_PASSWORD",
                "--json",
            ],
            env={"OPENFAAS_TEST_PASSWORD": _Handler.password},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )
        bad = subprocess.run(
            [
                sys.executable,
                str(script),
                "--gateway",
                base,
                "--bundle-base-url",
                base,
                "--password-env",
                "OPENFAAS_TEST_PASSWORD",
                "--json",
            ],
            env={"OPENFAAS_TEST_PASSWORD": "wrong"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()

    assert good.returncode == 0, good.stderr or good.stdout
    good_payload = json.loads(good.stdout)
    assert good_payload["ok"] is True
    good_text = json.dumps(good_payload)
    assert "runtime-token-should-not-leak" not in good_text
    assert "password-should-not-leak" not in good_text
    good_functions = [item for item in good_payload["checks"] if item["name"] == "gateway-functions"][0]
    assert "body" not in good_functions

    assert bad.returncode == 1
    bad_payload = json.loads(bad.stdout)
    assert bad_payload["ok"] is False
    functions = [item for item in bad_payload["checks"] if item["name"] == "gateway-functions"][0]
    assert functions["status"] == 401
    assert "bad-secret-token" not in json.dumps(functions)


if __name__ == "__main__":
    test_gateway_check_success_and_auth_failure()
    print(json.dumps({"ok": True}, sort_keys=True))
