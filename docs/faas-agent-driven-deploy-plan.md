# FaaS 生成：Agent 自闭环部署 方案（待评审）

> ⚠️ **运行时已更新(2026-06):FaaS 默认运行时已从 OpenFaaS/faasd 迁移到自研 Docker FaaS**(`FAAS_DEPLOY_MODE=local-docker`:容器即服务,控制面自管 部署/路由/冷唤醒/scale-to-zero/扩缩容,无 OpenFaaS CE 的 15 函数上限)。faasd/OpenFaaS 仅作为可选 legacy 模式保留。当前运行时与运维以 `docs/faas-docker-runtime.md` 为准;本文档中涉及 faasd/OpenFaaS 安装与网关的部分按 legacy 看待。

## 0. 目标
让生成后端的 JSON-APP **真的能连上它自己的后端**，由 **AI Agent 在 run 内全程主导**：
部署 → 拿真实 `service_id`/报错 → 自修重部署 → 自测后端 → 用真实 id 回改 JSON-APP → 上传。
弃用「服务端事后部署 + 盲改写 service_id」的脆弱兜底。

## 1. 为什么现在是坏的（已实测确认）
- 客户端 `DslHttpClient._resolveUrl()` 会把相对 `/api/...` 拼 `AppConfig.backendUrl`，**域名没问题**。
- 但生成的 app.json 里 invoke 用的是 AI 的 **slug**（如 `bookmark-api`），后端只认真实 `svc-xxx` → **404 → 点了没反应**。
- 服务端有 `_rewrite_faas_invoke_service_id`（slug→真实 id）兜底，但：
  - 只在 `server_upload_app_json`（服务端上传）路径跑；`upload_with_signature.sh` 有密钥时直传写 `json_app_ready` → 绕过；
  - 且依赖动作顺序（app 动作排在 faas 部署动作前则 `deployed_faas` 为空）→ 时灵时不灵。
- 根因：**Agent 生成时还不知道真实 id（id 是部署时分配的），却又没有 in-run 部署手段**，只能靠服务端事后补，不可靠。

## 2. 硬约束
Agent 运行时是**隔离**的：只拿到 LLM provider proxy token（`ANTHROPIC_BASE_URL=agent-node/proxy/<token>`），
**没有用户 access token、不直连后端 faas API、没有任何部署密钥**。所以「只靠提示词」不够，必须先补一段
**owner 级 scoped 的部署/调用通道**（仍不给 Agent 真密钥）。

## 3. 目标流程
```
1. 写 faas_bundle.json（service.routes 与 app.py @decorator 逐一对齐）
2. 部署: bash backend/faas_deploy.sh $AI_APP_WORKSPACE/faas_bundle.json
        → 读 $AI_APP_WORKSPACE/faas_deploy_result.json {ok, service_id, routes, error}
3. 失败 → 读 error 最小化修 bundle → 回 2（≤ FAAS_AGENT_DEPLOY_MAX_ATTEMPTS 次）
4. 成功 → 自测: bash backend/faas_invoke.sh <service_id> <route> [METHOD] [json]
        逐条验证关键路由 200 + 结构符合预期
5. 测试不过 → 修 app.py/bundle → 回 2
6. 测试通过 → 用【真实 service_id】回改 JSON-APP 所有 /api/faas/invoke/<id>/…
        （相对地址，客户端自动拼域名；禁止生成"让用户手填 URL"的输入框）
7. validate_json_app.py → upload_with_signature.sh 上传 app.json
```

## 4. 架构：复用 agent-node 代理模式
新增一条 **per-run faas 代理**，与现有 LLM provider proxy 同构：
- Agent 调 `{agent-node}/faas/<run_token>/deploy`、`/faas/<run_token>/invoke/<id>/<route>`。
- agent-node 用 `_proxy_lookup(run_token)` 取回该 run 的 `owner_user_id`，注入**可信内部鉴权**后转发到
  `{PULL_BACKEND_URL}/api/faas/deploy`（及 `/invoke/...`），把后端响应原样回给 Agent。
- run_token 短期、只能操作本 run owner 的服务；Agent 始终**不持有用户 token / 真密钥**。

## 5. 改动清单（按文件）

### A. backend/agent_node_service.py（新增 faas 代理）
1. `_issue_faas_proxy_token(run_id, owner_user_id)`：仿 `_issue_proxy_token`，存 `{owner_user_id, expires_at}`。
2. 启动 runtime 前注入 env：`MYAPP_FAAS_PROXY_URL = {PROVIDER_PROXY_BASE_URL}/faas/<token>`（仿 `_prepare_provider_proxy`）。
3. 新路由 `@APP.route("/faas/<token>/<path:subpath>", methods=[POST,GET])`：校验 token → 取 owner →
   转发到 `{PULL_BACKEND_URL}/api/faas/<subpath>`，带内部鉴权头 `X-MyApp-Agent-Node-Token: NODE_TOKEN` +
   body 注入 `owner_user_id`。
