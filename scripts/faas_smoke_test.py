#!/usr/bin/env python3
"""Smoke-test the MyApp generated-FaaS HTTP API.

This script intentionally uses only public backend HTTP routes. It is safe to
run against a test environment with FAAS_REQUIRE_AUTH=0, or with --token when
auth is enabled.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
from typing import Any

import requests


def _request(
    method: str,
    url: str,
    *,
    token: str = "",
    timeout: float = 60.0,
    **kwargs: Any,
) -> requests.Response:
    headers = dict(kwargs.pop("headers", {}) or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    resp = requests.request(method, url, headers=headers, timeout=timeout, **kwargs)
    if resp.status_code >= 400:
        raise RuntimeError(f"{method} {url} failed {resp.status_code}: {resp.text[:1000]}")
    return resp


def _bundle(service_id: str) -> dict[str, Any]:
    app_py = """from flask import Flask, jsonify, request

app = Flask(__name__)

@app.get("/hello")
def hello():
    name = request.args.get("name", "myapp")
    return jsonify({"ok": True, "message": f"hello {name}"})

@app.get("/headers")
def headers():
    return jsonify({
        "authorization": request.headers.get("Authorization"),
        "cookie": request.headers.get("Cookie"),
        "runtime_token": request.headers.get("X-MyApp-FaaS-Runtime-Token"),
        "user_id": request.headers.get("X-MyApp-User-Id"),
    })
"""
    return {
        "service": {
            "service_id": service_id,
            "slug": "smoke-api",
            "routes": [
                {"path": "/hello", "methods": ["GET"], "description": "smoke hello endpoint"},
                {"path": "/headers", "methods": ["GET"], "description": "header forwarding guard"},
            ],
        },
        "files": {
            "app.py": app_py,
            "requirements.txt": "flask==3.0.3\n",
            "README.md": "# smoke-api\n",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test generated FaaS deploy/invoke/cleanup.")
    parser.add_argument("--base-url", default="http://127.0.0.1:5566", help="backend base URL")
    parser.add_argument("--user-id", default=f"faas-smoke-{secrets.token_hex(4)}", help="test user id")
    parser.add_argument("--service-id", default=f"smoke-api-{secrets.token_hex(4)}", help="test service id")
    parser.add_argument("--token", default="", help="optional backend bearer token")
    parser.add_argument("--no-cleanup", action="store_true", help="leave the deployed service in place")
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    payload = _bundle(args.service_id)
    if not args.token:
        payload["user_id"] = args.user_id

    health = _request("GET", f"{base}/api/faas/health", token=args.token).json()
    print("health:", json.dumps(health, ensure_ascii=False))

    deploy = _request("POST", f"{base}/api/faas/services", token=args.token, json=payload).json()
    print("deploy:", json.dumps(deploy, ensure_ascii=False))

    invoke = _request(
        "GET",
        f"{base}/api/faas/invoke/{args.service_id}/hello?name=smoke",
        token=args.token,
    ).json()
    print("invoke:", json.dumps(invoke, ensure_ascii=False))
    if invoke.get("message") != "hello smoke":
        raise RuntimeError(f"unexpected invoke payload: {invoke}")

    header_resp = _request(
        "GET",
        f"{base}/api/faas/invoke/{args.service_id}/headers",
        headers={
            "Authorization": "Bearer should-not-forward",
            "Cookie": "sid=should-not-forward",
            "X-MyApp-FaaS-Runtime-Token": "should-not-forward",
            "X-MyApp-User-Id": "should-not-forward",
        },
    ).json()
    print("headers:", json.dumps(header_resp, ensure_ascii=False))
    if any(header_resp.get(key) for key in ("authorization", "cookie", "runtime_token", "user_id")):
        raise RuntimeError(f"sensitive headers were forwarded to generated service: {header_resp}")

    invalid = requests.get(f"{base}/api/faas/invoke/{args.service_id}/http://127.0.0.1:5566/api/faas/health")
    print("invalid_route_status:", invalid.status_code)
    if invalid.status_code != 400:
        raise RuntimeError(f"absolute route path was not rejected: {invalid.status_code} {invalid.text[:300]}")

    if not args.no_cleanup:
        cleanup_url = f"{base}/api/faas/services/{args.service_id}"
        cleanup_params = {} if args.token else {"user_id": args.user_id}
        cleanup = _request("DELETE", cleanup_url, token=args.token, params=cleanup_params).json()
        print("cleanup:", json.dumps(cleanup, ensure_ascii=False))

    print("ok")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
