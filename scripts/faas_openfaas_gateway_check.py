#!/usr/bin/env python3
"""Preflight checks for a real OpenFaaS/faasd gateway."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any

import requests

_SECRET_BODY_RE = re.compile(
    r'((?:"?[^",:{}\s]*(?:token|password|secret|authorization)[^",:{}\s]*"?\s*[:=]\s*)'
    r')("[^"]*"|[^,\s}]+)',
    re.IGNORECASE,
)


def _read_secret(*, env_name: str = "", file_path: str = "") -> str:
    if env_name:
        return os.environ.get(env_name, "").strip()
    if file_path:
        return Path(file_path).expanduser().read_text(encoding="utf-8").strip()
    return ""


def _auth(username: str, password: str):
    return (username, password) if password else None


def _safe_body(text: str, *, include: bool) -> str:
    if not include:
        return ""
    redacted = _SECRET_BODY_RE.sub(r'\1"***"', text)
    return redacted[:500]


def _check_http(name: str, method: str, url: str, *, auth=None, timeout: float = 8.0, ok_statuses: set[int] | None = None) -> dict[str, Any]:
    ok_statuses = ok_statuses or {200}
    try:
        resp = requests.request(method, url, auth=auth, timeout=timeout)
        ok = resp.status_code in ok_statuses
        body = _safe_body(resp.text, include=not ok)
        return {
            "name": name,
            "ok": ok,
            "status": resp.status_code,
            "url": url,
            **({"body": body} if body else {}),
        }
    except Exception as exc:
        return {
            "name": name,
            "ok": False,
            "status": 0,
            "url": url,
            "error": str(exc),
        }


def _print_table(rows: list[dict[str, Any]]) -> None:
    widths = {
        "name": max([len("CHECK"), *(len(str(row.get("name", ""))) for row in rows)]),
        "ok": len("OK"),
        "status": len("STATUS"),
        "url": max([len("URL"), *(len(str(row.get("url", ""))) for row in rows)]),
    }
    print(f"{'CHECK':<{widths['name']}}  {'OK':<2}  {'STATUS':<6}  URL")
    print(f"{'-' * widths['name']}  {'--'}  {'-' * 6}  {'-' * widths['url']}")
    for row in rows:
        ok = "yes" if row.get("ok") else "no"
        print(f"{row.get('name',''):<{widths['name']}}  {ok:<2}  {row.get('status','-')!s:<6}  {row.get('url','')}")
        if not row.get("ok") and (row.get("error") or row.get("body")):
            detail = row.get("error") or row.get("body")
            print(f"{'':<{widths['name']}}      {'':<6}  {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check a real OpenFaaS/faasd gateway before switching MyApp to openfaas mode.")
    parser.add_argument("--gateway", required=True, help="OpenFaaS/faasd gateway URL, e.g. http://faasd-host:8080")
    parser.add_argument("--username", default="admin", help="OpenFaaS basic auth username")
    parser.add_argument("--password-env", default="", help="environment variable containing OpenFaaS password")
    parser.add_argument("--password-file", default="", help="file containing OpenFaaS password")
    parser.add_argument("--bundle-base-url", required=True, help="backend base URL intended for runtime bundle fetches")
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args()

    gateway = args.gateway.rstrip("/")
    bundle_base = args.bundle_base_url.rstrip("/")
    password = _read_secret(env_name=args.password_env or "", file_path=args.password_file or "")
    auth = _auth(args.username, password)
    checks = [
        _check_http("gateway-health", "GET", f"{gateway}/healthz", ok_statuses={200, 204}),
        _check_http("gateway-functions", "GET", f"{gateway}/system/functions", auth=auth, ok_statuses={200}),
        _check_http("backend-faas-health", "GET", f"{bundle_base}/api/faas/health", ok_statuses={200}),
    ]
    payload = {
        "ok": all(item.get("ok") for item in checks),
        "gateway": gateway,
        "bundle_base_url": bundle_base,
        "auth_supplied": bool(password),
        "checks": checks,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    else:
        _print_table(checks)
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
