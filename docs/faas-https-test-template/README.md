# FaaS 测试台 / FaaS Test Lab — 前后端连体调参考样板

> JSON-APP 名为「FaaS 测试台 / FaaS Test Lab」，支持 zh/en i18n（`global.i18n` + `{{ t('a.b') }}`，首页「中/EN」按钮 `@set_locale` 切换）。
> **干净分层（v1.2.0，见 §5.1）**：框架暴露只读 `app` 命名空间（`{{ app.backendUrl }}` 等，取自 `AppConfig`）；`faas` JSON lib（`templates/lib_faas.json`，作为 `dependencies` 声明）用 `{{ app.backendUrl }}` 拼出完整 invoke URL 再调**通用 http builtin**；本 app 只 `@faas.get/post/put/del/sse(serviceId, route, …)`——**无硬编码域名、无相对地址魔法**。
> （目录名 `faas-https-test-template/` 与 faas 服务 slug `https-test-lab`/`svc-77be07ffad7b` 是稳定标识符，不随显示名改。`app` 命名空间是客户端 Dart 改动，**需重编客户端**才生效。）

> 一套**可直接复用**的「JSON-APP（前端） + FaaS（Python/Flask 后端）」端到端样板，专门用来验证客户端与生成式后端之间的 HTTPS 连通性。它本身就是一个测试 App：首页列出一串入口，每个入口点进去 = 跑一个 faas 路由的端到端用例，看真实 HTTP 状态码与响应体。
>
> 面向后续 AI Agent：**照这套结构生成「带后端的 JSON-APP」就能跑通**。下面把全貌、代码、约束、部署流程、部署预期、部署后单测全部讲清楚。

本样板已在 **77.237.233.229** 真实部署并全绿验证：

- FaaS 服务 `svc-77be07ffad7b`（status: ready，7 条路由）
- JSON-APP `templates/https_test_lab.json`（`validate_json_app` 干净通过）
- 部署后单测 `smoke_test.py` **11/11 PASS**（含真实 Supabase 鉴权拒绝+接受双向）
- canonical registry `myapp-registry.dapangyu.work` 上有 `official` 包 `https_test_lab`（v1.0.0 旧版：HTTPS 命名、绝对 faasBase）。当前源模版为 v1.1.0（FaaS 改名 + zh/en i18n + 相对 faasBase 去硬编码），见 §6.4

---

## 1. 全貌与数据流

```
┌─────────────── 客户端（预编译 Flutter，JSON-DSL 引擎）───────────────┐
│  templates/https_test_lab.json                                       │
│   global.functions.runPing  = [{call:@http_get, url:{{faasBase}}/ping}]│
│   button.action = {call:"@global.runPing"}                            │
│        │  @http_get/@http_post/@http_put/@http_delete/@http_sse        │
│        │  相对 URL → DslHttpClient._resolveUrl 前缀 AppConfig.backendUrl │
└────────┼──────────────────────────────────────────────────────────────┘
         ▼  https://<backend>/api/faas/invoke/svc-77be07ffad7b/<route>
┌─────────────── 后端 invoke 代理（backend，faas.py）──────────────────┐
│  · 校验 <route>/<method> 是否在 service.routes 声明内（否则 404/405）   │
│  · 剥离请求头 authorization / cookie（!!）→ 转发到函数                  │
│  · 冷启动重试（faasd scale-from-zero）                                 │
└────────┼──────────────────────────────────────────────────────────────┘
         ▼  faasd gateway（bridge 172.18.0.1:8731）/function/<fn>/<route>
┌─────────────── FaaS 函数（faasd，受限 Flask app.py）─────────────────┐
│  docs/faas-https-test-template/app.py                                 │
│   @app.get("/ping") ...                                               │
│   @app.post("/auth/verify"): 读 X-User-Token → urllib 真调 Supabase    │
└────────┼──────────────────────────────────────────────────────────────┘
         ▼  仅 /auth/verify 出网
   https://myapp-pre-de-auth.dapangyu.work/auth/v1/user  （真实 Supabase GoTrue）
```

