#!/usr/bin/env python3
"""FaaS runtime bundle endpoint token checks."""

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
    "AGENT_NODE_TOKEN": "",
    "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER": False,
    "FAAS_REQUIRE_AUTH": False,
    "FAAS_ENFORCE_ACCESS_POLICY": False,
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
    "FAAS_CALLER_PSEUDONYM_SECRET": "test-pseudo-secret",
    "SUPABASE_JWT_SECRET": "",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

faas_store = types.ModuleType("faas_store")
faas_store.FaaSError = type("FaaSError", (RuntimeError,), {})
faas_store.FaaSValidationError = type("FaaSValidationError", (RuntimeError,), {})
faas_store.deploy_bundle = lambda *args, **kwargs: None
faas_store.disable_service = lambda *args, **kwargs: None
faas_store.delete_service = lambda *args, **kwargs: {"deleted": True}
faas_store.running_replica_counts = lambda *args, **kwargs: {}
faas_store.ensure_local_docker_runtime_for_service = lambda *args, **kwargs: None
faas_store.ensure_tables = lambda *args, **kwargs: None
faas_store.get_application = lambda *a, **k: None
faas_store.is_consumer_granted = lambda *a, **k: False
faas_store.can_manage_service = lambda *a, **k: False
faas_store.get_service = lambda *args, **kwargs: None
faas_store.list_services = lambda *args, **kwargs: []
faas_store.load_bundle_bytes = lambda *args, **kwargs: {}
faas_store.load_bundle_zip = lambda *args, **kwargs: {}
faas_store.build_service_archive = lambda *args, **kwargs: b""
faas_store.runtime_bundle_for_service = lambda *args, **kwargs: {}
faas_store.runtime_token_for_service = lambda *args, **kwargs: "expected-runtime-token"
faas_store.service_deploy_mode = lambda service=None: "metadata"
faas_store.scale_service = lambda *args, **kwargs: {}
sys.modules["faas_store"] = faas_store

import faas  # noqa: E402


class _Request:
    def __init__(self, headers: dict[str, str] | None = None):
        self.headers = headers or {}


def _set_request(headers: dict[str, str] | None = None) -> None:
    faas.request = _Request(headers)


def test_runtime_bundle_requires_master_token() -> None:
    old_token = faas.FAAS_RUNTIME_TOKEN
    old_request = faas.request
    try:
        faas.FAAS_RUNTIME_TOKEN = ""
        _set_request({"X-MyApp-FaaS-Runtime-Token": "expected-runtime-token"})
        body, status = faas.runtime_bundle("notes-api")
    finally:
        faas.FAAS_RUNTIME_TOKEN = old_token
        faas.request = old_request

    assert status == 503
    assert body["code"] == "FAAS_RUNTIME_TOKEN_MISSING"


def test_runtime_bundle_rejects_missing_or_wrong_token_without_loading_bundle() -> None:
    old_request = faas.request
    old_loader = faas.runtime_bundle_for_service
    calls: list[str] = []

    def fail_if_called(service_id: str):
        calls.append(service_id)
        raise AssertionError("runtime bundle should not be loaded for a bad token")

    try:
        faas.runtime_bundle_for_service = fail_if_called

        _set_request({})
        body, status = faas.runtime_bundle("notes-api")
        assert status == 403
        assert body["code"] == "FAAS_RUNTIME_FORBIDDEN"

        _set_request({"X-MyApp-FaaS-Runtime-Token": "wrong-token"})
        body, status = faas.runtime_bundle("notes-api")
        assert status == 403
        assert body["code"] == "FAAS_RUNTIME_FORBIDDEN"
    finally:
        faas.request = old_request
        faas.runtime_bundle_for_service = old_loader

    assert calls == []


def test_runtime_bundle_returns_validated_bundle_with_correct_token() -> None:
    old_request = faas.request
    old_loader = faas.runtime_bundle_for_service
    loaded: list[str] = []
    bundle = {
        "service": {"service_id": "notes-api"},
        "files": {"app.py": "from flask import Flask\napp = Flask(__name__)\n"},
    }

    def load_bundle(service_id: str):
        loaded.append(service_id)
        return bundle

    try:
        faas.runtime_bundle_for_service = load_bundle
        _set_request({"X-MyApp-FaaS-Runtime-Token": "expected-runtime-token"})
        result = faas.runtime_bundle("notes-api")
    finally:
        faas.request = old_request
        faas.runtime_bundle_for_service = old_loader

    assert result == bundle
    assert loaded == ["notes-api"]


def test_runtime_bundle_maps_missing_service_to_404() -> None:
    old_request = faas.request
    old_loader = faas.runtime_bundle_for_service

    def missing(service_id: str):
        raise faas.FaaSValidationError("service not found")

    try:
        faas.runtime_bundle_for_service = missing
        _set_request({"X-MyApp-FaaS-Runtime-Token": "expected-runtime-token"})
        body, status = faas.runtime_bundle("missing-api")
    finally:
        faas.request = old_request
        faas.runtime_bundle_for_service = old_loader

    assert status == 404
    assert body["code"] == "FAAS_NOT_FOUND"


if __name__ == "__main__":
    test_runtime_bundle_requires_master_token()
    test_runtime_bundle_rejects_missing_or_wrong_token_without_loading_bundle()
    test_runtime_bundle_returns_validated_bundle_with_correct_token()
    test_runtime_bundle_maps_missing_service_to_404()
    print(json.dumps({"ok": True}, sort_keys=True))
