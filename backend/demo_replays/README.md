# Demo replays (免登录 super-demo 模式回放数据)

`demo_replay.py` 在 `chat_start` 识别到特殊 UUID 时，回放这里的 jsonl（SSE），
最后用同名 `.app.json` 现场重新上传得到一个**新的**临时链接（避免 24h presigned 过期），
所以用户拿到的是真实可运行的 app。

带 FaaS 后端的 demo：

| 特殊 UUID | base | 说明 | 依赖服务组（`services/` 已随仓库分发） |
|---|---|---|---|
| `00000000-0000-0000-0000-000000000001` | `forum_0001` | 论坛/贴吧类全栈 App（真实生成录制） | `svc-39e8b9300f41` |
| `00000000-0000-0000-0000-000000000023` | `community_forum_0023` | 广场社区·全栈论坛（板块/主题/楼中楼/好友/私信，真实生成录制） | `demo-forum`（由 `svc-8b1a1c765dbf` 一次真实生成的 bundle 收口而来） |

其余 UUID 均为纯前端 demo，无服务组依赖。完整 UUID→base 映射见 `demo_replay.py` 的
`DEMO_SESSIONS`；demo 选择列表（服务端下发）见 `DEMO_PROMPTS`。

## 文件布局

- `<base>.jsonl` — 每行一个**业务事件**（就是 SSE `data:` 里的 JSON）；末行 `{"_demo_final": {...}}`
  哨兵重建终态 meta（final_text / client_actions）。回放时遇到 `client_action.type==json_app_ready`
  的事件会把 `url` 替换成现场重新上传 `<base>.app.json` 得到的新链接。
- `<base>.app.json` — 该 demo 真实可运行的 JSON-DSL app。若 app 调用 FaaS，服务 ID 烧在
  `"svc"` 变量里，调用走 `{{backend}}/api/faas/invoke/<service_id>/<route>`（后端按 ID 路由，
  与域名/集群无关）。
- `services/<service_id>/` — ★该 demo 依赖的 FaaS 服务组 bundle（`app.py` / `schema.sql` /
  `service.json` / `requirements.txt`，可选 `seed.json`）。**仓库是唯一真相源**：
  `myapp-ctl deploy` 的 demo 装配器在每次部署时自动以 demo 账号将其部署为
  `access_policy=public` 的服务组——新集群开箱即用，无任何手工步骤。
  - `service.json` 的 `service_id` 必须与目录名一致（部署 API 按它保留 ID，
    从而与 app.json 里烧死的 `"svc"` 严格对上）。
  - `seed.json`（可选）— 首次装配成功后按序 invoke 的种子请求：
    `[{"route": "/boards", "method": "POST", "body": {...}}, ...]`；
    body 里 `"$prev.<路径>"` 会替换为上一步响应的对应字段（如 `"$prev.board.id"`）。
- `check_demo_services.py` — 一致性自检：所有 app.json 引用的 `"svc"` 必须在 `services/`
  有 bundle 且 ID 一致。装配器部署前自动跑；改动 demo 后请手动跑一次。

## 新增一个 demo 的完整步骤

1. 在部署主机录制一次真实生成：
   ```
   AI_DEMO_RECORD_SESSION_ID=<那次生成的 session_id>
   AI_DEMO_RECORD_PATH=backend/demo_replays/<base>.jsonl
   ```
   `ai_session` 会把业务事件 tee 成 jsonl；把那次上传的 app.json 存成 `<base>.app.json`。
2. 若 app 带 FaaS 后端：把该服务组的 bundle 放进 `services/<service_id>/`（可加 `seed.json`），
   跑 `python3 backend/demo_replays/check_demo_services.py` 确认一致。
3. `demo_replay.py`：`DEMO_SESSIONS` 加 UUID→base 映射，`DEMO_PROMPTS` 加列表条目（11 语标题/prompt）。
4. **发一版 backend 镜像并升级集群 pin**——回放/app.json/列表随镜像分发，服务组 bundle 随
   源码 checkout 分发；镜像 pin 落后于仓库时，装配器会在部署时告警（"checkout 有、镜像没有"）。

之后任何新集群 `myapp-ctl deploy` 即自动带上该 demo 及其服务组。

## demo 账号

- 每个集群一个专用 Supabase 账号（默认 `demo@example.com`，密码由装配器随机生成并持久化
  在 backend.env 的 `DEMO_ACCOUNT_EMAIL/PASSWORD`）；`/api/auth/demo` 用它做 password grant。
- demo 服务组统一由该账号持有；客户端 demo 会话即该账号登录态，天然与真实用户隔离。