**一句话**：JSON-APP 用相对地址 `/api/faas/invoke/<service_id>/<route>` 调后端 invoke 代理，代理转发给 faasd 里的函数；函数返回 mock 数据，唯独鉴权用例真实出网调 Supabase 验 token。

---

## 2. 九个测试用例

| 入口 | 方法 + 路由 | 验证点 | 部署后实测 |
|------|------------|--------|-----------|
| 存活探针 | `GET /ping` | 最基础连通 | 200 `{ok,message:"pong"}` |
| 回显 query | `GET /echo?from=…` | GET + 查询串透传 | 200 query 原样回显 |
| 回显 body | `POST /echo` | POST + JSON body | 201 body 回显 |
| 更新 | `PUT /items/<id>` | PUT + 动态路径段 + body | 200 updated |
| 删除 | `DELETE /items/<id>` | DELETE + 动态路径段 | 200 deleted |
| 看代理剥头 | `GET /headers` | 哪些头能到函数 | 200 `has_authorization:false, has_x_user_token:true` |
| SSE | `GET /stream` | text/event-stream 全链路 | 200，5 个 tick + done |
| **真实鉴权** | `POST /auth/verify` | 客户端 token → 后端真调 Supabase | garbage→`supabase_status:403`；有效→`supabase_status:200, authenticated:true` |
| 任意状态码 | `GET /status/<code>` | 非 2xx 处理 | 418 |
| （负向）未声明 | `GET /undeclared` | 路由强制 | 404 `FAAS_ROUTE_NOT_ALLOWED` |

---

## 3. 三个决定性约束（必须先懂，否则白写）

### 3.1 函数顶层与 import 受静态校验（`backend/faas_store.py`）
deploy 前 `validate_bundle` 会用 AST 校验 `app.py`：

- **顶层只允许**：`import`、`app = Flask(__name__)`、字面量常量、（路由及辅助）函数、可选 `if __name__=="__main__"`。顶层**不得有任何函数调用 / 网络/文件 IO / 循环 / 线程**。
- **import 白名单（根模块）**：`__future__ base64 collections dateutil datetime decimal flask functools hashlib hmac itertools json math pydantic random re statistics string time urllib uuid`。
  - ⚠️ **没有 `requests` / `http` / `socket` / `os`**。要出网只能用 **`urllib`**（stdlib，已在白名单）。`urllib` 是为本样板真调 Supabase 才加进白名单的（commit `99dc936`）。
  - 不能 `import os` 读环境 → 平台公开配置（Supabase 地址/anon key 等）经 `current_app.config["MYAPP"]` 注入，**不要写死域名**，见 §6.5。
- **方法装饰器只有** `@app.get/post/put/patch/delete`。`@app.head/@app.options` 不存在，会在 import 即崩 503；OPTIONS/HEAD 必须用 `@app.route(path, methods=[...])`。
- **`service.routes` 声明必须与 `@app.xxx` 装饰器逐一对齐**（按路径形状，`<int:id>`/`<id>` 视为同一段）。前端会调用的每个 path+method 都要在 routes 里声明，否则 invoke 代理返回 404（未声明路径）/405（未声明方法）。
- 健康检查 `/__myapp_faas_health` 由运行时自动提供，**不要自己写**。

### 3.2 invoke 代理会剥掉 Authorization / Cookie 请求头（`backend/faas.py`）
代理转发到函数前，**剔除** `host, content-length, connection, authorization, cookie, x-myapp-faas-runtime-token, x-myapp-user-id`。

→ **客户端的用户 token 不能走标准 `Authorization` 头**（到不了函数）。必须用**自定义头**（本样板用 `X-User-Token`，不在剔除表 → 能透传）或 body 传。`GET /headers` 用例就是用来肉眼确认这件事的（`has_authorization:false`）。

