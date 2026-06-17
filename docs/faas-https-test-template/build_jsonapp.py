#!/usr/bin/env python3
"""Generate templates/https_test_lab.json — the HTTPS 测试台 JSON-APP.

Building the DSL programmatically guarantees valid JSON and keeps the 9 test
cases (one faas route each) consistent. The faas service_id is a placeholder
(__SVC__) in global.faasBase; the deploy step rewrites it to the real svc-<hex>.

Run:  python3 docs/faas-https-test-template/build_jsonapp.py [service_id] [backend_base]
  - service_id  : real svc-<hex> (default placeholder __SVC__)
  - backend_base: 若给出（如 https://myapp-pre-de-backend.dapangyu.work），faasBase 用
                  指向该后端的【绝对地址】；不给则用相对地址（由客户端 backendUrl 前缀）。
                  本样板的 faas 服务只部署在 77，发布到「无 faas 的」registry/backend
                  时必须用绝对地址指向 77，否则 invoke 会 404。
"""
import json
import sys

SVC = sys.argv[1] if len(sys.argv) > 1 else "__SVC__"
BACKEND_BASE = sys.argv[2].rstrip("/") if len(sys.argv) > 2 else ""
FAAS_BASE = "%s/api/faas/invoke/%s" % (BACKEND_BASE, SVC) if BACKEND_BASE else "/api/faas/invoke/%s" % SVC

# ---- the 9 test cases: each maps to exactly one faas route ----------------
# logic = the @global.<fn> body (steps); display = result rows on the detail screen.
CASES = [
    {
        "id": "ping", "verb": "GET", "route": "/ping",
        "title": "GET /ping", "desc": "最基础的存活探针：客户端 GET 一个 faas 路由，期望 200 + {ok:true, message:'pong'}。",
        "fn": "runPing", "var": "resPing",
        "logic": [
            {"call": "@http_get", "args": {"url": "{{ global.faasBase }}/ping"}, "assign": "global.resPing"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resPing.status }}"), ("响应体", "{{ global.resPing.data }}"), ("错误", "{{ global.resPing.error }}")],
    },
    {
        "id": "echo_get", "verb": "GET", "route": "/echo",
        "title": "GET /echo?from=...", "desc": "GET + query 参数透传：后端把收到的 query 原样回显。",
        "fn": "runEchoGet", "var": "resEchoGet",
        "logic": [
            {"call": "@http_get", "args": {"url": "{{ global.faasBase }}/echo", "query": {"from": "https-test-lab", "n": "1"}}, "assign": "global.resEchoGet"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resEchoGet.status }}"), ("回显 query", "{{ global.resEchoGet.data }}"), ("错误", "{{ global.resEchoGet.error }}")],
    },
    {
        "id": "echo_post", "verb": "POST", "route": "/echo",
        "title": "POST /echo", "desc": "POST + JSON body 透传：后端回显请求体并返回 201。",
        "fn": "runEchoPost", "var": "resEchoPost",
        "logic": [
            {"call": "@http_post", "args": {"url": "{{ global.faasBase }}/echo", "body": {"hello": "world", "n": 42}}, "assign": "global.resEchoPost"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resEchoPost.status }}"), ("回显 body", "{{ global.resEchoPost.data }}"), ("错误", "{{ global.resEchoPost.error }}")],
    },
    {
        "id": "put", "verb": "PUT", "route": "/items/<id>",
        "title": "PUT /items/42", "desc": "PUT + 动态路径段 + body：更新一条 mock 资源。",
        "fn": "runPut", "var": "resPut",
        "logic": [
            {"call": "@http_put", "args": {"url": "{{ global.faasBase }}/items/42", "body": {"name": "updated", "price": 9.9}}, "assign": "global.resPut"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resPut.status }}"), ("更新结果", "{{ global.resPut.data }}"), ("错误", "{{ global.resPut.error }}")],
    },
    {
        "id": "delete", "verb": "DELETE", "route": "/items/<id>",
        "title": "DELETE /items/42", "desc": "DELETE + 动态路径段：删除一条 mock 资源。",
        "fn": "runDelete", "var": "resDelete",
        "logic": [
            {"call": "@http_delete", "args": {"url": "{{ global.faasBase }}/items/42"}, "assign": "global.resDelete"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resDelete.status }}"), ("删除结果", "{{ global.resDelete.data }}"), ("错误", "{{ global.resDelete.error }}")],
    },
    {
        "id": "headers", "verb": "GET", "route": "/headers",
        "title": "GET /headers（看代理剥头）", "desc": "后端回显它实际收到的请求头。可看到 invoke 代理剥掉了 Authorization/Cookie，而自定义头 X-User-Token / X-Demo 能透传。",
        "fn": "runHeaders", "var": "resHeaders",
        "logic": [
            {"call": "@http_get", "args": {"url": "{{ global.faasBase }}/headers", "headers": {"X-User-Token": "demo-token-123", "X-Demo": "hello", "Authorization": "Bearer should-be-stripped"}}, "assign": "global.resHeaders"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resHeaders.status }}"), ("后端收到的头", "{{ global.resHeaders.data }}"), ("错误", "{{ global.resHeaders.error }}")],
    },
    {
        "id": "stream", "verb": "GET(SSE)", "route": "/stream",
        "title": "GET /stream（SSE）", "desc": "text/event-stream 流式响应：后端推 5 个 tick + 1 个 done，客户端用 @http_sse 累加 events。",
        "fn": "runStream", "var": "resStream",
        "logic": [
            {"call": "@http_sse", "args": {"url": "{{ global.faasBase }}/stream", "method": "GET", "bind": "global.resStream"}, "assign": "global._sseRet"},
        ],
        "rows": [("SSE 状态", "{{ global.resStream.status }}"), ("收到的事件", "{{ global.resStream.events }}"), ("错误", "{{ global.resStream.error }}")],
    },
    {
        "id": "auth", "verb": "POST", "route": "/auth/verify",
        "title": "POST /auth/verify（真实 Supabase 鉴权）", "desc": "客户端用 @get_auth_token 拿当前用户 token，放进自定义头 X-User-Token 传给后端；后端真实调用 Supabase /auth/v1/user 验证并回传裁决。",
        "fn": "runAuth", "var": "resAuth",
        "logic": [
            {"call": "@get_auth_token", "args": {"bind": "global.userToken"}},
            {"call": "@http_post", "args": {"url": "{{ global.faasBase }}/auth/verify", "headers": {"X-User-Token": "{{ global.userToken }}"}, "body": {}}, "assign": "global.resAuth"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resAuth.status }}"), ("鉴权结果", "{{ global.resAuth.data }}"), ("错误", "{{ global.resAuth.error }}")],
    },
    {
        "id": "status", "verb": "GET", "route": "/status/<code>",
        "title": "GET /status/418", "desc": "让后端返回任意状态码（418），验证客户端对非 2xx 响应的处理。",
        "fn": "runStatus", "var": "resStatus",
        "logic": [
            {"call": "@http_get", "args": {"url": "{{ global.faasBase }}/status/418"}, "assign": "global.resStatus"},
        ],
        "rows": [("HTTP 状态码", "{{ global.resStatus.status }}"), ("响应体", "{{ global.resStatus.data }}"), ("错误", "{{ global.resStatus.error }}")],
    },
]

