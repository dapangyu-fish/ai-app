# RFC：FaaS 横向扩容（多节点 Docker FaaS + 后端二级路由 + 用户私有 faas 节点）

> 状态：**提案（待实现）** · 作者：平台团队 · 创建：2026-06-29
> 关联：`CLAUDE.md` §FaaS 服务组权限模型、`~/faas-b2g2-network-runbook.md`（网络锁定运维手册）、agent-node 集群（`backend/agent_node_registry.py` / `agent_nodes.py`）、`docs/playbooks/faas-jsonapp.md`（FaaS 生成约定）

---

## 1. 背景与问题

当前 FaaS 运行时是**彻底的单机模型**：服务没有节点归属，invoke 直连本机 Docker daemon，容器之间靠 Docker DNS 容器名互通，轮询计数在进程内存里，运行时容器经本机 docker 网桥网关连 Postgres。所有 AI 生成的后端都隐式绑定到「跑了那次 deploy 的那台后端」，无法把负载摊到第二台机器，也无法把某个用户自带的机器接进来跑他自己的服务。

具体地，单机假设硬编码在四个地方：

1. **invoke 直连本机 Docker**。`faas.invoke_service()`（`backend/faas.py:766`）在做完路由白名单、access_policy、限流、注入假名之后，唯一定位上游的调用是 `ensure_local_docker_runtime_for_service(service)`（`backend/faas.py:806`），它直接操作本机 Docker，没有「按 service_id 查承载节点 → 转发到远端节点」的概念。
2. **上游 = 本机 Docker DNS 容器名**。承载层把上游算成 `http://<容器名>:8080`（`backend/faas_store.py:497`，多副本 `_replica_upstream` 在 `backend/faas_store.py:508`），容器名在跨主机时不可解析。
3. **轮询状态是进程内字典**。冷唤醒/路由入口 `ensure_local_docker_runtime_for_service()`（`backend/faas_store.py:1975`）用进程内字典 `_RR_COUNTER`（`backend/faas_store.py:1989-1991`）在本机运行副本间轮询，状态不跨进程/跨主机共享。
4. **服务表没有节点列**。`faas_services` 建表语句（`backend/faas_store.py:313-327`）只有 `service_id/owner_user_id/function_name/status/active_commit/active_path/...`，**没有 `node_id/host/placement`** 任何列。

此外：

- **scale-to-zero reaper 只看本机**。`faas_docker_reaper.reap_once()`（`backend/faas_docker_reaper.py:45-67`）按 label `myapp.faas=1` 列**本机**运行容器后停空闲容器；dashboard/CLI 的 INST 真相 `running_replica_counts()`（`backend/faas_store.py:2179-2198`）也是一次**本机** Docker label 查询。
- **运行时容器的 DB 可达性是本机假设**。运行时容器经 `RUNTIME_HOST=172.18.0.1`（本机 docker 网桥网关）连 Postgres（`backend/faas_userdb.py:34`），远端节点的容器靠这个 IP 连不到中心库。
- **`faas node` CLI 是空头支票**。帮助文本宣传 `faas ls|node|disable|mode`（`scripts/myapp_ctl/`），但 `cmd_faas()`（`scripts/myapp_ctl/`）只有 `health/ls/disable/rm/smoke/ai-action-smoke/e2e/mode/git/config` 分支，**没有 `node` 分支**，传入即落到默认 `return 2`。

值得强调的是：**agent-node 集群早已把「注册表 + 心跳租约 + 通过 acquire 自注册 + 容量门控 + 私有节点 join」整套做成熟了**（见 §5），FaaS 横向扩容应当**照搬这套蓝本**，而不是另起炉灶。

## 2. 目标与非目标

**目标**

- 让一个 FaaS 服务可以**落在某个具体节点**（本机或远端），后端 invoke 时做**二级路由**：按 `service_id` 查承载节点 → 本机走 Docker、远端转发到该节点的内部 invoke 端口。
- 建立 **FaaS 节点注册表 + 心跳**（容量、已部署服务、各服务运行副本数、Docker 健康、build_commit），复用 agent-node 的 TTL 租约判活与 stale/paused/down/online 状态机。
- 支持**用户私有 faas 节点**：用户用自带机器 join 集群，把自己的服务「钉」到自己的私有节点，复用私有 agent-node 的 join-token / 上报公钥 / owner-scoped 管理流程。
- 跨节点不依赖共享文件系统：远端节点起容器时经 **bundle URL** 自拉代码（现成机制，见 §5.2）。
- 补齐 `faas node ls/register/join/status/rm` CLI。
- **不改 FaaS 服务组权限模型**（每服务组一 schema、假名隔离、access_policy 三档、run-token 信任）——横向扩容是放置与路由层的事，与权限层正交。