4. 鉴权中间件放行 `/faas/`（line 175 那处 `startswith("/proxy/")` 旁加 `/faas/`）。
5. run 结束时一并 revoke faas token。

### B. backend/faas.py（可信内部鉴权路径）
1. `_request_user_id()` 增加：若带合法 `X-MyApp-Agent-Node-Token`（== 后端侧已知 NODE_TOKEN/内部 secret），
   则信任 body 的 `owner_user_id`，绕过用户 Bearer 要求。**仅此可信头可指定 owner**。
2. `deploy_service()` / `invoke_service()` 自动受益（都走 `_request_user_id`）。
3. 配额、owner 归属校验不变（仍按解析出的 owner_user_id）。

### C. backend/faas_deploy.sh（新，Agent 侧；仿 upload_with_signature.sh）
- 入参：faas_bundle.json 路径。
- 读 `MYAPP_FAAS_PROXY_URL`，`curl -X POST $MYAPP_FAAS_PROXY_URL/deploy -d @bundle`。
- 把响应 JSON 写到 `$AI_APP_WORKSPACE/faas_deploy_result.json`（`{ok, service_id, routes, error}`），
  并 stdout 打印精简结果给 Agent 看。
- 无 `MYAPP_FAAS_PROXY_URL`（本地/非隔离调试）时回退：直接 POST `BACKEND_INTERNAL_URL/api/faas/deploy`。

### D. backend/faas_invoke.sh（新，Agent 侧自测）
- 入参：`<service_id> <route> [METHOD=GET] [json-body]`。
- `curl $MYAPP_FAAS_PROXY_URL/invoke/<service_id>/<route>` → stdout 打印 status+body 给 Agent 判断。

### E. backend/ai_session.py（提示词工作流 + 退役旧路径）
1. `_build_faas_backend_prompt_note`：替换为「§3 目标流程」全文（v1/v2 共享，一处生效）。
   - 明确：**不要**再写 `server_deploy_faas_service` 动作；部署只走 `faas_deploy.sh`。
   - 明确：回改 app.json 用真实 service_id；**禁止**生成让用户手填 URL 的输入框。
2. `_FAAS_GEN_EXAMPLE`：few-shot 末尾补「部署→自测→回改→上传」的命令序列示例。
3. 退役：`_SERVER_FAAS_ACTION`（server_deploy_faas_service）处理 + `_rewrite_faas_invoke_service_id` 调用，
   连同上一版加的 faas repair-loop（②）—— 因为现在由 Agent 自己 deploy+repair，服务端不再代劳。
   先保留函数体但不再挂载（灰度回退方便），或直接删，评审时定。

### F. agent-node 镜像
`faas_deploy.sh`/`faas_invoke.sh` 放在 `backend/`（Agent 已能 `bash backend/upload_with_signature.sh`，
同目录即可用）。需确认 agent-runtime 镜像把 `backend/` 这两个脚本 COPY 进去 + `curl` 可用。

## 6. 安全
- Agent 仅获 per-run、owner 级 scoped 的 faas proxy token；**不接触用户 token、git/openfaas 密钥**。
- 仅 agent-node（持 NODE_TOKEN）能通过 `X-MyApp-Agent-Node-Token` 指定 owner；该头只在内网 agent-node→backend 间使用。
- run 结束 token 立即 revoke；token 短 TTL。
- 配额/owner 归属仍由后端按真实 owner 校验，Agent 不能越权部署到别人名下。

## 7. 开放问题（评审定）
1. **invoke 自测是否要鉴权**：`invoke_service` 现在客户端也在调，可能本就不要 owner 鉴权 → faas_invoke.sh 可直连/免注入。需核对 `invoke_service` 鉴权。
2. **FAAS_REQUIRE_AUTH 当前在 77 是否开**：若开，B 步的内部鉴权头是必须的；若关，body `owner_user_id` 即可（但生产应按"开"设计）。
3. **旧 server 端 deploy/rewrite/repair-loop**：直接删还是灰度保留（env 开关）。
4. **agent-node 到 backend 的网络**：确认 runtime 容器能到 agent-node 的 `/faas/` 代理（与 LLM 代理同 host:port，应通）。
5. **本地 local-docker agent 模式**（非 pull）是否也要这条通道，还是仅 pull-agent。

## 8. 验证
- 单测：deploy_service 内部鉴权路径、faas 代理转发注入 owner。
- e2e：触发一次生成 → 看 Agent 日志里 faas_deploy.sh→拿到 svc-id→faas_invoke 自测→app.json 写入真实 id →
  最终客户端 app.json 的 invoke id 是 `svc-xxx`（不是 slug）→ 真机点按钮成功调后端。
- 回归：纯前端（无后端）生成不受影响。