### 3.3 函数无数据库、无持久卷；scale-to-zero 在 faasd CE 不生效
faasd 社区版只有 gateway + queue-worker，**没有 idler/autoscaler**，`com.openfaas.scale.zero` 标签不被兑现。所以函数实际是常驻的（不会缩容到 0，也别指望冷启动省资源）。数据用内存 dict mock 即可（重启即丢，测试足够）。真实业务要持久化得另接外部存储（同样经 `urllib`）。

---

## 4. FaaS 后端：`app.py`

要点（完整见同目录 `app.py`）：

```python
from __future__ import annotations
import json, urllib.error, urllib.request
from datetime import datetime, timezone
from flask import Flask, Response, current_app, jsonify, request

app = Flask(__name__)

# Supabase 地址 / anon key 不写死：由后端按环境注入，运行时桥接到 current_app.config["MYAPP"]。
# 换域名/换环境只重部署，不改代码。（注入的都是公开值；service_role 等密钥绝不会出现。）
def _platform_cfg():
    return current_app.config.get("MYAPP", {})        # supabase_url / supabase_anon_key / backend_base_url / faas_public_base_url

def _verify_supabase_token(token):           # 顶层辅助函数（无装饰器，合法）
    cfg = _platform_cfg()                    # 需 app/请求上下文 —— 路由内调用即满足
    supa = (cfg.get("supabase_url") or "").rstrip("/")
    anon = cfg.get("supabase_anon_key") or ""
    if not supa or not anon:
        return -1, None                      # -1 = 平台配置未注入
    req = urllib.request.Request(
        supa + "/auth/v1/user",
        headers={"apikey": anon, "Authorization": "Bearer " + token},
        method="GET")
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:    # token 无效 → GoTrue 401/403
        return exc.code, None
    except Exception:
        return 0, None                       # 0 = 根本没连上

@app.post("/auth/verify")
def auth_verify():
    token = (request.headers.get("X-User-Token") or "").strip()   # 自定义头，未被剥
    if not token:
        return jsonify(ok=False, authenticated=False, reason="缺少 token"), 400
    status, user = _verify_supabase_token(token)
    if status == -1:
        return jsonify(ok=False, authenticated=False, reason="平台配置缺失"), 503
    if status == 200 and isinstance(user, dict):
        return jsonify(ok=True, authenticated=True, supabase_status=200,
                       user={"id": user.get("id"), "email": user.get("email"), "role": user.get("role")})
    if status == 0:
        return jsonify(ok=False, authenticated=False, supabase_status=0, reason="无法连接 Supabase"), 502
    return jsonify(ok=True, authenticated=False, supabase_status=status, reason="Supabase 拒绝了该 token")
```

两个关键点：
- **不写死域名**：平台把公开配置（`supabase_url`/`supabase_anon_key`/`backend_base_url`/`faas_public_base_url`）注入到运行时，用户代码经 `current_app.config["MYAPP"]` 读。后端在 `faas_store.py` 的 `envVars` 注入 `MYAPP_CFG_*`，运行时 `faas_runtime_server.py` 把它们桥接进 `app.config["MYAPP"]`（用户代码不能 import `os`，所以由运行时代读 env）。换域名 = 改 `myapp-ctl` 配置后重部署，不动函数源码。见 §6.5。
- **校验为什么放行 `urlopen`**：校验器只拦 `ast.Name` 形态的禁用调用（裸 `open/eval/exec/...`）；`urlopen` 是 `urllib.request` 上的 **Attribute 调用**，不匹配禁用集；`urllib` 根模块在白名单。

---

## 5. JSON-APP：`templates/https_test_lab.json`

用 `build_jsonapp.py` 程序化生成（保证 JSON 合法 + 9 个用例一致）：

```bash
python3 docs/faas-https-test-template/build_jsonapp.py <service_id>
# 不传 service_id 则写占位 __SVC__；部署拿到真实 id 后再用真实 id 重跑一遍
```

DSL 关键写法（**踩过的坑都在这**）：

