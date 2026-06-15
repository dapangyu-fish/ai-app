#!/usr/bin/env python3
"""OpenFaaS adapter behavior checks.

These checks avoid starting Flask, Docker, or a real OpenFaaS gateway. They
exercise the REST method selection used by the backend-owned FaaS deployer.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import types

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
    "FAAS_OPENFAAS_GATEWAY": "http://openfaas-gateway:8080",
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


class _Response:
    def __init__(self, status_code: int, text: str = "") -> None:
        self.status_code = status_code
        self.text = text


class _FakeRequests:
    def __init__(self, *, exists_status: int, put_status: int = 200, post_status: int = 202) -> None:
        self.exists_status = exists_status
        self.put_status = put_status
        self.post_status = post_status
        self.calls: list[tuple[str, str, dict | None]] = []

    def get(self, url: str, **kwargs):
        self.calls.append(("GET", url, None))
        return _Response(self.exists_status, "exists" if self.exists_status == 200 else "missing")

    def post(self, url: str, json=None, **kwargs):
        self.calls.append(("POST", url, json))
        return _Response(self.post_status, "post")

    def put(self, url: str, json=None, **kwargs):
        self.calls.append(("PUT", url, json))
        return _Response(self.put_status, "put")


def _with_openfaas(fake: _FakeRequests):
    old = {
        "requests": faas_store.requests,
        "gateway": faas_store.FAAS_OPENFAAS_GATEWAY,
        "image": faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE,
        "base": faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL,
        "token": faas_store.FAAS_RUNTIME_TOKEN,
    }
    faas_store.requests = fake
    faas_store.FAAS_OPENFAAS_GATEWAY = "http://openfaas-gateway:8080"
    faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = "example/faas-runtime:test"
    faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = "https://backend.example"
    faas_store.FAAS_RUNTIME_TOKEN = "runtime-master-token"
    return old


def _restore_openfaas(old: dict) -> None:
    faas_store.requests = old["requests"]
    faas_store.FAAS_OPENFAAS_GATEWAY = old["gateway"]
    faas_store.FAAS_OPENFAAS_RUNTIME_IMAGE = old["image"]
    faas_store.FAAS_RUNTIME_BUNDLE_BASE_URL = old["base"]
    faas_store.FAAS_RUNTIME_TOKEN = old["token"]


def test_openfaas_deploy_uses_post_for_new_function() -> None:
    fake = _FakeRequests(exists_status=404)
    old = _with_openfaas(fake)
    try:
        result = faas_store._deploy_openfaas_function(
            function_name="myapp-test-api",
            service_id="test-api",
            commit_sha="abc123",
        )
    finally:
        _restore_openfaas(old)

    assert "method=POST" in result
    assert [call[0] for call in fake.calls] == ["GET", "POST"]
    payload = fake.calls[-1][2] or {}
    assert payload["service"] == "myapp-test-api"
    assert payload["image"] == "example/faas-runtime:test"
    assert payload["envVars"]["MYAPP_FAAS_SERVICE_ID"] == "test-api"
    assert payload["envVars"]["MYAPP_FAAS_BUNDLE_URL"] == "https://backend.example/api/faas/runtime_bundle/test-api"


def test_openfaas_deploy_uses_put_for_existing_function() -> None:
    fake = _FakeRequests(exists_status=200)
    old = _with_openfaas(fake)
    try:
        result = faas_store._deploy_openfaas_function(
            function_name="myapp-existing-api",
            service_id="existing-api",
            commit_sha="def456",
        )
    finally:
        _restore_openfaas(old)

    assert "method=PUT" in result
    assert [call[0] for call in fake.calls] == ["GET", "PUT"]


def test_openfaas_put_404_falls_back_to_post() -> None:
    fake = _FakeRequests(exists_status=200, put_status=404, post_status=202)
    old = _with_openfaas(fake)
    try:
        result = faas_store._deploy_openfaas_function(
            function_name="myapp-racy-api",
            service_id="racy-api",
            commit_sha="fedcba",
        )
    finally:
        _restore_openfaas(old)

    assert "method=POST" in result
    assert [call[0] for call in fake.calls] == ["GET", "PUT", "POST"]


if __name__ == "__main__":
    test_openfaas_deploy_uses_post_for_new_function()
    test_openfaas_deploy_uses_put_for_existing_function()
    test_openfaas_put_404_falls_back_to_post()
    print(json.dumps({"ok": True}, sort_keys=True))
