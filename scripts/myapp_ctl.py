#!/usr/bin/env python3
"""Control CLI for MyApp backend hosts.

The CLI is intentionally small and dependency-free: service inventory is data
in /etc/myapp/*.json, secrets are host-local files, and Docker/Compose do the
actual process management.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
import secrets as py_secrets
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


CONFIG_PATH = Path(os.environ.get("MYAPP_CTL_CONFIG", "/etc/myapp/ctl.json"))
SERVICES_PATH = Path(os.environ.get("MYAPP_CTL_SERVICES", "/etc/myapp/services.json"))

DEPLOY_ORDER = [
    "agent-runtime",
    "jsonapp-postgres",
    "ai-session-redis",
    "app-minio",
    "supabase-db",
    "supabase-analytics",
    "supabase-studio",
    "supabase-kong",
    "supabase-auth",
    "supabase-rest",
    "supabase-realtime",
    "supabase-imgproxy",
    "supabase-storage",
    "supabase-meta",
    "supabase-edge-functions",
    "supabase-vector",
    "supabase-pooler",
    "openim-mysql",
    "openim-mongo",
    "openim-redis",
    "openim-kafka",
    "openim-etcd",
    "openim-minio",
    "openim-server",
    "agent-node",
    "registry",
    "backend",
    "ai-worker",
    "config-center",
    "user-center",
]
IMAGE_TARGETS = {
    "agent-runtime": ("agent_runtime", "deploy/production/Dockerfile.agent-runtime"),
    "agent-node": ("agent_node", "deploy/production/Dockerfile.agent-node"),
    "backend": ("backend", "deploy/production/Dockerfile.backend"),
}
BACKEND_IMAGE_SERVICES = {"backend", "ai-worker", "registry", "config-center", "user-center"}
DEFAULT_NETWORKS = ["myapp_default", "myapp_agent_runtime"]
COMPOSE_ENV_FILE_NAMES = [
    "backend.env",
    "supabase.env",
    "openim.env",
    "ai-providers.env",
    "agent.env",
    "push.env",
    "config-center.env",
    "user-center.env",
]


def _load_json(path: Path, default: dict) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def _save_json(path: Path, data: dict, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if mode is not None:
        os.chmod(tmp, mode)
    tmp.replace(path)
    if mode is not None:
        os.chmod(path, mode)


def _cfg() -> dict:
    return _load_json(CONFIG_PATH, {"paths": {"secrets_dir": "/etc/myapp/secrets.d"}, "domains": {}})


def _services() -> dict:
    return _load_json(SERVICES_PATH, {"services": {}}).get("services", {})


def _run(cmd: list[str], *, capture: bool = True) -> subprocess.CompletedProcess:
    kwargs = {"text": True}
    if capture:
        kwargs.update({"stdout": subprocess.PIPE, "stderr": subprocess.PIPE})
    return subprocess.run(cmd, **kwargs)


def _docker_inspect(name: str) -> dict | None:
    proc = _run(["docker", "inspect", name])
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    return rows[0] if rows else None


def _docker_ps_all() -> list[dict]:
    proc = _run(["docker", "ps", "-a", "--format", "{{json .}}"])
    if proc.returncode != 0:
        return []
    rows = []
    for line in proc.stdout.splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


def _health(spec: dict | None) -> str:
    if not spec or spec.get("type") != "http":
        return "-"
    try:
        req = Request(str(spec.get("url") or ""), headers={"User-Agent": "myapp-ctl/1"})
        with urlopen(req, timeout=1.2) as resp:
            return "ok" if 200 <= getattr(resp, "status", 0) < 400 else f"http-{resp.status}"
    except HTTPError as exc:
        return f"http-{exc.code}"
    except (URLError, ValueError, OSError):
        return "down"


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


def _image_exists(image: str) -> bool:
    return _run(["docker", "image", "inspect", image]).returncode == 0


def _source_dir() -> Path:
    cfg = _cfg()
    candidates = [
        os.environ.get("MYAPP_SOURCE_DIR"),
        cfg.get("paths", {}).get("source"),
        str(Path(cfg.get("paths", {}).get("root", "/opt/myapp")) / "current"),
        "/opt/myapp/current-agent-control-plane",
        os.getcwd(),
    ]
    for raw in candidates:
        if not raw:
            continue
        path = Path(str(raw))
        if (path / "deploy/production").is_dir() and (path / "backend").is_dir():
            return path
    return Path(os.getcwd())


def _configured_image(target: str) -> str:
    cfg_images = _cfg().get("images", {})
    key, _ = IMAGE_TARGETS[target]
    default = f"dapangyufish/myapp-{target}:agent-control-plane"
    return str(cfg_images.get(key) or default)


def _image_targets_for_names(names: list[str]) -> list[str]:
    targets: list[str] = []
    if "agent-runtime" in names:
        targets.append("agent-runtime")
    if "agent-node" in names:
        targets.append("agent-node")
    if any(name in BACKEND_IMAGE_SERVICES for name in names):
        targets.append("backend")
    return [target for target in IMAGE_TARGETS if target in targets]


def _ordered_service_names(names: list[str]) -> list[str]:
    known = set(_services())
    seen = set()
    out: list[str] = []
    for name in DEPLOY_ORDER + names:
        if name in known and name in names and name not in seen:
            out.append(name)
            seen.add(name)
    for name in names:
        if name in known and name not in seen:
            out.append(name)
            seen.add(name)
    return out


def _service_names_for_target(target: str | None, group: str | None = None) -> list[str]:
    services = _services()
    if group:
        names = [name for name, spec in services.items() if spec.get("group") == group]
        if not names:
            raise KeyError(f"unknown group: {group}")
        return _ordered_service_names(names)
    normalized = (target or "all").strip()
    if normalized in {"", "all"}:
        return _ordered_service_names([name for name in DEPLOY_ORDER if name in services])
    if normalized in {spec.get("group") for spec in services.values()}:
        names = [name for name, spec in services.items() if spec.get("group") == normalized]
        return _ordered_service_names(names)
    if normalized not in services:
        raise KeyError(f"unknown service or group: {normalized}")
    return [normalized]


def _compose_command(spec: dict, command: list[str]) -> list[str]:
    project_dir = Path(spec.get("project_dir", "."))
    files = spec.get("compose_files") or []
    cmd = ["docker", "compose"]
    for env_file in _compose_env_files():
        cmd.extend(["--env-file", str(env_file)])
    for name in files:
        cmd.extend(["-f", str(project_dir / name)])
    cmd.extend(command)
    return [part for part in cmd if part]


def _compose_env_files() -> list[Path]:
    secret_dir = _secret_dir()
    return [secret_dir / name for name in COMPOSE_ENV_FILE_NAMES if (secret_dir / name).exists()]


def _run_or_print(cmd: list[str], *, dry_run: bool) -> int:
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    return _run(cmd, capture=False).returncode


def _process_status(spec: dict) -> dict:
    pid_file = spec.get("pid_file")
    pid = None
    alive = False
    if pid_file and Path(pid_file).exists():
        try:
            pid = int(Path(pid_file).read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            alive = True
        except (OSError, ValueError):
            alive = False
    return {
        "state": "running" if alive else "stopped",
        "pid": pid,
        "status": f"pid {pid}" if alive else "not running",
        "health": _health(spec.get("health")) if alive else "-",
    }


def _service_status(name: str, spec: dict) -> dict:
    kind = spec.get("kind", "docker")
    if kind == "process":
        return {"name": name, "group": spec.get("group", "-"), "kind": kind, **_process_status(spec)}
    if kind == "image":
        image = spec.get("image", name)
        return {
            "name": name,
            "group": spec.get("group", "-"),
            "kind": kind,
            "state": "present" if _image_exists(image) else "missing",
            "health": "-",
            "status": image,
        }
    container = spec.get("container") or name
    info = _docker_inspect(container)
    if not info:
        return {
            "name": name,
            "group": spec.get("group", "-"),
            "kind": kind,
            "state": "missing",
            "health": "-",
            "status": container,
        }
    state = info.get("State", {})
    return {
        "name": name,
        "group": spec.get("group", "-"),
        "kind": kind,
        "state": state.get("Status", "unknown"),
        "health": state.get("Health", {}).get("Status") or _health(spec.get("health")),
        "status": container,
    }


def _print_table(rows: list[dict], columns: list[tuple[str, str]]) -> None:
    if not rows:
        print("(empty)")
        return
    widths = [max(len(title), *(len(str(row.get(key, ""))) for row in rows)) for key, title in columns]
    print("  ".join(title.ljust(widths[i]) for i, (_, title) in enumerate(columns)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(str(row.get(key, "")).ljust(widths[i]) for i, (key, _) in enumerate(columns)))


def cmd_status(args) -> int:
    services = _services()
    names = [args.service] if args.service else sorted(services)
    rows = []
    for name in names:
        if name not in services:
            print(f"unknown service: {name}", file=sys.stderr)
            return 2
        rows.append(_service_status(name, services[name]))
    if not args.service:
        declared = {spec.get("container") or name for name, spec in services.items()}
        for item in _docker_ps_all():
            name = item.get("Names") or item.get("Name")
            if name and name not in declared:
                rows.append(
                    {
                        "group": "docker:auto",
                        "name": name,
                        "kind": "docker",
                        "state": item.get("State", "-"),
                        "health": "-",
                        "status": item.get("Status", "-"),
                    }
                )
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        _print_table(
            rows,
            [("group", "GROUP"), ("name", "SERVICE"), ("kind", "KIND"), ("state", "STATE"), ("health", "HEALTH"), ("status", "DETAIL")],
        )
    return 0


def _compose_cmd(spec: dict, action: str) -> int:
    project_dir = Path(spec.get("project_dir", "."))
    files = spec.get("compose_files") or []
    if not project_dir.exists():
        print(f"compose project missing: {project_dir}", file=sys.stderr)
        return 1
    if not files:
        print("compose_files is empty", file=sys.stderr)
        return 1
    if action == "deploy":
        cmd = _compose_command(spec, ["up", "-d", spec.get("compose_service", "")])
    else:
        cmd = _compose_command(spec, ["restart", spec.get("compose_service", "")])
    return _run(cmd, capture=False).returncode


def _deploy_images(targets: list[str], *, action: str, dry_run: bool) -> int:
    source_dir = _source_dir()
    for target in targets:
        image = _configured_image(target)
        if action == "build":
            _, dockerfile = IMAGE_TARGETS[target]
            cmd = ["docker", "build", "-f", str(source_dir / dockerfile), "-t", image, str(source_dir)]
        elif action == "push":
            cmd = ["docker", "push", image]
        elif action == "pull":
            cmd = ["docker", "pull", image]
        else:
            raise ValueError(action)
        rc = _run_or_print(cmd, dry_run=dry_run)
        if rc != 0:
            return rc
    return 0


def _group_in_names(names: list[str], group: str) -> bool:
    services = _services()
    return any(services.get(name, {}).get("group") == group for name in names)


def _prepare_openim_config(spec: dict, *, dry_run: bool) -> int:
    project_dir = Path(spec.get("project_dir", "."))
    cfg_dir = project_dir / "config-rendered"
    env = _parse_env(_secret_path("openim"))
    required = [
        "HOST_IP",
        "OPENIM_MONGO_PASSWORD",
        "OPENIM_REDIS_PASSWORD",
        "OPENIM_MINIO_ACCESS_KEY",
        "OPENIM_MINIO_SECRET_KEY",
        "OPENIM_MINIO_PORT",
        "OPENIM_SECRET",
    ]
    missing = [key for key in required if not env.get(key)]
    if missing:
        print("missing OpenIM env keys: " + ", ".join(missing), file=sys.stderr)
        print("run: myapp-ctl secret init-stack", file=sys.stderr)
        return 1
    image = "openim/openim-server:v3.8.3-patch.12"
    print(f"+ render OpenIM config: {cfg_dir}")
    if dry_run:
        return 0
    if not project_dir.exists():
        print(f"compose project missing: {project_dir}", file=sys.stderr)
        return 1
    if cfg_dir.exists():
        shutil.rmtree(cfg_dir)
    cfg_dir.mkdir(parents=True, exist_ok=True)
    rc = _run(
        [
            "docker",
            "run",
            "--rm",
            "--entrypoint",
            "sh",
            "-v",
            f"{cfg_dir}:/host",
            image,
            "-c",
            "cp -a /openim-server/config/. /host/ && chmod -R a+rwX /host/",
        ],
        capture=False,
    ).returncode
    if rc != 0:
        return rc
    replacements = {
        "mongodb.yml": [
            ("localhost:37017", "mongodb:27017"),
            ("username: openIM", "username: openim"),
            ("password: openIM123", f"password: {env['OPENIM_MONGO_PASSWORD']}"),
            ("authSource: openim_v3", "authSource: admin"),
        ],
        "redis.yml": [
            ("localhost:16379", "redis:6379"),
            ("password: openIM123", f"password: {env['OPENIM_REDIS_PASSWORD']}"),
        ],
        "kafka.yml": [("localhost:19094", "kafka:9092")],
        "discovery.yml": [("localhost:12379", "etcd:2379")],
        "minio.yml": [
            ("accessKeyID: root", f"accessKeyID: {env['OPENIM_MINIO_ACCESS_KEY']}"),
            ("secretAccessKey: openIM123", f"secretAccessKey: {env['OPENIM_MINIO_SECRET_KEY']}"),
            ("localhost:10005", "minio:9000"),
            ("http://external_ip:10005", f"http://{env['HOST_IP']}:{env['OPENIM_MINIO_PORT']}"),
        ],
        "share.yml": [("secret: openIM123", f"secret: {env['OPENIM_SECRET']}")],
    }
    for rel, pairs in replacements.items():
        path = cfg_dir / rel
        if not path.exists():
            print(f"OpenIM config file missing after extract: {path}", file=sys.stderr)
            return 1
        text = path.read_text(encoding="utf-8")
        for old, new in pairs:
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
    return 0


def _prepare_deploy(names: list[str], *, dry_run: bool) -> int:
    if not _group_in_names(names, "openim"):
        return 0
    services = _services()
    for name in names:
        spec = services.get(name, {})
        if spec.get("group") == "openim" and spec.get("kind") == "compose":
            return _prepare_openim_config(spec, dry_run=dry_run)
    return 0


def _ensure_images(targets: list[str], *, dry_run: bool) -> int:
    if dry_run:
        return 0
    missing = [target for target in targets if not _image_exists(_configured_image(target))]
    if missing:
        for target in missing:
            print(f"missing image: {_configured_image(target)}", file=sys.stderr)
        print("run with --pull to pull images or --build to build them locally", file=sys.stderr)
        return 1
    return 0


def _deploy_compose_services(names: list[str], *, dry_run: bool) -> int:
    services = _services()
    current_key: tuple[str, tuple[str, ...]] | None = None
    current_spec: dict | None = None
    current_services: list[str] = []

    def flush() -> int:
        nonlocal current_key, current_spec, current_services
        if not current_spec or not current_services:
            current_key = None
            current_spec = None
            current_services = []
            return 0
        cmd = _compose_command(current_spec, ["up", "-d", *current_services])
        rc = _run_or_print(cmd, dry_run=dry_run)
        current_key = None
        current_spec = None
        current_services = []
        return rc

    for name in names:
        spec = services[name]
        kind = spec.get("kind")
        if kind == "docker":
            rc = flush()
            if rc != 0:
                return rc
            rc = _run_or_print(["docker", "start", spec.get("container") or name], dry_run=dry_run)
            if rc != 0:
                return rc
            continue
        if kind != "compose":
            rc = flush()
            if rc != 0:
                return rc
            continue
        project_dir = str(spec.get("project_dir", "."))
        compose_files = tuple(spec.get("compose_files") or [])
        key = (project_dir, compose_files)
        if current_key is not None and key != current_key:
            rc = flush()
            if rc != 0:
                return rc
        current_key = key
        current_spec = spec
        current_services.append(str(spec.get("compose_service") or name))
    return flush()


def _compose_specs_for_names(names: list[str]) -> list[dict]:
    services = _services()
    seen: set[tuple[str, tuple[str, ...]]] = set()
    specs: list[dict] = []
    for name in names:
        spec = services[name]
        if spec.get("kind") != "compose":
            continue
        key = (str(spec.get("project_dir", ".")), tuple(spec.get("compose_files") or []))
        if key in seen:
            continue
        seen.add(key)
        specs.append(spec)
    return specs


def _remove_path(path: Path, *, dry_run: bool) -> int:
    print(f"+ rm -rf {path}")
    if dry_run or not path.exists():
        return 0
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
    return 0


def _remove_installed_config_path(path: Path, *, dry_run: bool) -> int:
    if not path.is_absolute():
        print(f"# skip non-installed config path: {path}")
        return 0
    return _remove_path(path, dry_run=dry_run)


def _docker_container_names(pattern: str) -> list[str]:
    proc = _run(["docker", "ps", "-a", "--filter", f"name={pattern}", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _docker_network_exists(name: str) -> bool:
    return _run(["docker", "network", "inspect", name]).returncode == 0


def cmd_uninstall(args) -> int:
    if not args.yes:
        print("refusing to uninstall without --yes", file=sys.stderr)
        return 2
    services = _services()
    names = _ordered_service_names(list(services))
    purge = bool(args.purge)
    remove_images = bool(args.images or purge)
    dry_run = bool(args.dry_run)

    for spec in _compose_specs_for_names(names):
        project_dir = Path(spec.get("project_dir", "."))
        compose_files = [project_dir / name for name in (spec.get("compose_files") or [])]
        if not dry_run and (not project_dir.exists() or any(not path.exists() for path in compose_files)):
            continue
        cmd = _compose_command(spec, ["down", "--remove-orphans"])
        if purge or args.volumes:
            cmd.append("--volumes")
        rc = _run_or_print(cmd, dry_run=dry_run)
        if rc != 0:
            return rc

    docker_names = []
    for name in names:
        spec = services[name]
        if spec.get("kind") == "docker":
            docker_names.append(spec.get("container") or name)
    docker_names.extend(name for name in _docker_container_names("myapp-agent-") if name != "myapp-agent-node")
    seen_containers: set[str] = set()
    for container in docker_names:
        if container in seen_containers:
            continue
        seen_containers.add(container)
        if not dry_run and not _docker_inspect(container):
            continue
        rc = _run_or_print(["docker", "rm", "-f", container], dry_run=dry_run)
        if rc != 0:
            return rc

    for network in DEFAULT_NETWORKS:
        if not dry_run and not _docker_network_exists(network):
            continue
        rc = _run_or_print(["docker", "network", "rm", network], dry_run=dry_run)
        if rc != 0:
            return rc

    if remove_images:
        for target in IMAGE_TARGETS:
            if not dry_run and not _image_exists(_configured_image(target)):
                continue
            rc = _run_or_print(["docker", "rmi", "-f", _configured_image(target)], dry_run=dry_run)
            if rc != 0:
                return rc

    if purge or args.state:
        _remove_path(Path(_cfg().get("paths", {}).get("state", "/var/lib/myapp")), dry_run=dry_run)
    if purge or args.logs:
        _remove_path(Path(_cfg().get("paths", {}).get("logs", "/var/log/myapp")), dry_run=dry_run)
    if purge or args.secrets:
        _remove_path(_secret_dir(), dry_run=dry_run)
    if purge or args.install_files:
        cfg = _cfg()
        root = Path(cfg.get("paths", {}).get("root", "/opt/myapp"))
        _remove_path(root / "deploy/production", dry_run=dry_run)
        _remove_installed_config_path(CONFIG_PATH, dry_run=dry_run)
        _remove_installed_config_path(SERVICES_PATH, dry_run=dry_run)
    if args.remove_ctl:
        _remove_path(Path("/usr/local/bin/myapp-ctl"), dry_run=dry_run)
        _remove_path(Path("/opt/myapp/bin/myapp-ctl"), dry_run=dry_run)
    print("uninstall completed" if not dry_run else "uninstall dry-run completed")
    return 0


def cmd_deploy(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    try:
        names = _service_names_for_target(args.target, args.group)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    image_targets = _image_targets_for_names(names)
    if args.plan:
        services = _services()
        compose_names = [name for name in names if services[name].get("kind") == "compose"]
        docker_names = [name for name in names if services[name].get("kind") == "docker"]
        print("deploy plan:")
        if image_targets:
            print("  images: " + ", ".join(image_targets))
        if compose_names:
            print("  compose services: " + ", ".join(compose_names))
        if docker_names:
            print("  docker containers: " + ", ".join(docker_names))
        return 0
    if args.build:
        rc = _deploy_images(image_targets, action="build", dry_run=args.dry_run)
        if rc != 0:
            return rc
    elif args.pull:
        rc = _deploy_images(image_targets, action="pull", dry_run=args.dry_run)
        if rc != 0:
            return rc
    else:
        rc = _ensure_images(image_targets, dry_run=args.dry_run)
        if rc != 0:
            return rc
    if not args.dry_run:
        _init_stack_secrets(quiet=True)
    rc = _prepare_deploy(names, dry_run=args.dry_run)
    if rc != 0:
        return rc
    return _deploy_compose_services(names, dry_run=args.dry_run)


def cmd_restart(args) -> int:
    try:
        names = _service_names_for_target(args.target, args.group)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    for name in names:
        spec = _services()[name]
        kind = spec.get("kind", "docker")
        if kind == "compose":
            rc = _compose_cmd(spec, "restart")
            if rc != 0:
                return rc
            continue
        if kind == "image":
            print(f"skip image target {name}; use myapp-ctl image build/pull/push {name}")
            continue
        if kind != "process":
            rc = _run(["docker", "restart", spec.get("container") or name], capture=False).returncode
            if rc != 0:
                return rc
            continue
        status = _process_status(spec)
        if status.get("pid") and status.get("state") == "running":
            os.kill(int(status["pid"]), signal.SIGTERM)
            time.sleep(1)
        command = spec.get("command")
        if not command:
            print(f"{name} has no command", file=sys.stderr)
            return 1
        log_file = spec.get("log_file") or f"/var/log/myapp/{name}.log"
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        with open(log_file, "ab") as out:
            subprocess.Popen(command, stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True)
        print(f"restarted process {name}")
    return 0


def cmd_log(args) -> int:
    spec = _services().get(args.service)
    if not spec:
        print(f"unknown service: {args.service}", file=sys.stderr)
        return 2
    if spec.get("log_file"):
        cmd = ["tail", "-n", str(args.lines)]
        if args.follow:
            cmd.append("-f")
        cmd.append(spec["log_file"])
        return _run(cmd, capture=False).returncode
    cmd = ["docker", "logs", "--tail", str(args.lines)]
    if args.follow:
        cmd.append("-f")
    cmd.append(spec.get("container") or args.service)
    return _run(cmd, capture=False).returncode


def _secret_dir() -> Path:
    return Path(_cfg().get("paths", {}).get("secrets_dir", "/etc/myapp/secrets.d"))


def _secret_path(group: str) -> Path:
    return _secret_dir() / f"{group.replace('/', '_').replace('..', '_')}.env"


def _parse_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def _write_env(path: Path, data: dict[str, str]) -> None:
    body = "".join(f"{key}={value}\n" for key, value in sorted(data.items()))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def _rand_hex(bytes_len: int) -> str:
    return py_secrets.token_hex(bytes_len)


def _rand_token(length: int = 32) -> str:
    token = py_secrets.token_urlsafe(length)
    return token.replace("-", "").replace("_", "")[:length]


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _mint_supabase_jwt(secret: str, role: str) -> str:
    now = int(time.time())
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": now,
        "exp": now + 5 * 365 * 24 * 3600,
    }
    header_b64 = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload_b64 = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()
    sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return f"{header_b64}.{payload_b64}.{_b64url(sig)}"


def _public_host(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    cfg = _cfg()
    node_ip = cfg.get("node", {}).get("public_ip")
    if node_ip:
        return str(node_ip)
    backend = str(cfg.get("domains", {}).get("backend") or "")
    parsed = urlparse(backend)
    if parsed.hostname:
        return parsed.hostname
    return "127.0.0.1"


def _merge_env_group(group: str, values: dict[str, str], *, force: bool = False) -> list[str]:
    path = _secret_path(group)
    data = _parse_env(path)
    changed: list[str] = []
    for key, value in values.items():
        if force or not data.get(key):
            data[key] = value
            changed.append(key)
    if changed:
        _write_env(path, data)
    return changed


def _init_stack_secrets(*, host: str | None = None, force: bool = False, quiet: bool = False) -> int:
    public_host = _public_host(host)
    secret_dir = _secret_dir()
    secret_dir.mkdir(parents=True, exist_ok=True)

    existing_backend = _parse_env(_secret_path("backend"))
    existing_supabase = _parse_env(_secret_path("supabase"))
    existing_openim = _parse_env(_secret_path("openim"))

    jwt_secret = existing_supabase.get("JWT_SECRET") if not force else ""
    jwt_secret = jwt_secret or _rand_hex(32)
    anon_key = existing_supabase.get("ANON_KEY") if not force else ""
    service_role_key = existing_supabase.get("SERVICE_ROLE_KEY") if not force else ""
    anon_key = anon_key or _mint_supabase_jwt(jwt_secret, "anon")
    service_role_key = service_role_key or _mint_supabase_jwt(jwt_secret, "service_role")

    openim_secret = existing_openim.get("OPENIM_SECRET") if not force else ""
    openim_secret = openim_secret or _rand_hex(32)
    openim_webhook_secret = existing_backend.get("OPENIM_WEBHOOK_SECRET") if not force else ""
    openim_webhook_secret = openim_webhook_secret or existing_openim.get("OPENIM_WEBHOOK_SECRET", "")
    openim_webhook_secret = openim_webhook_secret or _rand_hex(32)

    backend_defaults = {
        "PUBLIC_HOST": public_host,
        "BACKEND_PORT": "5566",
        "REGISTRY_PORT": "3254",
        "CONFIG_CENTER_PORT": "5000",
        "USER_CENTER_PORT": "5567",
        "JSONAPP_DB_USER": "jsonapp",
        "JSONAPP_DB_NAME": "jsonapp",
        "JSONAPP_DB_PASSWORD": _rand_token(32),
        "BACKEND_REDIS_PASSWORD": _rand_token(32),
        "APP_MINIO_ACCESS_KEY": "app" + _rand_hex(8),
        "APP_MINIO_SECRET_KEY": _rand_token(40),
        "APP_MINIO_PORT": "9000",
        "APP_MINIO_CONSOLE_PORT": "9090",
        "SUPABASE_URL": f"http://{public_host}:18000",
        "SUPABASE_ANON_KEY": anon_key,
        "SUPABASE_SERVICE_KEY": service_role_key,
        "OPENIM_API_URL": f"http://{public_host}:10002",
        "OPENIM_WS_URL": f"ws://{public_host}:10001",
        "OPENIM_SECRET": openim_secret,
        "OPENIM_WEBHOOK_SECRET": openim_webhook_secret,
        "FLASK_SECRET_KEY": _rand_hex(32),
        "REGISTRY_ADMIN_TOKEN": _rand_hex(32),
        "REGISTRY_ADMIN_AUTHOR_EMAIL": "2501808198@qq.com",
        "REGISTRY_ADMIN_AUTHOR_NAME": "fish",
        "REGISTRY_ADMIN_AUTHOR_ID": "2501808198@qq.com",
        "AI_WORKER_MAX_CONCURRENCY": "20",
        "AI_WORKER_QUEUE_MAX": "100",
        "DEEPSEEK_AI_WORKER_MAX_CONCURRENCY": "20",
        "DEEPSEEK_AI_WORKER_QUEUE_MAX": "100",
        "MINIMAX_AI_WORKER_MAX_CONCURRENCY": "5",
        "MINIMAX_AI_WORKER_QUEUE_MAX": "20",
    }
    supabase_defaults = {
        "HOST_IP": public_host,
        "POSTGRES_PASSWORD": _rand_token(32),
        "JWT_SECRET": jwt_secret,
        "ANON_KEY": anon_key,
        "SERVICE_ROLE_KEY": service_role_key,
        "SUPABASE_PUBLISHABLE_KEY": anon_key,
        "SUPABASE_SECRET_KEY": service_role_key,
        "DASHBOARD_USERNAME": "admin",
        "DASHBOARD_PASSWORD": _rand_token(24),
        "SECRET_KEY_BASE": _rand_hex(32),
        "VAULT_ENC_KEY": _rand_hex(16),
        "PG_META_CRYPTO_KEY": _rand_hex(32),
        "LOGFLARE_PUBLIC_ACCESS_TOKEN": _rand_hex(24),
        "LOGFLARE_PRIVATE_ACCESS_TOKEN": _rand_hex(24),
        "ANON_KEY_ASYMMETRIC": "",
        "SERVICE_ROLE_KEY_ASYMMETRIC": "",
        "JWT_KEYS": "[]",
        "JWT_JWKS": "{\"keys\":[]}",
        "POSTGRES_HOST": "db",
        "POSTGRES_DB": "postgres",
        "POSTGRES_PORT": "15432",
        "POOLER_TENANT_ID": "myapp" + _rand_hex(4),
        "POOLER_PROXY_PORT_TRANSACTION": "6543",
        "POOLER_DEFAULT_POOL_SIZE": "20",
        "POOLER_MAX_CLIENT_CONN": "100",
        "POOLER_DB_POOL_SIZE": "5",
        "KONG_HTTP_PORT": "18000",
        "KONG_HTTPS_PORT": "18443",
        "API_EXTERNAL_URL": f"http://{public_host}:18000",
        "SUPABASE_PUBLIC_URL": f"http://{public_host}:18000",
        "SITE_URL": f"http://{public_host}:18000",
        "SAML_EXTERNAL_URL": "",
        "ADDITIONAL_REDIRECT_URLS": "",
        "DISABLE_SIGNUP": "false",
        "ENABLE_EMAIL_SIGNUP": "true",
        "ENABLE_EMAIL_AUTOCONFIRM": "true",
        "ENABLE_PHONE_SIGNUP": "false",
        "ENABLE_PHONE_AUTOCONFIRM": "false",
        "ENABLE_ANONYMOUS_USERS": "false",
        "JWT_EXPIRY": "3600",
        "MAILER_URLPATHS_CONFIRMATION": "/auth/v1/verify",
        "MAILER_URLPATHS_EMAIL_CHANGE": "/auth/v1/verify",
        "MAILER_URLPATHS_INVITE": "/auth/v1/verify",
        "MAILER_URLPATHS_RECOVERY": "/auth/v1/verify",
        "SMTP_ADMIN_EMAIL": "noreply@example.local",
        "SMTP_HOST": "localhost",
        "SMTP_PORT": "587",
        "SMTP_USER": "",
        "SMTP_PASS": "",
        "SMTP_SENDER_NAME": "myapp",
        "GITHUB_ENABLED": "false",
        "GITHUB_CLIENT_ID": "",
        "GITHUB_SECRET": "",
        "GOOGLE_ENABLED": "false",
        "GOOGLE_CLIENT_ID": "",
        "GOOGLE_SECRET": "",
        "GOOGLE_PROJECT_ID": "",
        "GOOGLE_PROJECT_NUMBER": "",
        "AZURE_ENABLED": "false",
        "AZURE_CLIENT_ID": "",
        "AZURE_SECRET": "",
        "MFA_PHONE_ENROLL_ENABLED": "false",
        "MFA_PHONE_VERIFY_ENABLED": "false",
        "MFA_TOTP_ENROLL_ENABLED": "false",
        "MFA_TOTP_VERIFY_ENABLED": "false",
        "MFA_MAX_ENROLLED_FACTORS": "10",
        "SAML_ENABLED": "false",
        "SAML_PRIVATE_KEY": "",
        "SAML_ALLOW_ENCRYPTED_ASSERTIONS": "false",
        "SAML_RELAY_STATE_VALIDITY_PERIOD": "300",
        "SAML_RATE_LIMIT_ASSERTION": "",
        "SMS_PROVIDER": "",
        "SMS_OTP_EXP": "60",
        "SMS_OTP_LENGTH": "6",
        "SMS_MAX_FREQUENCY": "",
        "SMS_TWILIO_ACCOUNT_SID": "",
        "SMS_TWILIO_AUTH_TOKEN": "",
        "SMS_TWILIO_MESSAGE_SERVICE_SID": "",
        "SMS_TEMPLATE": "",
        "SMS_TEST_OTP": "",
        "PGRST_DB_SCHEMAS": "public,storage,graphql_public",
        "PGRST_DB_EXTRA_SEARCH_PATH": "public,extensions",
        "PGRST_DB_MAX_ROWS": "1000",
        "FUNCTIONS_VERIFY_JWT": "false",
        "STUDIO_DEFAULT_ORGANIZATION": "Default Organization",
        "STUDIO_DEFAULT_PROJECT": "Default Project",
        "OPENAI_API_KEY": "",
        "STORAGE_TENANT_ID": "stub",
        "GLOBAL_S3_BUCKET": "stub",
        "IMGPROXY_AUTO_WEBP": "true",
        "S3_PROTOCOL_ACCESS_KEY_ID": "s3" + _rand_hex(8),
        "S3_PROTOCOL_ACCESS_KEY_SECRET": _rand_token(32),
        "REGION": "local",
        "DOCKER_SOCKET_LOCATION": "/var/run/docker.sock",
    }
    openim_defaults = {
        "HOST_IP": public_host,
        "OPENIM_MYSQL_ROOT_PASSWORD": _rand_token(32),
        "OPENIM_MYSQL_PASSWORD": _rand_token(32),
        "OPENIM_MONGO_PASSWORD": _rand_token(32),
        "OPENIM_REDIS_PASSWORD": _rand_token(32),
        "OPENIM_MINIO_ACCESS_KEY": "openim" + _rand_hex(4),
        "OPENIM_MINIO_SECRET_KEY": _rand_token(32),
        "OPENIM_SECRET": openim_secret,
        "OPENIM_WEBHOOK_SECRET": openim_webhook_secret,
        "OPENIM_MYSQL_PORT": "13306",
        "OPENIM_MONGO_PORT": "37017",
        "OPENIM_REDIS_PORT": "16379",
        "OPENIM_MINIO_PORT": "10005",
        "OPENIM_MINIO_CONSOLE_PORT": "10006",
        "OPENIM_WS_PORT": "10001",
        "OPENIM_API_PORT": "10002",
        "OPENIM_ADMIN_PORT": "10009",
    }
    agent_defaults = {
        "AGENT_NODE_TOKEN": _rand_hex(24),
        "AGENT_NODE_REGISTRATION_TOKEN": _rand_hex(24),
        "AGENT_NODE_ID": _cfg().get("node", {}).get("id", os.uname().nodename),
    }
    config_center_defaults = {
        "CONFIG_CENTER_ADMIN_USERNAME": "admin",
        "CONFIG_CENTER_ADMIN_PASSWORD": _rand_token(24),
        "CONFIG_CENTER_SESSION_SECRET": _rand_hex(32),
    }
    user_center_defaults = {
        "USER_CENTER_ADMIN_USERNAME": "admin",
        "USER_CENTER_ADMIN_PASSWORD": _rand_token(24),
        "USER_CENTER_SESSION_SECRET": _rand_hex(32),
    }

    changed = {
        "backend": _merge_env_group("backend", backend_defaults, force=force),
        "supabase": _merge_env_group("supabase", supabase_defaults, force=force),
        "openim": _merge_env_group("openim", openim_defaults, force=force),
        "agent": _merge_env_group("agent", agent_defaults, force=force),
        "config-center": _merge_env_group("config-center", config_center_defaults, force=force),
        "user-center": _merge_env_group("user-center", user_center_defaults, force=force),
    }
    if not quiet:
        rows = [{"group": group, "keys": len(keys)} for group, keys in changed.items()]
        _print_table(rows, [("group", "GROUP"), ("keys", "CHANGED_KEYS")])
    return 0


def _redact(value: str) -> str:
    digest = hashlib.sha256(value.encode()).hexdigest()[:8]
    return f"<redacted len={len(value)} sha256:{digest}>"


def cmd_secret(args) -> int:
    _secret_dir().mkdir(parents=True, exist_ok=True)
    if args.secret_cmd == "init-stack":
        return _init_stack_secrets(host=args.host, force=args.force)
    if args.secret_cmd == "ls":
        rows = []
        for path in sorted(_secret_dir().glob("*.env")):
            for key, value in _parse_env(path).items():
                rows.append({"group": path.stem, "key": key, "value": _redact(value)})
        _print_table(rows, [("group", "GROUP"), ("key", "KEY"), ("value", "VALUE")])
        return 0
    path = _secret_path(args.group)
    data = _parse_env(path)
    if args.secret_cmd == "set":
        changed = []
        for item in args.items:
            if "=" in item:
                key, value = item.split("=", 1)
            else:
                key = item
                value = getpass.getpass(f"{args.group}.{key}: ")
            data[key] = value
            changed.append(key)
        _write_env(path, data)
        print(f"updated {args.group}: {', '.join(changed)}")
        return 0
    if args.secret_cmd == "generate":
        changed = []
        for key in args.keys:
            data[key] = py_secrets.token_urlsafe(args.bytes)
            changed.append(key)
        _write_env(path, data)
        print(f"generated {args.group}: {', '.join(changed)}")
        return 0
    if args.secret_cmd == "get":
        if args.key not in data:
            print(f"missing: {args.group}.{args.key}", file=sys.stderr)
            return 1
        print(data[args.key] if args.show else _redact(data[args.key]))
        return 0
    if args.secret_cmd == "rm":
        for key in args.keys:
            data.pop(key, None)
        _write_env(path, data)
        print(f"updated {args.group}")
        return 0
    return 2


def cmd_domain(args) -> int:
    data = _cfg()
    domains = data.setdefault("domains", {})
    if args.domain_cmd == "ls":
        _print_table([{"name": key, "value": value} for key, value in sorted(domains.items())], [("name", "NAME"), ("value", "VALUE")])
        return 0
    if args.domain_cmd == "set":
        domains[args.name] = args.value
        _save_json(CONFIG_PATH, data)
        print(f"set domain {args.name}={args.value}")
        return 0
    if args.domain_cmd == "rm":
        domains.pop(args.name, None)
        _save_json(CONFIG_PATH, data)
        print(f"removed domain {args.name}")
        return 0
    return 2


def _image_targets_for_arg(target: str) -> list[str]:
    normalized = (target or "all").strip()
    if normalized in {"", "all"}:
        return list(IMAGE_TARGETS)
    if normalized not in IMAGE_TARGETS:
        raise KeyError(f"unknown image target: {normalized}")
    return [normalized]


def cmd_image(args) -> int:
    if args.image_cmd == "ls":
        rows = []
        for target in IMAGE_TARGETS:
            image = _configured_image(target)
            rows.append({
                "target": target,
                "image": image,
                "state": "present" if _image_exists(image) else "missing",
            })
        _print_table(rows, [("target", "TARGET"), ("state", "STATE"), ("image", "IMAGE")])
        return 0
    try:
        targets = _image_targets_for_arg(args.target)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return _deploy_images(targets, action=args.image_cmd, dry_run=args.dry_run)


def _run_log_summary(path: Path) -> dict:
    row = {
        "run_id": path.stem,
        "session_id": "-",
        "agent_id": "-",
        "provider_id": "-",
        "status": "unknown",
        "returncode": "-",
        "duration": "-",
        "lines": 0,
    }
    started = None
    stopped = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        row["lines"] += 1
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "start":
            started = event.get("ts")
            row["run_id"] = event.get("run_id") or row["run_id"]
            row["session_id"] = event.get("session_id") or "-"
            row["agent_id"] = event.get("agent_id") or "-"
            row["provider_id"] = event.get("provider_id") or "-"
            row["status"] = "started"
        elif event.get("type") == "stop":
            stopped = event.get("ts")
            row["status"] = event.get("status") or "stopped"
            row["returncode"] = event.get("returncode", "-")
    if started and stopped:
        row["duration"] = f"{max(0, int((stopped - started) / 1000))}s"
    return row


def _duration_ms(started, finished=None) -> str:
    try:
        start = int(started)
        end = int(finished) if finished else int(time.time() * 1000)
        return f"{max(0, int((end - start) / 1000))}s"
    except (TypeError, ValueError):
        return "-"


def cmd_agent(args) -> int:
    if args.agent_cmd == "register":
        cfg = _cfg()
        backend_url = (args.backend or cfg.get("domains", {}).get("backend") or "").rstrip("/")
        node_url = (args.url or cfg.get("domains", {}).get("agent_node") or "").rstrip("/")
        node_id = args.node_id or cfg.get("node", {}).get("id") or os.uname().nodename
        if not backend_url:
            print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
            return 2
        if not node_url:
            print("agent node url is required; pass --url or set domains.agent_node", file=sys.stderr)
            return 2
        token = (
            args.token
            or os.environ.get("AGENT_NODE_REGISTRATION_TOKEN")
            or _parse_env(_secret_path("agent")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
            or _parse_env(_secret_path("backend")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
        )
        payload = json.dumps(
            {
                "node_id": node_id,
                "url": node_url,
                "capacity": args.capacity,
                "ttl_seconds": args.ttl,
                "labels": args.label or [],
            },
            ensure_ascii=False,
        ).encode("utf-8")
        headers = {"Content-Type": "application/json", "User-Agent": "myapp-ctl/1"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = Request(f"{backend_url}/api/ai/agent_nodes/register", data=payload, headers=headers, method="POST")
        try:
            with urlopen(req, timeout=8) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            print(f"register failed: http {exc.code} {detail}", file=sys.stderr)
            return 1
        except (URLError, OSError) as exc:
            print(f"register failed: {exc}", file=sys.stderr)
            return 1
        print(body)
        return 0
    if args.agent_cmd == "ls":
        cfg = _cfg()
        node_url = (args.url or "http://127.0.0.1:5590").rstrip("/")
        token = os.environ.get("AGENT_NODE_TOKEN") or _parse_env(_secret_path("agent")).get("AGENT_NODE_TOKEN", "")
        data = _http_json(f"{node_url}/v1/runs", token=token)
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
            history = [row for row in rows if row["status"] not in {"starting", "running"}]
            print(f"historical runs: {len(history)}")
            if history:
                _print_table(
                    history[:50],
                    [
                        ("run_id", "RUN"),
                        ("session_id", "SESSION"),
                        ("agent_id", "AGENT"),
                        ("provider_id", "PROVIDER"),
                        ("status", "STATUS"),
                        ("returncode", "RC"),
                        ("duration", "DURATION"),
                    ],
                )
            return 0
    rows = []
    proc = _run(["docker", "ps", "-a", "--filter", "name=myapp-agent-", "--format", "{{json .}}"])
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = item.get("Names", "-")
            if name == "myapp-agent-node":
                continue
            rows.append({"container": name, "status": item.get("Status", "-")})
    print(f"running agent containers: {sum('Up ' in row['status'] for row in rows)}")
    if rows:
        _print_table(rows, [("container", "CONTAINER"), ("status", "STATUS")])
    log_dir = Path(_cfg().get("paths", {}).get("agent_log_dir", "/var/log/myapp/agent-node"))
    history = [_run_log_summary(path) for path in sorted(log_dir.glob("*.jsonl"))]
    print(f"historical runs: {len(history)}")
    if history:
        _print_table(history[-50:], [("run_id", "RUN"), ("status", "STATUS"), ("returncode", "RC"), ("duration", "DURATION"), ("lines", "LINES")])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="myapp-ctl")
    sub = parser.add_subparsers(dest="cmd", required=True)
    status = sub.add_parser("status")
    status.add_argument("service", nargs="?")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)
    log = sub.add_parser("log")
    log.add_argument("service")
    log.add_argument("-n", "--lines", type=int, default=80)
    log.add_argument("-f", "--follow", action="store_true")
    log.set_defaults(func=cmd_log)
    image = sub.add_parser("image")
    image_sub = image.add_subparsers(dest="image_cmd", required=True)
    image_sub.add_parser("ls").set_defaults(func=cmd_image)
    for action in ("build", "pull", "push"):
        image_action = image_sub.add_parser(action)
        image_action.add_argument("target", nargs="?", default="all", choices=["all", *IMAGE_TARGETS.keys()])
        image_action.add_argument("--dry-run", action="store_true")
        image_action.set_defaults(func=cmd_image)
    deploy = sub.add_parser("deploy")
    deploy.add_argument("target", nargs="?", default="all", help="service, group, or all")
    deploy.add_argument("--group", choices=["infra", "agent", "core", "openim", "supabase"])
    deploy.add_argument("--build", action="store_true", help="build required images from the local source tree before deploy")
    deploy.add_argument("--pull", action="store_true", help="pull required images before deploy")
    deploy.add_argument("--plan", action="store_true", help="print deployment plan only")
    deploy.add_argument("--dry-run", action="store_true")
    deploy.set_defaults(func=cmd_deploy)
    uninstall = sub.add_parser("uninstall")
    uninstall.add_argument("--yes", action="store_true", help="required confirmation for destructive cleanup")
    uninstall.add_argument("--purge", action="store_true", help="remove containers, compose volumes, state, logs, secrets, install config, and app images")
    uninstall.add_argument("--volumes", action="store_true", help="remove compose volumes while stopping services")
    uninstall.add_argument("--state", action="store_true", help="remove state directory")
    uninstall.add_argument("--logs", action="store_true", help="remove log directory")
    uninstall.add_argument("--secrets", action="store_true", help="remove /etc/myapp/secrets.d")
    uninstall.add_argument("--install-files", action="store_true", help="remove installed compose/config files")
    uninstall.add_argument("--images", action="store_true", help="remove configured MyApp Docker images")
    uninstall.add_argument("--remove-ctl", action="store_true", help="remove the myapp-ctl executable after cleanup")
    uninstall.add_argument("--dry-run", action="store_true")
    uninstall.set_defaults(func=cmd_uninstall)
    restart = sub.add_parser("restart")
    restart.add_argument("target", nargs="?", default="all", help="service, group, or all")
    restart.add_argument("--group", choices=["infra", "agent", "core", "openim", "supabase"])
    restart.set_defaults(func=cmd_restart)
    secret = sub.add_parser("secret")
    secret_sub = secret.add_subparsers(dest="secret_cmd", required=True)
    secret_sub.add_parser("ls").set_defaults(func=cmd_secret)
    secret_init = secret_sub.add_parser("init-stack")
    secret_init.add_argument("--host", help="public host/IP used in generated local service URLs")
    secret_init.add_argument("--force", action="store_true", help="regenerate stack secrets managed by myapp-ctl")
    secret_init.set_defaults(func=cmd_secret)
    secret_set = secret_sub.add_parser("set")
    secret_set.add_argument("group")
    secret_set.add_argument("items", nargs="+")
    secret_set.set_defaults(func=cmd_secret)
    secret_generate = secret_sub.add_parser("generate")
    secret_generate.add_argument("group")
    secret_generate.add_argument("keys", nargs="+")
    secret_generate.add_argument("--bytes", type=int, default=32)
    secret_generate.set_defaults(func=cmd_secret)
    secret_get = secret_sub.add_parser("get")
    secret_get.add_argument("group")
    secret_get.add_argument("key")
    secret_get.add_argument("--show", action="store_true")
    secret_get.set_defaults(func=cmd_secret)
    secret_rm = secret_sub.add_parser("rm")
    secret_rm.add_argument("group")
    secret_rm.add_argument("keys", nargs="+")
    secret_rm.set_defaults(func=cmd_secret)
    domain = sub.add_parser("domain")
    domain_sub = domain.add_subparsers(dest="domain_cmd", required=True)
    domain_sub.add_parser("ls").set_defaults(func=cmd_domain)
    domain_set = domain_sub.add_parser("set")
    domain_set.add_argument("name")
    domain_set.add_argument("value")
    domain_set.set_defaults(func=cmd_domain)
    domain_rm = domain_sub.add_parser("rm")
    domain_rm.add_argument("name")
    domain_rm.set_defaults(func=cmd_domain)
    agent = sub.add_parser("agent")
    agent_sub = agent.add_subparsers(dest="agent_cmd", required=True)
    agent_ls = agent_sub.add_parser("ls")
    agent_ls.add_argument("--url")
    agent_ls.set_defaults(func=cmd_agent)
    agent_register = agent_sub.add_parser("register")
    agent_register.add_argument("--backend")
    agent_register.add_argument("--url")
    agent_register.add_argument("--node-id")
    agent_register.add_argument("--capacity", type=int, default=1)
    agent_register.add_argument("--ttl", type=int, default=120)
    agent_register.add_argument("--token")
    agent_register.add_argument("--label", action="append")
    agent_register.set_defaults(func=cmd_agent)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
