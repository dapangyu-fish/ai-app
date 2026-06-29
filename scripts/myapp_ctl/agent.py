"""myapp-ctl: agent commands (split from monolithic myapp_ctl.py; logic unchanged)."""
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

def _docker_container_running(name: str) -> bool:
    data = _docker_inspect(name)
    state = data.get("State") if isinstance(data, dict) else None
    return bool(isinstance(state, dict) and state.get("Running"))


def _agent_node_instance_slug(node_id: str) -> str:
    text = re.sub(r"[^a-zA-Z0-9_.-]+", "-", str(node_id or "agent-node")).strip(".-")
    return (text.lower() or "agent-node")[:96]


def _agent_node_instance_container_name(node_id: str) -> str:
    return f"myapp-agent-node-{_agent_node_instance_slug(node_id)}"


def _agent_node_instance_root(data_root: Path, node_id: str) -> Path:
    return data_root / "agent-nodes" / _agent_node_instance_slug(node_id)


def _agent_node_container_backend_url(backend_url: str) -> str:
    """Return a backend URL reachable from an extra agent-node container."""
    text = str(backend_url or "").strip().rstrip("/")
    parsed = urlparse(text)
    host = (parsed.hostname or "").lower()
    if host in {"127.0.0.1", "localhost", "0.0.0.0", "::1"} and (parsed.port or 80) == 5566:
        return "http://backend:5566"
    return text


