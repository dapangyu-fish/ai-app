#!/usr/bin/env python3
"""FaaS runtime bundle download and file materialization checks."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

flask = types.ModuleType("flask")


class _Flask:
    pass


flask.Flask = _Flask
flask.jsonify = lambda payload=None, *args, **kwargs: payload if payload is not None else {}
sys.modules["flask"] = flask

import faas_runtime_server  # noqa: E402


def test_write_runtime_bundle_allows_only_expected_text_files() -> None:
    root = faas_runtime_server._write_runtime_bundle(
        {
            "files": {
                "app.py": "from flask import Flask\napp = Flask(__name__)\n",
                "requirements.txt": "flask==3.0.3\n",
                "service.json": "{}\n",
                "README.md": "runtime bundle\n",
                "tests/test_service.py": "def test_service():\n    assert True\n",
            }
        },
        "notes-api",
    )

    assert (root / "app.py").read_text(encoding="utf-8").startswith("from flask")
    assert (root / "requirements.txt").read_text(encoding="utf-8") == "flask==3.0.3\n"
    assert (root / "tests" / "test_service.py").is_file()


def test_write_runtime_bundle_rejects_path_escape_extra_files_and_binary_content() -> None:
    bad_bundles = [
        {"files": {"../secret.txt": "x"}},
        {"files": {"/tmp/secret.txt": "x"}},
        {"files": {"secret.env": "TOKEN=x\n"}},
        {"files": {"app.py": b"binary"}},
    ]

    for bundle in bad_bundles:
        try:
            faas_runtime_server._write_runtime_bundle(bundle, "notes-api")
        except RuntimeError as exc:
            assert "bundle" in str(exc) or "file" in str(exc) or "path" in str(exc)
        else:
            raise AssertionError(f"bundle should have been rejected: {bundle}")


def test_download_runtime_bundle_sends_runtime_token_and_writes_files() -> None:
    old_environ = os.environ.copy()
    old_requests = faas_runtime_server.requests
    calls: list[dict] = []

    class _Response:
        def raise_for_status(self) -> None:
            return None

        @staticmethod
        def json():
            return {
                "files": {
                    "app.py": "from flask import Flask\napp = Flask(__name__)\n",
                    "service.json": "{}\n",
                }
            }

    def fake_get(url, headers=None, timeout=None):
        calls.append({"url": url, "headers": headers or {}, "timeout": timeout})
        return _Response()

    fake_requests = types.SimpleNamespace(get=fake_get)
    try:
        os.environ.clear()
        os.environ.update(
            {
                "MYAPP_FAAS_BUNDLE_URL": "https://backend.example/api/faas/runtime_bundle/notes-api",
                "MYAPP_FAAS_RUNTIME_TOKEN": "service-runtime-token",
            }
        )
        faas_runtime_server.requests = fake_requests
        root = faas_runtime_server._download_runtime_bundle("notes-api")
    finally:
        faas_runtime_server.requests = old_requests
        os.environ.clear()
        os.environ.update(old_environ)

    assert root is not None
    assert (root / "app.py").is_file()
    assert calls == [
        {
            "url": "https://backend.example/api/faas/runtime_bundle/notes-api",
            "headers": {
                "Accept": "application/json",
                "X-MyApp-FaaS-Runtime-Token": "service-runtime-token",
            },
            "timeout": (5, 30),
        }
    ]


def test_download_runtime_bundle_requires_json_object_response() -> None:
    old_environ = os.environ.copy()
    old_requests = faas_runtime_server.requests

    class _Response:
        def raise_for_status(self) -> None:
            return None

        @staticmethod
        def json():
            return []

    try:
        os.environ.clear()
        os.environ.update({"MYAPP_FAAS_BUNDLE_URL": "https://backend.example/bundle"})
        faas_runtime_server.requests = types.SimpleNamespace(get=lambda *args, **kwargs: _Response())
        try:
            faas_runtime_server._download_runtime_bundle("notes-api")
        except RuntimeError as exc:
            assert "JSON object" in str(exc)
        else:
            raise AssertionError("non-object runtime bundle response should fail")
    finally:
        faas_runtime_server.requests = old_requests
        os.environ.clear()
        os.environ.update(old_environ)


if __name__ == "__main__":
    test_write_runtime_bundle_allows_only_expected_text_files()
    test_write_runtime_bundle_rejects_path_escape_extra_files_and_binary_content()
    test_download_runtime_bundle_sends_runtime_token_and_writes_files()
    test_download_runtime_bundle_requires_json_object_response()
    print(json.dumps({"ok": True}, sort_keys=True))
