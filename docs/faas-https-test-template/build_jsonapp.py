#!/usr/bin/env python3
"""Generate templates/https_test_lab.json — the FaaS 测试台 / FaaS Test Lab JSON-APP.

Clean layering (no hardcoded domain, no relative-URL magic):
  - the framework exposes the platform addresses to the JSON layer as a read-only
    `app` namespace ({{ app.backendUrl }} etc.);
  - the `faas` JSON lib (templates/lib_faas.json, declared as a dependency) builds
    the full invoke URL from {{ app.backendUrl }} and calls the GENERIC http builtin;
  - this app just calls @faas.get/post/put/del/sse(serviceId, route, ...).

i18n: global.i18n = {locale: {nested}}; UI uses {{ t('a.b') }}; locale =
global.variables.locale (default zh), toggled by @set_locale.

Run:  python3 build_jsonapp.py [service_id]
"""
import json
import sys

SVC = sys.argv[1] if len(sys.argv) > 1 else "__SVC__"

# ---- common UI strings (zh / en) ------------------------------------------
COMMON = {
    "app": {
        "title": {"zh": "FaaS 测试台", "en": "FaaS Test Lab"},
        "subtitle": {
            "zh": "每个入口 = 一个 FaaS 端到端用例。点进去运行，看真实 HTTP 状态码与响应体。",
            "en": "Each entry is one FaaS end-to-end test case. Tap to run and see the real HTTP status and response.",
        },
        "backend_label": {"zh": "后端服务", "en": "Backend"},
    },
    "action": {
        "run": {"zh": "▶ 运行测试", "en": "▶ Run test"},
        "back": {"zh": "← 返回列表", "en": "← Back"},
        "call": {"zh": "调用", "en": "Call"},
    },
}

