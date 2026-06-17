# 带 FaaS 后端的 JSON-APP 生成方法（标准路径 · 范本：FaaS 测试台）

> **读者：后端生成 Agent（v1/v2 都适用）。** 一旦你判断用户需求需要「后端能力」，
> 在写任何 bundle/JSON 之前**必须通读本文件并严格照此执行**。这是把「前端 JSON-APP
> ＋ FaaS Python 后端」连起来的唯一正确路径，能最大化成功率。
>
> **范本**（已真实上线、`smoke_test.py` 11/11 全绿）：
> - 前端：`templates/https_test_lab.json`（FaaS 测试台，调 `@faas.*`，无硬编码域名）
> - 后端：`docs/faas-https-test-template/app.py` + `faas_bundle.json`
> - 调用库：`templates/lib_faas.json`（official 包 `faas`，已发布）
> - 详尽参考：`docs/faas-https-test-template/README.md`
>
> 照这个**结构和顺序**走，不要自创路子。

---

## 0. 七步全景

```
1 判断要不要后端 → 2 架构决策(faas lib + app 命名空间，绝不写死域名)
→ 3 写 app.py(受限 Flask) → 4 写 faas_bundle.json → 5 部署+自测(本轮内，拿真实 svc-id)
→ 6 写/接线 JSON-APP(@faas.*) → 7 校验+发布
```

---

## 1. 先判断：要不要 FaaS 后端？

**需要**（出现任一即生成后端）：跨用户/持久化数据、服务端计算或校验、调用外部 API（如真实
鉴权、第三方 HTTP）、需要对客户端隐藏的逻辑或密钥使用。

**不需要**：纯 UI / 纯客户端交互 / 只读静态数据 / 本地状态。→ 直接生成 JSON-APP，别建后端。

> 不确定就倾向「不建」。后端是配额受限资源（每用户 `max_services`），且增加部署面。

---

## 2. 架构决策（最关键一步）：怎么对接后端

**铁律：JSON-APP 里绝不写任何后端 URL / 域名 / 相对地址。** 用下面两个框架能力：

### 2.1 `faas` 调用库（已发布的 official 包 `faas`）
- 在 JSON-APP 顶层声明：`"dependencies": { "faas": "^1.0.0" }`
- 调用：`@faas.get/post/put/del/sse(serviceId, route, body?, headers?)`
  - `serviceId`：你部署后拿到的真实 `svc-<hex>`（收口到一个变量，如 `global.faasService`）
  - `route`：以 `/` 开头，如 `/ping`、`/items/42`、`/echo?from=x`
  - 返回 http 信封 `{status, data, headers, error}`，用 `assign` 存进变量再展示
- 它内部用 `{{ app.backendUrl }}/api/faas/invoke/<serviceId><route>` 拼**完整 URL** 再调通用
  `@http_*`。这样「打哪个后端」留在 JSON 层，http 层保持通用，**换域名/换环境零改码**。

### 2.2 `app` 命名空间（框架暴露的当前环境地址）
- `{{ app.backendUrl }}` / `app.{supabaseUrl,registryUrl,minioUrl,imApiUrl}`（只读，取自客户端
  当前环境）。需要在界面**显示**完整地址、或显式拼 URL 时用它。
- 普通 faas 调用不必直接碰它（`@faas.*` 已封装）。

### 2.3 用户登录态 token（鉴权场景）
- `@get_auth_token {bind: "global.userToken"}` 拿当前登录用户 token。
- **经自定义头传后端**（如 `X-User-Token`），**不要用 `Authorization`**——invoke 代理会剥掉
  `authorization`/`cookie`，自定义头才能透传。

### 2.4 函数调用前缀（最常见的「点了没反应」根因）
- 调用本 app 自己的函数必须带 `@global.` 前缀：`{"call": "@global.runPing"}`。漏前缀 → 解释器
  静默 `return null` 无动作。
- 调依赖库函数：`@<depName>.<func>`，`depName` == 库的 `meta.name`（faas 库就是 `@faas.get`）。

---

## 3. 写 FaaS 后端 `app.py`（受限 Flask，部署前静态校验）

校验器在 `backend/faas_store.py`。**违反任一即 deploy 被拒**，照下面写：

- **顶层只允许**：`import`、`app = Flask(__name__)`（或 `application`）、字面量常量、（路由及
  无装饰器的辅助）函数、可选 `if __name__ == "__main__": app.run()`。顶层**不得有任何函数
  调用 / 网络或文件 IO / 循环 / 线程**。函数默认参数、类型注解、装饰器也不能调用运行时代码。
- **import 白名单（根模块）**：`__future__ base64 collections dateutil datetime decimal flask
  functools hashlib hmac itertools json math pydantic random re statistics string time urllib
  uuid`。**没有 `requests`/`http`/`socket`/`os`**——要出网只能用 **`urllib`**。
- **方法装饰器只有** `@app.get/post/put/patch/delete`；OPTIONS/HEAD 等必须
  `@app.route(path, methods=[...])`（写 `@app.head` 会 import 即崩 503）。
- **`service.routes` 声明必须与 `@app.xxx` 装饰器逐一对齐**（按路径形状，`<int:id>`/`<id>` 视为
  同段）。前端会调的每个 path+method 都要声明，否则 invoke 返回 404（未声明路径）/405（方法）。
- 不要写健康检查 `/__myapp_faas_health`（运行时自动提供）。
- **平台配置不写死域名**：平台把公开配置注入到 `current_app.config["MYAPP"]`，键有
  `supabase_url`、`supabase_anon_key`、`backend_base_url`、`faas_public_base_url`。需要调用
  Supabase 或回调平台时从这里拼 URL（用 `urllib` 出网）；**绝不会注入 service_role 等密钥**，
  需要密钥的操作不要放在 FaaS 里做。

