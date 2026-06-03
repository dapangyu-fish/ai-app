#!/usr/bin/env python3
"""Control CLI for MyApp backend hosts.

The CLI is intentionally small and dependency-free: service inventory is data
in /etc/myapp/*.json, secrets are host-local files, and Docker/Compose do the
actual process management.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


CONFIG_PATH = Path(os.environ.get("MYAPP_CTL_CONFIG", "/etc/myapp/ctl.json"))
SERVICES_PATH = Path(os.environ.get("MYAPP_CTL_SERVICES", "/etc/myapp/services.json"))


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


def _image_exists(image: str) -> bool:
    return _run(["docker", "image", "inspect", image]).returncode == 0


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
    cmd = ["docker", "compose"]
    for name in files:
        cmd.extend(["-f", str(project_dir / name)])
    if action == "deploy":
        cmd.extend(["up", "-d", spec.get("compose_service", "")])
    else:
        cmd.extend(["restart", spec.get("compose_service", "")])
    return _run([part for part in cmd if part], capture=False).returncode


def cmd_deploy(args) -> int:
    spec = _services().get(args.service)
    if not spec:
        print(f"unknown service: {args.service}", file=sys.stderr)
        return 2
    kind = spec.get("kind", "docker")
    if kind == "compose":
        return _compose_cmd(spec, "deploy")
    if kind == "image":
        image = spec.get("image", "")
        if "/" in image:
            return _run(["docker", "pull", image], capture=False).returncode
        print(f"image present locally: {image}" if _image_exists(image) else f"local image missing: {image}")
        return 0 if _image_exists(image) else 1
    if kind == "process":
        print(f"{args.service} is a process service; using restart")
        return cmd_restart(args)
    print(f"{args.service} has no deploy plan yet; add compose/image metadata first", file=sys.stderr)
    return 1


def cmd_restart(args) -> int:
    spec = _services().get(args.service)
    if not spec:
        print(f"unknown service: {args.service}", file=sys.stderr)
        return 2
    kind = spec.get("kind", "docker")
    if kind == "compose":
        return _compose_cmd(spec, "restart")
    if kind == "process":
        status = _process_status(spec)
        if status.get("pid") and status.get("state") == "running":
            os.kill(int(status["pid"]), signal.SIGTERM)
            time.sleep(1)
        command = spec.get("command")
        if not command:
            print(f"{args.service} has no command", file=sys.stderr)
            return 1
        log_file = spec.get("log_file") or f"/var/log/myapp/{args.service}.log"
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        with open(log_file, "ab") as out:
            subprocess.Popen(command, stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True)
        print(f"restarted process {args.service}")
        return 0
    return _run(["docker", "restart", spec.get("container") or args.service], capture=False).returncode


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


def _redact(value: str) -> str:
    digest = hashlib.sha256(value.encode()).hexdigest()[:8]
    return f"***{value[-4:] if len(value) >= 4 else ''} sha256:{digest}"


def cmd_secret(args) -> int:
    _secret_dir().mkdir(parents=True, exist_ok=True)
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


def _run_log_summary(path: Path) -> dict:
    row = {"run_id": path.stem, "status": "unknown", "returncode": "-", "duration": "-", "lines": 0}
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
            row["status"] = "started"
        elif event.get("type") == "stop":
            stopped = event.get("ts")
            row["status"] = event.get("status") or "stopped"
            row["returncode"] = event.get("returncode", "-")
    if started and stopped:
        row["duration"] = f"{max(0, int((stopped - started) / 1000))}s"
    return row


def cmd_agent(args) -> int:
    if args.agent_cmd == "register":
        print("agent register: not wired to backend control plane yet")
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
    deploy = sub.add_parser("deploy")
    deploy.add_argument("service")
    deploy.set_defaults(func=cmd_deploy)
    restart = sub.add_parser("restart")
    restart.add_argument("service")
    restart.set_defaults(func=cmd_restart)
    secret = sub.add_parser("secret")
    secret_sub = secret.add_subparsers(dest="secret_cmd", required=True)
    secret_sub.add_parser("ls").set_defaults(func=cmd_secret)
    secret_set = secret_sub.add_parser("set")
    secret_set.add_argument("group")
    secret_set.add_argument("items", nargs="+")
    secret_set.set_defaults(func=cmd_secret)
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
    agent_sub.add_parser("ls").set_defaults(func=cmd_agent)
    agent_sub.add_parser("register").set_defaults(func=cmd_agent)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
