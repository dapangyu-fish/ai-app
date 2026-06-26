#!/usr/bin/env python3
"""部署后单测 / 冒烟：逐条 invoke HTTPS 测试台后端的每个路由并断言结果。

这是 faas 后端部署完成后的验收测试，覆盖 GET/POST/PUT/DELETE/SSE/真实 Supabase
鉴权(拒绝+接受)/任意状态码/未声明路由 404。任何一条不符合预期即 exit 1。

在 77 上、backend 容器内跑（容器内可直连 localhost:5566，且有 SUPABASE_* env 可签真实 token）：
    docker cp docs/faas-https-test-template/smoke_test.py myapp-backend:/tmp/smoke_test.py
    docker exec myapp-backend python3 /tmp/smoke_test.py svc-77be07ffad7b

也可指定 invoke base（如经公网域名，但注意公网代理可能剥更多头）：
    python3 smoke_test.py <service_id> [invoke_base]
        invoke_base 默认 http://localhost:5566/api/faas/invoke
"""
import json
import os
import sys
import urllib.error
import urllib.request

SERVICE_ID = sys.argv[1] if len(sys.argv) > 1 else "svc-77be07ffad7b"
INVOKE_BASE = (sys.argv[2] if len(sys.argv) > 2 else "http://localhost:5566/api/faas/invoke").rstrip("/")
BASE = "%s/%s" % (INVOKE_BASE, SERVICE_ID)

# Supabase（用于鉴权 happy-path：在 backend 容器内有这些 env）
SUPA = os.environ.get("SUPABASE_URL", "").rstrip("/")
SVC_KEY = os.environ.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or ""
ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")
E2E_EMAIL = "faas-e2e@e2e.local"
E2E_PW = "FaasE2e!fixed-2026"

_fail = 0


def _call(method, route, body=None, headers=None, base=None):
    url = (base or BASE) + route
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json"} if data is not None else {}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req, timeout=60)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, "EXC %r" % e


def check(name, ok, detail=""):
    global _fail
    print(("  PASS " if ok else "  FAIL ") + name + ((" — " + detail) if detail else ""))
    if not ok:
        _fail += 1


def expect_json(name, method, route, want_status, predicate, body=None, headers=None):
    code, raw = _call(method, route, body, headers)
    try:
        d = json.loads(raw)
    except Exception:
        d = None
    ok = code == want_status and d is not None and predicate(d)
    check("%s %s -> %s" % (method, route, want_status), ok, "got %s %s" % (code, raw[:160]))
    return d


def mint_token():
    """admin-create(idempotent) + password-grant -> real user access_token, or None."""
    if not (SUPA and ANON_KEY):
        return None

    def post(url, hdr, body):
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={**hdr, "Content-Type": "application/json"})
        try:
            r = urllib.request.urlopen(req, timeout=30)
            return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()
        except Exception:
            return -1, ""

    if SVC_KEY:
        post(SUPA + "/auth/v1/admin/users", {"apikey": SVC_KEY, "Authorization": "Bearer " + SVC_KEY},
             {"email": E2E_EMAIL, "password": E2E_PW, "email_confirm": True})
    c, b = post(SUPA + "/auth/v1/token?grant_type=password", {"apikey": ANON_KEY},
                {"email": E2E_EMAIL, "password": E2E_PW})
    return json.loads(b).get("access_token") if c == 200 else None


print("== HTTPS 测试台冒烟 ==  service=%s  base=%s\n" % (SERVICE_ID, BASE))

print("[GET /ping]")
expect_json("ping", "GET", "/ping", 200, lambda d: d.get("ok") is True and d.get("message") == "pong")

print("[GET /echo + query]")
expect_json("echo-get", "GET", "/echo?from=lab&n=1", 200, lambda d: d.get("query", {}).get("from") == "lab")

print("[POST /echo]")
expect_json("echo-post", "POST", "/echo", 201, lambda d: d.get("received", {}).get("hello") == "world", body={"hello": "world", "n": 42})

print("[PUT /items/42]")
expect_json("put", "PUT", "/items/42", 200, lambda d: d.get("id") == "42" and "name" in d.get("updated_fields", []), body={"name": "updated", "price": 9.9})

print("[DELETE /items/42]")
expect_json("delete", "DELETE", "/items/42", 200, lambda d: d.get("deleted") is True and d.get("id") == "42")

print("[GET /headers] — 代理应剥 Authorization，自定义头透传")
expect_json("headers", "GET", "/headers", 200,
            lambda d: d.get("has_authorization") is False and d.get("has_x_user_token") is True,
            headers={"X-User-Token": "demo-123", "Authorization": "Bearer should-be-stripped"})

print("[GET /stream] — SSE")
code, raw = _call("GET", "/stream")
check("stream SSE 5 ticks + done", code == 200 and raw.count("event: tick") == 5 and "event: done" in raw, "got %s, ticks=%s" % (code, raw.count("event: tick")))

print("[POST /auth/verify] — garbage token：真实调用 Supabase 应被拒")
expect_json("auth-reject", "POST", "/auth/verify", 200,
            lambda d: d.get("authenticated") is False and d.get("supabase_status") in (401, 403),
            body={}, headers={"X-User-Token": "garbage.invalid.token"})

print("[POST /auth/verify] — valid token：真实调用 Supabase 应通过")
tok = mint_token()
if tok:
    expect_json("auth-accept", "POST", "/auth/verify", 200,
                lambda d: d.get("authenticated") is True and d.get("supabase_status") == 200 and d.get("user", {}).get("email") == E2E_EMAIL,
                body={}, headers={"X-User-Token": tok})
else:
    print("  SKIP auth-accept（无 SUPABASE_* env，无法签真实 token；在 backend 容器内跑可启用）")

print("[GET /status/418]")
expect_json("status-418", "GET", "/status/418", 418, lambda d: d.get("requested_status") == 418)

print("[GET /undeclared] — 未声明路由应 404")
expect_json("route-enforce", "GET", "/undeclared", 404, lambda d: d.get("code") == "FAAS_ROUTE_NOT_ALLOWED")

print("\n== %s ==" % ("ALL PASS ✓" if _fail == 0 else ("%d FAILED ✗" % _fail)))
sys.exit(1 if _fail else 0)