def _write_agent_node_instance_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for key in sorted(values):
        clean_key = str(key).strip()
        if not clean_key or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", clean_key):
            continue
        clean_value = str(values[key]).replace("\r", "").replace("\n", "\\n")
        lines.append(f"{clean_key}={clean_value}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def _filtered_agent_node_instance_env(values: dict[str, str], keys: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for key in keys:
        value = values.get(key)
        if value is not None and str(value) != "":
            out[key] = str(value)
    for key, value in values.items():
        if any(str(key).startswith(prefix) for prefix in _AGENT_NODE_INSTANCE_OPTIONAL_PREFIXES) and str(value) != "":
            out.setdefault(str(key), str(value))
    return out


def _agent_node_provider_env_path(agent_root: Path) -> Path:
    return agent_root / "ai-providers.env"


def _run_agent_node_instance(
    *,
    node_id: str,
    env_path: Path,
    data_root: Path,
    provider_env_path: Path | None = None,
    build: bool = False,
    pull: bool = False,
    include_base: bool = False,
) -> int:
    if build and pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    image_targets = ["agent-runtime", "agent-node"]
    if build:
        rc = _deploy_images(image_targets, action="build", dry_run=False, include_base=include_base)
        if rc != 0:
            return rc
    elif pull:
        rc = _deploy_images(image_targets, action="pull", dry_run=False, include_base=include_base)
        if rc != 0:
            return rc
    for network in DEFAULT_NETWORKS:
        if not _docker_network_exists(network):
            rc = _run(["docker", "network", "create", network], capture=False).returncode
            if rc != 0:
                return rc
    container = _agent_node_instance_container_name(node_id)
    instance_root = _agent_node_instance_root(data_root, node_id)
    instance_root.mkdir(parents=True, exist_ok=True)
    _run(["docker", "rm", "-f", container], capture=True)
    image = _configured_image("agent-node")
    cmd = [
        "docker",
        "run",
        "-d",
        "--name",
        container,
        "--restart",
        "unless-stopped",
        "--network",
        "myapp_default",
    ]
    if provider_env_path and provider_env_path.exists():
        cmd.extend(["--env-file", str(provider_env_path)])
    cmd.extend(
        [
            "--env-file",
            str(env_path),
            "-e",
            f"AGENT_NODE_PROVIDER_PROXY_BASE_URL=http://{container}:5590",
        ]
    )
    cmd.extend([
        "-e",
        f"AGENT_NODE_RUNTIME_IMAGE={_configured_image('agent-runtime')}",
        "-e",
        "AGENT_NODE_DOCKER_NETWORK=myapp_agent_runtime",
        "-e",
        "AGENT_NODE_STATE_ROOT=/var/lib/myapp/agent-node/state",
        "-e",
        "AGENT_NODE_WORKSPACE_ROOT=/var/lib/myapp/agent-node/workspaces",
        "-e",
        f"AGENT_NODE_HOST_STATE_ROOT={instance_root}/state",
        "-e",
        f"AGENT_NODE_HOST_WORKSPACE_ROOT={instance_root}/workspaces",
        "-e",
        "AGENT_NODE_LOG_DIR=/var/lib/myapp/agent-node/logs",
        "-v",
        "/var/run/docker.sock:/var/run/docker.sock",
        "-v",
        f"{instance_root}:/var/lib/myapp/agent-node",
        image,
    ])
    rc = _run(cmd, capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["docker", "network", "connect", "myapp_agent_runtime", container], capture=True).returncode
    if rc != 0:
        _run(["docker", "rm", "-f", container], capture=True)
        return rc
    print(f"started agent-node instance: {container}")
    return 0


def _http_json(url: str, *, token: str = "", timeout: float = 3.0) -> dict | None:
    headers = {"User-Agent": "myapp-ctl/1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = Request(url, headers=headers)
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except (HTTPError, URLError, OSError, json.JSONDecodeError, ValueError):
        return None


def _default_adapter_kind(agent_id: str) -> str:
    registry = _provider_registry()
    if registry:
        return registry.default_adapter_kind(agent_id)
    normalized = str(agent_id or "").strip().lower().replace("_", "-")
    if normalized == "claude":
        return "anthropic"
    if normalized == "opencode":
        return "opencode"
    if normalized == "codex":
        return "openai-responses"
    return normalized or "unknown"


def _agent_node_default_display_host(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    backend_public_host = _parse_env(_secret_path("backend")).get("PUBLIC_HOST", "").strip()
    if backend_public_host and backend_public_host not in {"127.0.0.1", "localhost"}:
        return backend_public_host
    return _public_host(None)


def _duration_ms(started, finished=None) -> str:
    try:
        start = int(started)
        end = int(finished) if finished else int(time.time() * 1000)
        return f"{max(0, int((end - start) / 1000))}s"
    except (TypeError, ValueError):
        return "-"


def _agent_add_node_id(host: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(host or "").strip()).strip("-._")
    return f"myapp-agent-{text or os.uname().nodename}"


def _print_agent_add_script(args) -> int:
    cfg = _cfg()
    backend_url = (args.backend or cfg.get("domains", {}).get("backend") or "").rstrip("/")
    mode = (getattr(args, "mode", "pull") or "pull").strip().lower().replace("_", "-")
    host = (args.host or "").strip()
    node_url = (args.url or "").rstrip("/")
    if getattr(args, "build", False) and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    if mode not in {"pull", "direct"}:
        print("--mode must be pull or direct", file=sys.stderr)
        return 2
    if mode == "direct" and not node_url and not host:
        print("agent host is required in direct mode; pass --host or --url", file=sys.stderr)
        return 2
    if mode == "direct" and not node_url:
        node_url = f"http://{host}:{args.public_port}".rstrip("/")
    if not host:
        parsed = urlparse(node_url) if node_url else None
        host = (parsed.hostname if parsed else "") or (node_url.split(":", 1)[0] if node_url else "")
    if not host and not args.node_id:
        print("--node-id is required when --host/--url is omitted", file=sys.stderr)
        return 2
    node_id = args.node_id or _agent_add_node_id(host)
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    if mode == "pull" and not node_url:
        node_url = f"pull://{node_id}"
    display_host = host or node_id
    provider_mode = args.provider_mode.strip().lower().replace("_", "-")
    if provider_mode not in {"master", "local"}:
        print("--provider-mode must be master or local", file=sys.stderr)
        return 2

    agent_env = _parse_env(_secret_path("agent"))
    agent_token = agent_env.get("AGENT_NODE_TOKEN", "")
    registration_token = agent_env.get("AGENT_NODE_REGISTRATION_TOKEN", "")
    if not agent_token or not registration_token:
        print("missing agent tokens on master; run myapp-ctl secret init-stack first", file=sys.stderr)
        return 1

    labels = list(args.label or [])
    if not any(label.startswith("host=") for label in labels):
        labels.append(f"host={display_host}")
    if not any(str(label).replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={provider_mode}")
    if not any(str(label).replace("_", "-").startswith("mode=") for label in labels):
        labels.append(f"mode={mode}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")
    join_cmd = [
        "myapp-ctl",
        "agent-node",
        "join",
        "--backend",
        backend_url,
        "--node-id",
        node_id,
        "--name",
        node_name,
        "--url",
        node_url,
        "--host",
        display_host,
        "--data-root",
        str(args.data_root),
        "--local-port",
        str(args.local_port),
        "--capacity",
        str(args.capacity),
        "--queue-max",
        str(args.queue_max if args.queue_max is not None else args.capacity),
        "--ttl",
        str(args.ttl),
        "--mode",
        mode,
        "--provider-mode",
        provider_mode,
        "--agent-token",
        agent_token,
        "--registration-token",
        registration_token,
    ]
    if args.pull:
        join_cmd.append("--pull")
    if getattr(args, "build", False):
        join_cmd.append("--build")
    if getattr(args, "base", False):
        join_cmd.append("--base")
    if mode == "direct":
        join_cmd.extend(["--public-port", str(args.public_port)])
        if args.no_nginx:
            join_cmd.append("--no-nginx")
        if args.allow_from:
            join_cmd.extend(["--allow-from", args.allow_from])
    if args.no_timer:
        join_cmd.append("--no-timer")
    for label in labels:
        join_cmd.extend(["--label", label])

    print("# Run this on the new agent host after installing myapp-ctl from this branch.")
    print("# It contains agent registration tokens. Treat it as a secret.")
    print(" ".join(shlex.quote(part) for part in join_cmd))
    return 0


def _join_agent_node(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    if getattr(args, "base", False) and not (args.build or args.pull):
        print("--base requires --build or --pull", file=sys.stderr)
        return 2
    backend_url = (args.backend or "").rstrip("/")
    mode = (args.mode or "pull").strip().lower().replace("_", "-")
    provider_mode = (args.provider_mode or "master").strip().lower().replace("_", "-")
    node_id = str(args.node_id or "").strip()
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    node_url = (args.url or "").rstrip("/")
    host = (args.host or "").strip()
    if not backend_url:
        print("--backend is required", file=sys.stderr)
        return 2
    if mode not in {"pull", "direct"}:
        print("--mode must be pull or direct", file=sys.stderr)
        return 2
    if provider_mode not in {"master", "local"}:
        print("--provider-mode must be master or local", file=sys.stderr)
        return 2
    if not node_id:
        print("--node-id is required", file=sys.stderr)
        return 2
    if mode == "pull" and not node_url:
        node_url = f"pull://{node_id}"
    if mode == "direct" and not node_url:
        if not host:
            print("--host or --url is required in direct mode", file=sys.stderr)
            return 2
        node_url = f"http://{host}:{args.public_port}".rstrip("/")
    if not node_url:
        print("--url is required", file=sys.stderr)
        return 2
    if not host:
        parsed = urlparse(node_url)
        host = parsed.hostname or node_id
    if not args.agent_token or not args.registration_token:
        print("--agent-token and --registration-token are required", file=sys.stderr)
        return 2

    try:
        data_root = _ensure_data_root_config(args.data_root, interactive=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    _ensure_data_root_layout(data_root)
    rc = _init_stack_secrets(host=host or node_id, quiet=True)
    if rc != 0:
        return rc

    labels = list(args.label or [])
    if not any(str(label).startswith("host=") for label in labels):
        labels.append(f"host={host or node_id}")
    if not any(str(label).replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={provider_mode}")
    if not any(str(label).replace("_", "-").startswith("mode=") for label in labels):
        labels.append(f"mode={mode}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")

    agent_env = _parse_env(_secret_path("agent"))
    current_node_id = str(agent_env.get("AGENT_NODE_ID") or "").strip()
    has_running_agent_node = _docker_container_running("myapp-agent-node")
    use_instance = bool(
        mode == "pull"
        and has_running_agent_node
        and current_node_id != node_id
        and not getattr(args, "replace_existing_agent_node", False)
    )
    agent_root = _agent_node_instance_root(data_root, node_id) if use_instance else data_root / "agent-node"
    provider_env_path = _agent_node_provider_env_path(agent_root) if provider_mode == "local" else None
    if provider_env_path and not _ai_providers_configured(provider_env_path):
        if not sys.stdin.isatty():
            print(
                f"local provider config is missing at {provider_env_path} and stdin is not interactive",
                file=sys.stderr,
            )
            return 1
        rc = _setup_ai_providers(
            force=False,
            path=provider_env_path,
            title=f"Local provider setup for agent node {node_name}",
        )
        if rc != 0:
            return rc
    if mode == "direct" and has_running_agent_node and current_node_id != node_id and not getattr(args, "replace_existing_agent_node", False):
        print(
            "refusing to replace the running agent-node in direct mode; "
            "use pull mode for an additional local instance, or pass --replace-existing-agent-node",
            file=sys.stderr,
        )
        return 2
    if not use_instance:
        backend_env = _parse_env(_secret_path("backend"))
        backend_env["PUBLIC_HOST"] = host or node_id
        _write_env(_secret_path("backend"), backend_env)
    new_agent_env = dict(agent_env)
    new_agent_env.update(
        {
            "AGENT_NODE_ID": node_id,
            "AGENT_NODE_NAME": node_name,
            "AGENT_NODE_AUTH_MODE": "shared",
            "AGENT_NODE_PORT": str(args.local_port),
            "AGENT_NODE_PROVIDER_MODE": provider_mode,
            "AGENT_NODE_PULL_ENABLED": "1" if mode == "pull" else "0",
            "AGENT_NODE_BACKEND_URL": backend_url,
            "AGENT_NODE_SELF_REGISTER_URL": node_url,
            "AGENT_NODE_CAPACITY": str(args.capacity),
            "AGENT_NODE_QUEUE_MAX": str(args.queue_max if args.queue_max is not None else args.capacity),
            "AGENT_NODE_REGISTRATION_TTL_SECONDS": str(args.ttl),
            "AGENT_NODE_LABELS": ",".join(labels),
            "AGENT_NODE_TOKEN": args.agent_token,
            "AGENT_NODE_REGISTRATION_TOKEN": args.registration_token,
        }
    )
    if provider_env_path:
        new_agent_env["AGENT_NODE_AI_PROVIDERS_ENV_FILE"] = str(provider_env_path)
    if use_instance:
        env_path = agent_root / "agent.env"
        instance_env = _filtered_agent_node_instance_env(
            new_agent_env,
            [
                "AGENT_NODE_ID",
                "AGENT_NODE_NAME",
                "AGENT_NODE_AUTH_MODE",
                "AGENT_NODE_PORT",
                "AGENT_NODE_PROVIDER_MODE",
                "AGENT_NODE_AI_PROVIDERS_ENV_FILE",
                "AGENT_NODE_PULL_ENABLED",
                "AGENT_NODE_BACKEND_URL",
                "AGENT_NODE_SELF_REGISTER_URL",
                "AGENT_NODE_CAPACITY",
                "AGENT_NODE_QUEUE_MAX",
                "AGENT_NODE_REGISTRATION_TTL_SECONDS",
                "AGENT_NODE_LABELS",
                "AGENT_NODE_TOKEN",
                "AGENT_NODE_REGISTRATION_TOKEN",
            ],
        )
        instance_env["AGENT_NODE_BACKEND_URL"] = _agent_node_container_backend_url(backend_url)
        instance_env["PUBLIC_HOST"] = host or node_id
        _write_agent_node_instance_env(env_path, instance_env)
        _safe_write_default_config_snapshot()
        print(
            f"starting additional agent-node instance without replacing myapp-agent-node: "
            f"{node_name} ({node_id}) -> {node_url}",
            flush=True,
        )
        rc = _run_agent_node_instance(
            node_id=node_id,
            env_path=env_path,
            data_root=data_root,
            provider_env_path=provider_env_path,
            build=bool(args.build),
            pull=bool(args.pull),
            include_base=bool(getattr(args, "base", False)),
        )
        if rc != 0:
            return rc
        _run(["myapp-ctl", "agent", "ls"], capture=False)
        return 0

    _write_env(_secret_path("agent"), new_agent_env)
    _safe_write_default_config_snapshot()
    print(f"updated agent join config: {node_name} ({node_id}) -> {node_url}", flush=True)

    if mode == "direct" and not args.no_nginx:
        if shutil.which("apt-get"):
            rc = _run(["apt-get", "update"], capture=False).returncode
            if rc != 0:
                return rc
            rc = _run(["apt-get", "install", "-y", "nginx"], capture=False).returncode
            if rc != 0:
                return rc
        conf = Path("/etc/nginx/conf.d/myapp-agent-node.conf")
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_text(
            "\n".join(
                [
                    "server {",
                    f"  listen {int(args.public_port)};",
                    "  server_name _;",
                    "  location / {",
                    f"    proxy_pass http://127.0.0.1:{int(args.local_port)};",
                    "    proxy_http_version 1.1;",
                    "    proxy_read_timeout 7200s;",
                    "    proxy_send_timeout 7200s;",
                    "  }",
                    "}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        _run(["systemctl", "reload", "nginx"], capture=False)
        if args.allow_from and shutil.which("ufw"):
            _run(
                [
                    "ufw",
                    "allow",
                    "from",
                    args.allow_from,
                    "to",
                    "any",
                    "port",
                    str(int(args.public_port)),
                    "proto",
                    "tcp",
                ],
                capture=False,
            )

    deploy_args = [
        "myapp-ctl",
        "deploy",
        "agent-node",
        "agent-runtime",
        "--data-root",
        str(data_root),
        "--no-setup",
        "--no-test-user",
    ]
    if args.pull:
        deploy_args.append("--pull")
    elif args.build:
        deploy_args.append("--build")
    if getattr(args, "base", False):
        deploy_args.append("--base")
    rc = _run(deploy_args, capture=False).returncode
    if rc != 0:
        return rc

    if args.no_timer:
        _remove_agent_register_timer()
        register_args = argparse.Namespace(
            backend=backend_url,
            url=node_url,
            node_id=node_id,
            name=node_name,
            capacity=args.capacity,
            queue_max=args.queue_max if args.queue_max is not None else args.capacity,
            ttl=args.ttl,
            token=args.registration_token,
            label=labels,
        )
        return _register_agent_node(register_args)

    _run(["myapp-ctl", "status", "agent-node"], capture=False)
    _run(["myapp-ctl", "agent", "ls"], capture=False)
    return 0


def _private_agent_key_paths(agent_root: Path, node_id: str) -> tuple[Path, Path]:
    key_dir = agent_root / "private"
    safe_node = re.sub(r"[^A-Za-z0-9_.-]+", "_", node_id).strip("._") or "private-agent"
    return key_dir / f"{safe_node}.key.pem", key_dir / f"{safe_node}.public.pem"


def _ensure_private_agent_keypair(private_key: Path, public_key: Path) -> int:
    if private_key.exists() and public_key.exists():
        return 0
    if not shutil.which("openssl"):
        print("openssl is required to generate a private agent keypair", file=sys.stderr)
        return 1
    private_key.parent.mkdir(parents=True, exist_ok=True)
    rc = _run(
        [
            "openssl",
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:3072",
            "-out",
            str(private_key),
        ]
    ).returncode
    if rc != 0:
        return rc
    os.chmod(private_key, 0o600)
    rc = _run(["openssl", "rsa", "-pubout", "-in", str(private_key), "-out", str(public_key)]).returncode
    if rc != 0:
        return rc
    os.chmod(public_key, 0o644)
    return 0


def _private_agent_auth_token(args, *, prompt: bool = True) -> str:
    token = (
        getattr(args, "auth_token", None)
        or os.environ.get("MYAPP_AUTH_TOKEN")
        or os.environ.get("SUPABASE_ACCESS_TOKEN")
        or ""
    ).strip()
    if token:
        return token
    if prompt and sys.stdin.isatty():
        return _prompt_secret("user access token for private agent registration")
    return ""


def _private_agent_join_token(args) -> str:
    return (
        getattr(args, "join_token", None)
        or os.environ.get("MYAPP_PRIVATE_AGENT_JOIN_TOKEN")
        or ""
    ).strip()


def _local_private_agent_jwt() -> str:
    agent_env = _parse_env(_secret_path("agent"))
    if (agent_env.get("AGENT_NODE_AUTH_MODE", "") or "").strip().lower() not in {"private", "user-private"}:
        return ""
    token = os.environ.get("AGENT_NODE_TOKEN") or agent_env.get("AGENT_NODE_TOKEN", "")
    if not token:
        return ""
    try:
        port = int(agent_env.get("AGENT_NODE_PORT") or 5590)
    except (TypeError, ValueError):
        port = 5590
    data, _status, _error = _agent_node_request_json(
        f"http://127.0.0.1:{port}",
        "/private_auth",
        token=token,
        timeout=3,
    )
    if not data:
        return ""
    return str(data.get("token") or "").strip()


def _private_agent_nodes_payload(args, *, probe: bool = True) -> tuple[dict | None, int, str]:
    backend_url = _agent_node_backend_url(args)
    if not backend_url:
        return None, 2, "backend url is required; pass --backend or set AGENT_NODE_BACKEND_URL"
    auth_token = _private_agent_auth_token(args, prompt=False)
    probe_value = "1" if probe else "0"
    if auth_token:
        return _agent_node_request_json(
            backend_url,
            f"/api/ai/private_agent/nodes?probe={probe_value}",
            token=auth_token,
        )
    private_jwt = _local_private_agent_jwt()
    if private_jwt:
        return _agent_node_request_json(
            backend_url,
            f"/api/ai/private_agent/nodes/self?probe={probe_value}",
            extra_headers={"X-MyApp-Agent-JWT": private_jwt},
        )
    return None, 2, "--auth-token/MYAPP_AUTH_TOKEN is required, or start the local private agent-node"


def _list_private_agent_nodes(args) -> int:
    data, status, error = _private_agent_nodes_payload(args, probe=not getattr(args, "no_probe", False))
    if not data:
        print(f"private agent-node ls failed: {status or '-'} {error}", file=sys.stderr)
        return 1 if status != 2 else 2
    return _print_agent_node_rows(data, as_json=getattr(args, "json", False))


def _status_private_agent_node(args) -> int:
    data, status, error = _private_agent_nodes_payload(args, probe=not getattr(args, "no_probe", False))
    if not data:
        print(f"private agent-node status failed: {status or '-'} {error}", file=sys.stderr)
        return 1 if status != 2 else 2
    node_id = getattr(args, "node_id", None)
    if not node_id:
        return _print_agent_node_rows(data, as_json=getattr(args, "json", False))
    for node in data.get("nodes") or []:
        if node.get("node_id") == node_id:
            return _print_agent_node_status({"node": node}, as_json=getattr(args, "json", False))
    print(f"private agent-node not found: {node_id}", file=sys.stderr)
    return 1


def _join_private_agent_node(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    if getattr(args, "base", False) and not (args.build or args.pull):
        print("--base requires --build or --pull", file=sys.stderr)
        return 2
    backend_url = (args.backend or "").rstrip("/")
    if not backend_url:
        print("--backend is required", file=sys.stderr)
        return 2
    join_token = _private_agent_join_token(args)
    auth_token = "" if join_token else _private_agent_auth_token(args)
    if not join_token and not auth_token:
        print("--join-token, MYAPP_PRIVATE_AGENT_JOIN_TOKEN, --auth-token, or MYAPP_AUTH_TOKEN is required for private agent registration", file=sys.stderr)
        return 2
    node_id = str(args.node_id or f"private-{socket.gethostname()}").strip()
    node_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", node_id).strip("._") or "private-agent"
    try:
        data_root = _ensure_data_root_config(args.data_root, interactive=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    _ensure_data_root_layout(data_root)
    agent_env = _parse_env(_secret_path("agent"))
    current_node_id = str(agent_env.get("AGENT_NODE_ID") or "").strip()
    has_running_agent_node = _docker_container_running("myapp-agent-node")
    use_instance = bool(
        has_running_agent_node
        and current_node_id != node_id
        and not getattr(args, "replace_existing_agent_node", False)
    )
    agent_root = _agent_node_instance_root(data_root, node_id) if use_instance else data_root / "agent-node"
    provider_env_path = _agent_node_provider_env_path(agent_root)
    private_key, public_key = _private_agent_key_paths(agent_root, node_id)
    private_key_container = f"/var/lib/myapp/agent-node/private/{private_key.name}"
    rc = _ensure_private_agent_keypair(private_key, public_key)
    if rc != 0:
        return rc
    public_key_text = public_key.read_text(encoding="utf-8")
    provider_filter = [item.strip().lower().replace("_", "-") for item in (args.provider or []) if item.strip()]
    agent_filter = [item.strip().lower().replace("_", "-") for item in (args.agent or []) if item.strip()]
    node_name = (args.name or node_id).strip()[:128] or node_id
    if not _ai_providers_configured(provider_env_path):
        if getattr(args, "no_provider_setup", False):
            print(
                f"private agent provider config is missing at {provider_env_path}; "
                "rerun without --no-provider-setup and enter this node's provider keys",
                file=sys.stderr,
            )
            return 1
        if not sys.stdin.isatty():
            print(
                f"private agent provider config is missing at {provider_env_path} and stdin is not interactive",
                file=sys.stderr,
            )
            return 1
        rc = _setup_ai_providers(
            force=False,
            path=provider_env_path,
            title=f"Private agent provider setup for {node_name}",
        )
        if rc != 0:
            return rc
    provider_env = _parse_env(provider_env_path)
    configured_provider_ids = _ai_provider_ids_from_env(provider_env)
    if provider_filter:
        missing = [provider_id for provider_id in provider_filter if provider_id not in configured_provider_ids]
        if missing:
            print(
                f"private agent provider config at {provider_env_path} is missing: {', '.join(missing)}",
                file=sys.stderr,
            )
            return 1
    capabilities = _ai_provider_capabilities_from_env(
        provider_env,
        provider_filter=provider_filter,
        agent_filter=agent_filter,
    )
    explicit_caps = []
    for raw in getattr(args, "capability", None) or []:
        parts = [part.strip().lower().replace("_", "-") for part in str(raw or "").split(":") if part.strip()]
        if len(parts) not in {2, 3}:
            print("--capability must be provider:agent or provider:agent:adapter", file=sys.stderr)
            return 2
        provider_id, agent_id = parts[0], parts[1]
        explicit_caps.append(
            {
                "provider_id": provider_id,
                "agent_id": agent_id,
                "adapter_kind": parts[2] if len(parts) == 3 else _default_adapter_kind(agent_id),
                "status": "configured",
                "enabled": True,
            }
        )
    if explicit_caps:
        available = {(cap["provider_id"], cap["agent_id"]) for cap in capabilities}
        missing_caps = [cap for cap in explicit_caps if (cap["provider_id"], cap["agent_id"]) not in available]
        if missing_caps:
            text = ", ".join(f"{cap['provider_id']}:{cap['agent_id']}" for cap in missing_caps)
            print(f"private agent provider config does not support capability: {text}", file=sys.stderr)
            return 1
        capabilities = explicit_caps
    if not capabilities:
        print(
            f"private agent provider config at {provider_env_path} has no enabled Claude/Codex/OpenCode adapter",
            file=sys.stderr,
        )
        return 1
    provider_ids = sorted({str(cap["provider_id"]) for cap in capabilities})
    agent_ids = sorted({str(cap["agent_id"]) for cap in capabilities})
    payload = {
        "node_id": node_id,
        "name": node_name,
        "public_key": public_key_text,
        "provider_ids": provider_ids,
        "agent_ids": agent_ids,
        "capabilities": capabilities,
        "capacity": args.capacity,
        "queue_max": args.queue_max if args.queue_max is not None else args.capacity,
        "ttl_seconds": args.ttl,
    }
    data, status, error = _agent_node_request_json(
        backend_url,
        "/api/ai/private_agent/nodes",
        method="POST",
        token=join_token or auth_token,
        payload=payload,
        timeout=15,
    )
    if not data:
        print(f"private agent registration failed: {status or '-'} {error}", file=sys.stderr)
        return 1
    owner_user_id = str(data.get("owner_user_id") or "").strip()
    display_host = _agent_node_default_display_host(args.host)
    rc = _init_stack_secrets(host=display_host, quiet=True)
    if rc != 0:
        return rc
    agent_env = _parse_env(_secret_path("agent"))
    labels = list(args.label or [])
    if not any(str(label).startswith("host=") for label in labels):
        labels.append(f"host={display_host}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")
    for required_label in ("visibility=private", "provider_mode=local", "mode=pull"):
        key = required_label.split("=", 1)[0].replace("_", "-")
        if not any(str(label).replace("_", "-").startswith(f"{key}=") for label in labels):
            labels.append(required_label)
    new_agent_env = dict(agent_env)
    new_agent_env.update(
        {
            "AGENT_NODE_ID": node_id,
            "AGENT_NODE_NAME": node_name,
            "AGENT_NODE_PORT": str(args.local_port),
            "AGENT_NODE_AUTH_MODE": "private",
            "AGENT_NODE_OWNER_USER_ID": owner_user_id,
            "AGENT_NODE_PRIVATE_KEY_PATH": private_key_container,
            "AGENT_NODE_AI_PROVIDERS_ENV_FILE": str(provider_env_path),
            "AGENT_NODE_PROVIDER_MODE": "local",
            "AGENT_NODE_PULL_ENABLED": "1",
            "AGENT_NODE_BACKEND_URL": backend_url,
            "AGENT_NODE_SELF_REGISTER_URL": f"pull://{node_id}",
            "AGENT_NODE_CAPACITY": str(args.capacity),
            "AGENT_NODE_QUEUE_MAX": str(args.queue_max if args.queue_max is not None else args.capacity),
            "AGENT_NODE_REGISTRATION_TTL_SECONDS": str(args.ttl),
            "AGENT_NODE_PROVIDER_IDS": ",".join(provider_ids),
            "AGENT_NODE_AGENT_IDS": ",".join(agent_ids),
            "AGENT_NODE_CAPABILITIES": json.dumps(capabilities, separators=(",", ":")),
            "AGENT_NODE_LABELS": ",".join(labels),
            "AGENT_NODE_TOKEN": agent_env.get("AGENT_NODE_TOKEN") or _rand_hex(24),
            "AGENT_NODE_REGISTRATION_TOKEN": "",
        }
    )
    if use_instance:
        env_path = agent_root / "agent.env"
        instance_env = _filtered_agent_node_instance_env(
            new_agent_env,
            [
                "AGENT_NODE_ID",
                "AGENT_NODE_NAME",
                "AGENT_NODE_PORT",
                "AGENT_NODE_AUTH_MODE",
                "AGENT_NODE_OWNER_USER_ID",
                "AGENT_NODE_PRIVATE_KEY_PATH",
                "AGENT_NODE_AI_PROVIDERS_ENV_FILE",
                "AGENT_NODE_PROVIDER_MODE",
                "AGENT_NODE_PULL_ENABLED",
                "AGENT_NODE_BACKEND_URL",
                "AGENT_NODE_SELF_REGISTER_URL",
                "AGENT_NODE_CAPACITY",
                "AGENT_NODE_QUEUE_MAX",
                "AGENT_NODE_REGISTRATION_TTL_SECONDS",
                "AGENT_NODE_PROVIDER_IDS",
                "AGENT_NODE_AGENT_IDS",
                "AGENT_NODE_CAPABILITIES",
                "AGENT_NODE_LABELS",
                "AGENT_NODE_TOKEN",
            ],
        )
        instance_env["AGENT_NODE_BACKEND_URL"] = _agent_node_container_backend_url(backend_url)
        instance_env["PUBLIC_HOST"] = display_host
        _write_agent_node_instance_env(env_path, instance_env)
        _safe_write_default_config_snapshot()
        print(
            f"starting private agent-node instance without replacing myapp-agent-node: "
            f"{node_name} ({node_id})",
            flush=True,
        )
        rc = _run_agent_node_instance(
            node_id=node_id,
            env_path=env_path,
            data_root=data_root,
            provider_env_path=provider_env_path,
            build=bool(args.build),
            pull=bool(args.pull),
            include_base=bool(getattr(args, "base", False)),
        )
    else:
        _write_env(_secret_path("agent"), new_agent_env)
        _safe_write_default_config_snapshot()
        deploy_cmd = ["myapp-ctl", "deploy", "agent-node", "agent-runtime", "--no-setup", "--no-test-user"]
        if args.build:
            deploy_cmd.append("--build")
        elif args.pull:
            deploy_cmd.append("--pull")
        if getattr(args, "base", False):
            deploy_cmd.append("--base")
        rc = _run(deploy_cmd, capture=False).returncode
    if rc != 0:
        return rc
    print(json.dumps(data, ensure_ascii=False))
    if use_instance:
        _run(["myapp-ctl", "agent", "ls"], capture=False)
    else:
        _run(["myapp-ctl", "status", "agent-node"], capture=False)
    return 0


def _agent_node_backend_url(args) -> str:
    explicit = getattr(args, "backend", None)
    if explicit:
        return explicit.rstrip("/")
    agent_backend = (_parse_env(_secret_path("agent")).get("AGENT_NODE_BACKEND_URL", "") or "").rstrip("/")
    agent_backend_host = urlparse(agent_backend).hostname or ""
    if agent_backend and agent_backend_host not in {"backend", "myapp-backend", "agent-node"}:
        return agent_backend
    return (
        _cfg().get("domains", {}).get("backend")
        or _parse_env(_secret_path("backend")).get("BACKEND_PUBLIC_URL", "")
        or agent_backend
        or ""
    ).rstrip("/")


def _agent_node_registry_token(args) -> str:
    return (
        getattr(args, "token", None)
        or os.environ.get("AGENT_NODE_REGISTRATION_TOKEN")
        or _parse_env(_secret_path("agent")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
        or _parse_env(_secret_path("backend")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
    )


def _agent_node_request_json(
    backend_url: str,
    path: str,
    *,
    method: str = "GET",
    token: str = "",
    extra_headers: dict[str, str] | None = None,
    payload: dict | None = None,
    timeout: float = 8.0,
) -> tuple[dict | None, int, str]:
    headers = {"User-Agent": "myapp-ctl/1"}
    if extra_headers:
        headers.update({str(k): str(v) for k, v in extra_headers.items() if str(k) and str(v)})
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(backend_url.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body) if body else {}, int(getattr(resp, "status", 200)), ""
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(detail)
            detail = parsed.get("error") or detail
        except (TypeError, ValueError, json.JSONDecodeError):
            pass
        return None, int(exc.code), detail
    except (URLError, OSError, ValueError, json.JSONDecodeError) as exc:
        return None, 0, str(exc)


def _register_agent_node(args) -> int:
    backend_url = _agent_node_backend_url(args)
    node_url = (args.url or _cfg().get("domains", {}).get("agent_node") or "").rstrip("/")
    node_id = args.node_id or _cfg().get("node", {}).get("id") or os.uname().nodename
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    if not node_url:
        print("agent node url is required; pass --url or set domains.agent_node", file=sys.stderr)
        return 2
    payload = {
        "node_id": node_id,
        "name": node_name,
        "url": node_url,
        "capacity": args.capacity,
        "queue_max": getattr(args, "queue_max", None) if getattr(args, "queue_max", None) is not None else args.capacity,
        "ttl_seconds": args.ttl,
        "labels": args.label or [],
    }
    data, status, error = _agent_node_request_json(
        backend_url,
        "/api/ai/agent_nodes/register",
        method="POST",
        token=_agent_node_registry_token(args),
        payload=payload,
    )
    if not data:
        print(f"register failed: {status or '-'} {error}", file=sys.stderr)
        return 1
    print(json.dumps(data, ensure_ascii=False))
    return 0


def _expires_label(value) -> str:
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return "-"
    if seconds <= 0:
        return "expired"
    return f"{seconds}s"


def _version_label(item: dict) -> str:
    value = str(item.get("build_version") or item.get("version") or item.get("build_commit") or "").strip()
    if not value or value.lower() == "unknown":
        return "-"
    if len(value) >= 12 and all(ch in "0123456789abcdefABCDEF" for ch in value):
        return value[:12]
    return value[:24]


def _print_agent_node_rows(data: dict, *, as_json: bool = False) -> int:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    print(
        "agent nodes: "
        f"total={summary.get('total', 0)} "
        f"online={summary.get('online', 0)} "
        f"paused={summary.get('paused', 0)} "
        f"pending={summary.get('registered', 0)} "
        f"down={summary.get('down', 0)} "
        f"stale={summary.get('stale', 0)} "
        f"active_runs={summary.get('active_runs', 0)} "
        f"capacity={summary.get('capacity', 0)} "
        f"available={summary.get('available_capacity', summary.get('capacity', 0))} "
        f"queued={summary.get('queued', 0)} "
        f"qmax={summary.get('available_queue_max', summary.get('queue_max', 0))}/{summary.get('queue_max', 0)}"
    )
    rows = []
    for item in data.get("nodes") or []:
        rows.append(
            {
                "name": item.get("name") or item.get("display_name") or item.get("node_id", "-"),
                "node_id": item.get("node_id", "-"),
                "namespace": item.get("namespace") or ("public" if item.get("visibility", "public") == "public" else item.get("owner_user_id") or "-"),
                "host": item.get("host") or "-",
                "status": item.get("status", "-"),
                "version": _version_label(item),
                "active_runs": item.get("active_runs", "-"),
                "capacity": item.get("capacity", "-"),
                "queue_depth": item.get("queue_depth", "-"),
                "queue_max": item.get("queue_max", "-"),
                "provider_mode": item.get("provider_mode", "-"),
                "expires": _expires_label(item.get("expires_in_seconds")),
                "url": item.get("url", "-"),
            }
        )
    _print_table(
        rows,
        [
            ("name", "NAME"),
            ("node_id", "NODE"),
            ("namespace", "NS"),
            ("host", "HOST"),
            ("status", "STATUS"),
            ("version", "VERSION"),
            ("active_runs", "RUNS"),
            ("capacity", "CAP"),
            ("queue_depth", "QUEUE"),
            ("queue_max", "QMAX"),
            ("provider_mode", "KEY_SRC"),
            ("expires", "EXPIRES"),
            ("url", "URL"),
        ],
    )
    return 0


def _print_agent_node_status(data: dict, *, as_json: bool = False) -> int:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    node = data.get("node") if isinstance(data.get("node"), dict) else {}
    if not node:
        print("(empty)")
        return 0
    _print_table(
        [
            {
                "name": node.get("name") or node.get("display_name") or node.get("node_id", "-"),
                "node_id": node.get("node_id", "-"),
                "namespace": node.get("namespace") or ("public" if node.get("visibility", "public") == "public" else node.get("owner_user_id") or "-"),
                "host": node.get("host") or "-",
                "status": node.get("status", "-"),
                "health": node.get("health", "-"),
                "version": _version_label(node),
                "active_runs": node.get("active_runs", "-"),
                "capacity": node.get("capacity", "-"),
                "queue_depth": node.get("queue_depth", "-"),
                "queue_max": node.get("queue_max", "-"),
                "provider_mode": node.get("provider_mode", "-"),
                "expires": _expires_label(node.get("expires_in_seconds")),
                "url": node.get("url", "-"),
            }
        ],
        [
            ("name", "NAME"),
            ("node_id", "NODE"),
            ("namespace", "NS"),
            ("host", "HOST"),
            ("status", "STATUS"),
            ("health", "HEALTH"),
            ("version", "VERSION"),
            ("active_runs", "RUNS"),
            ("capacity", "CAP"),
            ("queue_depth", "QUEUE"),
            ("queue_max", "QMAX"),
            ("provider_mode", "KEY_SRC"),
            ("expires", "EXPIRES"),
            ("url", "URL"),
        ],
    )
    detail = node.get("detail")
    if detail:
        print(f"detail: {detail}")
    pause_reason = node.get("pause_reason")
    if pause_reason:
        print(f"pause_reason: {pause_reason}")
    runs = node.get("runs") if isinstance(node.get("runs"), list) else []
    if runs:
        run_rows = []
        for item in runs:
            started = item.get("created_at") or item.get("started_at")
            finished = item.get("finished_at")
            run_rows.append(
                {
                    "run_id": item.get("run_id", "-"),
                    "session_id": item.get("session_id", "-"),
                    "agent_id": item.get("agent_id", "-"),
                    "provider_id": item.get("provider_id", "-"),
                    "status": item.get("status", "-"),
                    "duration": _duration_ms(started, finished),
                }
            )
        print("")
        print(f"active runs: {len(run_rows)}")
        _print_table(
            run_rows,
            [
                ("run_id", "RUN"),
                ("session_id", "SESSION"),
                ("agent_id", "AGENT"),
                ("provider_id", "PROVIDER"),
                ("status", "STATUS"),
                ("duration", "DURATION"),
            ],
        )
    return 0


def _local_agent_node_url(agent_env: dict[str, str]) -> str:
    port = str(agent_env.get("AGENT_NODE_PORT") or "5590").strip() or "5590"
    return f"http://127.0.0.1:{port}"


def _local_agent_node_token(agent_env: dict[str, str]) -> str:
    return os.environ.get("AGENT_NODE_TOKEN") or agent_env.get("AGENT_NODE_TOKEN", "")


def _set_local_agent_node_limits(args) -> int:
    agent_env = _parse_env(_secret_path("agent"))
    current_capacity = agent_env.get("AGENT_NODE_CAPACITY", "10")
    current_queue_max = agent_env.get("AGENT_NODE_QUEUE_MAX", "100")
    capacity_value = getattr(args, "capacity", None)
    queue_max_value = getattr(args, "queue_max", None)
    if capacity_value is None and queue_max_value is None:
        print("pass --capacity and/or --queue-max", file=sys.stderr)
        return 2
    try:
        capacity = max(1, min(100, int(capacity_value if capacity_value is not None else current_capacity)))
    except (TypeError, ValueError):
        print("capacity must be an integer from 1 to 100", file=sys.stderr)
        return 2
    try:
        queue_max = max(0, min(10000, int(queue_max_value if queue_max_value is not None else current_queue_max)))
    except (TypeError, ValueError):
        print("queue max must be an integer from 0 to 10000", file=sys.stderr)
        return 2
    agent_env["AGENT_NODE_CAPACITY"] = str(capacity)
    agent_env["AGENT_NODE_QUEUE_MAX"] = str(queue_max)
    _write_env(_secret_path("agent"), agent_env)
    _safe_write_default_config_snapshot()
    node_url = _local_agent_node_url(agent_env)
    data, status, error = _agent_node_request_json(
        node_url,
        "/admin/limits",
        method="POST",
        payload={"capacity": capacity, "queue_max": queue_max},
        token=_local_agent_node_token(agent_env),
        timeout=5.0,
    )
    if not data:
        print(
            "agent-node limits were saved, but live hot update failed: "
            f"{status or '-'} {error}. Start or update agent-node and retry.",
            file=sys.stderr,
        )
        return 1
    previous = data.get("previous") or {}
    limits = data.get("limits") or {}
    running = data.get("running", "-")
    print(
        "updated live agent-node limits: "
        f"capacity {previous.get('capacity', current_capacity)} -> {limits.get('capacity', capacity)}, "
        f"queue_max {previous.get('queue_max', current_queue_max)} -> {limits.get('queue_max', queue_max)}, "
        f"active_runs={running}",
        flush=True,
    )
    backend_url = (args.backend or "").rstrip("/")
    if backend_url:
        time.sleep(1)
        data, status, error = _agent_node_request_json(
            backend_url,
            "/api/ai/agent_nodes?probe=1",
            token=_agent_node_registry_token(args),
        )
        if data:
            return _print_agent_node_rows(data, as_json=args.json)
        print(f"agent-node capacity updated, but status fetch failed: {status or '-'} {error}", file=sys.stderr)
    return 0


def cmd_agent_node(args) -> int:
    if args.agent_node_cmd == "add":
        return _print_agent_add_script(args)
    if args.agent_node_cmd == "join":
        return _join_agent_node(args)
    if args.agent_node_cmd == "private":
        if getattr(args, "private_cmd", "") == "ls":
            return _list_private_agent_nodes(args)
        if getattr(args, "private_cmd", "") == "status":
            return _status_private_agent_node(args)
        if getattr(args, "private_cmd", "") == "join":
            return _join_private_agent_node(args)
        print("private command is required", file=sys.stderr)
        return 2
    if args.agent_node_cmd == "register":
        return _register_agent_node(args)
    if args.agent_node_cmd in {"capacity", "limits"}:
        return _set_local_agent_node_limits(args)

    backend_url = _agent_node_backend_url(args)
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    token = _agent_node_registry_token(args)

    if args.agent_node_cmd == "ls":
        probe = "0" if args.no_probe else "1"
        namespace = quote(str(getattr(args, "namespace", None) or "public"), safe="")
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes?probe={probe}&namespace={namespace}",
            token=token,
        )
        if not data:
            print(f"agent-node ls failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_rows(data, as_json=args.json)

    if args.agent_node_cmd == "status":
        if not args.node_id:
            probe = "0" if args.no_probe else "1"
            namespace = quote(str(getattr(args, "namespace", None) or "public"), safe="")
            data, status, error = _agent_node_request_json(
                backend_url,
                f"/api/ai/agent_nodes?probe={probe}&namespace={namespace}",
                token=token,
            )
            if not data:
                print(f"agent-node status failed: {status or '-'} {error}", file=sys.stderr)
                return 1
            return _print_agent_node_rows(data, as_json=args.json)
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(args.node_id, safe='')}?runs=1",
            token=token,
        )
        if not data:
            print(f"agent-node status failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_status(data, as_json=args.json)

    if args.agent_node_cmd == "rm":
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(args.node_id, safe='')}",
            method="DELETE",
            token=token,
        )
        if not data:
            print(f"agent-node rm failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        print(json.dumps(data, ensure_ascii=False))
        return 0

    if args.agent_node_cmd in {"pause", "resume"}:
        node_id = args.node_id or _parse_env(_secret_path("agent")).get("AGENT_NODE_ID") or ""
        if not node_id:
            print("node_id is required, or configure AGENT_NODE_ID in agent.env", file=sys.stderr)
            return 2
        body = {}
        if args.agent_node_cmd == "pause" and args.reason:
            body["reason"] = args.reason
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(node_id, safe='')}/{args.agent_node_cmd}",
            method="POST",
            payload=body,
            token=token,
        )
        if not data:
            print(f"agent-node {args.agent_node_cmd} failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_status(data, as_json=args.json)

    return 2


def cmd_agent(args) -> int:
    if args.agent_cmd == "add":
        return _print_agent_add_script(args)
    if args.agent_cmd == "register":
        return _register_agent_node(args)
    if args.agent_cmd == "ls":
        agent_env = _parse_env(_secret_path("agent"))
        default_node_url = f"http://127.0.0.1:{agent_env.get('AGENT_NODE_PORT', '5590') or '5590'}"
        node_url = (args.url or default_node_url).rstrip("/")
        token = os.environ.get("AGENT_NODE_TOKEN") or _parse_env(_secret_path("agent")).get("AGENT_NODE_TOKEN", "")
        data = _http_json(f"{node_url}/v1/runs?history=0", token=token)
        if data and isinstance(data.get("runs"), list):
            rows = []
            for item in data["runs"]:
                started = item.get("created_at") or item.get("started_at")
                finished = item.get("finished_at")
                rows.append({
                    "run_id": item.get("run_id", "-"),
                    "session_id": item.get("session_id", "-"),
                    "agent_id": item.get("agent_id", "-"),
                    "provider_id": item.get("provider_id", "-"),
                    "status": item.get("status", "-"),
                    "returncode": item.get("returncode", "-"),
                    "duration": _duration_ms(started, finished),
                })
            active = [row for row in rows if row["status"] in {"starting", "running"}]
            print(f"active agent runs: {len(active)}")
            if active:
                _print_table(
                    active,
                    [
                        ("run_id", "RUN"),
                        ("session_id", "SESSION"),
                        ("agent_id", "AGENT"),
                        ("provider_id", "PROVIDER"),
                        ("status", "STATUS"),
                        ("duration", "DURATION"),
                    ],
                )
            return 0
    rows = []
    proc = _run(["docker", "ps", "--filter", "name=myapp-agent-", "--format", "{{json .}}"])
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = item.get("Names", "-")
            if str(name).startswith("myapp-agent-node"):
                continue
            rows.append({"container": name, "status": item.get("Status", "-")})
    print(f"running agent containers: {sum('Up ' in row['status'] for row in rows)}")
    if rows:
        _print_table(rows, [("container", "CONTAINER"), ("status", "STATUS")])
    return 0


__all__ = [
    '_docker_container_running',
    '_agent_node_instance_slug',
    '_agent_node_instance_container_name',
    '_agent_node_instance_root',
    '_agent_node_container_backend_url',
    '_write_agent_node_instance_env',
    '_filtered_agent_node_instance_env',
    '_agent_node_provider_env_path',
    '_run_agent_node_instance',
    '_http_json',
    '_default_adapter_kind',
    '_agent_node_default_display_host',
    '_duration_ms',
    '_agent_add_node_id',
    '_print_agent_add_script',
    '_join_agent_node',
    '_private_agent_key_paths',
    '_ensure_private_agent_keypair',
    '_private_agent_auth_token',
    '_private_agent_join_token',
    '_local_private_agent_jwt',
    '_private_agent_nodes_payload',
    '_list_private_agent_nodes',
    '_status_private_agent_node',
    '_join_private_agent_node',
    '_agent_node_backend_url',
    '_agent_node_registry_token',
    '_agent_node_request_json',
    '_register_agent_node',
    '_expires_label',
    '_version_label',
    '_print_agent_node_rows',
    '_print_agent_node_status',
    '_local_agent_node_url',
    '_local_agent_node_token',
    '_set_local_agent_node_limits',
    'cmd_agent_node',
    'cmd_agent',
]
