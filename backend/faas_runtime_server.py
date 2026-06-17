#!/usr/bin/env python3
"""Runtime entrypoint for generated Python/Flask FaaS services.

The control plane validates and writes generated service code under
FAAS_CODE_ROOT. This process runs in a separate container without backend
secrets, loads that service's app.py, and exposes it on port 8080.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
import threading
from pathlib import Path

import requests
from flask import Flask, jsonify


_SAFE_FILE_RE = re.compile(r"^[A-Za-z0-9_.\-/]+$")
_ALLOWED_FILES = {"app.py", "requirements.txt", "service.json", "README.md"}
_ALLOWED_PREFIXES = ("tests/",)


def _inject_platform_config(app: Flask) -> None:
    """Bridge backend-injected ``MYAPP_CFG_*`` env vars into ``app.config["MYAPP"]``.

    The backend injects public, non-secret platform config (Supabase URL + anon
    key, backend base URL, faasd public URL) as ``MYAPP_CFG_*`` env vars on every
    function. The generated ``app.py`` cannot import ``os`` (validator), so the
    runtime — which runs with full Python — copies them into the app config under
    a single ``MYAPP`` dict (lowercased, prefix stripped). Generated code reads
    ``current_app.config["MYAPP"]["supabase_url"]`` and builds URLs from config
    instead of hardcoding domains. Only the ``MYAPP_CFG_`` prefix is exposed;
    internal vars (``MYAPP_FAAS_RUNTIME_TOKEN`` / ``MYAPP_FAAS_BUNDLE_URL``) keep
    the ``MYAPP_FAAS_`` prefix and are never bridged.
    """
    platform = {}
    for key, value in os.environ.items():
        if key.startswith("MYAPP_CFG_") and value:
            platform[key[len("MYAPP_CFG_"):].lower()] = value
    app.config["MYAPP"] = platform


def _load_generated_app(service_dir: Path):
    app_py = service_dir / "app.py"
    if not app_py.is_file():
        raise RuntimeError(f"generated service app.py not found: {app_py}")

    module_name = f"myapp_generated_faas_{os.getpid()}"
    spec = importlib.util.spec_from_file_location(module_name, str(app_py))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load generated service: {app_py}")

    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    original_path = list(sys.path)
    sys.path.insert(0, str(service_dir))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original_path

    app = getattr(module, "app", None) or getattr(module, "application", None)
    if not isinstance(app, Flask):
        raise RuntimeError("generated app.py must expose a Flask instance named app or application")
    _inject_platform_config(app)
    return app


def _attach_health(app: Flask, service_id: str) -> Flask:
    @app.get("/__myapp_faas_health")
    def _myapp_faas_health():
        return jsonify({"ok": True, "service_id": service_id})

    return app


def _validate_bundle_path(path: str) -> str:
    normalized = os.path.normpath(str(path or "").strip()).replace("\\", "/")
    if normalized in {"", ".", ".."} or normalized.startswith("../") or os.path.isabs(normalized):
        raise RuntimeError(f"invalid bundle file path: {path}")
    if not _SAFE_FILE_RE.fullmatch(normalized):
        raise RuntimeError(f"unsupported bundle file path: {path}")
    if normalized not in _ALLOWED_FILES and not any(normalized.startswith(prefix) for prefix in _ALLOWED_PREFIXES):
        raise RuntimeError(f"file is not allowed in runtime bundle: {normalized}")
    return normalized


def _write_runtime_bundle(bundle: dict, service_id: str) -> Path:
    files = bundle.get("files")
    if not isinstance(files, dict):
        raise RuntimeError("runtime bundle must contain files")
    root = Path(tempfile.mkdtemp(prefix=f"myapp-faas-{service_id or 'service'}-"))
    for raw_path, raw_content in files.items():
        path = _validate_bundle_path(str(raw_path))
        if not isinstance(raw_content, str):
            raise RuntimeError(f"runtime bundle file content must be text: {path}")
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(raw_content, encoding="utf-8")
    return root


def _download_runtime_bundle(service_id: str) -> Path | None:
    url = os.environ.get("MYAPP_FAAS_BUNDLE_URL", "").strip()
    if not url:
        return None
    token = os.environ.get("MYAPP_FAAS_RUNTIME_TOKEN", "").strip()
    headers = {"Accept": "application/json"}
    if token:
        headers["X-MyApp-FaaS-Runtime-Token"] = token
    resp = requests.get(url, headers=headers, timeout=(5, 30))
    resp.raise_for_status()
    try:
        bundle = resp.json()
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"runtime bundle endpoint returned invalid JSON: {exc}") from exc
    if not isinstance(bundle, dict):
        raise RuntimeError("runtime bundle response must be a JSON object")
    return _write_runtime_bundle(bundle, service_id)


_RUNTIME_READY = threading.Event()
_RUNTIME_STATE: dict = {"app": None, "error": ""}


def _load_runtime(service_id: str, raw_service_dir: str) -> None:
    try:
        service_dir = _download_runtime_bundle(service_id)
        if service_dir is None:
            if not raw_service_dir:
                raise RuntimeError("MYAPP_FAAS_SERVICE_DIR is required")
            service_dir = Path(raw_service_dir).resolve()
        _RUNTIME_STATE["app"] = _attach_health(_load_generated_app(service_dir), service_id)
    except Exception as exc:  # noqa: BLE001 - surfaced via the health endpoint / 503
        _RUNTIME_STATE["error"] = str(exc)
    finally:
        _RUNTIME_READY.set()


def _runtime_dispatcher(environ, start_response):
    path = environ.get("PATH_INFO", "")
    if path == "/__myapp_faas_health":
        if _RUNTIME_STATE["app"] is not None:
            start_response("200 OK", [("Content-Type", "application/json")])
            return [b'{"ok": true}']
        if _RUNTIME_READY.is_set():
            start_response("500 Internal Server Error", [("Content-Type", "application/json")])
            return [json.dumps({"ok": False, "error": _RUNTIME_STATE["error"]}).encode("utf-8")]
        start_response("503 Service Unavailable", [("Content-Type", "application/json")])
        return [b'{"ok": false, "loading": true}']
    # Block the first cold request until the generated app finishes loading (or
    # fails), so faasd's task-running readiness never proxies into an app that is
    # not yet listening (which previously returned connection-refused).
    _RUNTIME_READY.wait(timeout=60)
    app = _RUNTIME_STATE["app"]
    if app is None:
        start_response("503 Service Unavailable", [("Content-Type", "application/json")])
        return [json.dumps({"ok": False, "error": _RUNTIME_STATE["error"] or "runtime not ready"}).encode("utf-8")]
    return app.wsgi_app(environ, start_response)


def main() -> int:
    service_id = os.environ.get("MYAPP_FAAS_SERVICE_ID", "").strip()
    raw_service_dir = os.environ.get("MYAPP_FAAS_SERVICE_DIR", "").strip()
    port = int(os.environ.get("PORT", "8080"))
    # Listen immediately; load the generated app in the background. A scale-from-
    # zero invoke then blocks briefly instead of hitting connection-refused.
    threading.Thread(target=_load_runtime, args=(service_id, raw_service_dir), daemon=True).start()
    from werkzeug.serving import make_server

    server = make_server("0.0.0.0", port, _runtime_dispatcher, threaded=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
