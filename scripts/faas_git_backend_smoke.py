#!/usr/bin/env python3
"""Temporarily verify backend-owned FaaS Git commit/push through HTTP API."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any

import requests

from faas_openfaas_backend_smoke import (
    _deploy_faas_group,
    _env_value,
    _faas_env_path,
    _must_run,
    _read_file,
    _wait_faas_health,
    _write_file,
)


def _run(cmd: list[str], *, cwd: Path | None = None, timeout: int = 60) -> str:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout[-1000:]}\n"
            f"stderr:\n{proc.stderr[-1000:]}"
        )
    return proc.stdout.strip()


def _bundle(service_id: str, *, version: int) -> dict[str, Any]:
    app_py = f"""from flask import Flask, jsonify

app = Flask(__name__)
VERSION = {version}

@app.get("/version")
def version():
    return jsonify({{"ok": True, "version": VERSION}})
"""
    return {
        "user_id": "",
        "service": {
            "service_id": service_id,
            "slug": "git-backend-smoke",
            "routes": [
                {"path": "/version", "methods": ["GET"], "description": "Git smoke version endpoint"},
            ],
        },
        "files": {
            "app.py": app_py,
            "requirements.txt": "flask==3.0.3\n",
            "README.md": "# git-backend-smoke\n",
        },
    }


def _request_json(method: str, url: str, *, timeout: int = 60, **kwargs: Any) -> dict[str, Any]:
    resp = requests.request(method, url, timeout=timeout, **kwargs)
    if resp.status_code >= 400:
        raise RuntimeError(f"{method} {url} failed {resp.status_code}: {resp.text[:1000]}")
    try:
        data = resp.json()
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{method} {url} returned invalid JSON: {resp.text[:500]}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"{method} {url} returned non-object JSON: {data!r}")
    return data


def _deploy_service(base_url: str, *, user_id: str, service_id: str, version: int) -> dict[str, Any]:
    payload = _bundle(service_id, version=version)
    payload["user_id"] = user_id
    data = _request_json("POST", f"{base_url.rstrip('/')}/api/faas/services", json=payload)
    if not data.get("ok"):
        raise RuntimeError(f"deploy failed: {data}")
    service = data.get("service")
    if not isinstance(service, dict) or service.get("service_id") != service_id:
        raise RuntimeError(f"unexpected deploy service payload: {data}")
    return service


def _delete_service(base_url: str, *, user_id: str, service_id: str) -> None:
    try:
        _request_json(
            "DELETE",
            f"{base_url.rstrip('/')}/api/faas/services/{service_id}",
            params={"user_id": user_id},
            timeout=30,
        )
    except Exception:
        pass


def _git_remote_head(remote: Path, branch: str) -> str:
    return _run(["git", "--git-dir", str(remote), "rev-parse", f"refs/heads/{branch}"])


def _git_tree(remote: Path, branch: str) -> list[str]:
    out = _run(["git", "--git-dir", str(remote), "ls-tree", "-r", "--name-only", branch])
    return [line.strip() for line in out.splitlines() if line.strip()]


def _git_commit_count(remote: Path, branch: str) -> int:
    out = _run(["git", "--git-dir", str(remote), "rev-list", "--count", branch])
    return int(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run backend FaaS Git push smoke with a local bare remote.")
    parser.add_argument("--yes", action="store_true", help="confirm temporary FaaS config switch and backend restart")
    parser.add_argument("--base-url", default="http://127.0.0.1:5566", help="backend base URL")
    parser.add_argument("--work-root", default="/mnt/myapp/faas/tmp", help="host/container shared temp root")
    parser.add_argument("--branch", default="main", help="temporary bare remote branch")
    parser.add_argument("--user-id", default="git-backend-smoke-user", help="test owner user id")
    parser.add_argument("--service-id", default=f"git-backend-smoke-{int(time.time())}", help="test service id")
    parser.add_argument("--pull-stack", action="store_true", help="pull backend/FaaS stack images while redeploying")
    parser.add_argument("--keep", action="store_true", help="keep temporary Git remote and generated service")
    args = parser.parse_args()

    if not args.yes:
        raise RuntimeError("refusing to switch backend FaaS Git config without --yes")
    if not shutil.which("myapp-ctl"):
        raise RuntimeError("myapp-ctl is required on PATH")
    if not shutil.which("git"):
        raise RuntimeError("git is required on PATH")

    faas_env = _faas_env_path()
    original = _read_file(faas_env)
    original_mode = _env_value(original, "FAAS_DEPLOY_MODE") or ""
    backup = faas_env.with_suffix(f".env.bak-git-smoke-{int(time.time())}")
    if original:
        _write_file(backup, original)

    work_root = Path(args.work_root).expanduser()
    run_root = work_root / f"git-backend-smoke-{int(time.time())}-{os.getpid()}"
    remote = run_root / "remote.git"
    run_root.mkdir(parents=True, exist_ok=True)
    _run(["git", "init", "--bare", str(remote)], timeout=60)
    restored = False

    try:
        _must_run(
            [
                "myapp-ctl",
                "faas",
                "mode",
                "metadata",
                "--public-base-url",
                args.base_url.rstrip("/"),
            ],
            timeout=120,
        )
        _must_run(
            [
                "myapp-ctl",
                "faas",
                "git",
                "--enable",
                "--push",
                "--remote",
                str(remote),
                "--branch",
                args.branch,
                "--author-name",
                "myapp-faas-smoke",
                "--author-email",
                "myapp-faas-smoke@localhost",
            ],
            timeout=120,
        )
        _deploy_faas_group(pull=args.pull_stack)
        _wait_faas_health(args.base_url, expected_mode="metadata")

        first = _deploy_service(args.base_url, user_id=args.user_id, service_id=args.service_id, version=1)
        first_head = _git_remote_head(remote, args.branch)
        if first.get("commit_sha") != first_head:
            raise RuntimeError(f"first pushed head mismatch: deploy={first.get('commit_sha')} remote={first_head}")
        tree = _git_tree(remote, args.branch)
        if not any(item.endswith(f"/services/{args.service_id}/app.py") for item in tree):
            raise RuntimeError(f"service app.py was not pushed to remote tree: {tree[:20]}")

        second = _deploy_service(args.base_url, user_id=args.user_id, service_id=args.service_id, version=2)
        second_head = _git_remote_head(remote, args.branch)
        if second.get("commit_sha") != second_head:
            raise RuntimeError(f"second pushed head mismatch: deploy={second.get('commit_sha')} remote={second_head}")
        if second_head == first_head:
            raise RuntimeError("second deploy did not create a new Git commit")
        commit_count = _git_commit_count(remote, args.branch)
        if commit_count < 2:
            raise RuntimeError(f"expected at least two commits, got {commit_count}")

        if not args.keep:
            _delete_service(args.base_url, user_id=args.user_id, service_id=args.service_id)
    finally:
        if original:
            _write_file(faas_env, original)
        else:
            try:
                faas_env.unlink()
            except FileNotFoundError:
                pass
        _deploy_faas_group(pull=args.pull_stack)
        _wait_faas_health(args.base_url, expected_mode=original_mode)
        restored = True
        if not args.keep:
            shutil.rmtree(run_root, ignore_errors=True)

    print(json.dumps(
        {
            "ok": True,
            "remote": str(remote),
            "branch": args.branch,
            "service_id": args.service_id,
            "commit_count": commit_count,
            "first_head": first_head,
            "second_head": second_head,
            "restored": restored,
            "kept": args.keep,
        },
        ensure_ascii=False,
        sort_keys=True,
    ))
    if backup.exists():
        print(f"backup: {backup}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
