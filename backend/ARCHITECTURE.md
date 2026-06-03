# Backend Architecture

最后更新：Redis 队列 + 独立 AI worker daemon 改造。

## 0. 服务概览

后端由 Flask API 进程和独立 AI worker daemon 组成，通过 supervisor 管理：

```
supervisor
├─ ai-app    → gunicorn -k eventlet -w <N> -b 0.0.0.0:5566 app:app
├─ ai-worker → cd backend && python ai_worker_daemon.py
└─ registry → 独立的 registry_server.py（包发布服务，不在本文档范围）
```

供应链：

```
客户端 ─HTTPS─▶ nginx ─▶ ai-app:5566
                       │
                       ├─ Supabase（鉴权 + 用户数据）       127.0.0.1:18000
                       ├─ OpenIM HTTP/WS                  10001-10002
                       ├─ MinIO                            127.0.0.1:19000
                       ├─ Postgres（业务库）                127.0.0.1:5433
                       ├─ Redis (OpenIM 专用)              docker 内网 only
                       ├─ AI session Redis                 127.0.0.1:16379
                       └─ ai-worker → claude CLI            /root/.nvm/.../claude
```

## 1. 模块划分（backend/*.py）

| 文件 | 职责 |
|------|------|
| `app.py` | Flask app 工厂 + 路由注册 + SocketIO 初始化。`eventlet.monkey_patch()` 必须在最前 |
| `config.py` | 全部环境变量集中点，`AI_PROVIDERS` / 数据库 / OpenIM / APNs / 路径常量 |
| `auth.py` | Supabase 鉴权代理（注册/登录/OTP/refresh）+ `require_auth` 装饰器 |
| `claude_chat.py` | **AI 聊天 API**：鉴权、配额、提交 Redis 队列、SSE 读 Redis stream |
| `ai_session.py` | AI session Redis 状态、Redis 队列、Claude CLI worker 执行逻辑 |
| `ai_worker_daemon.py` | 独立消费 Redis 队列并启动 Claude CLI 的 daemon |
| `database.py` | Postgres 连接池 + 配额表读写 |
| `store.py` | 应用市场（apps + components）增删查 |
| `im.py` | OpenIM 桥接（token 签发 / 用户搜索 / 推送 token） |
| `apns.py` | APNs HTTP/2 推送（iOS 端） |
| `openim.py` | OpenIM 管理 API 调用（user_register / update_user_info） |
| `registry_server.py` | 独立服务（不在 ai-app 进程里），包发布 |
| `bytedance_asr_routes.py` + `bytedance_asr_service.py` | 豆包语音 WebSocket |

## 2. AI 聊天当前流（**改造前快照**）

### 2.1 端点

```
POST /chat                     SSE 流式返回 claude CLI 输出
GET  /api/ai/session_status    查询 session 进程是否还活着（轻量）
GET  /api/ai/providers         可用 provider 列表
```

### 2.2 调用链（claude_chat.py: chat()）

```
1. 鉴权 → require_auth
2. 配额检查 → database.get_quota_info
3. 解析 messages / session_id / provider
4. increment_quota（先扣再说，半失败时配额可能损失 1，可接受）
5. yield SSE chunks via generate():
   ├─ 起 subprocess: claude CLI (stream-json output)
   ├─ Popen.stdout 持续 readline
   ├─ 每行解析为 stream_event / assistant / result 类型
   ├─ 转写成业务 SSE 事件 yield 给客户端
   └─ subprocess 结束 → yield "data: [DONE]"
```

### 2.3 进程管理

- `_session_procs: dict[session_id, Popen]`：跟踪每个 session 的活进程
- `_session_procs_lock`：线程锁保护
- `session_status` 端点查 `proc.poll() is None` 判断是否存活

### 2.4 致命弱点（这一轮要修的）

**HTTP 连接 = 任务生命周期**，三处耦合：
1. SSE 是 generator，只在 HTTP 连接活着的时候推
2. eventlet greenlet 跟 HTTP 请求绑定，连接断 → greenlet 退出 → generator GC → 但 subprocess 不会立即被回收（claude CLI 仍在跑）
3. 客户端断了之后，CLI 的 stdout 还在被 `readline` 读，但 yield 没人接 → eventlet 卡住或被 socket hangup 唤醒终止
4. 客户端**重连没有任何接续机制**——只能从头来

