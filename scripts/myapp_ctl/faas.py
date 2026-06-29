"""myapp-ctl: faas commands (split from monolithic myapp_ctl.py; logic unchanged)."""
from __future__ import annotations

import argparse
import ast
import base64
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets as py_secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .core import *  # noqa: F401,F403

def _http_request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict | None = None,
    token: str = "",
    timeout: float = 30.0,
    extra_headers: dict | None = None,
) -> tuple[int, dict | None, str]:
    headers = {"User-Agent": "myapp-ctl/1"}
    body = None
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if extra_headers:
        headers.update({k: v for k, v in extra_headers.items() if v})
    req = Request(url, data=body, headers=headers, method=method.upper())
    try:
        with urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            try:
                data = json.loads(text) if text else None
            except json.JSONDecodeError:
                data = None
            return int(getattr(resp, "status", 0) or 0), data, text
    except HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(text) if text else None
        except json.JSONDecodeError:
            data = None
        return int(exc.code), data, text
    except (URLError, OSError, ValueError) as exc:
        return 0, None, str(exc)


def _backend_base_url(explicit: str | None = None) -> str:
    if explicit:
        return explicit.rstrip("/")
    backend_env = _parse_env(_secret_path("backend"))
    for candidate in (
        backend_env.get("BACKEND_PUBLIC_URL"),
        _cfg().get("domains", {}).get("backend"),
    ):
        text = str(candidate or "").strip()
        if text:
            return text.rstrip("/")
    port = backend_env.get("BACKEND_PORT") or "5566"
    return f"http://127.0.0.1:{port}"


def _print_faas_health(data: dict, *, as_json: bool = False) -> int:
    if as_json:
        print(json.dumps(data, ensure_ascii=False))
        return 0
    rows = [
        {"key": "ok", "value": data.get("ok")},
        {"key": "deploy_mode", "value": data.get("deploy_mode")},
        {"key": "auth_required", "value": data.get("auth_required")},
        {"key": "tables", "value": data.get("tables")},
    ]
    _print_table(rows, [("key", "KEY"), ("value", "VALUE")])
    return 0 if data.get("ok") else 1


def _faas_token_arg(args) -> str:
    if getattr(args, "token", ""):
        return args.token
    token_env = getattr(args, "token_env", "") or ""
    return os.environ.get(token_env, "").strip() if token_env else ""


def _faas_user_query(args) -> str:
    params = {}
    user_id = getattr(args, "user_id", "") or ""
    if user_id:
        params["user_id"] = user_id
    if getattr(args, "all", False):
        params["include_disabled"] = "1"
    if not params:
        return ""
    return "?" + urlencode(params)


def _set_faas_mode(args) -> int:
    env_path = _secret_path("faas")
    data = _parse_env(env_path)
    mode = str(args.mode or "").strip().lower().replace("_", "-")
    data["FAAS_DEPLOY_MODE"] = mode
    if args.max_services is not None:
        data["FAAS_MAX_SERVICES_PER_USER"] = str(max(1, int(args.max_services)))
    if args.public_base_url:
        data["FAAS_PUBLIC_BASE_URL"] = args.public_base_url.rstrip("/")
    if args.bundle_base_url:
        data["FAAS_RUNTIME_BUNDLE_BASE_URL"] = args.bundle_base_url.rstrip("/")
    if args.runtime_image:
        data["FAAS_LOCAL_DOCKER_IMAGE"] = args.runtime_image
    if mode == "local-docker":
        data.setdefault("FAAS_LOCAL_DOCKER_IMAGE", _configured_image("faas-runtime"))
        data.setdefault("FAAS_LOCAL_DOCKER_NETWORK", "myapp_default")
        data.setdefault("FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT", "/mnt/myapp/faas/code")
        data.setdefault("FAAS_LOCAL_DOCKER_HOST_CODE_ROOT", str(_data_root_from_cfg() / "faas" / "code"))
        # Self-managed scale-to-zero. The backend runs the reaper; the invoke
        # proxy cold-wakes. Tunable, and managed here so they survive deploys.
        data.setdefault("FAAS_DOCKER_SCALE_ZERO", "1")
        data.setdefault("FAAS_DOCKER_IDLE_SECONDS", "600")
        data.setdefault("FAAS_DOCKER_REAPER_INTERVAL", "60")
        data.setdefault("FAAS_DOCKER_STATE_DIR", "/mnt/myapp/faas/state")
    if mode == "script":
        if args.deploy_script:
            data["FAAS_DEPLOY_SCRIPT"] = args.deploy_script
        if not data.get("FAAS_DEPLOY_SCRIPT"):
            print("FAAS_DEPLOY_SCRIPT is required for script mode", file=sys.stderr)
            return 2
    if mode not in {"local-docker", "docker", "docker-local", "script", "metadata"}:
        print(f"unsupported FaaS mode: {mode}", file=sys.stderr)
        return 2
    _write_env(env_path, data)
    _sync_runtime_secrets_from_host_config(_data_root_from_cfg())
    _safe_write_default_config_snapshot()
    print(f"updated faas mode: {mode}")
    print("run: myapp-ctl deploy --group faas --pull")
    return 0


