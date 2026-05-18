#!/usr/bin/env python3
"""
为 Supabase 生成 ANON_KEY / SERVICE_ROLE_KEY。

用法:
    python3 mint-jwt.py <JWT_SECRET> anon
    python3 mint-jwt.py <JWT_SECRET> service_role

输出: 单行 JWT，直接用 $() 捕获。

依赖: 标准库（不需要 pyjwt）。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys
import time


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def mint(secret: str, role: str) -> str:
    now = int(time.time())
    five_years = 5 * 365 * 24 * 3600
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": now,
        "exp": now + five_years,
    }
    header_b64 = _b64(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()
    sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return f"{header_b64}.{payload_b64}.{_b64(sig)}"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: mint-jwt.py <secret> <role>", file=sys.stderr)
        sys.exit(2)
    print(mint(sys.argv[1], sys.argv[2]))