# ---- the 9 test cases: each maps to exactly one faas route -----------------
# method = faas lib export (get/post/put/del/sse); verb = display label.
ROW_HTTP = {"zh": "HTTP 状态码", "en": "HTTP status"}
ROW_ERR = {"zh": "错误", "en": "Error"}
CASES = [
    {
        "id": "ping", "verb": "GET", "method": "get", "route": "/ping", "var": "resPing",
        "title": {"zh": "GET /ping", "en": "GET /ping"},
        "desc": {"zh": "最基础的存活探针：GET 一个 FaaS 路由，期望 200 + {ok:true, message:'pong'}。",
                 "en": "Basic liveness probe: GET a FaaS route, expect 200 + {ok:true, message:'pong'}."},
        "rows": [(ROW_HTTP, "{{ global.resPing.status }}"),
                 ({"zh": "响应体", "en": "Response body"}, "{{ global.resPing.data }}"),
                 (ROW_ERR, "{{ global.resPing.error }}")],
    },
    {
        "id": "echo_get", "verb": "GET", "method": "get", "route": "/echo?from=faas-test-lab&n=1", "var": "resEchoGet",
        "title": {"zh": "GET /echo?from=…", "en": "GET /echo?from=…"},
        "desc": {"zh": "GET + query 参数透传：后端把收到的 query 原样回显。",
                 "en": "GET with query passthrough: the backend echoes the received query."},
        "rows": [(ROW_HTTP, "{{ global.resEchoGet.status }}"),
                 ({"zh": "回显 query", "en": "Echoed query"}, "{{ global.resEchoGet.data }}"),
                 (ROW_ERR, "{{ global.resEchoGet.error }}")],
    },
    {
        "id": "echo_post", "verb": "POST", "method": "post", "route": "/echo", "var": "resEchoPost",
        "body": {"hello": "world", "n": 42},
        "title": {"zh": "POST /echo", "en": "POST /echo"},
        "desc": {"zh": "POST + JSON body 透传：后端回显请求体并返回 201。",
                 "en": "POST with JSON body: the backend echoes the body and returns 201."},
        "rows": [(ROW_HTTP, "{{ global.resEchoPost.status }}"),
                 ({"zh": "回显 body", "en": "Echoed body"}, "{{ global.resEchoPost.data }}"),
                 (ROW_ERR, "{{ global.resEchoPost.error }}")],
    },
    {
        "id": "put", "verb": "PUT", "method": "put", "route": "/items/42", "var": "resPut",
        "body": {"name": "updated", "price": 9.9},
        "title": {"zh": "PUT /items/42", "en": "PUT /items/42"},
        "desc": {"zh": "PUT + 动态路径段 + body：更新一条 mock 资源。",
                 "en": "PUT with a dynamic path segment + body: update a mock resource."},
        "rows": [(ROW_HTTP, "{{ global.resPut.status }}"),
                 ({"zh": "更新结果", "en": "Update result"}, "{{ global.resPut.data }}"),
                 (ROW_ERR, "{{ global.resPut.error }}")],
    },
    {
        "id": "delete", "verb": "DELETE", "method": "del", "route": "/items/42", "var": "resDelete",
        "title": {"zh": "DELETE /items/42", "en": "DELETE /items/42"},
        "desc": {"zh": "DELETE + 动态路径段：删除一条 mock 资源。",
                 "en": "DELETE with a dynamic path segment: delete a mock resource."},
        "rows": [(ROW_HTTP, "{{ global.resDelete.status }}"),
                 ({"zh": "删除结果", "en": "Delete result"}, "{{ global.resDelete.data }}"),
                 (ROW_ERR, "{{ global.resDelete.error }}")],
    },
    {
        "id": "headers", "verb": "GET", "method": "get", "route": "/headers", "var": "resHeaders",
        "headers": {"X-User-Token": "demo-token-123", "X-Demo": "hello", "Authorization": "Bearer should-be-stripped"},
        "title": {"zh": "GET /headers（看代理剥头）", "en": "GET /headers (proxy header strip)"},
        "desc": {"zh": "后端回显它实际收到的请求头。可看到 invoke 代理剥掉了 Authorization/Cookie，自定义头 X-User-Token / X-Demo 能透传。",
                 "en": "The backend echoes the headers it received. The invoke proxy strips Authorization/Cookie; custom headers (X-User-Token / X-Demo) pass through."},
        "rows": [(ROW_HTTP, "{{ global.resHeaders.status }}"),
                 ({"zh": "后端收到的头", "en": "Received headers"}, "{{ global.resHeaders.data }}"),
                 (ROW_ERR, "{{ global.resHeaders.error }}")],
    },
    {
        "id": "stream", "verb": "GET", "method": "sse", "route": "/stream", "var": "resStream",
        "title": {"zh": "GET /stream（SSE）", "en": "GET /stream (SSE)"},
        "desc": {"zh": "text/event-stream 流式响应：后端推 5 个 tick + 1 个 done，客户端经 @faas.sse 累加 events。",
                 "en": "text/event-stream streaming: the backend pushes 5 ticks + 1 done; the client accumulates events via @faas.sse."},
        "rows": [({"zh": "SSE 状态", "en": "SSE status"}, "{{ global.resStream.status }}"),
                 ({"zh": "收到的事件", "en": "Received events"}, "{{ global.resStream.events }}"),
                 (ROW_ERR, "{{ global.resStream.error }}")],
    },
    {
        "id": "auth", "verb": "POST", "method": "post", "route": "/auth/verify", "var": "resAuth",
        "auth": True, "headers": {"X-User-Token": "{{ global.userToken }}"}, "body": {},
        "title": {"zh": "POST /auth/verify（真实 Supabase 鉴权）", "en": "POST /auth/verify (real Supabase auth)"},
        "desc": {"zh": "客户端用 @get_auth_token 拿当前用户 token，放进自定义头 X-User-Token 传给后端；后端真实调用 Supabase /auth/v1/user 验证并回传裁决。",
                 "en": "The client gets the user token via @get_auth_token and passes it in the X-User-Token header; the backend really calls Supabase /auth/v1/user and returns the verdict."},
        "rows": [(ROW_HTTP, "{{ global.resAuth.status }}"),
                 ({"zh": "鉴权结果", "en": "Auth result"}, "{{ global.resAuth.data }}"),
                 (ROW_ERR, "{{ global.resAuth.error }}")],
    },
    {
        "id": "status", "verb": "GET", "method": "get", "route": "/status/418", "var": "resStatus",
        "title": {"zh": "GET /status/418", "en": "GET /status/418"},
        "desc": {"zh": "让后端返回任意状态码（418），验证客户端对非 2xx 响应的处理。",
                 "en": "Make the backend return an arbitrary status (418) to test client handling of non-2xx responses."},
        "rows": [(ROW_HTTP, "{{ global.resStatus.status }}"),
                 ({"zh": "响应体", "en": "Response body"}, "{{ global.resStatus.data }}"),
                 (ROW_ERR, "{{ global.resStatus.error }}")],
    },
]

SID = "{{ global.faasService }}"


def build_logic(c):
    steps = []
    if c.get("auth"):
        steps.append({"call": "@get_auth_token", "args": {"bind": "global.userToken"}})
    if c["method"] == "sse":
        args = {"serviceId": SID, "route": c["route"], "method": "GET", "bind": "global.%s" % c["var"]}
        steps.append({"call": "@faas.sse", "args": args, "assign": "global._sseRet"})
    else:
        args = {"serviceId": SID, "route": c["route"]}
        if "body" in c:
            args["body"] = c["body"]
        if "headers" in c:
            args["headers"] = c["headers"]
        steps.append({"call": "@faas.%s" % c["method"], "args": args, "assign": "global.%s" % c["var"]})
    steps.append({"expression": {"var": "global.%s" % c["var"]}})
    return steps


# ---- global.i18n = {zh:{...}, en:{...}} ------------------------------------
i18n = {"zh": {"case": {}}, "en": {"case": {}}}
for section, entries in COMMON.items():
    for key, langs in entries.items():
        for lang in ("zh", "en"):
            i18n[lang].setdefault(section, {})[key] = langs[lang]