**非目标（本期不做）**

- 不做「数据跟着节点走」——DB schema 隔离模型不变，DSN 始终指向中心库的同一 schema（私有节点数据本地化是更激进的二期议题，见 §10）。
- 不做单服务多副本跨节点分布（本期坚持「一个 service_id 钉一个节点，节点内部再多副本轮询」，简化路由与计数，见 §4 取舍）。
- 不改 GitHub 源真相模型（`FAAS_GIT_REMOTE` / `faas_push_worker`），只改「代码如何到达承载节点」。
- 不重写 agent-node 注册表去合二为一（FaaS 容量语义与 agent 不同，新建独立注册表，见 §4）。

## 3. 术语

| 术语 | 含义 |
|------|------|
| **FaaS 节点（faas node）** | 一台能承载 FaaS 容器的机器，运行一个 FaaS-agent 周期性向控制面心跳；`public`（平台公共）或 `private`（用户自带）。 |
| **承载节点（placement）** | 某个 `service_id` 被放置到的节点；写入 `faas_services.node_id`。 |
| **控制面（control plane）** | 现有 backend，持有服务表、注册表、签发 run-token / runtime-token、做二级路由与门控。 |
| **二级路由** | invoke 时「先按 service_id 查承载节点，再决定本机 Docker 还是转发远端」的转发层。 |
| **内部 invoke 端点** | 远端节点上 FaaS-agent 暴露的、带节点 token 鉴权的内网 invoke 入口（`/__faas_internal/invoke/<service_id>`），内部再调本地冷唤醒。 |
| **bundle URL** | 控制面按 service 签发的代码整包 HTTP 拉取地址 + runtime token，容器自拉代码，无需共享 FS。 |
| **私有 faas 节点** | `visibility=private`、`owner_user_id=<user>` 的 FaaS 节点；其 owner 的服务可钉到它。 |

## 4. 总体设计

分四层，自上而下。控制面保留所有权限/门控/签名职责；承载节点只负责「在本地把容器跑起来并响应 invoke」，把 cold-wake / 轮询 / reaper 留在节点本地，避免把单机状态跨主机化。

```
                       ┌─────────────────────── 控制面 backend ───────────────────────┐
   client / JSON-APP   │  faas.invoke_service (faas.py:766)                            │
        invoke         │   ├─ 路由白名单 / access_policy / 限流 / 注入假名（沿用，不变）│
   ───────────────────▶│   └─ 【新增】二级路由 locate_node(service)                    │
                       │         ├─ node.local?  → ensure_local_docker_runtime(...)    │
                       │         └─ 远端      → 转发 {node.url}/__faas_internal/invoke/ │
                       │  faas_node_registry（新，照搬 agent_node_registry）           │
                       │   ├─ upsert / TTL 租约判活 / stale|paused|down|online         │
                       │   └─ heartbeat 端点（照搬 acquire：心跳+容量+放置事实一次同步）│
                       │  faas_services.node_id（新列） + 放置决策 place_service(...)   │
                       │  runtime_bundle 签发（已有 faas.py:666）                      │
                       └──────────────┬─────────────────────────────┬─────────────────┘
                                      │ 心跳 / 派活                   │ 转发 invoke（带节点 token）
                  ┌───────────────────▼──────────┐      ┌───────────▼──────────────────┐
                  │  本机节点（node-local）       │      │  远端 / 私有 faas 节点         │
                  │  ensure_local_docker_runtime  │      │  FaaS-agent（照搬 _pull_loop） │
                  │  本机 Docker daemon           │      │   ├─ 心跳上报容量/服务/副本数  │
                  │  _RR_COUNTER 进程内轮询       │      │   └─ /__faas_internal/invoke   │
                  │  reaper（本机）               │      │        → 本地 ensure_local... │
                  └───────────────┬───────────────┘      │        → 本机 Docker + reaper  │
                                  │                       │        代码经 bundle URL 自拉  │
                                  ▼                       └───────────────┬───────────────┘
                       ┌──────────────────────────────────────────────────▼──────────┐
                       │  中心 Postgres（schema 隔离不变；节点经可路由地址 + TLS 连） │
                       └───────────────────────────────────────────────────────────┘
```