- **`global.faasBase` 收口 service_id**：`"faasBase": "/api/faas/invoke/svc-77be07ffad7b"`，所有调用写 `"{{ global.faasBase }}/ping"`。换服务只改一处。相对地址由客户端 `DslHttpClient._resolveUrl` 自动前缀 `AppConfig.backendUrl`。
- **i18n**：`global.i18n = {"zh": {...}, "en": {...}}`（嵌套点路径），UI 文案写 `"{{ t('case.ping.title') }}"`；locale 取 `global.variables.locale`（默认 `zh`），首页「中/EN」按钮 `{"call": "@set_locale", "args": {"value": "en"}}` 切换。缺键回退 key 本身（便于调试）。`build_jsonapp.py` 程序化生成保证 zh/en 同步。
- **用户函数调用必须带 `@global.` 前缀**：按钮 `action: {"call": "@global.runPing", "args": {}}`。
  - ⚠️ 写成 `"@runPing"`（无前缀）会被解释器当未知内置 → **静默 `return null` 无动作**（点了没反应的经典坑）。`@global.` 之后才路由到 `global.functions.runPing`。
  - `action` 可省略 `"type":"call"`（`type` 缺省即 `call`）；导航用 `{"type":"navigate","screen":"case_ping"}`，返回用 `{"type":"back"}`。
- **函数体 `logic`**：步骤 `{call, args, assign}` 把结果存进变量，末尾 `{"expression": {"var": "global.xxx"}}` 作为返回值。
  ```json
  "runPing": {"params": [], "logic": [
    {"call": "@http_get", "args": {"url": "{{ global.faasBase }}/ping"}, "assign": "global.resPing"},
    {"expression": {"var": "global.resPing"}}
  ]}
  ```
- **`@http_get/post/put/delete` 返回信封** `{status, data, headers, error}`。详情页直接展示 `{{ global.resPing.status }}` / `{{ global.resPing.data }}`（支持嵌套路径取字段）。
- **拿用户 token**：`{"call": "@get_auth_token", "args": {"bind": "global.userToken"}}` → 把当前登录用户的 token 写进 `global.userToken`；再经自定义头传给后端：
  ```json
  {"call": "@http_post", "args": {
     "url": "{{ global.faasBase }}/auth/verify",
     "headers": {"X-User-Token": "{{ global.userToken }}"},
     "body": {}}, "assign": "global.resAuth"}
  ```
- **SSE**：`{"call": "@http_sse", "args": {"url": "{{ global.faasBase }}/stream", "method": "GET", "bind": "global.resStream"}}`。`bind` 的变量会被持续写成 `{status, events, last_event, error}`，详情页展示 `{{ global.resStream.events }}`。
- **页面**：`ui.screens` 是数组，每屏 `{id, title, layout, padding, scrollable, children}`；首页用 9 个按钮 `action:{type:navigate, screen:case_xxx}` 跳到各用例详情屏。

---

### 5.1 干净分层：app 命名空间 + faas lib（v1.2.0，替代相对地址魔法）

之前（v1.1.0）用相对地址 `/api/faas/invoke/...`，靠 `DslHttpClient._resolveUrl` 自动前缀 `AppConfig.backendUrl`。这是**分层污染**——通用 HTTP 客户端不该知道"后端在哪"。v1.2.0 改成：

```
框架  interpreter._appContext()  → 暴露只读 app 命名空间（getVariable('app.x') + _buildDataContext()['app']，模板与 jsonlogic 都可读）
   {{ app.backendUrl }} / app.{supabaseUrl,registryUrl,minioUrl,imApiUrl}   （取自 AppConfig，跟随环境切换）
        │
faas JSON lib  templates/lib_faas.json （消费方 dependencies: {"faas": "^1.0.0"}）
   export get/post/put/del/sse/url；内部 {{ app.backendUrl }}/api/faas/invoke/<sid><route> 拼完整 URL
        │  调
通用 http builtin  @http_get/post/…  —— 只认完整 URL（有 scheme → _resolveUrl 原样放行，不再猜后端）
```

