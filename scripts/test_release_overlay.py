#!/usr/bin/env python3
"""code overlay / 发布检测的离线回归测试（无 docker/git 副作用，直接跑：
   python3 scripts/test_release_overlay.py

覆盖：
1) _parse_dockerfile_copy_map 对 4 个真实 Dockerfile 的解析不变量
   （COPY 映射的单一真相源——挂载映射由它派生，不再手抄）
2) _maybe_auto_code_overlay 的 7 场景矩阵（dry-run + monkeypatch）：
   混合发布（曾是 P0 缺陷：只看 backend）、全 retag、全 rebuild 的 auto 退场、
   手动 overlay 保留、判定不明保守不动、agent-node 单独部署触发、已在目标 no-op
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import myapp_ctl.deploy as D  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def test_parser() -> None:
    checks = {
        "backend": {("backend", "/app/backend"), ("config_center", "/app/config_center")},
        "agent-node": {("backend/providers", "/app/backend/providers")},
        "agent-runtime": {("deploy/production/agent_runner.py", "/opt/myapp/agent_runner.py"),
                          ("pubspec.yaml", "/app/pubspec.yaml"), ("docs", "/app/docs")},
        "faas-runtime": {("backend/faas_runtime_db.py", "/app/backend/myapp_db.py"),  # 重命名映射
                         ("backend/faas_runtime_server.py", "/app/backend/faas_runtime_server.py")},
    }
    for name, must_contain in checks.items():
        got = set(D._parse_dockerfile_copy_map(REPO / f"deploy/production/Dockerfile.{name}"))
        assert got, f"{name}: empty parse"
        missing = must_contain - got
        assert not missing, f"{name}: parser lost {missing}"
        for src, dst in got:
            assert not src.startswith("/") and dst.startswith("/"), f"{name}: bad pair {(src, dst)}"
    print(f"parser: 4 Dockerfiles ok")


FBF = "fbf683890c3eddd2de475ab2eb903012f2e385b2"
NEW = "3f96d87133ae0000000000000000000000000000"
TAGS = {k: f"dapangyu/myapp-{k.replace('_', '-')}:9.9.9-3f96d87"
        for k in ("backend", "agent_node", "agent_runtime", "faas_runtime")}


def _run_case(images, baked_map, overlay, names=("backend",)) -> str:
    D._cfg = lambda: {"images": images, "code_overlay": overlay or {},
                      "paths": {"data_root": "/tmp/x", "state": "/tmp/x"}}
    D._image_baked_commit = lambda k="backend": baked_map.get(k, "")
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        D._maybe_auto_code_overlay(list(names), dry_run=True)
    return (out.getvalue() + err.getvalue()).strip()


def test_detection_matrix() -> None:
    o = _run_case(TAGS, {"backend": NEW, "agent_node": FBF, "agent_runtime": FBF, "faas_runtime": FBF}, None)
    assert "会自动启用" in o and "agent-node" in o, f"mixed release not detected: {o!r}"
    assert "会自动启用" in _run_case(TAGS, {k: FBF for k in TAGS}, None)
    assert "退掉过期的 auto overlay" in _run_case(
        TAGS, {k: NEW for k in TAGS}, {"enabled": True, "sha": "c37ccd052d6c", "auto": True})
    assert "保留不动" in _run_case(
        TAGS, {k: NEW for k in TAGS}, {"enabled": True, "sha": "c37ccd052d6c", "auto": False})
    assert _run_case(TAGS, {"backend": NEW, "agent_node": NEW, "agent_runtime": "", "faas_runtime": NEW},
                     {"enabled": True, "sha": "c37ccd052d6c", "auto": True}) == "", "acted on uncertain state"
    assert "会自动启用" in _run_case(TAGS, {k: FBF for k in TAGS}, None, names=("agent-node",)), \
        "agent-node-only deploy skipped detection"
    assert _run_case(TAGS, {k: FBF for k in TAGS}, {"enabled": True, "sha": "3f96d87133ae", "auto": True}) == ""
    print("detection matrix: 7/7 ok")


if __name__ == "__main__":
    test_parser()
    test_detection_matrix()
    print("ALL PASS")
