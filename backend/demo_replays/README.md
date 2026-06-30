# Demo replays (免登录 super-demo 模式回放数据)

`demo_replay.py` 在 `chat_start` 识别到特殊 UUID 时，回放这里的 jsonl（SSE），
最后用同名 `.app.json` 现场重新上传得到一个**新的**临时链接（避免 24h presigned 过期），
所以用户拿到的是真实可运行的 app。

| 特殊 UUID | base | 说明 | 依赖 |
|---|---|---|---|
| `00000000-0000-0000-0000-000000000001` | `forum_0001` | 论坛/贴吧类全栈 App | 预建公共 FaaS 服务组 `svc-demo-forum` |
| `00000000-0000-0000-0000-000000000002` | `pomodoro_0002` | 番茄钟（纯前端，无后端） | 无 |
| `00000000-0000-0000-0000-000000000023` | `community_forum_0023` | 广场社区·全栈论坛（板块/主题/楼中楼/好友/私信）**真实生成录制** | 公开 FaaS 服务组 `demo-forum`（demo 账号持有 + `access_policy=public`，**已部署**） |

> `community_forum_0023` 是**首个用真实生成落地**的全栈 demo（非占位）：后端 `demo-forum`
> 由 `svc-8b1a1c765dbf`（一次真实论坛生成）的 bundle 以 demo 账号重部署而成，app.json 的
> `global.svc` 收口到 `demo-forum`，免登录回放后可真发帖。`forum_0001` 占位保留不动。

## 文件

- `<base>.jsonl` — 每行一个**业务事件**（就是 SSE `data:` 里的 JSON）；末行 `{"_demo_final": {...}}`
  哨兵重建终态 meta（final_text / client_actions）。回放时遇到 `client_action.type==json_app_ready`
  的事件会把 `url` 替换成现场重新上传 `<base>.app.json` 得到的新链接。
- `<base>.app.json` — 该 demo 真实可运行的 JSON-DSL app。`forum_0001` 的 FaaS 调用必须指向
  `{{backend}}/api/faas/services/svc-demo-forum/invoke/<route>`（预建的公共组）。

## ⚠️ 当前文件是占位（placeholder）

下面的占位文件让整条链路结构完整、可联调，但**正式上线前必须在部署主机用真实生成重录**：

### 录制步骤（部署主机）
1. 预建 demo 账号（真实 Supabase 用户，JWT 可验证）+ 后端 env `DEMO_ACCOUNT_EMAIL/PASSWORD`。
2. 预建公共 FaaS 组 `svc-demo-forum`：部署带 `schema.sql`（每表 `owner text` + `id uuid PK`）的 bundle，
   再 `set_application_policy(owner, svc-demo-forum, public)`，确认 `status==ready`，灌点种子帖子。
3. 设置 env 后跑一次真实论坛生成：
   ```
   AI_DEMO_RECORD_SESSION_ID=<那次生成的 session_id>
   AI_DEMO_RECORD_PATH=backend/demo_replays/forum_0001.jsonl
   ```
   `ai_session` 会把业务事件 tee 成 jsonl。把那次上传的 app.json 存成 `forum_0001.app.json`。
4. 重复一次纯前端番茄钟生成 → `pomodoro_0002.{jsonl,app.json}`。