def _copy_faas_secret_file(source: str, target_name: str, *, mode: int) -> str:
    src = Path(source).expanduser()
    if not src.is_file():
        raise FileNotFoundError(f"secret file not found: {src}")
    dest_dir = _secret_dir() / "files"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / target_name
    shutil.copyfile(src, dest)
    os.chmod(dest, mode)
    return f"/etc/myapp/secret-files/{target_name}"


def _set_faas_git(args) -> int:
    env_path = _secret_path("faas")
    data = _parse_env(env_path)
    if args.enable:
        data["FAAS_GIT_ENABLED"] = "1"
    if args.disable:
        data["FAAS_GIT_ENABLED"] = "0"
    if args.push:
        data["FAAS_GIT_PUSH_ENABLED"] = "1"
    if args.no_push:
        data["FAAS_GIT_PUSH_ENABLED"] = "0"
    if args.remote is not None:
        data["FAAS_GIT_REMOTE"] = args.remote.strip()
    if args.clear_remote:
        data["FAAS_GIT_REMOTE"] = ""
        data["FAAS_GIT_PUSH_ENABLED"] = "0"
    if args.branch:
        data["FAAS_GIT_BRANCH"] = args.branch.strip()
    if args.author_name:
        data["FAAS_GIT_AUTHOR_NAME"] = args.author_name.strip()
    if args.author_email:
        data["FAAS_GIT_AUTHOR_EMAIL"] = args.author_email.strip()
    try:
        if args.ssh_key_file:
            data["FAAS_GIT_SSH_KEY_PATH"] = _copy_faas_secret_file(
                args.ssh_key_file,
                "faas_git_ssh_key",
                mode=0o600,
            )
        if args.known_hosts_file:
            data["FAAS_GIT_KNOWN_HOSTS_PATH"] = _copy_faas_secret_file(
                args.known_hosts_file,
                "faas_git_known_hosts",
                mode=0o644,
            )
    except OSError as exc:
        print(f"failed to copy FaaS Git secret file: {exc}", file=sys.stderr)
        return 1
    if args.ssh_key_path:
        data["FAAS_GIT_SSH_KEY_PATH"] = args.ssh_key_path.strip()
    if args.known_hosts_path:
        data["FAAS_GIT_KNOWN_HOSTS_PATH"] = args.known_hosts_path.strip()
    if args.clear_ssh:
        data["FAAS_GIT_SSH_KEY_PATH"] = ""
        data["FAAS_GIT_KNOWN_HOSTS_PATH"] = ""
    if data.get("FAAS_GIT_PUSH_ENABLED") == "1" and not data.get("FAAS_GIT_REMOTE"):
        print("FAAS_GIT_REMOTE is required when Git push is enabled", file=sys.stderr)
        return 2
    _write_env(env_path, data)
    _sync_runtime_secrets_from_host_config(_data_root_from_cfg())
    _safe_write_default_config_snapshot()
    print("updated faas git config")
    print("run: myapp-ctl deploy --group faas --pull")
    return 0