**关键设计取舍**

1. **新建 `faas_node_registry`，不与 agent-node 合一**：照搬 `agent_node_registry` 的表/upsert/TTL，但容量语义不同（agent 是并发作业数，FaaS 是承载服务数/内存/容器数），`capabilities` 位置改放 `runtime_image / hosted_service_ids / free_slots / docker_healthy`。
2. **心跳照搬 acquire 模式**：每个 FaaS 节点跑一个 FaaS-agent（类比 `agent_node_service._pull_loop`），周期性 POST `/api/faas/nodes/heartbeat`，**一次同步节点状态、容量、放置事实**，避免控制面反查每台节点的 Docker。
3. **二级路由 = 远端内部 invoke 端口 + 后端反代**：把 `faas.py:806` 改成 `node = locate_node(service); upstream = 本机Docker 或 f"{node.url}/__faas_internal/invoke/{service_id}"`。**cold-wake、轮询、reaper 全部留在承载节点本地**，无需把 `_RR_COUNTER`/Docker DNS 跨主机化，改动面最小。
4. **代码走 bundle URL，不要求共享 FS**；**DB 中心化**，schema 隔离不变。
5. **一个 service_id 只钉一个节点**（节点内部仍可多副本轮询），把跨节点多副本与跨节点计数聚合留到二期。

## 5. 详细设计

> 约定：每条标注「**已实现可复用**」或「**待新增**」。已实现项给出 file:line 锚点。

### 5.1 FaaS 节点注册表与心跳

**已实现可复用（直接蓝本）**

- agent-node 注册表表结构 `backend/agent_node_registry.py:26-50`：`node_id PK / url / capacity / queue_max / build_commit / owner_user_id / visibility(public|private) / auth_public_key / auth_key_id / capabilities JSONB / last_seen_ms / ttl_seconds / paused`。这套字段几乎可原样作为 `faas_nodes` 起点。
- 幂等 upsert `upsert_node(...)` `backend/agent_node_registry.py:168-275`：`ON CONFLICT (node_id) DO UPDATE`，`last_seen_ms` 仅在 `>0` 时更新（`backend/agent_node_registry.py:230`，心跳/非心跳两用，`touch_seen` 参数 `:187`）。
- 列表/读取 `list_nodes()` `backend/agent_node_registry.py:278`。
- 心跳 = acquire 自注册（**最该照搬的形态**）：`agent_pull_acquire()`（`backend/ai_session.py:3532`）一个端点同时做三件事——心跳 upsert 元数据+容量+TTL（`backend/ai_session.py:3575`，`ttl_seconds=max(30, ...)` `:3584`）；容量门控（`if not accept_jobs or active_runs >= capacity: return 204`，`backend/ai_session.py:3599`）；认领作业并把 per-node 运行集写 Redis。节点侧长轮询 `agent_node_service._pull_loop()`（`backend/agent_node_service.py:2021-2083`）自算 `active_runs < capacity` 后 POST acquire，body 携带 `node_id/capacity/queue_max/build_commit/url=pull://<node_id>/ttl_seconds/active_runs`。

**待新增**

- `backend/faas_node_registry.py`：照搬 `agent_node_registry`，`capabilities` 改放 `runtime_image / hosted_service_ids / free_slots / docker_healthy / replica_counts`。
- `POST /api/faas/nodes/heartbeat`（照搬 acquire）：FaaS-agent 上报 `node_id / capacity / free_slots / hosted_service_ids / 各 service 运行副本数 / docker_healthy / build_commit / ttl_seconds`；控制面 upsert + 把 per-node running 写 Redis（key 形如 `faas:node:<id>:running`）。
- `GET /api/faas/nodes` / `GET /api/faas/nodes/<id>` / `DELETE` / pause/resume：照搬 `agent_nodes.py` 的 `list/get/delete/pause` 端点形态（见 §5.5）。
- TTL 判活与状态装饰：照搬 agent-node 的 `_node_expires_in()`（`backend/agent_nodes.py:330-335`）+ `_decorate_node()` 里 `stale|paused|down|online` 的判定（`backend/agent_nodes.py:455-466`）。

### 5.2 二级路由与跨节点代码投递

