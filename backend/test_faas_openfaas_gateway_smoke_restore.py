#!/usr/bin/env python3
"""Real-gateway smoke restore-path checks."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

import faas_openfaas_gateway_smoke as gateway_smoke  # noqa: E402


def test_gateway_smoke_restores_faas_env_after_smoke_failure() -> None:
    with tempfile.TemporaryDirectory(prefix="myapp-faas-gateway-smoke-") as raw:
        env_path = Path(raw) / "faas.env"
        original = "FAAS_DEPLOY_MODE=local-docker\nFAAS_RUNTIME_TOKEN=original-token\n"
        env_path.write_text(original, encoding="utf-8")

        old_env = os.environ.get("MYAPP_FAAS_ENV_PATH")
        old_argv = list(sys.argv)
        old_which = gateway_smoke.shutil.which
        old_must_run = gateway_smoke._must_run
        old_deploy = gateway_smoke._deploy_faas_group
        old_wait = gateway_smoke._wait_faas_health
        deploy_snapshots: list[str] = []
        mode_commands: list[list[str]] = []

        def fake_must_run(cmd: list[str], *, timeout: int = 300) -> str:
            if cmd[:4] == ["myapp-ctl", "faas", "config", "--json"]:
                return json.dumps({"FAAS_OPENFAAS_RUNTIME_IMAGE": "example/faas-runtime:test"})
            if cmd[:4] == ["myapp-ctl", "faas", "mode", "openfaas"]:
                mode_commands.append(cmd)
                env_path.write_text("FAAS_DEPLOY_MODE=openfaas\nFAAS_RUNTIME_TOKEN=temp-token\n", encoding="utf-8")
                return "updated faas mode: openfaas\n"
            if cmd[:3] == ["myapp-ctl", "faas", "smoke"]:
                raise RuntimeError("simulated smoke failure")
            raise AssertionError(f"unexpected command: {cmd}")

        def fake_deploy_faas_group(*, pull: bool = False) -> None:
            deploy_snapshots.append(env_path.read_text(encoding="utf-8"))

        def fake_wait_faas_health(base_url: str, *, expected_mode: str = "", timeout: float = 90.0) -> dict:
            return {"ok": True, "deploy_mode": expected_mode}

        try:
            os.environ["MYAPP_FAAS_ENV_PATH"] = str(env_path)
            sys.argv = [
                "faas_openfaas_gateway_smoke.py",
                "--yes",
                "--gateway",
                "http://openfaas.example:8080",
                "--bundle-base-url",
                "https://backend.example",
            ]
            gateway_smoke.shutil.which = lambda name: "/usr/bin/myapp-ctl" if name == "myapp-ctl" else old_which(name)
            gateway_smoke._must_run = fake_must_run
            gateway_smoke._deploy_faas_group = fake_deploy_faas_group
            gateway_smoke._wait_faas_health = fake_wait_faas_health
            try:
                gateway_smoke.main()
            except RuntimeError as exc:
                assert "simulated smoke failure" in str(exc)
            else:
                raise AssertionError("gateway smoke should have failed")
        finally:
            if old_env is None:
                os.environ.pop("MYAPP_FAAS_ENV_PATH", None)
            else:
                os.environ["MYAPP_FAAS_ENV_PATH"] = old_env
            sys.argv = old_argv
            gateway_smoke.shutil.which = old_which
            gateway_smoke._must_run = old_must_run
            gateway_smoke._deploy_faas_group = old_deploy
            gateway_smoke._wait_faas_health = old_wait

        assert mode_commands
        assert env_path.read_text(encoding="utf-8") == original
        assert deploy_snapshots[-1] == original


if __name__ == "__main__":
    test_gateway_smoke_restores_faas_env_after_smoke_failure()
    print(json.dumps({"ok": True}, sort_keys=True))