实际表现：
- 客户端切后台 → iOS/Android 网络层关 socket → SSE 断 → CLI 进程残留几秒后被 OS / supervisor reload 时清掉，但生成结果**丢了**
- 客户端没法"接着读"——`/chat` 请求是 POST + 推流，没有"按 session_id 续读"的接口

## 3. 改造目标（feat/ai-background-push）

### 3.1 新增 Redis（独立部署）

为什么不复用 OpenIM 的 Redis：
- OpenIM 那个挂在 docker `openim-docker_openim` 内部网络，宿主机 ai-app 进程根本访问不到
- 它配了 `--appendonly yes` 给 OpenIM 做消息持久化；我们的数据是 24h TTL 的会话状态，**目的相反**
- 共用一旦 OpenIM 挂了 / 占满内存，AI 也跟着挂；隔离更稳

新 Redis 配置：
- 容器名：`ai-session-redis`
- 端口：宿主 `127.0.0.1:16379` → 容器 `6379`（仅本地，外网不开）
- 密码：从 `.env` 读 `AI_SESSION_REDIS_PASSWORD`
- 建议开启 appendonly（pending queue / session stream 可在 Redis 重启后恢复），仍保留 TTL 自动清
- `maxmemory 256mb` + `maxmemory-policy allkeys-lru`
- `restart: unless-stopped`

### 3.2 Session 状态模型（Redis 数据结构）

AI session 和全局调度在 Redis 里映射为这些 key：

```
ai:session:<session_id>:meta      Hash    元信息（status / quota / provider / 起止时间）
ai:session:<session_id>:stream    Stream  SSE 事件序列（worker append，客户端按 entry id 续读）
ai:session:<session_id>:abort     String  取消标记，短 TTL
ai:queue:pending:<provider>       List    等待中的 AI 任务，按供应商隔离 FIFO
ai:queue:running                  Hash    全局运行中任务的 worker/lease 元信息
ai:queue:running:leases           ZSet    session_id → lease_until_ms，用于机器总并发和存活判断
ai:queue:running:<provider>       Hash    供应商运行中任务的 worker/lease 元信息
ai:queue:running:leases:<provider> ZSet   session_id → lease_until_ms，用于供应商级并发

session meta / stream 都设 TTL 86400s（24h），完工后自动清。
```

`meta` Hash 字段：
| 字段 | 含义 |
|------|------|
| `status` | `queued` \| `running` \| `done` \| `failed` \| `aborted` |
| `user_id` | 发起用户 |
| `provider` | AI provider id |
| `started_at` | epoch 毫秒 |
| `finished_at` | epoch 毫秒（结束后写） |
| `error` | 失败时的错误文本 |
| `event_count` | stream event 数量（方便 O(1) 查总数） |
| `final_text` | 完成时的最终文本（result 事件里的 text）|
| `queued_job` | 当前排队 job 的 JSON，用于 force restart 时跳过旧 job |

### 3.3 新流程

```
[1] POST /api/ai/chat/start        鉴权 + 配额检查
                                   Redis Lua 原子判断 pending 是否满
                                   未满：写 meta status=queued + RPUSH ai:queue:pending:<provider>
                                   已满：返回 429 AI_QUEUE_FULL

[2] ai_worker_daemon.py            Redis Lua 原子判断全局 running lease 是否低于 AI_WORKER_MAX_CONCURRENCY，
                                   且供应商 running lease 是否低于 <PROVIDER>_AI_WORKER_MAX_CONCURRENCY
                                   有空位：LPOP pending + 写 running lease
                                   daemon 线程池启动 Claude CLI
                                   CLI 输出每行 → Redis stream

[3] GET /api/ai/chat/<id>/stream?last_id=N
                                   SSE 端点可由任意 gunicorn worker 处理
                                   - 先用 Redis Stream 回放 last_id 之后的事件
                                   - queued 时定期发排队状态
                                   - running 但 lease 过期时标 failed + needs_retry
                                   - terminal 后推 [DONE]

[4] GET /api/ai/chat/<id>/result   一次性返回 meta.final_text + status

[5] GET /api/ai/chat/<id>/status   轻量轮询：返回 meta + queue_position + process_alive
```

### 3.4 客户端流程改造

```
sendMessage(text):
   1. POST /chat → 拿 session_id（已有）+ 立即开始流式
   2. 同时 SSE 订阅 /chat/<session_id>/stream
   3. 切后台 → SSE 自然断（iOS/Android 关 socket）
   4. 回前台 → 重新订阅 /chat/<session_id>/stream?last_seq=N
            → 后端从 N+1 重放 + 继续推
   5. 任务结束（meta.status=done）→ 流自动 [DONE]
```