**已实现可复用**

- 单机定位点 `ensure_local_docker_runtime_for_service(service)`（`backend/faas.py:806`）——invoke 路径上**唯一**找承载的调用，二级路由只需在此分叉。
- invoke 周边能力全部可保留：路由白名单 `_route_allowed`（`backend/faas.py:780`）、access_policy fail-closed `_access_denied_reason`（`backend/faas.py:788`）、限流 `_rate_limited`（`backend/faas.py:795`）、注入假名/data-token + 剥离 client 头 `_build_proxy_headers`（`backend/faas.py:820`）、**冷启动重试**（5 次 + `_cold_markers`，`backend/faas.py:825-850`）。
- 本机冷唤醒 + 轮询 `ensure_local_docker_runtime_for_service()`（`backend/faas_store.py:1975-1992`）：无运行副本则 `_wake_replica_zero()`（`start()` 保留 DSN，镜像过期则重建）；活动文件 `touch_service_activity()`（`backend/faas_store.py` 被 `:1986` 调用）供 reaper 判空闲。
- **跨节点代码投递的现成砖（路径②）**：容器端 `faas_runtime_server._download_runtime_bundle()`（`backend/faas_runtime_server.py:139-155`）用 `MYAPP_FAAS_BUNDLE_URL` + `X-MyApp-FaaS-Runtime-Token` 从控制面 HTTP 拉取整包代码到临时目录，**无需共享文件系统**；控制面侧端点 `faas.runtime_bundle()`（`backend/faas.py:666` 起，路由 `backend/app.py:165-169`）。

**待新增**

- 控制面 `locate_node(service)`：读 `faas_services.node_id` → 查 `faas_node_registry`；节点 stale → 标 `node_offline`（可触发重放置，见 §10）。
- 改 `backend/faas.py:806`：
  ```python
  node = locate_node(service)
  if node.local:
      upstream = ensure_local_docker_runtime_for_service(service)   # 现状逻辑
  else:
      upstream = f"{node.url}/__faas_internal/invoke/{service_id}"   # 转发远端
  ```
  其余转发/重试/流式响应（`backend/faas.py:809-864`）原样复用——内部端点同样可能返回冷启动 5xx，重试逻辑天然适用。
- 远端节点 FaaS-agent 暴露 `POST /__faas_internal/invoke/<service_id>`：**带节点 token 鉴权**，内部调本地 `ensure_local_docker_runtime_for_service`（本地 cold-wake + 本地 `_RR_COUNTER` 轮询 + 本地 reaper 全部不变）。
- 远端节点起容器时**启用路径②**：`_start_local_docker_runtime`（`backend/faas_store.py:1835` 起）当前只挂卷不设 bundle 环境变量；新增注入 `MYAPP_FAAS_BUNDLE_URL=<控制面>/api/faas/runtime_bundle/<service_id>` + `MYAPP_FAAS_RUNTIME_TOKEN`（控制面已有 per-service token 签发，见 §5.4），容器自拉代码，节点本地无需 `myapp-faas-services` checkout。

### 5.3 放置（placement）

**已实现可复用**

- `faas_services` 表（`backend/faas_store.py:313-327`）——叠加 `node_id` 列即可，DDL 沿用现有 `db_execute` 建表/`ALTER TABLE ADD COLUMN IF NOT EXISTS` 模式（参照 `agent_node_registry` 的就地迁移写法 `backend/agent_node_registry.py:53` 起）。
- DB 定位 `_db_tenant_key()`（`backend/faas_store.py:961` 起；新服务组 `app_id=service_id` 各自独立 schema，legacy `appd-<owner>` 复用 owner 旧库），DSN 由 `faas_userdb.dsn_for_user()`（`backend/faas_userdb.py:402` 起）派发——**与节点正交，放置不影响 DSN**。

**待新增**

- `faas_services.node_id TEXT NOT NULL DEFAULT ''`（空 = 本机节点）。
- `place_service(service, owner)`：deploy 时选节点。策略：`free_slots` 优先；同 owner 服务尽量同节点（共享同库网络）；私有服务**钉到 owner 的私有节点**。写入 `node_id`。
- 状态一致性沿用 TTL：节点 stale → 该节点上的服务标 `node_offline`，可重新放置（重放置天然满足代码可得性，因路径② 不依赖节点本地 FS）。

### 5.4 节点信任与 run-token