# ---- global.variables -----------------------------------------------------
variables = {"faasBase": FAAS_BASE, "userToken": None, "_sseRet": None}
for c in CASES:
    variables[c["var"]] = None

# ---- global.functions (each called as @global.<fn>) -----------------------
functions = {}
for c in CASES:
    functions[c["fn"]] = {
        "params": [],
        "description": "运行测试用例 %s (%s %s)" % (c["id"], c["verb"], c["route"]),
        "logic": c["logic"] + [{"expression": {"var": "global.%s" % c["var"]}}],
    }

# ---- ui.screens -----------------------------------------------------------
# home: a header + one nav button per case
home_children = [
    {"type": "text", "value": "HTTPS 测试台", "style": {"fontSize": 24, "fontWeight": "bold"}},
    {"type": "text", "value": "每个入口 = 一个 faas 端到端用例。点进去运行，看真实 HTTP 状态码与响应体。", "style": {"fontSize": 13, "color": "#666666"}},
    {"type": "text", "value": "后端服务: %s" % FAAS_BASE, "style": {"fontSize": 11, "color": "#999999"}},
    {"type": "divider"},
]
for c in CASES:
    home_children.append({
        "type": "button",
        "label": "%s · %s" % (c["verb"], c["title"]),
        "variant": "outlined",
        "action": {"type": "navigate", "screen": "case_%s" % c["id"]},
    })

screens = [{"id": "home", "title": "HTTPS 测试台", "layout": "column", "padding": 16, "scrollable": True, "children": home_children}]

# one detail screen per case
for c in CASES:
    children = [
        {"type": "button", "label": "← 返回列表", "variant": "text", "action": {"type": "back"}},
        {"type": "text", "value": c["title"], "style": {"fontSize": 20, "fontWeight": "bold"}},
        {"type": "text", "value": c["desc"], "style": {"fontSize": 13, "color": "#666666"}},
        {"type": "text", "value": "调用: %s {{ global.faasBase }}%s" % (c["verb"], c["route"]), "style": {"fontSize": 12, "color": "#999999"}},
        {"type": "divider"},
        {"type": "button", "label": "▶ 运行测试", "variant": "filled", "action": {"call": "@global.%s" % c["fn"], "args": {}}},
        {"type": "divider"},
    ]
    for label, tmpl in c["rows"]:
        children.append({"type": "text", "value": "%s:" % label, "style": {"fontSize": 13, "fontWeight": "bold"}})
        children.append({"type": "text", "value": tmpl, "style": {"fontSize": 12, "color": "#333333"}})
    screens.append({"id": "case_%s" % c["id"], "title": c["title"], "layout": "column", "padding": 16, "scrollable": True, "children": children})

app = {
    "dsl": "3.3",
    "appid": "7c9e6f10-2a3b-4c5d-8e9f-0a1b2c3d4e5f",
    "meta": {
        "name": "https_test_lab",
        "displayName": {"zh": "HTTPS 测试台", "en": "HTTPS Test Lab", "default": "HTTPS Test Lab"},
        "version": "1.0.0",
        "type": "app",
        "description": "FaaS HTTPS 连通性端到端测试台：GET/POST/PUT/DELETE/SSE/真实 Supabase 鉴权/任意状态码。",
        "author": "claude",
    },
    "global": {"variables": variables, "computed": {}, "functions": functions, "i18n": {}},
    "steps": [],
    "ui": {"screens": screens},
}

out = "templates/https_test_lab.json"
with open(out, "w", encoding="utf-8") as f:
    json.dump(app, f, ensure_ascii=False, indent=2)
print("wrote %s  (%d screens, %d functions, svc=%s)" % (out, len(screens), len(functions), SVC))
