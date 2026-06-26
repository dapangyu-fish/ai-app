#!/usr/bin/env python3
"""B0-G2 / R21 adversarial tests: the FaaS capability sandbox must DENY the
reflection escapes the feasibility audit found (random._os, getattr, urllib's
public os attr, vars/globals), and B0-G1 must keep the Supabase anon key OUT of
the injected runtime env by default. These guard the live-vuln fixes; they are
defense-in-depth, NOT the security boundary (that is "no secrets in container +
locked network", later batches)."""
from __future__ import annotations

import ast
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# --- stub config + database so faas_store imports without real deps ---
_config = types.ModuleType("config")
for _name, _value in {
    "FAAS_BUNDLE_MAX_BYTES": 512 * 1024,
    "FAAS_BUNDLE_SERVE_ROOT": "",
    "FAAS_CODE_ROOT": "/tmp/myapp-faas-sandbox",
    "FAAS_DEPLOY_MODE": "metadata",
    "FAAS_DEPLOY_SCRIPT": "",
    "FAAS_ENABLED": True,
    "FAAS_FILE_MAX_BYTES": 256 * 1024,
    "FAAS_FUNCTION_PREFIX": "myapp",
    "FAAS_GIT_AUTHOR_EMAIL": "x@localhost",
    "FAAS_GIT_AUTHOR_NAME": "x",
    "FAAS_GIT_BRANCH": "main",
    "FAAS_GIT_ENABLED": False,
    "FAAS_GIT_PUSH_ENABLED": False,
    "FAAS_GIT_REMOTE": "",
    "FAAS_GIT_SSH_KEY_PATH": "",
    "FAAS_GIT_KNOWN_HOSTS_PATH": "",
    "FAAS_GIT_ASYNC_PUSH": False,
    "FAAS_INJECT_SUPABASE_ANON_KEY": False,
    "FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_HOST_CODE_ROOT": "/mnt/myapp/faas/code",
    "FAAS_LOCAL_DOCKER_IMAGE": "example/faas-runtime:test",
    "FAAS_LOCAL_DOCKER_NETWORK": "myapp_default",
    "FAAS_HARDEN_CONTAINERS": True, "FAAS_LOCAL_DOCKER_MEM_LIMIT": "512m", "FAAS_LOCAL_DOCKER_PIDS_LIMIT": 256,
    "FAAS_LOCAL_DOCKER_START_ON_DEPLOY": False,
    "FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS": 15,
    "FAAS_MAX_SERVICES_PER_USER": 2,
    "FAAS_NODE_PUBLIC_URL": "https://faas.example",
    "FAAS_PUBLIC_BASE_URL": "https://backend.example",
    "FAAS_REQUIREMENTS_MAX_LINES": 40,
    "FAAS_RUNTIME_BUNDLE_BASE_URL": "https://backend.example",
    "FAAS_RUNTIME_TOKEN": "runtime-token",
    "SUPABASE_URL": "https://supabase.example",
    "SUPABASE_ANON_KEY": "anon-key-value",
}.items():
    setattr(_config, _name, _value)
sys.modules["config"] = _config

_database = types.ModuleType("database")
_database.db_execute = lambda *a, **k: None
_database.db_query = lambda *a, **k: []
sys.modules["database"] = _database

import faas_store  # noqa: E402
from faas_store import FaaSValidationError, _check_safe_python  # noqa: E402


def _check(code: str) -> None:
    _check_safe_python(ast.parse(code), filename="app.py", local_modules=set())


def _denies(code: str, label: str) -> None:
    try:
        _check(code)
    except FaaSValidationError:
        return
    raise AssertionError(f"sandbox FAILED to deny: {label}\n--- code ---\n{code}")


# --- DENY: the live escapes from the feasibility audit (R21) ---
def test_deny_single_underscore_os_reflection():
    _denies("import random\nx = random._os.environ\n", "random._os.environ")


def test_deny_public_os_attr_via_whitelisted_module():
    _denies("import urllib.request\nx = urllib.request.os\n", "urllib.request.os")
    _denies("import uuid\nx = uuid.os\n", "uuid.os")


def test_deny_getattr_reflection():
    _denies("import random\nx = getattr(random, '_' + 'os')\n", "getattr reflection")


def test_deny_other_reflection_builtins():
    _denies("g = globals()\n", "globals()")
    _denies("v = vars()\n", "vars()")
    _denies("import json\nsetattr(json, 'x', 1)\n", "setattr()")


def test_deny_dunder_class_traversal():
    _denies("x = ().__class__.__bases__\n", "().__class__.__bases__")


def test_deny_import_os_direct():
    _denies("import os\n", "import os")


def test_deny_attr_named_system_or_popen():
    _denies("import urllib\nx = urllib.system\n", "attr .system")


def test_deny_format_string_attribute_traversal():
    _denies(
        "def f():\n    return '{0.__class__.__init__.__globals__}'.format(f)\n",
        "str.format dunder traversal",
    )
    _denies("x = '{0._os}'.format(0)\n", "str.format single-underscore traversal")


def test_deny_breakpoint():
    _denies("breakpoint()\n", "breakpoint()")


# --- ACCEPT: a normal CRUD snippet must still pass (no regression) ---
def test_accept_normal_crud():
    code = (
        "import json\n"
        "import datetime\n"
        "from flask import Flask, request\n"
        "app = Flask(__name__)\n"
        "@app.post('/items')\n"
        "def create():\n"
        "    data = request.get_json()\n"
        "    name = data['name']\n"
        "    now = datetime.datetime.utcnow().isoformat()\n"
        "    return {'ok': True, 'name': name, 'at': now}\n"
    )
    _check(code)  # must not raise


def test_accept_normal_format_and_json_strings():
    # false-positive guard: ordinary format fields + JSON with dunder-ish keys
    # must NOT be rejected by the format-string heuristic.
    _check("x = 'hello {name}, you have {count} items'.format(name='a', count=2)\n")
    _check("import json\nx = json.dumps({'__typename': 'User', 'a.b': 1})\n")
    _check("y = '{0} + {1} = {2}'.format(1, 2, 3)\n")


# --- B0-G1: anon key not injected by default; opt-in when flag is on ---
def test_anon_key_not_injected_by_default():
    env = faas_store._platform_runtime_env()
    assert "MYAPP_CFG_SUPABASE_ANON_KEY" not in env, env
    assert env.get("MYAPP_CFG_SUPABASE_URL")  # public non-secret still present


def test_anon_key_injected_when_opted_in():
    original = faas_store.FAAS_INJECT_SUPABASE_ANON_KEY
    try:
        faas_store.FAAS_INJECT_SUPABASE_ANON_KEY = True
        env = faas_store._platform_runtime_env()
        assert env.get("MYAPP_CFG_SUPABASE_ANON_KEY") == "anon-key-value", env
    finally:
        faas_store.FAAS_INJECT_SUPABASE_ANON_KEY = original


if __name__ == "__main__":
    import json as _json

    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(_json.dumps({"ok": True, "tests": len(fns)}, sort_keys=True))
