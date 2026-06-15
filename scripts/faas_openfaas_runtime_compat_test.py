#!/usr/bin/env python3
"""OpenFaaS-compatible runtime smoke test.

This is not a replacement for a real faasd/OpenFaaS gateway test. It verifies
the part of the contract that tends to break before a real gateway is
available: MyApp's OpenFaaS deploy payload, the generic FaaS runtime image,
runtime bundle download with the per-service token, and function invocation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import types
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

import requests


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_DIR = REPO_ROOT / "backend"
sys.path.insert(0, str(BACKEND_DIR))


def _install_backend_stubs(runtime_image: str, bundle_base_url: str, runtime_token: str) -> None:
    config = types.ModuleType("config")
    for name, value in {
        "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
        "FAAS_CODE_ROOT": "/tmp/myapp-faas-openfaas-compat",
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
        "FAAS_GIT_SSH_KEY_PATH": "",
        "FAAS_GIT_KNOWN_HOSTS_PATH": "",
        "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
        "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
        "FAAS_LOCAL_DOCKER_IMAGE": runtime_image,
        "FAAS_LOCAL_DOCKER_NETWORK": "bridge",
        "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": True,
        "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
        "FAAS_MAX_SERVICES_PER_USER": 5,
        "FAAS_OPENFAAS_GATEWAY": "",
        "FAAS_OPENFAAS_MAX_REPLICAS": 1,
        "FAAS_OPENFAAS_MIN_REPLICAS": 0,
        "FAAS_OPENFAAS_PASSWORD": "",
        "FAAS_OPENFAAS_READ_TIMEOUT": "60s",
        "FAAS_OPENFAAS_RUNTIME_IMAGE": runtime_image,
        "FAAS_OPENFAAS_SCALE_ZERO": True,
        "FAAS_OPENFAAS_USERNAME": "admin",
        "FAAS_OPENFAAS_WRITE_TIMEOUT": "60s",
        "FAAS_PUBLIC_BASE_URL": "http://127.0.0.1",
        "FAAS_REQUIREMENTS_MAX_LINES": 40,
        "FAAS_RUNTIME_BUNDLE_BASE_URL": bundle_base_url,
        "FAAS_RUNTIME_TOKEN": runtime_token,
    }.items():
        setattr(config, name, value)
    sys.modules["config"] = config

    database = types.ModuleType("database")
    database.db_execute = lambda *args, **kwargs: None
    database.db_query = lambda *args, **kwargs: []
    sys.modules["database"] = database


def _run(cmd: list[str], *, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )


def _docker(*args: str, timeout: int = 60) -> str:
    proc = _run(["docker", *args], timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "docker command failed").strip())
    return proc.stdout.strip()


def _host_gateway_supported() -> bool:
    proc = _run(["docker", "version", "--format", "{{.Server.Version}}"], timeout=10)
    return proc.returncode == 0


def _container_name(function_name: str) -> str:
    digest = hashlib.sha256(function_name.encode("utf-8")).hexdigest()[:12]
    safe = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in function_name.lower()).strip(".-")
    return f"myapp-openfaas-compat-{safe[:32]}-{digest}"


def _bundle_for_service(service_id: str) -> dict[str, Any]:
    app_py = """from flask import Flask, jsonify, request

app = Flask(__name__)

@app.get("/hello")
def hello():
    return jsonify({"ok": True, "message": "hello " + request.args.get("name", "openfaas")})

@app.post("/echo")
def echo():
    return jsonify({"ok": True, "json": request.get_json(silent=True)})
