#!/usr/bin/env python3
"""Temporarily verify deployed backend against a real OpenFaaS/faasd gateway."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from faas_openfaas_backend_smoke import (
    _deploy_faas_group,
    _env_value,
    _faas_env_path,
    _must_run,
    _read_file,
    _wait_faas_health,
    _write_file,
)


def _optional_arg(cmd: list[str], flag: str, value: str) -> None:
    if value:
        cmd.extend([flag, value])


def main() -> int:
    parser = argparse.ArgumentParser(description="Run backend FaaS smoke against a real OpenFaaS/faasd gateway.")
    parser.add_argument("--yes", action="store_true", help="confirm temporary backend FaaS mode switch and restart")
    parser.add_argument("--gateway", required=True, help="real OpenFaaS/faasd gateway URL, e.g. http://faasd-host:8080")
    parser.add_argument("--username", default="admin", help="OpenFaaS basic auth username")
    parser.add_argument("--password-env", default="", help="environment variable containing the OpenFaaS password")
    parser.add_argument("--password-file", default="", help="file containing the OpenFaaS password")
    parser.add_argument("--base-url", default="http://127.0.0.1:5566", help="backend base URL used by faas smoke")
    parser.add_argument("--bundle-base-url", required=True, help="backend base URL visible from the OpenFaaS runtime")
    parser.add_argument("--runtime-image", default="", help="runtime image; defaults to configured FAAS_OPENFAAS_RUNTIME_IMAGE")
    parser.add_argument("--service-id", default=f"openfaas-gateway-smoke-{int(time.time())}", help="test service id")
    parser.add_argument("--user-id", default="openfaas-gateway-smoke", help="test owner user id")
    parser.add_argument("--pull-stack", action="store_true", help="pull backend/FaaS stack images while redeploying")
    args = parser.parse_args()

    if not args.yes:
        raise RuntimeError("refusing to switch backend FaaS mode without --yes")
    if not shutil.which("myapp-ctl"):
        raise RuntimeError("myapp-ctl is required on PATH")

    faas_env = _faas_env_path()
    original = _read_file(faas_env)
    original_mode = _env_value(original, "FAAS_DEPLOY_MODE") or ""
    backup = faas_env.with_suffix(f".env.bak-openfaas-real-smoke-{int(time.time())}")
    if original:
        _write_file(backup, original)

    restored = False
    try:
        configured = json.loads(_must_run(["myapp-ctl", "faas", "config", "--json", "--show-secrets"], timeout=60) or "{}")
        runtime_image = args.runtime_image or configured.get("FAAS_OPENFAAS_RUNTIME_IMAGE") or "dapangyu/myapp-faas-runtime:agent-control-plane"
        mode_cmd = [
            "myapp-ctl",
            "faas",
            "mode",
            "openfaas",
            "--gateway",
            args.gateway.rstrip("/"),
            "--username",
            args.username,
            "--bundle-base-url",
            args.bundle_base_url.rstrip("/"),
            "--public-base-url",
            args.base_url.rstrip("/"),
            "--runtime-image",
            runtime_image,
            "--scale-zero",
        ]
        _optional_arg(mode_cmd, "--password-env", args.password_env)
        _optional_arg(mode_cmd, "--password-file", args.password_file)
        _must_run(mode_cmd, timeout=120)
        _deploy_faas_group(pull=args.pull_stack)
        health = _wait_faas_health(args.base_url, expected_mode="openfaas")
        if health.get("openfaas_gateway_ok") is False:
            raise RuntimeError(f"backend cannot reach OpenFaaS gateway: {health}")
        smoke = _must_run(
            [
                "myapp-ctl",
                "faas",
                "smoke",
                "--base-url",
                args.base_url.rstrip("/"),
                "--user-id",
                args.user_id,
                "--service-id",
                args.service_id,
            ],
            timeout=300,
        )
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

    print(json.dumps(
        {
            "ok": True,
            "gateway": args.gateway.rstrip("/"),
            "bundle_base_url": args.bundle_base_url.rstrip("/"),
            "restored": restored,
            "service_id": args.service_id,
            "smoke_tail": smoke.strip().splitlines()[-5:],
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
