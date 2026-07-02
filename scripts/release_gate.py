#!/usr/bin/env python3
"""release_gate.py — rebuild-vs-retag 判别式的单一真相源。

对每个 app 镜像回答一个问题：从 base_sha（镜像烘焙的代码 commit，即镜像 config 里的
MYAPP_BUILD_COMMIT）升级到 target_sha（本次发布的 commit），这个镜像必须重建（rebuild），
还是重打 tag 即可（retag，代码由 code overlay 在部署侧挂载补齐）？

规则（与 CLAUDE.md「Release & Images」一节保持一致）：
  rebuild ⟺ diff 触碰了该镜像的「运行环境定义」：
    - 依赖 lock/manifest（各 base 安装的 requirements）
    - Dockerfile.<img>-base（任何行）
    - Dockerfile.<img> 的非 COPY / 非注释行（RUN/FROM/ENV/ARG…）
    - .github/workflows/images-base.yml
  其余一切（被 COPY 的代码、docs、client、ctl…）→ retag。

用法：
  release_gate.py --repo <path> --base <sha> --target <sha> --image backend [--json]
  release_gate.py --repo <path> --base <sha> --target <sha> --all --json
退出码 0=有结论（stdout 输出 rebuild/retag 或 JSON）；2=用法/仓库错误。
本脚本被 GitHub Actions（images-app.yml 的 decide job）与 myapp-ctl（code set 安全闸）
共同调用——改规则只改这里。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

IMAGES: dict[str, dict] = {
    "backend": {
        "dockerfile": "deploy/production/Dockerfile.backend",
        "env_paths": [
            "backend/requirements.txt",
            "backend/requirements.lock",
            "deploy/production/Dockerfile.backend-base",
        ],
    },
    "agent-node": {
        "dockerfile": "deploy/production/Dockerfile.agent-node",
        "env_paths": [
            "deploy/production/requirements/agent-node-base.txt",
            "deploy/production/requirements/agent-node-base.lock",
            "deploy/production/Dockerfile.agent-node-base",
        ],
    },
    "agent-runtime": {
        "dockerfile": "deploy/production/Dockerfile.agent-runtime",
        # agent-runtime-base 也安装 backend/requirements.lock（见其 Dockerfile L96）
        "env_paths": [
            "backend/requirements.txt",
            "backend/requirements.lock",
            "deploy/production/Dockerfile.agent-runtime-base",
        ],
    },
    "faas-runtime": {
        "dockerfile": "deploy/production/Dockerfile.faas-runtime",
        "env_paths": [
            "deploy/production/requirements/faas-runtime-base.txt",
            "deploy/production/requirements/faas-runtime-base.lock",
            "deploy/production/Dockerfile.faas-runtime-base",
        ],
    },
}
COMMON_ENV_PATHS = [".github/workflows/images-base.yml"]


def _git(repo: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def decide(repo: str, base: str, target: str, image: str) -> dict:
    spec = IMAGES[image]
    reasons: list[str] = []
    # 基线 commit 必须在仓库中可见，否则无法判定 → 安全默认 rebuild
    if _git(repo, "cat-file", "-e", f"{base}^{{commit}}").returncode != 0:
        return {"image": image, "decision": "rebuild",
                "reasons": [f"baseline commit {base} not found in repo (safe default)"]}
    r = _git(repo, "diff", "--name-only", f"{base}..{target}", "--",
             *spec["env_paths"], *COMMON_ENV_PATHS)
    if r.returncode != 0:
        return {"image": image, "decision": "rebuild",
                "reasons": [f"git diff failed: {(r.stderr or '').strip()[:160]} (safe default)"]}
    touched = [line for line in r.stdout.split("\n") if line.strip()]
    for path in touched:
        reasons.append(f"environment file changed: {path}")
    # Dockerfile.<img>：非 COPY / 非注释行的增删 = 环境语义变化
    d = _git(repo, "diff", f"{base}..{target}", "--", spec["dockerfile"])
    if d.returncode == 0:
        for line in d.stdout.split("\n"):
            if len(line) < 2 or line[0] not in "+-" or line.startswith(("+++", "---")):
                continue
            body = line[1:].strip()
            if not body or body.startswith(("#", "COPY")):
                continue
            reasons.append(f"{spec['dockerfile']} non-COPY line: {line.strip()[:100]}")
    else:
        reasons.append(f"git diff on {spec['dockerfile']} failed (safe default)")
    return {"image": image, "decision": "rebuild" if reasons else "retag", "reasons": reasons}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--base", required=True, help="baked commit of the currently published image")
    ap.add_argument("--target", required=True, help="commit being released")
    ap.add_argument("--image", choices=sorted(IMAGES))
    ap.add_argument("--all", action="store_true", help="decide for all images")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if not args.all and not args.image:
        print("--image or --all is required", file=sys.stderr)
        return 2
    images = sorted(IMAGES) if args.all else [args.image]
    results = {img: decide(args.repo, args.base, args.target, img) for img in images}
    if args.json:
        print(json.dumps(results if args.all else results[images[0]], ensure_ascii=False, indent=1))
    else:
        for img in images:
            res = results[img]
            prefix = f"{img}: " if args.all else ""
            print(f"{prefix}{res['decision']}")
            for reason in res["reasons"]:
                print(f"  - {reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