- JSON-APP 写 `@faas.get('svc-77be07ffad7b','/ping')`，**不再写任何 URL/域名**。
- 框架改动在客户端 Dart（`lib/json_ui/interpreter.dart`）：`flutter analyze` 干净、单测 `test/json_ui/app_namespace_test.dart` 通过；**但要重编客户端才生效**（旧客户端 `{{ app.backendUrl }}` 为 null）。
- `_resolveUrl` 的相对地址自动前缀**保留作向后兼容**（存量 app 都靠它），新写法走 `app.backendUrl` + faas lib。
- 访问路径仍是后端代理 `/api/faas/invoke/<svc>/<route>`（见 §6.5）。

> §6.4 的相对/绝对 faasBase 讨论是 v1.1.0 的历史；v1.2.0 起不再有 faasBase 变量，URL 由 `app.backendUrl`（客户端当前环境）驱动，跨机拓扑的 Supabase 注意点仍适用。

## 6. 部署流程与预期结果

### 6.1 推荐：Agent 在生成轮内自助部署（v1/v2 提示词已内置此工作流）
生成 `faas_bundle.json` 后，Agent 在当前 shell 依次：
1. `bash backend/faas_deploy.sh $AI_APP_WORKSPACE/faas_bundle.json` → 读 `faas_deploy_result.json` 拿**真实 `service_id`**（经 per-run agent-node faas 代理，注入 owner + node token，无需用户 token）。
2. 失败按 `error` 最小化修 bundle → 重跑（≤5 次）。
3. 成功 → `bash backend/faas_invoke.sh <service_id> <route> [METHOD] [body]` 自测。
4. 把 JSON-APP 的 `faasBase` 接成真实 `service_id` → 上传。

### 6.2 本样板的手工部署（不经生成流水线，直接验证 bundle）
内部鉴权路径：`X-MyApp-Agent-Node-Token: <AGENT_NODE_TOKEN>` + `X-MyApp-Owner-User-Id: <owner>`（faas.py `_request_user_id` 信任此头）。在 77 上、从 backend 容器内直连 `localhost:5566`（避开公网 nginx 对内部头的处理）：

```bash
# bundle 与脚本 scp 到 77 后：
docker cp faas_bundle.json myapp-backend:/tmp/faas_bundle.json
docker exec -e NODE_TOKEN="$(myapp-ctl secret get agent AGENT_NODE_TOKEN --show)" \
            -e OWNER="0abecafe-0000-4000-8000-000000000001" \
            myapp-backend python3 - <<'PY'
import os, json, urllib.request
data = open("/tmp/faas_bundle.json","rb").read()
req = urllib.request.Request("http://localhost:5566/api/faas/services", data=data, method="POST",
    headers={"X-MyApp-Agent-Node-Token": os.environ["NODE_TOKEN"],
             "X-MyApp-Owner-User-Id": os.environ["OWNER"], "Content-Type":"application/json"})
print(urllib.request.urlopen(req, timeout=180).read().decode())
PY
```

**预期成功响应**（实测）：
```json
{"ok": true, "service": {"service_id": "svc-77be07ffad7b", "status": "ready",
  "routes": [{"path":"/ping","methods":["GET"]}, …7 条… ]}}
```
- `status: ready` = 函数已在 faasd 起来、可被 invoke。
- 失败时 HTTP 4xx + `{ok:false, error/code}`，按 error 修 bundle（典型：`declared route not implemented`、`@app.head 不存在`、`import is not allowed: requests`）。

> ⚠️ `docker exec` 跑 heredoc 必须 `-i`，否则 stdin 不转发、容器内 python 读到空、静默无输出。本样板改用 `docker cp 一个 .py 再 exec` 规避。

### 6.3 框架前置改动
真调 Supabase 需要函数能出网，而 import 白名单原本无任何网络库。已加 `urllib`（`backend/faas_store.py` `_ALLOWED_IMPORT_ROOTS`，commit `99dc936`），并重建 `dapangyu/myapp-backend:agent-control-plane` 推 DockerHub、77 `myapp-ctl deploy --pull backend` 重建生效。**校验器在 backend 进程内，改白名单必须重建 backend 镜像才生效。**

