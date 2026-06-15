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
from pathlib import Path

import requests
from flask import Flask, jsonify


_SAFE_FILE_RE = re.compile(r"^[A-Za-z0-9_.\-/]+$")
_ALLOWED_FILES = {"app.py", "requirements.txt", "service.json", "README.md"}
_ALLOWED_PREFIXES = ("tests/",)


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


def main() -> int:
    service_id = os.environ.get("MYAPP_FAAS_SERVICE_ID", "").strip()
    service_dir = _download_runtime_bundle(service_id)
    raw_service_dir = os.environ.get("MYAPP_FAAS_SERVICE_DIR", "").strip()
    if service_dir is None and not raw_service_dir:
        raise RuntimeError("MYAPP_FAAS_SERVICE_DIR is required")
    if service_dir is None:
        service_dir = Path(raw_service_dir).resolve()
    app = _attach_health(_load_generated_app(service_dir), service_id)
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), threaded=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