范本 `app.py`（节选，完整见 `docs/faas-https-test-template/app.py`）：

```python
from __future__ import annotations
import json, urllib.error, urllib.request
from flask import Flask, current_app, jsonify, request
app = Flask(__name__)

def _verify_supabase_token(token):           # 顶层辅助函数（无装饰器）
    cfg = current_app.config.get("MYAPP", {})            # 平台注入的公开配置
    supa = (cfg.get("supabase_url") or "").rstrip("/")
    anon = cfg.get("supabase_anon_key") or ""
    if not supa or not anon:
        return -1, None
    req = urllib.request.Request(supa + "/auth/v1/user",
        headers={"apikey": anon, "Authorization": "Bearer " + token}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, None

@app.post("/auth/verify")
def auth_verify():
    token = (request.headers.get("X-User-Token") or "").strip()   # 自定义头，未被剥
    if not token:
        return jsonify(ok=False, authenticated=False, reason="缺少 token"), 400
    status, user = _verify_supabase_token(token)
    return jsonify(ok=True, authenticated=(status == 200), supabase_status=status,
                   user=user if status == 200 else None)
```

---

## 4. 写 `faas_bundle.json`

```json
{"service": {"slug": "<kebab-slug>", "routes": [
    {"path": "/ping", "methods": ["GET"]},
    {"path": "/items/<item_id>", "methods": ["PUT", "DELETE"]}
  ]},
 "files": {"app.py": "<完整 app.py 源码>", "requirements.txt": "flask==3.0.3\n"}}
```

- 续写已有后端：复用其 `service_id`（放进 `service.service_id`），基于 `faas_services.json` 里的
  现有 `source` 续写，routes 保留旧+新。无关新后端才建新 `service_id`（别超 `max_services`）。

---

## 5. 部署 + 自测（**必须在本轮内自己完成，绝不能只写动作让服务端代劳**）

部署所需环境变量已在你的运行环境里，**在当前 shell 直接运行**（不要 `env -i`/`sudo`/新 shell）：

1. **部署**：`bash backend/faas_deploy.sh $AI_APP_WORKSPACE/faas_bundle.json`
   → 读 `$AI_APP_WORKSPACE/faas_deploy_result.json`：成功含真实 `service_id`+`routes`，失败含 `error`。
2. **失败** → 按 `error` 最小化修 bundle → 重跑第 1 步（≤5 次）。**绝不能编造 service_id。**
3. **成功 → 自测**：`bash backend/faas_invoke.sh <真实service_id> <route> [METHOD] [json体]`
   逐条验证关键接口 200 且结构符合预期（至少一次 GET、一次写操作）。

---

## 6. 写 / 接线 JSON-APP（用 `@faas.*`）

- 顶层 `"dependencies": {"faas": "^1.0.0"}`。
- `global.variables.faasService = "<真实 svc-id>"`（收口；自测拿到的那个）。
- 每个接口调用：
  ```json
  {"call": "@faas.post",
   "args": {"serviceId": "{{ global.faasService }}", "route": "/auth/verify",
            "headers": {"X-User-Token": "{{ global.userToken }}"}, "body": {}},
   "assign": "global.resAuth"}
  ```
- 展示：`{{ global.resAuth.status }}` / `{{ global.resAuth.data }}` / `{{ global.resAuth.error }}`。
- 需要展示后端地址：`{{ app.backendUrl }}/api/faas/invoke/{{ global.faasService }}`。
- 自测过的接口才接进 UI。

---

## 7. 校验 + 发布

- 校验：`python3 backend/validate_json_app.py <app>.json`（0 ERROR）。
- 发布走平台上传路径（v1/v2 各自的上传脚本/动作）；若新增了可复用的 JSON 库，库也要发布到
  Registry（消费方靠 `dependencies` 从 Registry 解析）。

---

## 8. 范本回顾：FaaS 测试台是怎么生成的

判断「需要后端（真实鉴权 + 多种 HTTP 验证）」→ 决策用 `faas` lib + `app` 命名空间，不写死域名
→ 写 `app.py`（7 路由，`/auth/verify` 用 `current_app.config["MYAPP"]` 读 Supabase 配置、`urllib`
真调）→ `faas_bundle.json` → `faas_deploy.sh` 拿到 `svc-77be07ffad7b` → `faas_invoke.sh` 自测全绿
→ JSON-APP 声明 `dependencies:{faas}`、9 个用例调 `@faas.get/post/put/del/sse`、`faasService` 收口
→ `validate_json_app` 通过 → 发布。结果：`smoke_test.py` 11/11，含鉴权拒绝(403)+接受(200)双向。

---

## 9. Checklist（逐条对照再交付）

- [ ] 真的需要后端？纯前端就别建。
- [ ] JSON-APP **零** URL/域名/相对地址；只 `@faas.*(serviceId, route, …)` + `dependencies:{faas}`。
- [ ] 用户 token 走自定义头（`X-User-Token`），不是 `Authorization`；`@get_auth_token` 取。
- [ ] 本 app 函数调用带 `@global.` 前缀。
- [ ] `app.py` 顶层无调用/IO/循环；只 import 白名单（出网用 `urllib`，不要 `requests`）；方法装饰器
      合法；`service.routes` 与装饰器逐一对齐；平台配置读 `current_app.config["MYAPP"]` 不写死域名。
- [ ] **本轮内**真部署 + 自测，拿真实 `service_id` 接好；部署失败按 error 改，绝不编造 id。
- [ ] `validate_json_app.py` 0 ERROR；接进 UI 的接口都自测过。
