#!/usr/bin/env python3
"""
在测试环境的 Supabase 上创建测试账号。

用法:
    SUPABASE_URL=http://192.168.1.100:18000 \
    SERVICE_ROLE_KEY=<key> \
    TEST_USER_EMAIL=test@example.com \
    TEST_USER_PASSWORD=Test123456 \
    python3 seed-test-user.py
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def env(key: str) -> str:
    v = os.environ.get(key)
    if not v:
        print(f"❌ 缺少环境变量: {key}", file=sys.stderr)
        sys.exit(1)
    return v


def main() -> int:
    supabase_url = env("SUPABASE_URL").rstrip("/")
    service_key = env("SERVICE_ROLE_KEY")
    email = env("TEST_USER_EMAIL")
    password = env("TEST_USER_PASSWORD")
    username = os.environ.get("TEST_USER_USERNAME") or email.split("@")[0]

    url = f"{supabase_url}/auth/v1/admin/users"
    body = json.dumps({
        "email": email,
        "password": password,
        "email_confirm": True,            # 测试环境，免邮箱验证
        "user_metadata": {"username": username},
        "app_metadata": {"role": "user"},
    }).encode()
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
            print(f"✔ 测试账号已创建: {email} (id={data.get('id')})")
            return 0
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if e.code == 422 and ("already" in body.lower() or "exists" in body.lower()):
            print(f"ℹ 账号已存在: {email}（跳过创建）")
            return 0
        print(f"❌ 创建失败 HTTP {e.code}: {body}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"❌ 创建失败: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
