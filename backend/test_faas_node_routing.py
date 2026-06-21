#!/usr/bin/env python3
"""Multi-node FaaS gateway routing: meta_json.deploy.node_id -> FAAS_OPENFAAS_NODES.

Single-node faasd per server (no cluster); with several faas-node servers the
backend proxies each service to its assigned node's gateway. These checks pin the
resolution priority and the loud failure on an unknown node_id.
"""

from __future__ import annotations

from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))

_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-node-routing",
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
    "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 5,
    "FAAS_DEFAULT_NODE_ID": "node-a",
    "FAAS_OPENFAAS_GATEWAY": "http://global-gw:8080",
    "FAAS_OPENFAAS_NODES": {"node-a": "http://gw-a:8731", "node-b": "http://gw-b:8731"},
    "FAAS_OPENFAAS_MAX_REPLICAS": 1,
    "FAAS_OPENFAAS_MIN_REPLICAS": 0,
    "FAAS_OPENFAAS_PASSWORD": "",
    "FAAS_OPENFAAS_READ_TIMEOUT": "60s",
    "FAAS_OPENFAAS_RUNTIME_IMAGE": "example/faas-runtime:test",
    "FAAS_OPENFAAS_SCALE_ZERO": True,
    "FAAS_OPENFAAS_USERNAME": "admin",
    "FAAS_OPENFAAS_WRITE_TIMEOUT": "60s",
    "FAAS_PUBLIC_BASE_URL": "https://backend.example",
    "FAAS_NODE_PUBLIC_URL": "https://openfaas.example",
    "FAAS_REQUIREMENTS_MAX_LINES": 40,
    "FAAS_RUNTIME_BUNDLE_BASE_URL": "https://backend.example",
    "FAAS_RUNTIME_TOKEN": "runtime-master-token",
    "SUPABASE_URL": "https://supabase.example",
    "SUPABASE_ANON_KEY": "anon-key",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

_database = types.ModuleType("database")
_database.db_execute = lambda *a, **k: None
_database.db_query = lambda *a, **k: None
sys.modules["database"] = _database

import faas_store  # noqa: E402


def _svc(deploy: dict) -> dict:
    return {"service_id": "s1", "meta_json": {"deploy": deploy}}


def test_node_id_resolves_to_registry_url() -> None:
    assert faas_store.openfaas_gateway_for_service(_svc({"node_id": "node-a"})) == "http://gw-a:8731"
    assert faas_store.openfaas_gateway_for_service(_svc({"node_id": "node-b"})) == "http://gw-b:8731"


def test_unknown_node_id_raises() -> None:
    try:
        faas_store.openfaas_gateway_for_service(_svc({"node_id": "ghost"}))
    except faas_store.FaaSError as exc:
        assert "ghost" in str(exc)
    else:
        raise AssertionError("unknown node_id must raise FaaSError, not silently misroute")


def test_pinned_gateway_without_node_id() -> None:
    got = faas_store.openfaas_gateway_for_service(_svc({"openfaas_gateway": "http://pinned:8080/"}))
    assert got == "http://pinned:8080"


def test_falls_back_to_global_gateway() -> None:
    assert faas_store.openfaas_gateway_for_service(None) == "http://global-gw:8080"
    assert faas_store.openfaas_gateway_for_service(_svc({})) == "http://global-gw:8080"


def test_deploy_meta_stamps_default_node_id() -> None:
    meta = faas_store._current_deploy_meta()
    assert meta.get("node_id") == "node-a"
    assert meta.get("openfaas_gateway") == "http://global-gw:8080"


def main() -> int:
    test_node_id_resolves_to_registry_url()
    test_unknown_node_id_raises()
    test_pinned_gateway_without_node_id()
    test_falls_back_to_global_gateway()
    test_deploy_meta_stamps_default_node_id()
    print("ok: faas node routing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