def cmd_faas(args) -> int:
    base_url = _backend_base_url(getattr(args, "base_url", None))
    token = _faas_token_arg(args)
    if args.faas_cmd == "health":
        status, data, text = _http_request_json(f"{base_url}/api/faas/health", token=token, timeout=8)
        if not data:
            print(f"faas health failed: {status or '-'} {text[:500]}", file=sys.stderr)
            return 1
        return _print_faas_health(data, as_json=args.json)
    if args.faas_cmd == "ls":
        # Default (no --user-id) lists ALL services on this host (operator view);
        # --user-id scopes to one owner. --all also includes disabled services.
        user_id = (getattr(args, "user_id", "") or "").strip()
        params = [f"user_id={quote(user_id, safe='')}"] if user_id else ["all_users=1"]
        if getattr(args, "all", False):
            params.append("include_disabled=1")
        # B0-G1 (R14): all_users is now operator-only (fail-closed). Send the
        # agent-node operator token so the host operator view keeps working.
        op_headers = {}
        if not user_id:
            op_token = (
                (os.environ.get("AGENT_NODE_TOKEN") or "").strip()
                or _parse_env(_secret_path("agent")).get("AGENT_NODE_TOKEN", "").strip()
                or _parse_env(_secret_path("backend")).get("AGENT_NODE_TOKEN", "").strip()
            )
            if op_token:
                op_headers["X-MyApp-Agent-Node-Token"] = op_token
        status, data, text = _http_request_json(
            f"{base_url}/api/faas/services?{'&'.join(params)}",
            token=token,
            timeout=15,
            extra_headers=op_headers,
        )
        if not data:
            print(f"faas ls failed: {status or '-'} {text[:500]}", file=sys.stderr)
            return 1
        services = data.get("services", []) if isinstance(data, dict) else []
        if args.json:
            print(json.dumps(data, ensure_ascii=False))
            return 0
        rows = []
        for item in services:
            routes = item.get("routes") or []
            fn = item.get("function_name", "-")
            # Instance count comes from the backend's authoritative running_replicas
            # (same source the dashboard uses); 0 = scaled to zero. '?' only if an old
            # backend didn't supply it — never inferred from a local docker probe.
            rr = item.get("running_replicas")
            rows.append({
                "service_id": item.get("service_id", "-"),
                "owner": (str(item.get("owner_user_id", "") or "-"))[:13],
                "status": item.get("status", "-"),
                "inst": rr if isinstance(rr, int) else "?",
                "routes": len(routes) if isinstance(routes, list) else "-",
                "function": fn,
            })
        scope = f"owner {user_id[:13]}" if user_id else "all owners on this host"
        print(f"faas services: {len(rows)}  ({scope})")
        _print_table(rows, [
            ("service_id", "SERVICE"),
            ("owner", "OWNER"),
            ("status", "STATUS"),
            ("inst", "INST"),
            ("routes", "ROUTES"),
            ("function", "FUNCTION"),
        ])
        return 0
    if args.faas_cmd == "disable":
        status, data, text = _http_request_json(
            f"{base_url}/api/faas/services/{quote(args.service_id, safe='')}{_faas_user_query(args)}",
            method="DELETE",
            token=token,
            timeout=30,
        )
        if status >= 400 or not data:
            print(f"faas disable failed: {status or '-'} {text[:500]}", file=sys.stderr)
            return 1
        print(json.dumps(data, ensure_ascii=False) if args.json else f"disabled faas service: {args.service_id}")
        return 0
    if args.faas_cmd == "rm":
        # Hard delete: removes containers + DB record + code. Works on any status,
        # including 'disabled'. Resolve the owner automatically so the operator does
        # not need to know it (auth-disabled host accepts ?user_id=<owner>).
        owner = (getattr(args, "user_id", "") or "").strip()
        if not owner:
            _st, sdata, _stext = _http_request_json(
                f"{base_url}/api/faas/services/{quote(args.service_id, safe='')}",
                token=token, timeout=20,
            )
            if isinstance(sdata, dict):
                owner = str((sdata.get("service") or {}).get("owner_user_id") or "").strip()
        if not owner:
            print(f"faas rm failed: cannot resolve owner for {args.service_id} (pass --user-id)", file=sys.stderr)
            return 1
        q = "?" + urlencode({"user_id": owner, "purge": "1"})
        status, data, text = _http_request_json(
            f"{base_url}/api/faas/services/{quote(args.service_id, safe='')}{q}",
            method="DELETE",
            token=token,
            timeout=60,
        )
        if status >= 400 or not data:
            print(f"faas rm failed: {status or '-'} {text[:500]}", file=sys.stderr)
            return 1
        print(json.dumps(data, ensure_ascii=False) if args.json else f"deleted faas service: {args.service_id}")
        return 0
    if args.faas_cmd == "smoke":
        script = _source_dir() / "scripts" / "faas_smoke_test.py"
        if not script.is_file():
            print(f"faas smoke script not found: {script}", file=sys.stderr)
            return 1
        cmd = [sys.executable, str(script), "--base-url", base_url]
        if args.user_id:
            cmd.extend(["--user-id", args.user_id])
        if args.service_id:
            cmd.extend(["--service-id", args.service_id])
        if token:
            cmd.extend(["--token", token])
        else:
            # Deploy now requires a trusted owner. With no bearer token, pass the
            # host's agent-node token so smoke uses the trusted owner path instead
            # of the (now-rejected) bare body user_id.
            node_token = _parse_env(_secret_path("agent")).get("AGENT_NODE_TOKEN", "").strip()
            if not node_token:
                node_token = _parse_env(_secret_path("backend")).get("AGENT_NODE_TOKEN", "").strip()
            if node_token:
                cmd.extend(["--node-token", node_token])
        if args.no_cleanup:
            cmd.append("--no-cleanup")
        return _run(cmd, capture=False).returncode
    if args.faas_cmd == "ai-action-smoke":
        script = _source_dir() / "scripts" / "faas_ai_action_smoke.py"
        if not script.is_file():
            print(f"faas AI action smoke script not found: {script}", file=sys.stderr)
            return 1
        container_path = f"/tmp/myapp-faas-ai-action-smoke-{os.getpid()}.py"
        copy = _run(["docker", "cp", str(script), f"myapp-backend:{container_path}"])
        if copy.returncode != 0:
            print(f"failed to copy smoke script into myapp-backend: {(copy.stderr or copy.stdout).strip()}", file=sys.stderr)
            return 1
        cmd = [
            "docker",
            "exec",
            "myapp-backend",
            "python",
            container_path,
            "--base-url",
            args.base_url or "http://127.0.0.1:5566",
            "--user-id",
            args.user_id,
            "--session-id",
            args.session_id,
            "--service-id",
            args.service_id,
        ]
        if args.no_cleanup:
            cmd.append("--no-cleanup")
        if args.include_invalid:
            cmd.append("--include-invalid")
        try:
            return _run(cmd, capture=False).returncode
        finally:
            _run(["docker", "exec", "myapp-backend", "rm", "-f", container_path], capture=True)
    if args.faas_cmd == "e2e":
        script = _source_dir() / "scripts" / "faas_e2e_test.py"
        if not script.is_file():
            print(f"faas e2e test script not found: {script}", file=sys.stderr)
            return 1
        container_path = f"/tmp/myapp-faas-e2e-{os.getpid()}.py"
        copy = _run(["docker", "cp", str(script), f"myapp-backend:{container_path}"])
        if copy.returncode != 0:
            print(f"failed to copy e2e script into myapp-backend: {(copy.stderr or copy.stdout).strip()}", file=sys.stderr)
            return 1
        # Runs inside myapp-backend so it inherits SUPABASE_* env and reaches 127.0.0.1:5566.
        cmd = [
            "docker", "exec", "myapp-backend", "python", container_path,
            "--base-url", args.base_url or "http://127.0.0.1:5566",
            "--provider", args.provider,
            "--agent", args.agent,
            "--timeout", str(args.timeout),
        ]
        if args.email:
            cmd.extend(["--email", args.email])
        if args.password:
            cmd.extend(["--password", args.password])
        if args.with_update:
            cmd.append("--with-update")
        if args.keep:
            cmd.append("--keep")
        try:
            return _run(cmd, capture=False).returncode
        finally:
            _run(["docker", "exec", "myapp-backend", "rm", "-f", container_path], capture=True)
    if args.faas_cmd == "mode":
        return _set_faas_mode(args)
    if args.faas_cmd == "git":
        return _set_faas_git(args)
    if args.faas_cmd == "config":
        data = _parse_env(_secret_path("faas"))
        if args.json:
            print(json.dumps(data if args.show_secrets else {k: _redact(v) for k, v in data.items()}, ensure_ascii=False))
            return 0
        rows = [{"key": key, "value": value if args.show_secrets else _redact(value)} for key, value in sorted(data.items())]
        _print_table(rows, [("key", "KEY"), ("value", "VALUE")])
        return 0
    return 2


__all__ = [
    '_http_request_json',
    '_backend_base_url',
    '_print_faas_health',
    '_faas_token_arg',
    '_faas_user_query',
    '_set_faas_mode',
    '_copy_faas_secret_file',
    '_set_faas_git',
    'cmd_faas',
]