"""
    return {
        "service": {
            "service_id": service_id,
            "slug": "openfaas-compat",
            "function_name": "myapp-openfaas-compat",
            "routes": [
                {"path": "/hello", "methods": ["GET"]},
                {"path": "/echo", "methods": ["POST"]},
            ],
        },
        "files": {
            "app.py": app_py,
            "requirements.txt": "flask==3.0.3\n",
            "service.json": json.dumps({"service_id": service_id, "runtime": "python-flask"}) + "\n",
            "README.md": "# openfaas-compat\n",
        },
    }


class _BundleState:
    def __init__(self, *, service_id: str, token: str, bundle: dict[str, Any]) -> None:
        self.service_id = service_id
        self.token = token
        self.bundle = bundle
        self.calls: list[dict[str, Any]] = []


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict | list | None = None) -> None:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)


def _bundle_handler(state: _BundleState):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            return

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            token = self.headers.get("X-MyApp-FaaS-Runtime-Token", "")
            state.calls.append({"path": path, "token": token})
            expected_path = f"/api/faas/runtime_bundle/{state.service_id}"
            if path != expected_path:
                _json_response(self, 404, {"error": "not found"})
                return
            if token != state.token:
                _json_response(self, 403, {"error": "forbidden"})
                return
            _json_response(self, 200, state.bundle)

    return Handler


class _GatewayState:
    def __init__(self, *, keep: bool = False, network: str = "") -> None:
        self.keep = keep
        self.network = network
        self.functions: dict[str, dict[str, Any]] = {}
        self.containers: dict[str, str] = {}
        self.calls: list[tuple[str, str, dict | None]] = []

    def cleanup(self) -> None:
        if self.keep:
            return
        for container in list(self.containers.values()):
            _run(["docker", "rm", "-f", container], timeout=30)
        self.containers.clear()


def _read_json(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length") or "0")
    raw = handler.rfile.read(length) if length > 0 else b"{}"
    return json.loads(raw.decode("utf-8")) if raw else {}


def _wait_http(url: str, *, timeout: float = 30.0) -> None:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            resp = requests.get(url, timeout=1.0)
            if resp.status_code == 200:
                return
            last = f"status={resp.status_code} body={resp.text[:200]}"
        except Exception as exc:
            last = str(exc)
        time.sleep(0.3)
    raise RuntimeError(f"runtime did not become healthy: {last}")


def _start_runtime_container(function_name: str, payload: dict[str, Any], state: _GatewayState) -> str:
    image = str(payload.get("image") or "").strip()
    env_vars = payload.get("envVars") if isinstance(payload.get("envVars"), dict) else {}
    if not image:
        raise RuntimeError("OpenFaaS payload missing image")
    name = _container_name(function_name)
    _run(["docker", "rm", "-f", name], timeout=30)
    cmd = [
        "docker",
        "run",
        "-d",
        "--name",
        name,
        "--label",
        "myapp.component=faas-openfaas-compat",
        "--add-host",
        "host.docker.internal:host-gateway",
        "-p",
        "127.0.0.1::8080",
    ]
    if state.network:
        cmd.extend(["--network", state.network])
    for key, value in env_vars.items():
        cmd.extend(["-e", f"{key}={value}"])
    cmd.append(image)
    proc = _run(cmd, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "docker run failed").strip())
    state.containers[function_name] = name
    inspect = _docker(
        "inspect",
        "-f",
        "{{(index (index .NetworkSettings.Ports \"8080/tcp\") 0).HostPort}}",
        name,
        timeout=30,
    )
    upstream = f"http://127.0.0.1:{inspect.strip()}"
    _wait_http(f"{upstream}/__myapp_faas_health")
    return upstream


def _gateway_handler(state: _GatewayState):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            return

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path
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
                parts = path.split("/", 3)
                name = unquote(parts[2]) if len(parts) >= 3 else ""
                suffix = "/" + parts[3] if len(parts) == 4 else ""
                item = state.functions.get(name)
                state.calls.append(("GET", path, None))
                if not item:
                    _json_response(self, 404, {"error": "not found"})
                    return
                upstream = str(item.get("upstream") or "").rstrip("/") + suffix
                if parsed.query:
                    upstream = f"{upstream}?{parsed.query}"
                resp = requests.get(upstream, timeout=30)
                self.send_response(resp.status_code)
                for key, value in resp.headers.items():
                    if key.lower() not in {"connection", "content-length", "transfer-encoding"}:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(resp.content)))
                self.end_headers()
                self.wfile.write(resp.content)
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
            try:
                upstream = _start_runtime_container(name, payload, state)
            except Exception as exc:
                _json_response(self, 500, {"error": str(exc)})
                return
            item = dict(payload)
            item["upstream"] = upstream
            state.functions[name] = item
            _json_response(self, 202, {"status": "accepted"})

        def do_PUT(self) -> None:
            path = urlparse(self.path).path
            payload = _read_json(self)
            state.calls.append(("PUT", path, payload))
            if path != "/system/functions":
                _json_response(self, 404, {"error": "not found"})
                return
            name = str(payload.get("service") or "")
            if name not in state.functions:
                _json_response(self, 404, {"error": "not found"})
                return
            try:
                upstream = _start_runtime_container(name, payload, state)
            except Exception as exc:
                _json_response(self, 500, {"error": str(exc)})
                return
            item = dict(payload)
            item["upstream"] = upstream
            state.functions[name] = item
            _json_response(self, 200, {"status": "updated"})

        def do_DELETE(self) -> None:
            path = urlparse(self.path).path
            payload = _read_json(self)
            state.calls.append(("DELETE", path, payload))
            if path != "/system/functions":
                _json_response(self, 404, {"error": "not found"})
                return
            name = str(payload.get("functionName") or "")
            container = state.containers.pop(name, "")
            if container:
                _run(["docker", "rm", "-f", container], timeout=30)
            state.functions.pop(name, None)
            _json_response(self, 202, {"status": "deleted"})

    return Handler


def _serve(handler, *, bind_host: str = "127.0.0.1") -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer((bind_host, 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def _close(server: ThreadingHTTPServer) -> None:
    server.shutdown()
    server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run an OpenFaaS-compatible runtime smoke test with local Docker.")
    parser.add_argument("--runtime-image", default=os.environ.get("MYAPP_FAAS_RUNTIME_IMAGE", "dapangyu/myapp-faas-runtime:agent-control-plane"))
    parser.add_argument("--service-id", default="openfaas-compat-api")
    parser.add_argument("--function-name", default="myapp-openfaas-compat-api")
    parser.add_argument("--pull-image", action="store_true", help="docker pull the runtime image before running")
    parser.add_argument("--keep", action="store_true", help="keep runtime containers after the test")
    args = parser.parse_args()

    if not shutil.which("docker"):
        raise RuntimeError("docker CLI is required")
    if not _host_gateway_supported():
        raise RuntimeError("docker daemon is not reachable")
    if args.pull_image:
        _docker("pull", args.runtime_image, timeout=300)

    master_token = "openfaas-compat-runtime-master"
    _install_backend_stubs(args.runtime_image, "http://host.docker.internal:0", master_token)
    import faas_store  # noqa: E402

    runtime_token = faas_store.runtime_token_for_service(args.service_id)
    bundle_state = _BundleState(
        service_id=args.service_id,
        token=runtime_token,
        bundle=_bundle_for_service(args.service_id),
    )
    bundle_server, bundle_base = _serve(_bundle_handler(bundle_state), bind_host="0.0.0.0")
    gateway_state = _GatewayState(keep=args.keep)
    gateway_server, gateway_base = _serve(_gateway_handler(gateway_state))

    try:
        faas_store.FAAS_OPENFAAS_GATEWAY = gateway_base
        faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = args.runtime_image
        faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = bundle_base.replace("127.0.0.1", "host.docker.internal")
        faas_store.FAAS_RUNTIME_TOKEN = master_token

        first = faas_store._deploy_openfaas_function(
            function_name=args.function_name,
            service_id=args.service_id,
            commit_sha="compat-1",
        )
        invoke = requests.get(f"{gateway_base}/function/{args.function_name}/hello?name=compat", timeout=30)
        invoke.raise_for_status()
        payload = invoke.json()
        if payload.get("message") != "hello compat":
            raise RuntimeError(f"unexpected function response: {payload}")

        second = faas_store._deploy_openfaas_function(
            function_name=args.function_name,
            service_id=args.service_id,
            commit_sha="compat-2",
        )
        deleted = faas_store._delete_openfaas_function(args.function_name)
    finally:
        gateway_state.cleanup()
        _close(gateway_server)
        _close(bundle_server)

    methods = [item[0] for item in gateway_state.calls if item[1].startswith("/system/")]
    if methods != ["GET", "POST", "GET", "PUT", "DELETE"]:
        raise RuntimeError(f"unexpected OpenFaaS method sequence: {methods}")
    if not bundle_state.calls:
        raise RuntimeError("runtime did not fetch its bundle")
    if any(item["token"] != runtime_token for item in bundle_state.calls):
        raise RuntimeError(f"runtime used the wrong bundle token: {bundle_state.calls}")

    print(json.dumps(
        {
            "ok": True,
            "runtime_image": args.runtime_image,
            "gateway": gateway_base,
            "bundle_calls": len(bundle_state.calls),
            "openfaas_methods": methods,
            "deploy": [first, second, deleted],
        },
        sort_keys=True,
    ))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