### 6.4 发布到 Registry（市场）
本样板已发布到 canonical registry `myapp-registry.dapangyu.work`（= 老生产机 `myapp-backend.dapangyu.work`，**supervisor 部署，非 docker**；`registry_server:app` 跑在 `:3254`，repo 在 `/root/ai-app`，venv `/opt/ai-app-venv`）：

```bash
# 官方包（meta.name 无命名空间）需 admin token：registry 用 token==REGISTRY_ADMIN_TOKEN 判 admin
export REGISTRY_ADMIN_TOKEN="$(grep ^REGISTRY_ADMIN_TOKEN= /etc/ai-app/backend.env | cut -d= -f2-)"
REGISTRY_URL=http://localhost:3254 python3 publish_one.py https_test_lab.json   # POST {json_content,force_update} -> /publish
```
发布结果：`official` 包 `https_test_lab` v1.0.0，`download_url` 落对象存储；`GET /package/https_test_lab` 可解析。

⚠️ **跨机拓扑（决定 faasBase 形态）**：faas 服务只在 **77**，而这台 registry/backend（老生产机）**没有 faas**（`/api/faas/invoke` → 404）。两种选择：
- **相对地址（默认，无硬编码域名）**：`"/api/faas/invoke/svc-77be07ffad7b"`，由客户端 `AppConfig.backendUrl` 前缀。当客户端 backendUrl 指向「自带该服务」的 backend（如 77）时直接可用、且鉴权用客户端同环境 Supabase——这是源模版的形态（`build_jsonapp.py <svc>`）。
- **绝对地址（指向 77，works-anywhere 但写死域名）**：`"https://myapp-pre-de-backend.dapangyu.work/api/faas/invoke/svc-77be07ffad7b"`（`build_jsonapp.py <svc> https://myapp-pre-de-backend.dapangyu.work`）。无论客户端指向哪都打到 77，但 anti-hardcode 角度不理想，且鉴权 happy-path 要求客户端登录在 77 的 Supabase。

⚠️ **鉴权用例的跨环境前提**：`@get_auth_token` 拿的是客户端当前登录态的 token。77 的 Supabase 是 `myapp-pre-de-auth.dapangyu.work`，老生产机是 `myapp-auth.dapangyu.work`（**不同项目**）。所以鉴权 happy-path（`authenticated:true`）要求客户端登录在 **77 的 Supabase**；若登录在老生产机，该用例仍会真实往返 Supabase 但被拒（`authenticated:false`，依然证明前后端连通）。其余 8 个用例与登录态无关，任何客户端都能跑通。

### 6.5 平台配置自动注入（让函数不写死域名）

faas 函数不能 `import os`（校验器禁），所以平台公开配置经一条「env → app.config」桥接喂给用户代码，整条链路：

```
myapp-ctl ingress render
  └ 写 faas.env: FAAS_NODE_PUBLIC_URL = cfg.domains.openfaas（faasd 主域名）
                 FAAS_PUBLIC_BASE_URL = backend 公网；SUPABASE_URL/ANON_KEY 已在 backend env
        │
backend  faas_store.py `_platform_runtime_env()`  → 注入每个 faasd 函数的 envVars：
  MYAPP_CFG_SUPABASE_URL / MYAPP_CFG_SUPABASE_ANON_KEY / MYAPP_CFG_BACKEND_BASE_URL / MYAPP_CFG_FAAS_PUBLIC_BASE_URL
        │  （只注公开值；service_role / runtime_token / bundle_url 绝不注入）
runtime  faas_runtime_server.py `_inject_platform_config(app)`  → app.config["MYAPP"] = {supabase_url, supabase_anon_key, …}
        │
用户 app.py：  current_app.config["MYAPP"]["supabase_url"]      （不能 import os，由运行时代读 env）
```

