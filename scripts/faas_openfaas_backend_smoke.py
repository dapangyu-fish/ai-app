#!/usr/bin/env python3
"""Temporarily verify deployed backend in OpenFaaS mode.

This starts a local OpenFaaS-compatible gateway, switches the deployed backend
to openfaas mode, runs the public FaaS smoke test, and restores the previous
FaaS configuration. It is intentionally opt-in because it restarts backend and
ai-worker through `myapp-ctl deploy --group faas --pull`.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from faas_openfaas_runtime_compat_test import _GatewayState, _close, _docker, _gateway_handler, _run, _serve


def _must_run(cmd: list[str], *, timeout: int = 300) -> str:
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout[-2000:]}\n"
            f"stderr:\n{proc.stderr[-2000:]}"
        )
    return proc.stdout


def _network_gateway(network: str) -> str:
    out = _docker("network", "inspect", "-f", "{{(index .IPAM.Config 0).Gateway}}", network, timeout=30)
    value = out.strip()
    if not value or value == "<no value>":
        raise RuntimeError(f"cannot determine Docker gateway for network: {network}")
    return value


def _read_file(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def _write_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, 0o600)


def _deploy_faas_group() -> None:
    _must_run(["myapp-ctl", "deploy", "--group", "faas", "--pull"], timeout=600)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run backend OpenFaaS-mode smoke with a temporary compatibility gateway.")
    parser.add_argument("--yes", action="store_true", help="confirm temporary backend FaaS mode switch and restart")
    parser.add_argument("--base-url", default="http://127.0.0.1:5566", help="backend base URL used by faas smoke")
    parser.add_argument("--runtime-image", default="", help="runtime image; defaults to configured FAAS_OPENFAAS_RUNTIME_IMAGE")
    parser.add_argument("--network", default="myapp_default", help="Docker network shared by backend and test runtime containers")
    parser.add_argument("--bundle-base-url", default="http://backend:5566", help="bundle URL base visible from runtime containers")
    parser.add_argument("--service-id", default=f"openfaas-backend-smoke-{int(time.time())}", help="test service id")
    parser.add_argument("--user-id", default="openfaas-backend-smoke", help="test owner user id")
    parser.add_argument("--pull-image", action="store_true", help="pull the runtime image before running")
    parser.add_argument("--keep", action="store_true", help="keep test runtime containers after completion")
    args = parser.parse_args()

    if not args.yes:
        raise RuntimeError("refusing to switch backend FaaS mode without --yes")
    if not shutil.which("myapp-ctl"):
        raise RuntimeError("myapp-ctl is required on PATH")
    if not shutil.which("docker"):
        raise RuntimeError("docker CLI is required on PATH")

    faas_env = Path("/etc/myapp/secrets.d/faas.env")
    original = _read_file(faas_env)
    backup = faas_env.with_suffix(f".env.bak-openfaas-smoke-{int(time.time())}")
    if original:
        _write_file(backup, original)

    gateway_state = _GatewayState(keep=args.keep, network=args.network)
    gateway_server, gateway_local = _serve(_gateway_handler(gateway_state), bind_host="0.0.0.0")
    gateway_for_backend = f"http://{_network_gateway(args.network)}:{gateway_local.rsplit(':', 1)[-1]}"
    restored = False

    try:
        configured = json.loads(_must_run(["myapp-ctl", "faas", "config", "--json", "--show-secrets"], timeout=60) or "{}")
        runtime_image = args.runtime_image or configured.get("FAAS_OPENFAAS_RUNTIME_IMAGE") or "dapangyu/myapp-faas-runtime:agent-control-plane"
        if args.pull_image:
            _docker("pull", runtime_image, timeout=300)

        _must_run(
            [
                "myapp-ctl",
                "faas",
                "mode",
                "openfaas",
                "--gateway",
                gateway_for_backend,
                "--bundle-base-url",
                args.bundle_base_url.rstrip("/"),
                "--public-base-url",
                args.base_url.rstrip("/"),
                "--runtime-image",
                runtime_image,
                "--scale-zero",
            ],
            timeout=120,
        )
        _deploy_faas_group()
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
            timeout=180,
        )
    finally:
        if original:
            _write_file(faas_env, original)
        else:
            try:
                faas_env.unlink()
            except FileNotFoundError:
                pass
        try:
            _deploy_faas_group()
            restored = True
        finally:
            gateway_state.cleanup()
            _close(gateway_server)

    methods = [item[0] for item in gateway_state.calls if item[1].startswith("/system/")]
    if methods[:2] != ["GET", "POST"] or "DELETE" not in methods:
        raise RuntimeError(f"backend did not exercise expected OpenFaaS API sequence: {methods}")

    print(json.dumps(
        {
            "ok": True,
            "gateway": gateway_for_backend,
            "restored": restored,
            "openfaas_methods": methods,
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