for c in CASES:
    for lang in ("zh", "en"):
        node = {"title": c["title"][lang], "desc": c["desc"][lang]}
        for idx, (label, _tmpl) in enumerate(c["rows"]):
            node["row%d" % idx] = label[lang]
        i18n[lang]["case"][c["id"]] = node

# ---- global.variables + functions -----------------------------------------
variables = {"locale": "zh", "faasService": SVC, "userToken": None, "_sseRet": None}
functions = {}
for c in CASES:
    variables[c["var"]] = None
    functions[c["fn"] if "fn" in c else "run_%s" % c["id"]] = {
        "params": [],
        "description": "run %s (%s %s)" % (c["id"], c["verb"], c["route"]),
        "logic": build_logic(c),
    }

# ---- ui.screens -----------------------------------------------------------
home_children = [
    {"type": "container", "layout": "row", "children": [
        {"type": "text", "value": "{{ t('app.title') }}", "style": {"fontSize": 24, "fontWeight": "bold"}},
        {"type": "button", "label": "中", "variant": "text", "action": {"call": "@set_locale", "args": {"value": "zh"}}},
        {"type": "button", "label": "EN", "variant": "text", "action": {"call": "@set_locale", "args": {"value": "en"}}},
    ]},
    {"type": "text", "value": "{{ t('app.subtitle') }}", "style": {"fontSize": 13, "color": "#666666"}},
    # 完整真实地址：app.backendUrl（框架暴露）+ 服务路径，不写死域名
    {"type": "text", "value": "{{ t('app.backend_label') }}: {{ app.backendUrl }}/api/faas/invoke/{{ global.faasService }}", "style": {"fontSize": 11, "color": "#999999"}},
    {"type": "divider"},
]
for c in CASES:
    home_children.append({
        "type": "button",
        "label": "%s · {{ t('case.%s.title') }}" % (c["verb"], c["id"]),
        "variant": "outlined",
        "action": {"type": "navigate", "screen": "case_%s" % c["id"]},
    })
screens = [{"id": "home", "title": "{{ t('app.title') }}", "layout": "column", "padding": 16, "scrollable": True, "children": home_children}]

for c in CASES:
    children = [
        {"type": "button", "label": "{{ t('action.back') }}", "variant": "text", "action": {"type": "back"}},
        {"type": "text", "value": "{{ t('case.%s.title') }}" % c["id"], "style": {"fontSize": 20, "fontWeight": "bold"}},
        {"type": "text", "value": "{{ t('case.%s.desc') }}" % c["id"], "style": {"fontSize": 13, "color": "#666666"}},
        {"type": "text", "value": "{{ t('action.call') }}: %s {{ app.backendUrl }}/api/faas/invoke/{{ global.faasService }}%s" % (c["verb"], c["route"]), "style": {"fontSize": 12, "color": "#999999"}},
        {"type": "divider"},
        {"type": "button", "label": "{{ t('action.run') }}", "variant": "filled", "action": {"call": "@global.run_%s" % c["id"], "args": {}}},
        {"type": "divider"},
    ]
    for idx, (_label, tmpl) in enumerate(c["rows"]):
        children.append({"type": "text", "value": "{{ t('case.%s.row%d') }}:" % (c["id"], idx), "style": {"fontSize": 13, "fontWeight": "bold"}})
        children.append({"type": "text", "value": tmpl, "style": {"fontSize": 12, "color": "#333333"}})
    screens.append({"id": "case_%s" % c["id"], "title": "{{ t('case.%s.title') }}" % c["id"], "layout": "column", "padding": 16, "scrollable": True, "children": children})

app = {
    "dsl": "3.3",
    "appid": "7c9e6f10-2a3b-4c5d-8e9f-0a1b2c3d4e5f",
    "meta": {
        "name": "https_test_lab",
        "displayName": {"zh": "FaaS 测试台", "en": "FaaS Test Lab", "default": "FaaS Test Lab"},
        "version": "1.3.0",
        "type": "app",
        "description": "FaaS 端到端连通性测试台（i18n + faas lib）：GET/POST/PUT/DELETE/SSE/真实 Supabase 鉴权/任意状态码。",
        "author": "claude",
    },
    "dependencies": {"faas": "^1.0.1"},
    "global": {"variables": variables, "computed": {}, "functions": functions, "i18n": i18n},
    "steps": [],
    "ui": {"screens": screens},
}

out = "templates/https_test_lab.json"
with open(out, "w", encoding="utf-8") as f:
    json.dump(app, f, ensure_ascii=False, indent=2)
print("wrote %s  (%d screens, %d functions, deps=%s, locales=%s, svc=%s)"
      % (out, len(screens), len(functions), list(app["dependencies"].keys()), list(i18n.keys()), SVC))
