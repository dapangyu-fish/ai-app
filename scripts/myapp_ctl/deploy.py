"""myapp-ctl: deploy commands (split from monolithic myapp_ctl.py; logic unchanged)."""
from __future__ import annotations

import argparse
import ast
import base64
import getpass
import hashlib
import hmac
import io
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
import zipfile
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .core import *  # noqa: F401,F403

def _seed_supabase_postgres_custom_config(*, dry_run: bool) -> int:
    """Seed Supabase Postgres custom config into the local data root.

    The Supabase Postgres image ships required files in /etc/postgresql-custom.
    Once that path is a bind mount, an empty host directory hides those files and
    Postgres fails before the health check. Preserve the directory after first
    seed because it also stores database-local custom configuration.
    """
    target = _data_root_from_cfg() / "supabase-db" / "config"
    target.mkdir(parents=True, exist_ok=True)
    try:
        if any(target.iterdir()):
            return 0
    except OSError as exc:
        print(f"cannot inspect Supabase Postgres custom config dir {target}: {exc}", file=sys.stderr)
        return 1
    cmd = [
        "docker",
        "run",
        "--rm",
        "--user",
        "0:0",
        "-v",
        f"{target}:/host",
        SUPABASE_POSTGRES_IMAGE,
        "sh",
        "-lc",
        "cp -a /etc/postgresql-custom/. /host/ && chmod -R a+rwX /host",
    ]
    return _run_or_print(cmd, dry_run=dry_run)


def _services() -> dict:
    return _load_json(SERVICES_PATH, {"services": {}}).get("services", {})


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
    if not spec:
        return "-"
    if spec.get("type") == "http":
        try:
            req = Request(str(spec.get("url") or ""), headers={"User-Agent": "myapp-ctl/1"})
            with urlopen(req, timeout=1.2) as resp:
                return "ok" if 200 <= getattr(resp, "status", 0) < 400 else f"http-{resp.status}"
        except HTTPError as exc:
            return f"http-{exc.code}"
        except (URLError, ValueError, OSError):
            return "down"
    if spec.get("type") == "tcp":
        host = str(spec.get("host") or "127.0.0.1")
        try:
            port = int(spec.get("port"))
            with socket.create_connection((host, port), timeout=1.2):
                return "ok"
        except (TypeError, ValueError, OSError):
            return "down"
    return "-"


def _image_targets_for_names(names: list[str]) -> list[str]:
    targets: list[str] = []
    if "agent-runtime" in names:
        targets.append("agent-runtime")
    if any(name in FAAS_IMAGE_SERVICES for name in names):
        targets.append("faas-runtime")
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
    if not services:
        raise KeyError(
            f"service inventory is empty or missing: {SERVICES_PATH}; "
            "run deploy/production/install_ctl.sh before deploy"
        )
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


def _service_names_for_targets(targets: list[str] | None, group: str | None = None) -> list[str]:
    raw_targets = [str(target).strip() for target in (targets or []) if str(target).strip()]
    if group:
        if raw_targets and raw_targets != ["all"]:
            raise KeyError("--group cannot be combined with explicit service targets")
        return _service_names_for_target(None, group)
    if not raw_targets:
        return _service_names_for_target("all")
    if len(raw_targets) == 1:
        return _service_names_for_target(raw_targets[0])
    if any(target in {"all", ""} for target in raw_targets):
        raise KeyError("'all' cannot be combined with other deploy targets")
    names: list[str] = []
    for target in raw_targets:
        names.extend(_service_names_for_target(target))
    return _ordered_service_names(names)


def _is_edge_ingress_disabled() -> bool:
    ingress = _cfg().get("ingress")
    return isinstance(ingress, dict) and ingress.get("enabled") is False


def _filter_disabled_optional_services(names: list[str]) -> list[str]:
    if "edge-nginx" not in names or not _is_edge_ingress_disabled():
        return names
    print("skip edge-nginx: ingress is disabled; enable it with `myapp-ctl ingress setup`")
    return [name for name in names if name != "edge-nginx"]


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
    runtime_dir = _runtime_secret_dir()
    secret_dir = _secret_dir()
    files: list[Path] = []
    for name in COMPOSE_ENV_FILE_NAMES:
        runtime_path = runtime_dir / name
        host_path = secret_dir / name
        if runtime_path.exists():
            files.append(runtime_path)
        elif host_path.exists():
            files.append(host_path)
    return files


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
        image = _configured_image(name) if name in IMAGE_TARGETS else spec.get("image", name)
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


def cmd_status(args) -> int:
    services = _services()
    requested = getattr(args, "services", None) or []
    names = requested if requested else sorted(services)
    rows = []
    for name in names:
        if name not in services:
            print(f"unknown service: {name}", file=sys.stderr)
            return 2
        rows.append(_service_status(name, services[name]))
    if not requested:
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


def _compose_config_spec(spec: dict) -> dict:
    config_spec = dict(spec)
    project_dir = Path(config_spec.get("project_dir", "."))
    if not project_dir.exists():
        parts = project_dir.parts
        for idx in range(len(parts) - 1):
            if parts[idx] == "deploy" and parts[idx + 1] == "production":
                candidate = _source_dir() / Path(*parts[idx:])
                files = config_spec.get("compose_files") or []
                if candidate.exists() and all((candidate / name).exists() for name in files):
                    config_spec["project_dir"] = str(candidate)
                break
    return config_spec


def _compose_images_for_spec(spec: dict, compose_services: list[str] | None = None) -> tuple[int, list[str]]:
    config_spec = _compose_config_spec(spec)
    if compose_services:
        cmd = _compose_command(config_spec, ["config", "--format", "json"])
        proc = _run(cmd)
        if proc.returncode != 0:
            if proc.stderr.strip():
                print(proc.stderr.strip(), file=sys.stderr)
            return proc.returncode, []
        try:
            data = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            print(f"docker compose config returned invalid JSON: {exc}", file=sys.stderr)
            return 1, []
        services = data.get("services") or {}
        images: list[str] = []
        seen: set[str] = set()
        for service in compose_services:
            image = str((services.get(service) or {}).get("image") or "").strip()
            if not image or image in seen:
                continue
            seen.add(image)
            images.append(image)
        return 0, images
    cmd = _compose_command(config_spec, ["config", "--images"])
    proc = _run(cmd)
    if proc.returncode != 0:
        if proc.stderr.strip():
            print(proc.stderr.strip(), file=sys.stderr)
        return proc.returncode, []
    images: list[str] = []
    seen: set[str] = set()
    for line in proc.stdout.splitlines():
        image = line.strip()
        if not image or image in seen:
            continue
        seen.add(image)
        images.append(image)
    return 0, images


def _compose_images_for_names(names: list[str]) -> tuple[int, list[str]]:
    services = _services()
    groups: dict[tuple[str, tuple[str, ...]], tuple[dict, list[str]]] = {}
    for name in names:
        spec = services[name]
        if spec.get("kind") != "compose":
            continue
        key = (str(spec.get("project_dir", ".")), tuple(spec.get("compose_files") or []))
        if key not in groups:
            groups[key] = (spec, [])
        groups[key][1].append(str(spec.get("compose_service") or name))
    images: list[str] = []
    seen: set[str] = set()
    for spec, compose_services in groups.values():
        rc, spec_images = _compose_images_for_spec(spec, compose_services)
        if rc != 0:
            return rc, []
        for image in spec_images:
            if image in seen:
                continue
            seen.add(image)
            images.append(image)
    return 0, images