**已实现可复用**

- 可信 owner 判定 `faas._request_user_id()`（`backend/faas.py:99-140`）：优先级 = 后端签发 run-token（`mint_run_token`/`_verify_run_token`，`backend/faas.py:244-270`，agent-node 无 `FAAS_RUN_TOKEN_SECRET` 不能伪造）> `X-MyApp-Agent-Node-Token`（== `AGENT_NODE_TOKEN`）+ owner 头 > Bearer。
- per-service runtime token 已有（`runtime_token_for_service` / `runtime_bundle_for_service`，由 `backend/faas.py:666` 起的 `runtime_bundle()` 使用）——bundle 拉取的鉴权砖已就位。
- 私有节点双认证模板：私有 agent-node 的 `_private_pull_jwt` + 节点公钥签名（见 §5.5）。

**待新增**

- 每节点独立的节点 token（用于 `/__faas_internal/invoke` 鉴权与心跳鉴权），**不复用平台级 `AGENT_NODE_TOKEN`**——尤其私有节点不能持平台级 token（见 §7）。
- 多节点下是否默认开 `FAAS_REQUIRE_RUN_TOKEN`（当前默认关）的决策，见 §10。

### 5.5 私有 faas 节点（用户自带机器）

**已实现可复用（直接模板）**

- 一次性 join token 签发 `create_private_agent_join_token()`（`backend/agent_nodes.py:659-728`）：`URLSafeTimedSerializer` + Redis 一次性消费，回传完整 `join_command`（`myapp-ctl agent-node private join ...`，`backend/agent_nodes.py:711-718`）。
- 私有节点注册 `create_private_agent_node()`（`backend/agent_nodes.py:731-788`）：校验 join token 身份，要求节点**上传公钥**（`public_key`），`visibility=private / owner_user_id=<user> / url=pull://<node_id>`，labels 打 `visibility=private`。
- owner-scoped 管理端点 `list_private_agent_nodes`（`backend/agent_nodes.py:603`）、delete/pause/resume/limits（`backend/agent_nodes.py:798` 起），路由 `backend/app.py:121-128`。

**待新增**

- FaaS 版 join token + `POST /api/faas/private_nodes`（照搬上面四个端点，把注册写入 `faas_node_registry` 而非 `agent_nodes`）。
- 私有 faas 节点的 FaaS-agent：join 后启动，跑 §5.1 心跳 + §5.2 内部 invoke 端点；鉴权复用节点公钥签名 / 私有 JWT。
- 「钉服务到私有节点」：`place_service` 对私有服务把 `node_id` 设为 owner 的私有 faas 节点（见 §5.3）。

### 5.6 reaper / 副本计数的多节点形态

**已实现可复用**

- 本机 reaper `faas_docker_reaper.reap_once()`（`backend/faas_docker_reaper.py:45-67`，flock 单实例）、本机副本计数 `running_replica_counts()`（`backend/faas_store.py:2179-2198`）——在「一个 service 钉一个节点」前提下，**每台节点各自跑本机 reaper、各自上报本机计数**即可，逻辑不必改，只是从「控制面直查」改为「节点心跳上报 + 控制面聚合」。

**待新增**

- 控制面聚合视图：dashboard 的 INST 计数改为读各节点心跳上报的 `replica_counts`（最终一致，接受 TTL 滞后），不再直查本机 Docker。
- 节点本地的 reaper 不变（仍只管本机）；冷唤醒跨节点由远端内部 invoke 端点在节点本地完成。

### 5.7 `faas node` CLI 补齐

**已实现可复用**

- `cmd_faas()`（`scripts/myapp_ctl/`）现有 `health/ls/disable/rm/...` 分支与 `_http_request_json` / 操作员 token 注入（`scripts/myapp_ctl/`）可直接复用。
- 私有节点 join 落地与注册 timer：私有 agent-node 的 `_join_private_agent_node`、本机注册命令 `_local_agent_node_register_command()`（`scripts/myapp_ctl/`）+ systemd timer `_ensure_local_agent_node_registration_timer()`（`scripts/myapp_ctl/`）。

**待新增**

- `cmd_faas` 增 `node` 分支：`faas node ls` / `register` / `join` / `status` / `rm`，直接调 §5.1/§5.5 新端点；`join` 复刻私有 agent-node 的 systemd/容器落地。帮助文本宣传的 `faas node`（`scripts/myapp_ctl/`）至此兑现。