- **访问路径（确认）**：JSON-APP 默认走【后端代理】`/api/faas/invoke/<svc>/<route>`（路由强制 + 剥头 + 冷启动重试），不是直连 faasd。faasd 直连域名（`MYAPP_CFG_FAAS_PUBLIC_BASE_URL`）是旁路，注入它是为了函数间直连 / 函数自知公网地址。
- **安全边界**：只桥 `MYAPP_CFG_` 前缀；内部密钥用 `MYAPP_FAAS_` 前缀（`MYAPP_FAAS_RUNTIME_TOKEN` / `MYAPP_FAAS_BUNDLE_URL`），永不进 `app.config`。
- **换域名**：改 `myapp-ctl domain set openfaas/...` + `ingress render` 重写 env，再重部署函数即可，**不动任何函数源码**。
- **验证**：`GET /ping` 的 `config_keys` 字段会列出实际注入了哪些键（只列键不泄值）。

---

## 7. 部署后单测 / 冒烟

`smoke_test.py` 是断言式验收测试（任一不符 exit 1）。在 backend 容器内跑（可直连 + 有 `SUPABASE_*` env 签真实 token 验 happy-path）：

```bash
docker cp docs/faas-https-test-template/smoke_test.py myapp-backend:/tmp/smoke_test.py
docker exec myapp-backend python3 /tmp/smoke_test.py svc-77be07ffad7b
```

**实测输出：`== ALL PASS ✓ ==`（11/11，EXIT=0）**，含：
- `GET /headers` → `has_authorization:false, has_x_user_token:true`（证明代理剥 Authorization、自定义头透传）。
- `POST /auth/verify` garbage token → `supabase_status:403`（证明函数**真实出网**调到了 Supabase 且被拒；不是 mock，不是 0/不可达）。
- `POST /auth/verify` 有效 token（faas-e2e@e2e.local，admin-create + password-grant）→ `supabase_status:200, authenticated:true, user.email=faas-e2e@e2e.local`。
- `GET /undeclared` → 404 `FAAS_ROUTE_NOT_ALLOWED`（路由强制）。

---

## 8. 给后续 AI Agent 的 checklist

写「带 faas 后端的 JSON-APP」时，逐条对照：

- [ ] `service.routes` 每个 path+method 都有对应 `@app.get/post/put/patch/delete` 或 `@app.route(methods=[...])`；动态段声明与实现一致。
- [ ] `app.py` 顶层无调用/IO/循环；只 import 白名单内根模块；要出网用 `urllib`，**不要 `requests`**。
- [ ] 前端会调的每个接口都在 routes 里声明（否则 404/405）。
- [ ] 用户 token 走**自定义头**（如 `X-User-Token`）或 body，**不要靠 `Authorization`**（被剥）。
- [ ] JSON-APP 用户函数调用一律 `@global.<name>`（漏前缀 = 点了没反应）。
- [ ] service_id 收口到一个变量（`global.faasBase`），相对地址 `/api/faas/invoke/<id>/<route>`，别让用户手填 `https://`。
- [ ] 生成后**在本轮内真部署 + 自测**（`faas_deploy.sh` → `faas_invoke.sh`），拿真实 `service_id` 接好再上传；部署失败就按 error 改，**绝不能编造 service_id**。
- [ ] `validate_json_app.py` 跑干净（0 ERROR）。

---

## 9. 文件清单

| 文件 | 作用 |
|------|------|
| `app.py` | FaaS 后端源码（7 路由 + 真实 Supabase 鉴权） |
| `faas_bundle.json` | 可直接部署的 bundle（`{service:{slug,routes}, files:{app.py, requirements.txt}}`） |
| `build_jsonapp.py` | JSON-APP 生成器（参数化 service_id） |
| `../../templates/https_test_lab.json` | 生成出的 JSON-APP（已接真实 `svc-77be07ffad7b`） |
| `smoke_test.py` | 部署后断言式单测（11 项） |
| `publish_one.py` | 发布单个 JSON-APP 到 Registry（`/publish`，admin token） |
| `README.md` | 本文 |