def _pull_compose_images(names: list[str], *, mirror: str | None, dry_run: bool, skip_images: set[str] | None = None) -> int:
    rc, images = _compose_images_for_names(names)
    if rc != 0:
        return rc
    skip_images = skip_images or set()
    for image in images:
        if image in skip_images:
            continue
        rc = _pull_image(image, mirror=mirror, dry_run=dry_run)
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
    backend_env = _parse_env(_secret_path("backend"))
    required = [
        "HOST_IP",
        "OPENIM_MONGO_PASSWORD",
        "OPENIM_REDIS_PASSWORD",
        "OPENIM_MINIO_ACCESS_KEY",
        "OPENIM_MINIO_SECRET_KEY",
        "OPENIM_MINIO_PORT",
        "OPENIM_SECRET",
        "OPENIM_WEBHOOK_SECRET",
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
    backend_public_url = (
        backend_env.get("BACKEND_PUBLIC_URL")
        or backend_env.get("PUBLIC_URL")
        or f"http://{env['HOST_IP']}:{backend_env.get('BACKEND_PORT') or '5566'}"
    ).rstrip("/")
    webhook_url = (
        f"{backend_public_url}/api/im/after_send_msg"
        f"?secret={env['OPENIM_WEBHOOK_SECRET']}"
    )
    replacements["webhooks.yml"] = [
        ("url: http://127.0.0.1:10006/callbackExample", f"url: {webhook_url}"),
        ("afterSendSingleMsg:\n  enable: false\n  timeout: 5", "afterSendSingleMsg:\n  enable: true\n  timeout: 10"),
    ]
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


def _remove_legacy_user_center(*, dry_run: bool) -> None:
    """user-center 已并入 config-center dashboard（/admin/dashboard 用户 Tab，功能超集）并从
    部署清单移除；存量主机上仍在跑的旧容器在部署时顺手拆掉（幂等、非阻断）。"""
    if not _docker_inspect("myapp-user-center"):
        return
    if dry_run:
        print("+ docker rm -f myapp-user-center  # legacy, merged into config-center dashboard")
        return
    if _run(["docker", "rm", "-f", "myapp-user-center"], capture=True).returncode == 0:
        print("+ removed legacy myapp-user-center (merged into config-center dashboard)")


def _prepare_deploy(names: list[str], *, dry_run: bool) -> int:
    _remove_legacy_user_center(dry_run=dry_run)
    if _pgbouncer_in_names(names):
        # bug2: compose up 前先备好 pgbouncer userlist（否则 bind mount 建成目录、池起不来）
        rc = _ensure_pgbouncer_userlist(dry_run=dry_run)
        if rc != 0:
            return rc
    if _group_in_names(names, "supabase"):
        rc = _seed_supabase_postgres_custom_config(dry_run=dry_run)
        if rc != 0:
            return rc
    if "edge-nginx" in names:
        rc = _render_edge_nginx_config(dry_run=dry_run)
        if rc != 0:
            return rc
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


def _deploy_needs_supabase_auth_migration(names: list[str]) -> bool:
    services = _services()
    return any(services.get(name, {}).get("group") == "supabase" for name in names)


def _run_supabase_auth_migrations(*, dry_run: bool) -> int:
    cmd = ["docker", "exec", "supabase-auth", "gotrue", "migrate"]
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    info = _docker_inspect("supabase-auth")
    if not info or info.get("State", {}).get("Status") != "running":
        print("supabase-auth is not running; cannot run GoTrue migrations", file=sys.stderr)
        return 1
    return _run(cmd, capture=False).returncode


def _run_platform_migrations(*, dry_run: bool) -> int:
    """部署后自动应用平台 jsonapp 库的 schema 迁移（backend/migrate.py 应用未应用的
    backend/migrations/00N_*.sql）。见 docs/planning/version-management.md §3.6 / §11.2。

    阻断策略（§11.2-#6）：区分两种"非 0"——
      · migrate.py **不在镜像内**（老镜像）或 backend 未运行 → 跳过、返回 0（不阻断部署）；
      · migrate.py 在镜像内但**执行失败** → 返回其 rc，让 deploy 中止（迁移是部署最高风险环，
        失败必须显式暴露，不能静默放行新代码跑在半迁移的库上）。
    migrate.py 对存量主机会自动打基线、对 checksum 漂移仅告警（非致命），故正常路径仍稳定。"""
    if dry_run:
        print("+ docker exec -w /app/backend myapp-backend python migrate.py")
        return 0
    info = _docker_inspect("myapp-backend")
    if not info or info.get("State", {}).get("Status") != "running":
        print("myapp-backend 未运行；跳过平台 schema 迁移", file=sys.stderr)
        return 0
    # 老镜像可能没有 migrate.py——先探测，缺失则优雅跳过（不阻断）。
    probe = _run(
        ["docker", "exec", "myapp-backend", "test", "-f", "/app/backend/migrate.py"],
        capture=True,
    )
    if probe.returncode != 0:
        print("当前 backend 镜像无 /app/backend/migrate.py（老镜像）；跳过平台 schema 迁移",
              file=sys.stderr)
        return 0
    cmd = ["docker", "exec", "-w", "/app/backend", "myapp-backend", "python", "migrate.py"]
    print("+ " + " ".join(cmd))
    rc = _run(cmd, capture=False).returncode
    if rc != 0:
        print(f"❌ 平台 schema 迁移失败（rc={rc}）；中止部署——请检查上面的 migrate 输出后重试",
              file=sys.stderr)
    return rc


_SUPABASE_INTERNAL_NET = "supabase_default"
# backend 家族（跑 backend 镜像、会做服务端 Supabase 调用的服务）：接入 supabase 网络后
# 才能用内网 SUPABASE_INTERNAL_URL=http://supabase-kong:8000 调 Supabase（admin/storage/建桶），
# 避免用公网 URL 从容器内 hairpin 回边缘 nginx 得 404（bug1）。
_SUPABASE_NET_CLIENTS = [
    "myapp-backend", "myapp-ai-worker", "myapp-faas-push-worker",
    "myapp-registry", "myapp-config-center",
]


_SUPABASE_NET_CLIENT_SERVICES = (
    "backend", "ai-worker", "faas-push-worker", "registry", "config-center",
)


def _ensure_supabase_internal_net(names: list[str], *, dry_run: bool) -> int:
    """把 backend 家族容器接入 supabase 网络，使其能用内网 kong 调 Supabase（bug1 修复）。
    幂等；容器未跑/已接入则跳过；supabase 网络不存在（未部署 supabase）则跳过。非阻断。
    门槛=任一 client 服务在本轮部署里（compose recreate 会丢 network connect，单独
    `deploy config-center` 这类部署也必须重接，不能只认 backend）。"""
    if not any(n in names for n in _SUPABASE_NET_CLIENT_SERVICES):
        return 0
    if dry_run:
        print(f"+ docker network connect {_SUPABASE_INTERNAL_NET} <backend 家族容器>")
        return 0
    if _run(["docker", "network", "inspect", _SUPABASE_INTERNAL_NET], capture=True).returncode != 0:
        print(f"网络 {_SUPABASE_INTERNAL_NET} 不存在（supabase 未部署？）；跳过内网接入", file=sys.stderr)
        return 0
    for c in _SUPABASE_NET_CLIENTS:
        info = _docker_inspect(c)
        if not info or info.get("State", {}).get("Status") != "running":
            continue
        nets = (info.get("NetworkSettings", {}) or {}).get("Networks", {}) or {}
        if _SUPABASE_INTERNAL_NET in nets:
            continue
        r = _run(["docker", "network", "connect", _SUPABASE_INTERNAL_NET, c], capture=True)
        if r.returncode == 0:
            print(f"+ docker network connect {_SUPABASE_INTERNAL_NET} {c}")
        else:
            print(f"接入 {_SUPABASE_INTERNAL_NET} 失败 {c}: {(r.stderr or '').strip()[:140]}", file=sys.stderr)
    return 0


def _pgbouncer_in_names(names: list[str]) -> bool:
    return any(n in names for n in ("pgbouncer-platform", "pgbouncer-faas"))


def _ensure_pgbouncer_userlist(*, dry_run: bool) -> int:
    """compose up 前生成 pgbouncer auth 密钥 + userlist.txt（bug2）。必须先存在，否则 docker 把
    不存在的 bind-mount 源建成目录、pgbouncer 起不来。密钥持久化在 secrets.d/pgbouncer.env（幂等复用）。
    userlist 用明文口令（pgbouncer scram-sha-256 auth_type 支持明文；见 pgbouncer-jsonapp-postgres.md）。"""
    data_root = _data_root_from_cfg()
    secrets_dir = data_root / "secrets.d"
    pw_file = secrets_dir / "pgbouncer.env"
    userlist = secrets_dir / "pgbouncer-userlist.txt"
    if dry_run:
        print(f"+ ensure {userlist} (pgbouncer_auth)")
        return 0
    secrets_dir.mkdir(parents=True, exist_ok=True)
    pw = ""
    if pw_file.exists():
        for line in pw_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("PGB_AUTH_PW="):
                pw = line.split("=", 1)[1].strip()
    if not pw:
        pw = py_secrets.token_hex(24)
        pw_file.write_text(f"PGB_AUTH_PW={pw}\n", encoding="utf-8")
        try:
            pw_file.chmod(0o600)
        except OSError:
            pass
    if not userlist.exists():
        userlist.write_text(f'"pgbouncer_auth" "{pw}"\n', encoding="utf-8")
        try:
            userlist.chmod(0o644)
        except OSError:
            pass
        print(f"+ generated {userlist}")
    return 0


def _ensure_pgbouncer_db(names: list[str], *, dry_run: bool) -> int:
    """建 pgbouncer 的 DB 侧鉴权（bug2）：pgbouncer_auth 角色（口令取 userlist）+ 每个库
    (jsonapp/userdata) 的 pgbouncer schema + user_lookup(SECURITY DEFINER 读 pg_authid) + grants，
    然后重启两个池让其重新鉴权。幂等。跑在 jsonapp-postgres healthy 之后。非阻断（失败仅告警）。
    见 docs/planning/pgbouncer-jsonapp-postgres.md。"""
    if not _pgbouncer_in_names(names):
        return 0
    if dry_run:
        print("+ setup pgbouncer_auth role + pgbouncer.user_lookup in jsonapp/userdata + restart pools")
        return 0
    userlist = _data_root_from_cfg() / "secrets.d" / "pgbouncer-userlist.txt"
    pw = ""
    if userlist.exists():
        m = re.search(r'"pgbouncer_auth"\s+"([^"]+)"', userlist.read_text(encoding="utf-8"))
        if m:
            pw = m.group(1)
    if not pw:
        print("pgbouncer userlist 缺失/无口令；跳过 DB 侧设置", file=sys.stderr)
        return 0
    pg = _docker_inspect("myapp-jsonapp-postgres")
    if not pg or pg.get("State", {}).get("Status") != "running":
        print("jsonapp-postgres 未运行；跳过 pgbouncer DB 设置", file=sys.stderr)
        return 0

    def _psql(db: str, sql: str):
        return _run(["docker", "exec", "myapp-jsonapp-postgres", "psql",
                     "-v", "ON_ERROR_STOP=1", "-U", "jsonapp", "-d", db, "-c", sql], capture=True)

    # 1) 角色（token_hex 口令仅 hex，安全内嵌；幂等：无则建、有则对齐口令）
    role_sql = (
        "DO $$ BEGIN "
        "IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pgbouncer_auth') THEN "
        f"CREATE ROLE pgbouncer_auth LOGIN PASSWORD '{pw}' "
        "NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION; "
        f"ELSE ALTER ROLE pgbouncer_auth LOGIN PASSWORD '{pw}'; END IF; END $$;"
    )
    r = _psql("jsonapp", role_sql)
    if r.returncode != 0:
        print(f"pgbouncer 角色创建失败: {(r.stderr or '').strip()[:200]}", file=sys.stderr)
        return 0
    # 2) userdata 库（FaaS 租户数据；pgbouncer-faas 的 auth_dbname）——不存在则建（CREATE DATABASE 不能在事务/DO 内）
    chk = _psql("jsonapp", "SELECT 1 FROM pg_database WHERE datname='userdata'")
    if "1" not in (chk.stdout or ""):
        cr = _psql("jsonapp", "CREATE DATABASE userdata OWNER jsonapp")
        if cr.returncode == 0:
            print("+ created database userdata")
    # 3) 每个库：schema + user_lookup 函数 + grants
    func_sql = (
        "CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION jsonapp; "
        "CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(IN i_username text, OUT uname text, OUT phash text) "
        "RETURNS record LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS "
        "$fn$ SELECT rolname::text, rolpassword::text FROM pg_catalog.pg_authid WHERE rolname=i_username; $fn$; "
        "REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM public; "
        "GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth; "
        "GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;"
    )
    for db in ("jsonapp", "userdata"):
        # 显式 GRANT CONNECT：faas_userdb 首个服务建库时会 REVOKE CONNECT ... FROM PUBLIC，
        # pgbouncer_auth 若只靠 PUBLIC 隐式权限，第一个 FaaS 服务部署后 auth_query 即断
        # （FATAL permission denied for database "userdata"）。显式授权不受该 REVOKE 影响。
        fr = _psql(db, f'GRANT CONNECT ON DATABASE "{db}" TO pgbouncer_auth; ' + func_sql)
        if fr.returncode == 0:
            print(f"+ pgbouncer.user_lookup ready in {db}")
        else:
            print(f"pgbouncer schema/func 在 {db} 失败: {(fr.stderr or '').strip()[:160]}", file=sys.stderr)
    # 4) 重启两个池（清 server_login_retry 缓存——池在角色/函数建好前起过、缓存了鉴权失败）。
    for c in ("myapp-pgbouncer-platform", "myapp-pgbouncer-faas"):
        if _docker_inspect(c):
            _run(["docker", "restart", c], capture=True)
    # 依赖 pgbouncer 的 worker：只重启「本轮部署过的」或「确实处于崩溃态的」——健康运行中的
    # 不动，避免 `deploy --group infra` 这类不含 worker 的部署绕过活跃 AI 任务守卫误杀进行中的生成。
    for svc, cont in (("faas-push-worker", "myapp-faas-push-worker"), ("ai-worker", "myapp-ai-worker")):
        info = _docker_inspect(cont)
        if not info:
            continue
        state = str((info.get("State", {}) or {}).get("Status") or "")
        if svc in names or state in {"restarting", "exited"}:
            _run(["docker", "restart", cont], capture=True)
    print("+ pgbouncer pools 已配置并重启")
    return 0


def _deploy_should_ensure_demo_assets(names: list[str]) -> bool:
    return "backend" in names


def _ensure_demo_bucket_assets(*, dry_run: bool) -> int:
    """集群初始化的一部分：部署后确保 demo 对象存储桶就绪并把 demo app.json 固定上传。

    在 myapp-backend 容器内执行 demo_replay.ensure_demo_assets()，复用其 MinIO 凭据与网络。
    免登录 demo 模式回放时直接返回该桶的固定公共 URL（不再每次临时上传）。失败不阻断部署。"""
    cmd = [
        "docker", "exec", "-w", "/app/backend", "myapp-backend",
        "python3", "-c",
        "import demo_replay; print('demo assets:', demo_replay.ensure_demo_assets())",
    ]
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    info = _docker_inspect("myapp-backend")
    if not info or info.get("State", {}).get("Status") != "running":
        print("myapp-backend 未运行；跳过 demo 桶初始化（下次部署会补）", file=sys.stderr)
        return 0  # 非阻断
    result = _run(cmd, capture=False)
    if result.returncode != 0:
        print("demo 桶初始化失败（非阻断，可稍后重新部署或手动重试）", file=sys.stderr)
    return 0  # 永不阻断部署


def _ensure_avatar_bucket(*, dry_run: bool) -> int:
    """集群初始化的一部分：部署后确保 Supabase Storage 的 `avatars` 桶就绪。

    头像上传写 `storage/v1/object/avatars/...`，但该桶此前无任何地方创建 → 首次上传报
    404「Bucket not found」。在 myapp-backend 容器内执行 auth.ensure_avatar_bucket()
    （复用其 Supabase service-key）。失败不阻断部署（上传路径也会在 404 时自愈建桶）。"""
    cmd = [
        "docker", "exec", "-w", "/app/backend", "myapp-backend",
        "python3", "-c",
        "import auth; print('avatar bucket:', auth.ensure_avatar_bucket())",
    ]
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    info = _docker_inspect("myapp-backend")
    if not info or info.get("State", {}).get("Status") != "running":
        print("myapp-backend 未运行；跳过 avatar 桶初始化（下次部署会补）", file=sys.stderr)
        return 0  # 非阻断
    result = _run(cmd, capture=False)
    if result.returncode != 0:
        print("avatar 桶初始化失败（非阻断，上传时会自愈重试）", file=sys.stderr)
    return 0  # 永不阻断部署


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


def _docker_container_names(pattern: str) -> list[str]:
    proc = _run(["docker", "ps", "-a", "--filter", f"name={pattern}", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def cmd_uninstall(args) -> int:
    if not args.yes:
        print("refusing to uninstall without --yes", file=sys.stderr)
        return 2
    services = _services()
    names = _ordered_service_names(list(services))
    dry_run = bool(args.dry_run)
    data_root = _data_root_from_cfg()

    for spec in _compose_specs_for_names(names):
        project_dir = Path(spec.get("project_dir", "."))
        compose_files = [project_dir / name for name in (spec.get("compose_files") or [])]
        if not dry_run and (not project_dir.exists() or any(not path.exists() for path in compose_files)):
            continue
        cmd = _compose_command(spec, ["down", "--remove-orphans"])
        if args.volumes:
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
    docker_names.extend(_docker_container_names("myapp-faas-"))
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

    if args.state:
        print(f"# preserve MyApp data/state under {data_root}")
    if args.logs:
        print(f"# preserve MyApp data/logs under {data_root}")
    if args.secrets:
        print("# preserve MyApp host config and secrets under /etc/myapp")
    if args.install_files:
        print("# preserve installed myapp-ctl service inventory and compose files")
    if args.remove_ctl:
        _remove_path(Path("/usr/local/bin/myapp-ctl"), dry_run=dry_run)
        _remove_path(Path("/opt/myapp/bin/myapp-ctl"), dry_run=dry_run)
    print("uninstall completed" if not dry_run else "uninstall dry-run completed")
    print(f"data root preserved: {data_root}")
    print("host config preserved: /etc/myapp")
    print("Docker images preserved.")
    print("To permanently delete local service data, run manually if needed:")
    print(f"  find {shlex.quote(str(data_root))} -mindepth 1 -maxdepth 1 -exec rm -rf -- {{}} +")
    return 0


def _pin_image_version(tag: str) -> None:
    """Pin the 4 app images to an immutable tag: write ctl.json images map +
    force-write backend/faas env image vars so docker compose uses that exact
    image. See docs/planning/version-management.md §3.9 (--image-version)."""
    cfg = _cfg()
    images = cfg.setdefault("images", {})
    backend_env: dict[str, str] = {}
    for target in ("backend", "faas-runtime", "agent-node", "agent-runtime"):
        key, _ = IMAGE_TARGETS[target]
        ref = f"dapangyu/myapp-{target}:{tag}"
        images[key] = ref
        backend_env["MYAPP_" + target.upper().replace("-", "_") + "_IMAGE"] = ref
    _save_json(CONFIG_PATH, cfg, mode=0o644)
    _merge_env_group("backend", backend_env, force=True)
    _merge_env_group("faas", {"FAAS_LOCAL_DOCKER_IMAGE": f"dapangyu/myapp-faas-runtime:{tag}"}, force=True)
    print(f"pinned app images to tag '{tag}' (ctl.json + backend/faas env)")


def cmd_deploy(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    if getattr(args, "base", False) and not (args.build or args.pull):
        print("--base requires --build or --pull", file=sys.stderr)
        return 2
    if getattr(args, "mirror", None) and not args.pull:
        print("--mirror requires --pull", file=sys.stderr)
        return 2
    image_version = (getattr(args, "image_version", None) or "").strip()
    if image_version:
        if args.build:
            print("--image-version cannot be combined with --build", file=sys.stderr)
            return 2
        if not args.dry_run:
            _pin_image_version(image_version)
        else:
            print(f"[dry-run] would pin app images to '{image_version}'")
        args.pull = True  # pull the pinned immutable tag
    try:
        names = _service_names_for_targets(args.targets, args.group)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    names = _filter_disabled_optional_services(names)
    if not names:
        print("nothing to deploy")
        return 0
    image_targets = _image_targets_for_names(names)
    if args.plan:
        services = _services()
        compose_names = [name for name in names if services[name].get("kind") == "compose"]
        docker_names = [name for name in names if services[name].get("kind") == "docker"]
        print("deploy plan:")
        if image_targets:
            print("  images: " + ", ".join(image_targets))
            if getattr(args, "base", False):
                print("  base images: " + ", ".join(_configured_base_image(target) for target in image_targets))
        if compose_names:
            print("  compose services: " + ", ".join(compose_names))
        if docker_names:
            print("  docker containers: " + ", ".join(docker_names))
        return 0
    try:
        data_root = _ensure_data_root_config(
            getattr(args, "data_root", None),
            interactive=not getattr(args, "no_setup", False),
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    try:
        _restore_data_root_config_if_needed(data_root)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"data root config restore failed: {exc}", file=sys.stderr)
        return 1
    _ensure_data_root_layout(data_root)
    rc = _ensure_human_config_for_deploy(args, names)
    if rc != 0:
        return rc
    if not args.dry_run:
        # demo 账号凭据须在 runtime secrets 同步/容器创建前就位（env 才能进 backend 容器）
        if not getattr(args, "no_demo", False) and _deploy_should_ensure_demo_assets(names):
            _ensure_demo_account_secrets()
        _sync_runtime_secrets_from_host_config(data_root)
    if args.build:
        rc = _deploy_images(image_targets, action="build", dry_run=args.dry_run, include_base=bool(getattr(args, "base", False)))
        if rc != 0:
            return rc
    elif args.pull:
        rc = _deploy_images(
            image_targets,
            action="pull",
            dry_run=args.dry_run,
            mirror=args.mirror,
            include_base=bool(getattr(args, "base", False)),
        )
        if rc != 0:
            return rc
        pulled_images = {_configured_image(target) for target in image_targets}
        rc = _pull_compose_images(names, mirror=args.mirror, dry_run=args.dry_run, skip_images=pulled_images)
        if rc != 0:
            return rc
    else:
        rc = _ensure_images(image_targets, dry_run=args.dry_run)
        if rc != 0:
            return rc
    rc = _prepare_deploy(names, dry_run=args.dry_run)
    if rc != 0:
        return rc
    rc = _guard_active_ai_runs_for_deploy(args, names)
    if rc != 0:
        return rc
    rc = _deploy_compose_services(names, dry_run=args.dry_run)
    if rc != 0:
        return rc
    # bug1: 把 backend 家族接入 supabase 内网，使服务端 Supabase 调用走内网 kong（非阻断）
    _ensure_supabase_internal_net(names, dry_run=args.dry_run)
    # bug2: 建 pgbouncer DB 侧鉴权 + 重启池（userlist 已在 _prepare_deploy 生成；非阻断）
    _ensure_pgbouncer_db(names, dry_run=args.dry_run)
    if "agent-node" in names:
        rc = _ensure_local_agent_node_registration_timer(dry_run=args.dry_run)
        if rc != 0:
            return rc
    if _deploy_needs_supabase_auth_migration(names):
        rc = _run_supabase_auth_migrations(dry_run=args.dry_run)
        if rc != 0:
            return rc
    if "backend" in names:
        rc = _run_platform_migrations(dry_run=args.dry_run)
        if rc != 0:
            return rc
    if _deploy_should_ensure_demo_assets(names):
        # 非阻断：确保 demo 对象存储桶就绪并固定上传 demo app.json（集群初始化的一部分）
        _ensure_demo_bucket_assets(dry_run=args.dry_run)
        # 非阻断：确保 Supabase Storage avatars 桶就绪（头像上传依赖，否则 404 Bucket not found）
        _ensure_avatar_bucket(dry_run=args.dry_run)
    # 非阻断：demo 全家桶（账号/registry 模板/demo FaaS 服务组）随部署自动就绪 → 开箱即用 demo
    _ensure_demo_stack(names, dry_run=args.dry_run, skip=bool(getattr(args, "no_demo", False)))
    if not args.dry_run and not args.no_test_user and _deploy_can_seed_test_user(names):
        rc = _maybe_seed_test_user(args)
        if rc != 0:
            return rc
    if not args.dry_run and not args.no_client_env and _is_full_deploy(args):
        _emit_client_env_summary(
            host=args.client_env_host or args.host,
            name=args.client_env_name,
            terminal_qr=not args.no_terminal_qr,
        )
    return 0


def _is_full_deploy(args) -> bool:
    targets = [str(target).strip() for target in (getattr(args, "targets", None) or []) if str(target).strip()]
    return not args.group and (not targets or targets == ["all"])


def cmd_update(args) -> int:
    source = Path(args.source).expanduser() if args.source else _source_dir()
    if not source.exists():
        print(_t("update_missing_source", source=str(source)), file=sys.stderr)
        return 1
    install_script = source / "deploy/production/install_ctl.sh"
    if not install_script.exists():
        print(_t("update_missing_install", path=str(install_script)), file=sys.stderr)
        return 1
    print(_t("update_running", source=str(source)))
    if not args.no_pull:
        if (source / ".git").exists():
            rc = _run(["git", "-C", str(source), "pull", "--ff-only"], capture=False).returncode
            if rc != 0:
                return rc
        else:
            print(f"source is not a git checkout; skipping git pull: {source}")
    rc = _run(["bash", str(install_script)], capture=False).returncode
    if rc != 0:
        return rc
    print(_t("update_done"))
    return 0


def cmd_restart(args) -> int:
    try:
        names = _service_names_for_targets(args.targets, args.group)
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


def _deploy_requires_ai_config(names: list[str]) -> bool:
    if any(name in {"backend", "ai-worker"} for name in names):
        return True
    if "agent-node" not in names:
        return False
    mode = (
        _parse_env(_secret_path("agent"))
        .get("AGENT_NODE_PROVIDER_MODE", "master")
        .strip()
        .lower()
        .replace("_", "-")
    )
    return mode in {"local", "node", "self", "agent-local"}


def _deploy_has_required_ai_config(names: list[str]) -> bool:
    if any(name in {"backend", "ai-worker"} for name in names):
        return _ai_providers_configured()
    if "agent-node" not in names:
        return True
    agent_env = _parse_env(_secret_path("agent"))
    mode = (
        agent_env
        .get("AGENT_NODE_PROVIDER_MODE", "master")
        .strip()
        .lower()
        .replace("_", "-")
    )
    if mode in {"local", "node", "self", "agent-local"}:
        provider_env_path = agent_env.get("AGENT_NODE_AI_PROVIDERS_ENV_FILE", "").strip()
        return bool(provider_env_path and _ai_providers_configured(Path(provider_env_path)))
    return True


def _deploy_can_seed_test_user(names: list[str]) -> bool:
    return "supabase-auth" in names


def _ensure_human_config_for_deploy(args, names: list[str]) -> int:
    if args.dry_run:
        return 0
    rc = _init_stack_secrets(host=getattr(args, "host", None), quiet=True, write_snapshot=False)
    if rc != 0:
        return rc
    if not _deploy_requires_ai_config(names) or _deploy_has_required_ai_config(names):
        return 0
    if getattr(args, "no_setup", False):
        print("AI provider config is missing; run: myapp-ctl setup", file=sys.stderr)
        return 1
    if not sys.stdin.isatty():
        print("AI provider config is missing and stdin is not interactive; run: myapp-ctl setup", file=sys.stderr)
        return 1
    print("AI provider config is missing; starting first-run setup.")
    return _run_setup_wizard(host=getattr(args, "host", None), include_ai=True, include_push=True)


def _prompt_password_twice(prompt: str, confirm_prompt: str, *, min_len: int = 6) -> str:
    while True:
        password = _prompt_secret(prompt)
        if len(password) < min_len:
            print(_t("password_too_short", min_len=min_len), file=sys.stderr)
            continue
        confirm = _prompt_secret(confirm_prompt)
        if password != confirm:
            print(_t("password_mismatch"), file=sys.stderr)
            continue
        return password


def _supabase_admin_base_url(supabase_env: dict[str, str]) -> str:
    port = supabase_env.get("KONG_HTTP_PORT") or "18000"
    return f"http://127.0.0.1:{port}".rstrip("/")


def _supabase_admin_request(
    *,
    method: str,
    base_url: str,
    service_key: str,
    path: str,
    body: dict | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict | list | None, str]:
    raw: bytes | None = None
    if body is not None:
        raw = json.dumps(body).encode("utf-8")
    req = Request(
        base_url.rstrip("/") + path,
        data=raw,
        method=method,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
        },
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(text) if text.strip() else None, text
    except HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text) if text.strip() else None
        except json.JSONDecodeError:
            parsed = None
        return exc.code, parsed, text


def _wait_supabase_auth(base_url: str, *, api_key: str = "", timeout_s: float = 90.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            headers = {"User-Agent": "myapp-ctl/1"}
            if api_key:
                headers["apikey"] = api_key
                headers["Authorization"] = f"Bearer {api_key}"
            req = Request(base_url.rstrip("/") + "/auth/v1/health", headers=headers)
            with urlopen(req, timeout=3) as resp:
                if 200 <= resp.status < 500:
                    return True
        except HTTPError as exc:
            if 400 <= exc.code < 500:
                return True
        except (URLError, OSError):
            pass
        time.sleep(2)
    return False


def _find_supabase_user_by_email(base_url: str, service_key: str, email: str) -> dict | None:
    wanted = email.strip().lower()
    page = 1
    while page <= 20:
        status, data, text = _supabase_admin_request(
            method="GET",
            base_url=base_url,
            service_key=service_key,
            path=f"/auth/v1/admin/users?page={page}&per_page=1000",
            timeout=20,
        )
        if status >= 400:
            raise RuntimeError(f"list users HTTP {status}: {text[:300]}")
        users = data.get("users", []) if isinstance(data, dict) else []
        for user in users:
            if str(user.get("email") or "").strip().lower() == wanted:
                return user
        if len(users) < 1000:
            return None
        page += 1
    return None


def _create_or_update_supabase_test_user(*, email: str, username: str, password: str, role: str | None = None) -> tuple[str, dict]:
    # role=None 保持历史行为（新建=user、已存在不动其角色）；显式传 "admin"/"user" 则强制设置。
    supabase_env = _parse_env(_secret_path("supabase"))
    service_key = supabase_env.get("SERVICE_ROLE_KEY")
    if not service_key:
        raise RuntimeError(_t("test_user_missing_supabase"))
    base_url = _supabase_admin_base_url(supabase_env)
    _wait_supabase_auth(base_url, api_key=service_key)
    existing = _find_supabase_user_by_email(base_url, service_key, email)
    if existing:
        user_metadata = dict(existing.get("user_metadata") or {})
        user_metadata["username"] = username
        app_metadata = dict(existing.get("app_metadata") or {})
        if role:
            app_metadata["role"] = role
        else:
            app_metadata.setdefault("role", "user")
        status, data, text = _supabase_admin_request(
            method="PUT",
            base_url=base_url,
            service_key=service_key,
            path=f"/auth/v1/admin/users/{existing.get('id')}",
            body={
                "password": password,
                "email_confirm": True,
                "user_metadata": user_metadata,
                "app_metadata": app_metadata,
            },
        )
        if status >= 400:
            raise RuntimeError(f"update user HTTP {status}: {text[:300]}")
        return "updated", data if isinstance(data, dict) else {}
    status, data, text = _supabase_admin_request(
        method="POST",
        base_url=base_url,
        service_key=service_key,
        path="/auth/v1/admin/users",
        body={
            "email": email,
            "password": password,
            "email_confirm": True,
            "user_metadata": {"username": username},
            "app_metadata": {"role": role or "user"},
        },
    )
    if status >= 400:
        raise RuntimeError(f"create user HTTP {status}: {text[:300]}")
    return "created", data if isinstance(data, dict) else {}


def _maybe_seed_test_user(args) -> int:
    password = ""
    password_file = getattr(args, "test_user_password_file", "") or ""
    password_env = getattr(args, "test_user_password_env", "") or ""
    if password_file:
        try:
            password = Path(password_file).expanduser().read_text(encoding="utf-8").strip()
        except OSError as exc:
            print(f"test user password file read failed: {exc}", file=sys.stderr)
            return 1
    if not password and password_env:
        password = os.environ.get(password_env, "").strip()
    if not sys.stdin.isatty() and not password:
        print(_t("test_user_skipped_noninteractive"))
        return 0
    email = getattr(args, "test_user_email", None) or "test@example.com"
    username = getattr(args, "test_user_username", None) or "test"
    if sys.stdin.isatty() and not _prompt_bool(_t("create_test_user_prompt"), default=True):
        print(_t("test_user_skipped"))
        return 0
    if not password:
        password = _prompt_password_twice(
            _t("test_user_password_prompt"),
            _t("test_user_password_confirm_prompt"),
            min_len=6,
        )
    if len(password) < 6:
        print(_t("password_too_short", min_len=6), file=sys.stderr)
        return 1
    try:
        action, _ = _create_or_update_supabase_test_user(email=email, username=username, password=password)
    except Exception as exc:
        print(f"test user setup failed: {exc}", file=sys.stderr)
        return 1
    if action == "created":
        print(_t("test_user_created", email=email))
    else:
        print(_t("test_user_updated", email=email))
    return 0


def cmd_test_user(args) -> int:
    """myapp-ctl test-user —— 全交互创建/更新测试用户：用户名 → 邮箱 → 密码（隐藏输入）→ 是否 admin。"""
    if not sys.stdin.isatty():
        print(_t("test_user_skipped_noninteractive"), file=sys.stderr)
        return 1
    username = _prompt_line(_t("test_user_username_prompt"), default="test")
    email = _prompt_line(_t("test_user_email_prompt"), default="test@example.com")
    password = _prompt_password_twice(
        _t("test_user_password_prompt"),
        _t("test_user_password_confirm_prompt"),
        min_len=6,
    )
    is_admin = _prompt_bool(_t("test_user_admin_prompt"), default=False)
    try:
        action, _ = _create_or_update_supabase_test_user(
            email=email,
            username=username,
            password=password,
            role="admin" if is_admin else "user",
        )
    except Exception as exc:
        print(f"test user setup failed: {exc}", file=sys.stderr)
        return 1
    if action == "created":
        print(_t("test_user_created", email=email))
    else:
        print(_t("test_user_updated", email=email))
    return 0


# ---------- demo 全家桶装配：账号 / registry 模板 / demo FaaS 服务组随集群初始化自动就绪 ----------
#
# 单一真相源 = 仓库 backend/demo_replays/：回放与 app.json 随 backend 镜像分发；
# 依赖的 FaaS 服务组 bundle 在 services/<service_id>/ 随源码 checkout 分发，由本装配器
# 在每次 deploy 时幂等部署（demo 账号持有 + access_policy=public + 可选 seed.json）。
# 新增 demo 只改仓库；集群侧零手工步骤。设计详见 backend/demo_replays/README.md。

_DEMO_DEFAULT_EMAIL = "demo@example.com"


def _demo_replays_dir() -> Path:
    src = str(_cfg().get("paths", {}).get("source") or "").strip() or "/opt/myapp/current"
    return Path(src) / "backend" / "demo_replays"


def _demo_backend_base() -> str:
    env = _parse_env(_secret_path("backend"))
    return f"http://127.0.0.1:{env.get('BACKEND_PORT') or '5566'}"


def _demo_registry_base() -> str:
    env = _parse_env(_secret_path("backend"))
    return f"http://127.0.0.1:{env.get('REGISTRY_PORT') or '3254'}"


def _demo_http(method: str, url: str, *, token: str = "", body=None,
               content_type: str = "application/json", timeout: float = 60.0) -> tuple[int, dict]:
    headers: dict[str, str] = {}
    if content_type:
        headers["Content-Type"] = content_type
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = body if isinstance(body, (bytes, bytearray)) else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            code = int(resp.getcode() or 0)
    except HTTPError as exc:
        raw = exc.read()
        code = int(exc.code)
    except (URLError, OSError, TimeoutError) as exc:
        return 0, {"error": str(exc)}
    try:
        parsed = json.loads(raw.decode("utf-8", errors="replace") or "{}")
        if not isinstance(parsed, dict):
            parsed = {"data": parsed}
    except ValueError:
        parsed = {"raw": raw[:200].decode("utf-8", errors="replace")}
    return code, parsed


def _ensure_demo_account_secrets(*, dry_run: bool = False) -> tuple[str, str]:
    """确保 backend.env 有 DEMO_ACCOUNT_EMAIL/PASSWORD（缺失则生成随机口令并持久化）。
    必须在 runtime secrets 同步/backend 容器创建之前调用，env 才能进容器。"""
    path = _secret_path("backend")
    data = _parse_env(path)
    email = (data.get("DEMO_ACCOUNT_EMAIL") or "").strip()
    password = (data.get("DEMO_ACCOUNT_PASSWORD") or "").strip()
    changed = False
    if not email:
        email = _DEMO_DEFAULT_EMAIL
        data["DEMO_ACCOUNT_EMAIL"] = email
        changed = True
    if not password:
        password = py_secrets.token_urlsafe(18)
        data["DEMO_ACCOUNT_PASSWORD"] = password
        changed = True
    if changed and not dry_run:
        _write_env(path, data)
        print("+ demo account credentials ensured in backend.env")
    return email, password


def _ensure_demo_account(email: str, password: str) -> str:
    """确保 demo Supabase 账号存在且口令与 secrets 一致（幂等重置，防手工漂移）。返回 uid（失败空串）。"""
    supabase_env = _parse_env(_secret_path("supabase"))
    service_key = supabase_env.get("SERVICE_ROLE_KEY") or ""
    if not service_key:
        print("demo 装配：缺 SERVICE_ROLE_KEY，跳过账号创建", file=sys.stderr)
        return ""
    base_url = _supabase_admin_base_url(supabase_env)
    if not _wait_supabase_auth(base_url, api_key=service_key):
        print("demo 装配：supabase auth 未就绪，跳过账号创建", file=sys.stderr)
        return ""
    existing = _find_supabase_user_by_email(base_url, service_key, email)
    if existing:
        status, _data, text = _supabase_admin_request(
            method="PUT", base_url=base_url, service_key=service_key,
            path=f"/auth/v1/admin/users/{existing.get('id')}",
            body={"password": password, "email_confirm": True},
        )
        if status >= 400:
            print(f"demo 账号口令同步失败 HTTP {status}: {text[:160]}", file=sys.stderr)
        return str(existing.get("id") or "")
    status, data, text = _supabase_admin_request(
        method="POST", base_url=base_url, service_key=service_key,
        path="/auth/v1/admin/users",
        body={"email": email, "password": password, "email_confirm": True,
              "user_metadata": {"username": "demo"}, "app_metadata": {"role": "user"}},
    )
    if status >= 400:
        print(f"demo 账号创建失败 HTTP {status}: {text[:160]}", file=sys.stderr)
        return ""
    print(f"+ demo account created: {email}")
    return str((data or {}).get("id") or "")


def _demo_jwt(email: str, password: str) -> str:
    supabase_env = _parse_env(_secret_path("supabase"))
    anon = supabase_env.get("ANON_KEY") or ""
    base_url = _supabase_admin_base_url(supabase_env)
    req = Request(
        f"{base_url}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": password}).encode("utf-8"),
        headers={"Content-Type": "application/json", "apikey": anon},
        method="POST",
    )
    try:
        with urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return str(data.get("access_token") or "")
    except (HTTPError, URLError, OSError, ValueError) as exc:
        print(f"demo 账号登录失败: {exc}", file=sys.stderr)
        return ""


def _ensure_demo_templates() -> None:
    """把仓库 templates/*.json 幂等发布进本机 registry（demo 依赖 common-ui 等库包；市场非空）。"""
    src = Path(str(_cfg().get("paths", {}).get("source") or "")) / "templates"
    token = _parse_env(_secret_path("backend")).get("REGISTRY_ADMIN_TOKEN") or ""
    if not src.is_dir() or not token:
        print("demo 装配：templates 目录或 REGISTRY_ADMIN_TOKEN 缺失，跳过模板种子", file=sys.stderr)
        return
    base = _demo_registry_base()
    deadline = time.time() + 60
    while time.time() < deadline:
        code, _ = _demo_http("GET", f"{base}/health", content_type="")
        if code == 200:
            break
        time.sleep(2)
    else:
        print("demo 装配：registry 未就绪，跳过模板种子", file=sys.stderr)
        return
    published = existed = skipped = 0
    for f in sorted(src.glob("*.json")):
        try:
            content = json.loads(f.read_text(encoding="utf-8"))
        except ValueError:
            skipped += 1
            continue
        if not isinstance(content, dict) or not (content.get("meta") or {}).get("name"):
            skipped += 1
            continue
        code, _resp = _demo_http("POST", f"{base}/publish", token=token, body={"json_content": content})
        if code == 200:
            published += 1
        elif code == 409:
            existed += 1
        else:
            skipped += 1
    print(f"+ registry templates: {published} published, {existed} existing, {skipped} skipped")


def _demo_bundle_fingerprint(bundle_dir: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in bundle_dir.iterdir() if p.is_file() and p.name != "seed.json"):
        h.update(f.name.encode("utf-8"))
        h.update(b"\0")
        h.update(f.read_bytes())
    return h.hexdigest()


def _demo_zip_bundle(bundle_dir: Path) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(p for p in bundle_dir.iterdir() if p.is_file() and p.name != "seed.json"):
            zf.writestr(f.name, f.read_bytes())
    return buf.getvalue()


def _demo_subst_prev(obj, prev: dict):
    if isinstance(obj, dict):
        return {k: _demo_subst_prev(v, prev) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_demo_subst_prev(v, prev) for v in obj]
    if isinstance(obj, str) and obj.startswith("$prev."):
        cur = prev
        for part in obj[len("$prev."):].split("."):
            cur = cur.get(part) if isinstance(cur, dict) else None
        return cur
    return obj


def _run_demo_seed(base: str, jwt: str, service_id: str, seed_file: Path) -> bool:
    try:
        steps = json.loads(seed_file.read_text(encoding="utf-8"))
    except ValueError as exc:
        print(f"demo service {service_id}: seed.json 解析失败: {exc}", file=sys.stderr)
        return False
    prev: dict = {}
    for step in steps:
        route = str(step.get("route") or "")
        method = str(step.get("method") or "POST").upper()
        body = _demo_subst_prev(step.get("body") or {}, prev)
        code, resp = _demo_http(method, f"{base}/api/faas/invoke/{quote(service_id)}{route}", token=jwt, body=body)
        if code != 200:
            print(f"demo service {service_id}: seed {method} {route} → HTTP {code} {str(resp)[:120]}", file=sys.stderr)
            return False
        prev = resp
    print(f"+ demo service {service_id}: seeded ({len(steps)} steps)")
    return True


def _ensure_demo_services(jwt: str, *, dry_run: bool = False) -> None:
    sdir = _demo_replays_dir() / "services"
    if not sdir.is_dir():
        return
    checker = _demo_replays_dir() / "check_demo_services.py"
    if checker.is_file():
        r = _run([sys.executable, str(checker)], capture=True)
        if r.returncode != 0:
            print(f"demo 装配：一致性自检失败，跳过服务组部署\n{(r.stderr or r.stdout or '').strip()[:400]}", file=sys.stderr)
            return
    state_path = Path(str(_cfg().get("paths", {}).get("state") or "/mnt/myapp/state")) / "demo-services.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
    except ValueError:
        state = {}
    base = _demo_backend_base()
    for bundle_dir in sorted(p for p in sdir.iterdir() if p.is_dir()):
        sid = bundle_dir.name
        if not (bundle_dir / "service.json").is_file():
            continue
        fp = _demo_bundle_fingerprint(bundle_dir)
        code, info = _demo_http("GET", f"{base}/api/faas/apps/{quote(sid)}", token=jwt, content_type="")
        mine = code == 200
        previously_managed = sid in state  # 有 state 记录 = 本装配器管理，内容仅来自 seed → 重试安全
        entry = dict(state.get(sid) or {})
        created = False
        if mine and entry.get("fingerprint") == fp:
            print(f"+ demo service {sid}: up-to-date")
        else:
            if dry_run:
                print(f"+ demo service {sid}: would deploy")
                continue
            code, resp = _demo_http("POST", f"{base}/api/faas/services", token=jwt,
                                    body=_demo_zip_bundle(bundle_dir), content_type="application/zip", timeout=300)
            if code != 200 or not resp.get("ok"):
                hint = "" if mine else "（若该 service_id 已被其他用户占用则不会覆盖）"
                print(f"demo service {sid} 部署失败 HTTP {code}: {str(resp)[:200]} {hint}", file=sys.stderr)
                continue
            _demo_http("POST", f"{base}/api/faas/apps/{quote(sid)}/policy", token=jwt, body={"access_policy": "public"})
            entry["fingerprint"] = fp
            created = not mine
            status = str((resp.get("service") or {}).get("status") or "?")
            print(f"+ demo service {sid}: deployed (status={status}, policy=public)")
        seed_file = bundle_dir / "seed.json"
        # 灌种子：仅「本次新建」或「装配器管理且尚未成功 seed」（避免给收编的存量服务造重复内容；失败可重试）
        if seed_file.is_file() and not entry.get("seeded") and not dry_run and (created or previously_managed):
            entry["seeded"] = _run_demo_seed(base, jwt, sid, seed_file)
        state[sid] = entry
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(state, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"demo 装配：状态文件写入失败: {exc}", file=sys.stderr)


def _check_demo_image_consistency() -> None:
    """护栏：checkout 里的 demo 若不在 pin 的 backend 镜像里，回放/列表不会出现——当场告警。"""
    checkout = {p.name for p in _demo_replays_dir().glob("*.app.json")}
    if not checkout:
        return
    r = _run(["docker", "exec", "myapp-backend", "sh", "-c",
              "ls /app/backend/demo_replays/*.app.json 2>/dev/null"], capture=True)
    if r.returncode != 0:
        return
    image = {line.rsplit("/", 1)[-1] for line in (r.stdout or "").split() if line.strip()}
    missing = sorted(checkout - image)
    if missing:
        print(
            f"⚠️ demo 镜像滞后：{len(missing)} 个 demo 在源码里但不在 pin 的 backend 镜像里"
            f"（{', '.join(missing[:5])}{'…' if len(missing) > 5 else ''}）→ 请发新版镜像并升级 --image-version",
            file=sys.stderr,
        )


def _ensure_demo_stack(names: list[str], *, dry_run: bool = False, skip: bool = False) -> int:
    """非阻断：demo 账号 + registry 模板 + demo FaaS 服务组随部署自动就绪（开箱即用 demo）。"""
    if skip:
        print("+ demo 装配已跳过（--no-demo）")
        return 0
    if not _deploy_should_ensure_demo_assets(names):
        return 0
    if not _demo_replays_dir().is_dir():
        return 0
    try:
        email, password = _ensure_demo_account_secrets(dry_run=dry_run)
        if dry_run:
            print("+ demo stack: would ensure account / registry templates / FaaS service groups")
            return 0
        uid = _ensure_demo_account(email, password)
        _ensure_demo_templates()
        if uid:
            jwt = _demo_jwt(email, password)
            if jwt:
                _ensure_demo_services(jwt)
            else:
                print("demo 装配：拿不到 demo JWT，跳过服务组部署", file=sys.stderr)
        _check_demo_image_consistency()
    except Exception as exc:  # 非阻断：demo 装配失败不拖垮部署
        print(f"demo 装配失败（非阻断，可用 myapp-ctl demo provision 重试）: {exc}", file=sys.stderr)
    return 0


def cmd_demo(args) -> int:
    """myapp-ctl demo provision|status —— 手动装配 / 检查开箱即用 demo 全家桶。"""
    action = getattr(args, "demo_cmd", None) or "status"
    if action == "provision":
        email, password = _ensure_demo_account_secrets(dry_run=False)
        uid = _ensure_demo_account(email, password)
        _ensure_demo_templates()
        if uid:
            jwt = _demo_jwt(email, password)
            if jwt:
                _ensure_demo_services(jwt)
            else:
                print("demo provision：拿不到 demo JWT，服务组未处理", file=sys.stderr)
                return 1
        else:
            return 1
        _check_demo_image_consistency()
        r = _run(["docker", "exec", "myapp-backend", "sh", "-c", "env | grep -c ^DEMO_ACCOUNT_EMAIL="], capture=True)
        if (r.stdout or "").strip() == "0":
            print("⚠️ 运行中的 backend 容器缺 DEMO_ACCOUNT_* env（demo 登录端点需要）→ 跑一次 `myapp-ctl deploy backend` 重建容器", file=sys.stderr)
        return 0
    # status
    backend_env = _parse_env(_secret_path("backend"))
    email = backend_env.get("DEMO_ACCOUNT_EMAIL") or ""
    password = backend_env.get("DEMO_ACCOUNT_PASSWORD") or ""
    print(f"secrets:  {'✓' if email and password else '✗'} DEMO_ACCOUNT_EMAIL/PASSWORD in backend.env")
    r = _run(["docker", "exec", "myapp-backend", "sh", "-c", "env | grep -c ^DEMO_ACCOUNT_EMAIL="], capture=True)
    print(f"backend:  {'✓' if (r.stdout or '').strip() not in ('', '0') else '✗'} container has DEMO_ACCOUNT_* env")
    uid = ""
    if email:
        supabase_env = _parse_env(_secret_path("supabase"))
        service_key = supabase_env.get("SERVICE_ROLE_KEY") or ""
        if service_key:
            user = _find_supabase_user_by_email(_supabase_admin_base_url(supabase_env), service_key, email)
            uid = str((user or {}).get("id") or "")
    print(f"account:  {'✓ ' + uid if uid else '✗ ' + (email or '(no email)')}")
    code, _ = _demo_http("GET", f"{_demo_registry_base()}/resolve?name=calculator", content_type="")
    print(f"registry: {'✓' if code == 200 else '✗'} resolve calculator → HTTP {code}")
    sdir = _demo_replays_dir() / "services"
    jwt = _demo_jwt(email, password) if email and password else ""
    if sdir.is_dir():
        for bundle_dir in sorted(p for p in sdir.iterdir() if p.is_dir()):
            sid = bundle_dir.name
            if not jwt:
                print(f"service:  ? {sid} (no demo JWT)")
                continue
            code, info = _demo_http("GET", f"{_demo_backend_base()}/api/faas/apps/{quote(sid)}", token=jwt, content_type="")
            if code == 200:
                app_info = info.get("application") or info
                policy = str(app_info.get("access_policy") or "?")
                print(f"service:  ✓ {sid} (policy={policy})")
            else:
                print(f"service:  ✗ {sid} → HTTP {code}")
    return 0


def _restore_data_root_config_if_needed(data_root: Path, *, force: bool = False) -> bool:
    bundle_path = data_root / "myapp-config.json"
    if not bundle_path.exists():
        return False
    if not force and CONFIG_PATH.exists() and any(_secret_dir().glob("*.env")):
        return False
    bundle = _load_config_bundle(bundle_path)
    _import_config_bundle_data(bundle)
    cfg = _cfg()
    _apply_data_root_to_cfg(cfg, data_root)
    _save_json(CONFIG_PATH, cfg, mode=0o644)
    _ensure_data_root_layout(data_root)
    print(_t("config_imported", path=str(bundle_path)))
    return True


def _emit_client_env_summary(*, host: str | None = None, name: str | None = None, terminal_qr: bool = True) -> None:
    payload = _client_env_payload(host=host, name=name)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    out_path = _default_client_env_path()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(body + "\n", encoding="utf-8")
    os.chmod(out_path, 0o644)

    print("")
    print("== " + _t("client_env_summary") + " ==")
    print(_t("client_env_json", path=str(out_path)))
    qr_path = out_path.with_suffix(".png")
    ok, detail = _write_qr_png(body, qr_path)
    if ok:
        print(_t("client_env_qr", path=detail))
    else:
        print(f"warning: QR PNG not generated: {detail}", file=sys.stderr)
    print(_t("copy_json"))
    print(body)
    if terminal_qr and sys.stdout.isatty():
        _print_terminal_qr(body)


def _local_agent_node_register_command() -> list[str]:
    cfg = _cfg()
    agent_env = _parse_env(_secret_path("agent"))
    backend_env = _parse_env(_secret_path("backend"))
    backend_port = backend_env.get("BACKEND_PORT") or "5566"
    backend_url = (agent_env.get("AGENT_NODE_BACKEND_URL") or f"http://127.0.0.1:{backend_port}").rstrip("/")
    node_id = (
        agent_env.get("AGENT_NODE_ID")
        or cfg.get("node", {}).get("id")
        or os.uname().nodename
    )
    node_name = (agent_env.get("AGENT_NODE_NAME") or node_id).strip()[:128] or node_id
    pull_enabled = str(agent_env.get("AGENT_NODE_PULL_ENABLED", "1")).strip().lower() in {"1", "true", "yes", "on"}
    default_node_url = (
        f"pull://{node_id}"
        if pull_enabled
        else (cfg.get("domains", {}).get("agent_node") or "http://agent-node:5590")
    )
    node_url = (agent_env.get("AGENT_NODE_SELF_REGISTER_URL") or default_node_url).rstrip("/")
    public_host = _public_host()
    provider_mode = (
        agent_env.get("AGENT_NODE_PROVIDER_MODE", "master")
        .strip()
        .lower()
        .replace("_", "-")
        or "master"
    )
    capacity = agent_env.get("AGENT_NODE_CAPACITY") or "10"
    queue_max = agent_env.get("AGENT_NODE_QUEUE_MAX") or "100"
    ttl = agent_env.get("AGENT_NODE_REGISTRATION_TTL_SECONDS") or "180"
    return [
        "/usr/local/bin/myapp-ctl",
        "agent-node",
        "register",
        "--backend",
        backend_url,
        "--url",
        node_url,
        "--node-id",
        node_id,
        "--name",
        node_name,
        "--capacity",
        str(capacity),
        "--queue-max",
        str(queue_max),
        "--ttl",
        str(ttl),
        "--label",
        f"host={public_host}",
        "--label",
        f"provider_mode={provider_mode}",
        "--label",
        "role=all-in-one",
    ]


def _ensure_local_agent_node_registration_timer(*, dry_run: bool) -> int:
    agent_env = _parse_env(_secret_path("agent"))
    pull_enabled = str(agent_env.get("AGENT_NODE_PULL_ENABLED", "1")).strip().lower() in {"1", "true", "yes", "on"}
    cmd = _local_agent_node_register_command()
    script_path = Path("/etc/myapp/agent-node-register.sh")
    service_path = Path("/etc/systemd/system/myapp-agent-register.service")
    timer_path = Path("/etc/systemd/system/myapp-agent-register.timer")
    if pull_enabled:
        print("+ pull-mode agent-node registers itself through backend acquire; disable host register timer")
        if dry_run:
            return 0
        _remove_agent_register_timer()
        return 0
    script = "#!/usr/bin/env bash\nset -euo pipefail\n" + " ".join(shlex.quote(part) for part in cmd) + "\n"
    service = """[Unit]
Description=Register local MyApp agent node

[Service]
Type=oneshot
ExecStart=/bin/bash /etc/myapp/agent-node-register.sh
"""
    timer = """[Unit]
Description=Register local MyApp agent node periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=myapp-agent-register.service

[Install]
WantedBy=timers.target
"""
    print("+ install local agent-node registration timer")
    if dry_run:
        print(script.rstrip())
        return 0
    script_path.parent.mkdir(parents=True, exist_ok=True)
    script_path.write_text(script, encoding="utf-8")
    os.chmod(script_path, 0o755)
    service_path.write_text(service, encoding="utf-8")
    timer_path.write_text(timer, encoding="utf-8")
    rc = _run(["systemctl", "daemon-reload"], capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["systemctl", "enable", "--now", "myapp-agent-register.timer"], capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["systemctl", "start", "myapp-agent-register.service"], capture=False).returncode
    if rc != 0:
        print("warning: local agent-node immediate registration failed; systemd timer will retry", file=sys.stderr)
    return 0


def _redis_cli(args: list[str]) -> subprocess.CompletedProcess:
    redis_cmd = ["redis-cli", "--no-auth-warning", "--raw", *args]
    password = _parse_env(_secret_path("backend")).get("BACKEND_REDIS_PASSWORD", "")
    if password:
        return _run(["docker", "exec", "-e", f"REDISCLI_AUTH={password}", "myapp-ai-session-redis", *redis_cmd])
    return _run(["docker", "exec", "myapp-ai-session-redis", *redis_cmd])


def _redis_int(args: list[str]) -> int:
    proc = _redis_cli(args)
    if proc.returncode != 0:
        return 0
    try:
        return int((proc.stdout or "0").strip() or "0")
    except ValueError:
        return 0


def _redis_lines(args: list[str]) -> list[str]:
    proc = _redis_cli(args)
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _active_ai_run_summary() -> dict:
    now_ms = str(int(time.time() * 1000))
    worker_leases = _redis_int(["ZCOUNT", "ai:queue:running:leases", now_ms, "+inf"])
    pull_pending = _redis_int(["LLEN", "ai:agent_pull:pending"])
    pull_running = 0
    for key in _redis_lines(["KEYS", "ai:agent_pull:node_running:*"]):
        pull_running += _redis_int(["SCARD", key])
    local_agent_containers = len(_active_local_agent_container_names())
    active_total = max(worker_leases, pull_running, local_agent_containers)
    return {
        "active_total": active_total,
        "worker_leases": worker_leases,
        "pull_running": pull_running,
        "pull_pending": pull_pending,
        "local_agent_containers": local_agent_containers,
    }


def _deploy_may_interrupt_ai_runs(names: list[str]) -> bool:
    return any(name in {"ai-worker", "agent-node"} for name in names)


def _guard_active_ai_runs_for_deploy(args, names: list[str]) -> int:
    if getattr(args, "dry_run", False) or getattr(args, "force", False):
        return 0
    if not _deploy_may_interrupt_ai_runs(names):
        return 0
    summary = _active_ai_run_summary()
    if int(summary.get("active_total") or 0) <= 0:
        return 0
    print(
        "refusing to deploy services that can interrupt active AI generation; "
        "wait for runs to finish or pass --force",
        file=sys.stderr,
    )
    print(
        "active summary: "
        f"worker_leases={summary['worker_leases']} "
        f"pull_running={summary['pull_running']} "
        f"local_agent_containers={summary['local_agent_containers']} "
        f"pull_pending={summary['pull_pending']}",
        file=sys.stderr,
    )
    return 1


def _active_local_agent_container_names() -> list[str]:
    proc = _run(["docker", "ps", "--filter", "name=myapp-agent-", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        return []
    return [
        line.strip()
        for line in proc.stdout.splitlines()
        if line.strip() and not line.strip().startswith("myapp-agent-node")
    ]


__all__ = [
    '_seed_supabase_postgres_custom_config',
    '_services',
    '_docker_ps_all',
    '_health',
    '_image_targets_for_names',
    '_ordered_service_names',
    '_service_names_for_target',
    '_service_names_for_targets',
    '_is_edge_ingress_disabled',
    '_filter_disabled_optional_services',
    '_compose_command',
    '_compose_env_files',
    '_process_status',
    '_service_status',
    'cmd_status',
    '_compose_cmd',
    '_compose_config_spec',
    '_compose_images_for_spec',
    '_compose_images_for_names',
    '_pull_compose_images',
    '_group_in_names',
    '_prepare_openim_config',
    '_prepare_deploy',
    '_ensure_images',
    '_deploy_compose_services',
    '_deploy_needs_supabase_auth_migration',
    '_run_supabase_auth_migrations',
    '_deploy_should_ensure_demo_assets',
    '_ensure_demo_bucket_assets',
    '_ensure_avatar_bucket',
    '_compose_specs_for_names',
    '_docker_container_names',
    'cmd_uninstall',
    'cmd_deploy',
    '_is_full_deploy',
    'cmd_update',
    'cmd_restart',
    'cmd_log',
    '_deploy_requires_ai_config',
    '_deploy_has_required_ai_config',
    '_deploy_can_seed_test_user',
    '_ensure_human_config_for_deploy',
    '_prompt_password_twice',
    '_supabase_admin_base_url',
    '_supabase_admin_request',
    '_wait_supabase_auth',
    '_find_supabase_user_by_email',
    '_create_or_update_supabase_test_user',
    '_maybe_seed_test_user',
    'cmd_test_user',
    '_ensure_demo_stack',
    '_ensure_demo_account_secrets',
    'cmd_demo',
    '_restore_data_root_config_if_needed',
    '_emit_client_env_summary',
    '_local_agent_node_register_command',
    '_ensure_local_agent_node_registration_timer',
    '_redis_cli',
    '_redis_int',
    '_redis_lines',
    '_active_ai_run_summary',
    '_deploy_may_interrupt_ai_runs',
    '_guard_active_ai_runs_for_deploy',
    '_active_local_agent_container_names',
]
