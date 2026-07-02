#!/usr/bin/env python3
"""demo 内容一致性自检：每个 *.app.json 引用的 FaaS 服务（"svc": "<id>"）必须
在 services/<id>/ 有随仓库分发的 bundle（service.json 的 service_id 也须一致）。
myapp-ctl 的 demo 装配器与 CI/人工均可跑。exit 0 = 一致。"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVICES = HERE / "services"


def main() -> int:
    errors = []
    referenced = {}
    for app in sorted(HERE.glob("*.app.json")):
        text = app.read_text(encoding="utf-8")
        for sid in re.findall(r'"svc"\s*:\s*"([^"]+)"', text):
            referenced.setdefault(sid, []).append(app.name)
    for sid, apps in sorted(referenced.items()):
        bundle = SERVICES / sid
        if not (bundle / "service.json").exists():
            errors.append(f"{sid}: referenced by {apps} but services/{sid}/service.json missing")
            continue
        meta = json.loads((bundle / "service.json").read_text(encoding="utf-8"))
        if meta.get("service_id") != sid:
            errors.append(f"{sid}: service.json.service_id={meta.get('service_id')!r} mismatches dir name")
        if not (bundle / "app.py").exists():
            errors.append(f"{sid}: app.py missing")
    for line in errors:
        print("ERROR:", line, file=sys.stderr)
    if not errors:
        print(f"ok: {len(referenced)} referenced service(s) all vendored: {', '.join(sorted(referenced))}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