## 6. 数据模型 / 接口汇总

| 对象 | 位置 | 状态 |
|------|------|------|
| `faas_nodes`（注册表） | 平台 Postgres，新模块 `faas_node_registry.py` | **新增**，照搬 `agent_nodes`（`agent_node_registry.py:26-50`） |
| `faas_services.node_id` | 平台 Postgres，`faas_store.py:313` 加列 | **新增**（默认 `''`=本机） |
| Redis `faas:node:<id>:running` | Redis | **新增**，per-node 运行集（照搬 acquire 的 per-node running） |
| `POST /api/faas/nodes/heartbeat` | 控制面 | **新增**，照搬 `agent_pull_acquire`（`ai_session.py:3532`） |
| `GET/DELETE /api/faas/nodes[/<id>]` + pause/resume | 控制面 | **新增**，照搬 `agent_nodes` 端点（`app.py:115-119`） |
| `POST /api/faas/private_nodes` + join_token | 控制面 | **新增**，照搬私有 agent-node（`agent_nodes.py:659/731`，`app.py:121-128`） |
| `POST /__faas_internal/invoke/<service_id>` | 远端节点 FaaS-agent | **新增**，节点 token 鉴权 |
| `runtime_bundle` 端点 + 容器自拉 | `faas.py:666` / `faas_runtime_server.py:139` | **已实现**，远端起容器时启用 |
| invoke 二级路由分叉 | `faas.py:806` | **改造**（现状直连本机 Docker） |
| `faas node` CLI 子命令 | `myapp_ctl/faas.py` | **新增**（现帮助文本已宣传，`cli.py`） |

## 7. 安全与防滥用

1. **节点信任最小化**：远端/私有节点持平台级 `AGENT_NODE_TOKEN` 即可冒充 operator（如 `list_user_services?all_users=1` fail-closed 要这个 token，`backend/faas.py:361-364`）。多节点下**每节点发独立 token**，私有节点**绝不持平台级 token**；内部 invoke 与心跳都用节点专属 token。
2. **权限层不变**：access_policy（owner-only/allowlist/public）fail-closed、假名隔离、`myapp_data` 中介、run-token 信任全部保留在控制面（`backend/faas.py:99-140` / `:780-820`），二级路由只在门控**之后**转发，远端节点拿不到原始 token，也无法绕过策略。
3. **代码投递鉴权**：bundle 拉取用 per-service runtime token（`backend/faas.py:666` 起），节点拿到的代码限本服务；token 短时效，不入函数运行时长期环境。
4. **DB 跨网络可达性加固**：中心 PG 对远端/私有节点暴露须加 TLS + IP allowlist；运行时 role 已是 DML-only / NOLOGIN-owner 分离 + 每租户随机口令 Fernet 加密（`backend/faas_userdb.py:39-49`），跨网络再叠加证书/专用 least-priv role。对齐 `~/faas-b2g2-network-runbook.md`。
5. **私有节点不可信前提**：私有节点是用户自己的机器，不得承载他人服务、不得读他人 schema；放置层强制「私有服务 → owner 私有节点」「他人服务 → 仅公共节点」。
6. **心跳真相边界**：节点上报的 `replica_counts/free_slots` 仅用于展示与放置参考，**不作为权限判定依据**；权限始终由控制面验证 JWT/run-token 决定。

## 8. 兼容性与迁移

- **存量服务零迁移**：`faas_services.node_id` 新列默认 `''`；空值即「本机节点」，invoke 二级路由对空值直接走现状 `ensure_local_docker_runtime_for_service`（`backend/faas.py:806`）——存量全在主机 77 的服务行为不变。
- **DB 隔离模型不变**：`_db_tenant_key`（`backend/faas_store.py:961`）与 DSN 派发不动；服务无论落哪个节点，DSN 仍指向中心库同一 schema，零数据迁移、零数据丢失。
- **节点回填**：可选一次性回填——把存量服务 `node_id` 显式写为「本机节点 id」并把主机 77 注册为第一个 public faas 节点；回填前 reaper/invoke 对 `node_id=''` 与显式本机 id 双写兼容。
- **GitHub 源真相不变**：`FAAS_GIT_REMOTE` / `faas_push_worker` / serve checkout 链路不动，只新增「节点经 bundle URL 取代码」这条投递路径。
- **老 CLI 兼容**：`faas node` 是纯新增子命令，不影响 `health/ls/disable/rm/...`。