### 3.5 兼容性

- **保留旧 `/chat` 端点 N 个版本**：旧客户端继续走老路（subprocess 直推 SSE，无 Redis）
  - 老客户端不会遇到任何变化
- 新客户端版本号触发新路径：检测到 backend 支持 `/chat/<id>/stream` 时切换
- 配额扣减只发生在 worker 启动前（和现在一致），重复订阅不重复扣

### 3.6 并发控制

- worker 用 `concurrent.futures.ThreadPoolExecutor(max_workers=N)`，N 是机器总上限。
- `AI_WORKER_MAX_CONCURRENCY` / `AI_WORKER_QUEUE_MAX` 保留为全局总并发和默认队列上限。
- `AI_WORKER_PROVIDER_DEFAULT_MAX_CONCURRENCY` / `AI_WORKER_PROVIDER_DEFAULT_QUEUE_MAX` 给未单独配置的供应商设置默认值。
- `<PROVIDER>_AI_WORKER_MAX_CONCURRENCY` / `<PROVIDER>_AI_WORKER_QUEUE_MAX` 覆盖单个供应商，例如 `DEEPSEEK_AI_WORKER_MAX_CONCURRENCY=3`、`MINIMAX_AI_WORKER_QUEUE_MAX=20`。
- `ai_worker_daemon.py` round-robin 轮询各供应商队列；某个供应商队列满时，只拒绝该供应商的新请求。

### 3.7 关键风险点

1. **eventlet + threading 混用**：worker 跑在普通 thread 里调 subprocess + Redis 客户端，eventlet monkey-patch 后 socket 都是协程的——subprocess.Popen 需要小心，**必须用 `redis-py` 而不是 `aioredis`**，要求 `redis>=5.0`（已支持 eventlet patch 后的 socket）
2. **CLI 进程僵尸**：worker 必须 finally 里 `proc.wait()` + `_clear_session_proc`，否则进程表挤爆
3. **Redis 连接池**：用 `redis.Redis(host=..., decode_responses=False)` 单例，按需连接
4. **客户端 abort**：abort 时调 `POST /chat/<id>/abort`，后端 worker 看到 abort flag 杀 CLI 进程

## 4. 部署流程（改动相关）

```
本机：
1. backend/ 改代码 → commit + push 到 feat/ai-background-push
2. 验证测试（本地起 redis 6379 + python app.py）

服务器：
1. ssh + cd /root/ai-app
2. 编辑 backend/.env 加 AI_SESSION_REDIS_PASSWORD
3. docker run ai-session-redis（详见 4.1）
4. git checkout feat/ai-background-push && git pull
5. /opt/ai-app-venv/bin/pip install -r backend/requirements.txt
6. supervisorctl restart ai-app
7. supervisorctl tail -f ai-app stdout 看启动日志
```

### 4.1 启动 ai-session-redis

```bash
source /root/ai-app/backend/.env  # 拿到 AI_SESSION_REDIS_PASSWORD
docker run -d \
  --name ai-session-redis \
  --restart unless-stopped \
  -p 127.0.0.1:16379:6379 \
  redis:7.4-alpine \
  redis-server \
    --requirepass "$AI_SESSION_REDIS_PASSWORD" \
    --maxmemory 256mb \
    --maxmemory-policy allkeys-lru \
    --appendonly yes
```

回滚：`docker rm -f ai-session-redis` —— 不会影响 OpenIM 的 redis。

### 4.2 启动 AI worker daemon

生产必须在启动 Flask/gunicorn 之外，再启动一个 daemon 消费 Redis 队列：

```bash
cd /root/ai-app/backend
BACKEND_ENV_PATH=/etc/ai-app/backend.env /opt/ai-app-venv/bin/python ai_worker_daemon.py
```

确认 daemon 已经启动后，`ai-app` 的 gunicorn worker 数可以按普通 API 吞吐调整。
AI 总并发由 Redis 全局 lease 上的 `AI_WORKER_MAX_CONCURRENCY` 控制，供应商并发由各自 provider lease 控制，不再乘以 gunicorn worker 数。

## 5. 后续阶段（不在本次范围）

- Phase 2：完成时 push 通知（APNs alert + FCM data）
- Phase 3（可选）：iOS Live Activity / Dynamic Island
- Phase 4（可选）：跨设备 session 同步（用户 A 设备发的，B 设备能续）