## 9. 分期实施计划

**P1 · 注册表 + 心跳 + node_id（不改 invoke 路径，先建底座）**

1. 新建 `faas_node_registry.py`（照搬 `agent_node_registry`）+ `POST /api/faas/nodes/heartbeat`（照搬 `agent_pull_acquire`）+ list/get/delete/pause/resume 端点。
2. `faas_services` 加 `node_id` 列；把主机 77 注册为首个 public 节点并回填存量服务为本机 id。
3. FaaS-agent 雏形：在本机后端进程内/旁路跑心跳上报（容量、`hosted_service_ids`、本机 `running_replica_counts` 结果、`docker_healthy`）。
4. dashboard/CLI 计数真相从「控制面直查本机 Docker」切到「读节点心跳聚合」。
5. `faas node ls/status` CLI。

**P2 · 二级路由 + 跨节点代码投递（接入第二台公共节点）**

6. 控制面 `locate_node` + 改 `faas.py:806` 分叉（本机 / 远端转发）。
7. 远端节点 FaaS-agent 暴露 `/__faas_internal/invoke/<service_id>`（节点 token 鉴权），内部调本地 cold-wake。
8. 远端起容器启用 bundle URL（`_start_local_docker_runtime` 注入 `MYAPP_FAAS_BUNDLE_URL` + runtime token）。
9. 中心 PG 对远端节点的 TLS + IP allowlist + 每节点 least-priv role。
10. `place_service`（`free_slots` + 同 owner 亲和）；节点 stale → `node_offline` 标记。

**P3 · 私有 faas 节点 + 加固**

11. FaaS 版 join token + `POST /api/faas/private_nodes`（照搬私有 agent-node）；`faas node join/register/rm` CLI。
12. 私有服务钉到 owner 私有节点；放置隔离强制（私有/他人服务不混跑）。
13. 每节点独立 token + 多节点下 `FAAS_REQUIRE_RUN_TOKEN` 默认策略评估；审计入 `faas_audit_log`。
14. 节点离线时 invoke 行为定义（503 vs 重放置）、私有节点 SLA / 唤醒形态。

## 10. 开放问题

1. **放置粒度**：服务组（FaaS+DB）整体一个节点，还是允许同组多副本跨节点？跨节点多副本要求 reaper/计数跨节点聚合（`running_replica_counts` 改为查所有承载节点）——本期非目标，二期再议。
2. **失败转移**：承载节点离线时，invoke 返回 503 还是触发「重放置到健康节点 + 重启容器」？重放置需新节点可得代码（路径② 天然满足）。
3. **负载在哪决策**：若坚持「一个 service_id 钉一个节点」，则无需跨节点加权挑选；一旦放开多副本跨节点，是否引入类似 `_select_agent_node_url`（`backend/ai_session.py:2783`）的一致性哈希？
4. **DB 网络安全模型**：中心 PG 对远端/私有节点的暴露形态（cert-auth？每节点专用 least-priv role？隧道/边车？）需与 `~/faas-b2g2-network-runbook.md` 对齐。
5. **节点 token 体系**：每节点独立 token 的签发/轮换/吊销，以及 `FAAS_REQUIRE_RUN_TOKEN` 是否在多节点默认开启。
6. **状态一致性真相源**：INST 计数从「直查本机 Docker」转「心跳上报聚合」后有 TTL 滞后，dashboard 接受最终一致还是提供「按需现拉某节点」的强一致入口？
7. **私有节点离线体验**：用户机器随时离线，私有 faas 服务的 SLA、离线时 invoke 行为、唤醒（WoL/常驻）需明确定义。
8. **私有节点数据本地化（远期）**：是否允许私有服务的 DB schema 落在节点本地 PG 而非中心库？这是「数据跟着节点走」，与本期「DB 中心化」相悖，需单独 RFC。

---

**实现完成后**：把 FaaS 节点注册表/心跳/二级路由/私有 faas 节点的契约回流到 `CLAUDE.md` §FaaS 服务组权限模型与 `docs/playbooks/faas-jsonapp.md`；把跨节点 DB 网络与节点 token 模型回流到 `~/faas-b2g2-network-runbook.md`；把 `faas node` 子命令回流到 `myapp-ctl` 帮助与运维文档。
