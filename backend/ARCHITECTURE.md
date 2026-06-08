# Backend Architecture

最后更新：`myapp-ctl` 生产控制面、pull-mode agent-node、隔离运行时。

本文件只描述当前分支的真实运行链路。旧的裸跑 Flask、supervisor、
`POST /chat` 直连 Claude CLI、手工 Redis/OpenIM 部署路径都已经废弃；部署和
运维命令以 [deploy/production/README.md](../deploy/production/README.md) 为准。

## 1. System Overview

生产/测试后端由 `myapp-ctl` 管理，核心服务运行在 Docker Compose 中：

```text
client
  | HTTPS / SSE / WSS
  v
backend:5566
  |-- auth.py                 Supabase auth proxy and require_auth
  |-- claude_chat.py          AI chat API, provider/agent selection, SSE replay
  |-- agent_nodes.py          public/private agent-node registry APIs
  |-- im.py / openim.py       OpenIM token, user search, push-token bridge
  |-- store.py                legacy store routes plus AI/IM upload URL helpers
  |-- bytedance_asr_routes.py ASR websocket proxy
  |
  |-- ai-session-redis        AI queue, session metadata, SSE event streams
  |-- jsonapp-postgres        quotas, device tokens, agent nodes, registry enrichment/social data
  |-- app-minio               JSON apps, media, temporary generated files
  |-- supabase-*              auth, REST, storage-compatible services
  |-- openim-*                IM server, MySQL, Mongo, Redis, Kafka, MinIO
  |
  v
ai-worker
  |
  v
agent-node
  | starts one Docker runtime container per active run
  v
myapp-agent-runtime
  | Claude/Codex/OpenCode CLI with isolated env and mounted workspace
  v
agent-node provider proxy
  |
  v
DeepSeek / MiniMax / custom provider
```

`backend`, `ai-worker`, `registry`, `config-center`, and `user-center` share the
backend image. `agent-node` and `agent-runtime` are separate images so AI
execution can be updated independently from the HTTP API.

## 2. Service Inventory

| Service | Container | Responsibility |
|---|---|---|
| Backend API | `myapp-backend` | Flask/Gunicorn API, auth proxy, AI chat start/status/stream/result, IM bridge, upload endpoints |
| AI worker | `myapp-ai-worker` | Moves accepted chat jobs into the agent pull queue and reconciles failed/finished states |
| Registry | `myapp-registry` | JSON-APP/component publish, resolve, search, namespace, mirror, appid lookup |
| Config Center | `myapp-config-center` | Public client config, APK upload/config links, remote flags |
| User Center | `myapp-user-center` | Admin UI/API for user operations |
| Agent node | `myapp-agent-node` plus optional `myapp-agent-node-<node>` | Pulls jobs, starts runtime containers, proxies provider calls, streams run events back |
| Agent runtime | image only | Ubuntu 24.04 runtime with Claude/Codex/OpenCode tooling and a source snapshot under `/app` |
| Infra | `jsonapp-postgres`, `ai-session-redis`, `app-minio` | Data, queue/session state, object storage |
| Supabase | `supabase-*` | Auth and storage-compatible services |
| OpenIM | `myapp-openim-*` | IM, WebSocket, message storage, OpenIM dependencies |

Persistent state is bind-mounted under the configured data root, normally
`/mnt/myapp`. Docker named volumes are not the source of truth for MyApp data.

Important paths:

```text
/etc/myapp/ctl.json
/etc/myapp/services.json
/etc/myapp/secrets.d/*.env
/etc/myapp/secrets.d/files/**
/mnt/myapp/myapp-config.json
/mnt/myapp/jsonapp-postgres/data
/mnt/myapp/ai-session-redis/data
/mnt/myapp/app-minio/data
/mnt/myapp/agent-node/{state,workspaces,logs}
/mnt/myapp/agent-nodes/<node-id>/
/mnt/myapp/supabase-*
/mnt/myapp/openim-*
```

## 3. Client-Facing AI API

Current AI chat endpoints:

```text
GET  /api/ai/providers?agent_scope=public|private
POST /api/ai/chat/start
POST /api/ai/chat/<session_id>/stream_token
GET  /api/ai/chat/<session_id>/stream?last_id=<redis-stream-id>
GET  /api/ai/chat/<session_id>/result
GET  /api/ai/chat/<session_id>/status
POST /api/ai/chat/<session_id>/abort
```

There is no supported legacy `POST /chat` route in the current control-plane
path.

Chat start request shape:

```json
{
  "session_id": "uuid",
  "messages": [{"role": "user", "content": "..."}],
  "provider": "deepseek",
  "agent": "claude",
  "agent_scope": "public"
}
```

`agent_scope` is explicit:

- `public`: use platform/public agent nodes.
- `private`: use only the signed-in user's private nodes. No automatic fallback
  to public nodes is performed.

Provider and agent choices are also scope-aware. The provider list is built from
online agent nodes plus configured provider metadata; a private-mode request can
only pick providers reported by the user's own private nodes.

## 4. AI Session And SSE Flow

The HTTP request is not the worker lifecycle. The backend stores AI session state
in Redis and clients can reconnect to the same stream.

```text
1. client -> POST /api/ai/chat/start
   - require_auth
   - validate provider / agent / scope
   - check quota and queue limits
   - write session metadata
   - enqueue a job
   - return session_id, status, queue position

2. client -> GET /api/ai/chat/<id>/stream
   - mobile: Authorization header
   - web: short-lived stream_token query param
   - read Redis stream from last_id
   - emit queued/running/result/action/error events
   - emit [DONE] when terminal

3. worker/agent-node continue independently
   - client disconnect does not kill the run
   - client reconnects with last_id
   - /result can recover final text and client_actions after stream loss
```

Redis keys are intentionally short-lived:

```text
ai:session:<session_id>:meta              hash
ai:session:<session_id>:stream            stream
ai:session:<session_id>:abort             string
ai:queue:pending:<provider>               list
ai:queue:running                          hash
ai:queue:running:<provider>               hash
ai:agent_pull:pending                     list
ai:agent_pull:pending:user:<user_id>      list
ai:agent_pull:job:<job_id>                hash with JSON spec/status fields
ai:agent_pull:events:<job_id>             stream
ai:agent_pull:artifact:<job_id>:<path>    string
ai:agent_pull:node_running:<node_id>      set
ai:agent_node:<node_id>                   hash, short-lived compatibility/cache state
```

Session metadata and stream data are TTL-based. The durable source for published
apps and generated JSON files is object storage/Registry, not Redis. Durable
agent-node registration lives in Postgres `agent_nodes`; Redis keeps queue,
assignment, running, stream, and artifact state with TTLs.

## 5. Agent Execution Model

The compose default is pull mode (`AI_WORKER_EXECUTION_BACKEND=agent-pull`):

```text
backend queues job
agent-node polls /api/ai/agent_pull/acquire
backend assigns an eligible job
agent-node starts myapp-agent-runtime container
runtime runs Claude/Codex/OpenCode CLI
agent-node records JSONL logs and streams events/artifacts back
backend writes Redis stream events for clients
```

Pull mode means an extra agent host only needs outbound access to the backend.
It does not need a public inbound port.

The code also contains direct `agent-node` and `local` execution backends for
controlled deployments and development, but they are not the default path in the
production compose files.

Scheduling behavior:

- Each node reports `RUNS`, `CAP`, `QUEUE`, `QMAX`, version, labels, namespace,
  provider list, and supported agents.
- A paused node keeps heartbeating but receives no new work.
- If a node is full, it receives no new job until `RUNS < CAP`.
- Same-session affinity prefers the node that previously handled the session so
  workspace and CLI session state can continue.
- If the bound node is stale, removed, or paused, another eligible node can take
  the job.

`myapp-ctl agent ls` is local-only and current-only: it lists active runtime
containers on the machine where the command is run. Cluster node visibility is
handled by `myapp-ctl agent-node ls`.

## 6. Public And Private Agent Nodes

Public nodes belong to the platform. They are visible in the public namespace
and can serve platform users.

Private nodes belong to one user. Invariants:

- A private registration token can only create a private node for its owner.
- The backend stores only public key, metadata, heartbeat, capacity, and
  provider/agent descriptors.
- Long-lived provider keys stay on the user's private agent host.
- A private node can only pull jobs for its owner.
- `agent-node private ls/status` shows only the current user's node(s).
- Admin `agent-node ls --namespace <user-id>` is required to inspect a user's
  private namespace from the control plane.

The app creates a one-time join token through:

```text
POST /api/ai/private_agent/join_token
```

The private host consumes it with:

```bash
export MYAPP_PRIVATE_AGENT_JOIN_TOKEN='<copied from app settings>'
myapp-ctl agent-node private join \
  --backend https://<backend-host> \
  --node-id my-private-agent \
  --name "My private agent" \
  --provider deepseek \
  --agent claude \
  --capacity 2 \
  --queue-max 10 \
  --pull
```

The join command generates a local keypair, registers the public key, prompts
for local provider configuration if needed, and starts only `agent-node` plus
`agent-runtime`.

## 7. Provider And Agent Abstraction

The backend treats provider configuration as data. Built-in provider templates
can be filled during `myapp-ctl setup`, and custom providers can be added
without changing code if they expose Anthropic-compatible Claude CLI variables.

For Claude-compatible execution, the agent runtime receives environment values
like:

```text
ANTHROPIC_BASE_URL
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
CLAUDE_CODE_EFFORT_LEVEL
```

For Codex-capable providers, provider metadata supplies Codex CLI model/provider
settings. Provider support is exposed to clients as `supported_agents`; for
example a provider can support `claude` only, while another supports both
`claude` and `codex`.

Runtime containers do not receive the real platform provider keys directly.
Agent-node mints short-lived local proxy tokens, forwards provider requests, and
revokes tokens after the run. Private nodes with local provider mode keep their
own long-lived keys in the private host data root.

## 8. Workspace And Artifacts

Agent runtime workspaces are persisted under the data root:

```text
<data-root>/agent-node/workspaces/<user-id>/<session-id>/current
<data-root>/agent-node/workspaces/<user-id>/<session-id>/runs/<job-id>
```

The goal is "one conversation keeps refining one app":

- Later turns in the same session reuse the same workspace when possible.
- The runtime can inspect current JSON, generated assets, templates, prompts,
  validators, and relevant source files under `/app`.
- The final app JSON is uploaded to object storage and emitted as a structured
  client action, not as a free-form markdown tag that the client has to parse.

Client action example:

```json
{
  "client_actions": [
    {
      "type": "json_app_ready",
      "url": "https://..."
    }
  ]
}
```

The backend converts this into SSE/action state for the client and stores the
same terminal state in Redis so reconnecting clients can recover it.

## 9. Deployment Boundaries

Use `myapp-ctl` for all deployment state:

```bash
./deploy/production/install_ctl.sh
myapp-ctl setup --host <public-ip-or-domain> --data-root /mnt/myapp
myapp-ctl deploy --build
myapp-ctl status
myapp-ctl client-env --terminal-qr
```

Routine updates should only touch the changed surface:

```bash
myapp-ctl update
myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user
myapp-ctl deploy agent-node agent-runtime --build --no-setup --no-test-user
```

Do not restart Supabase, OpenIM, Postgres, Redis, or MinIO for ordinary backend,
prompt, validator, or agent-runtime changes unless their config/storage layout
actually changed.

## 10. Failure Modes To Check First

| Symptom | First checks |
|---|---|
| Client says queued forever | `myapp-ctl agent-node ls`, `myapp-ctl log ai-worker`, Redis queue state |
| Agent starts then fails immediately | `myapp-ctl log agent-node`, runtime JSONL under `<data-root>/agent-node/logs/` |
| SSE disconnected but generation continues | client should reconnect with `last_id`; inspect `/status` and `/result` |
| Private mode says offline | private node heartbeat, provider/agent mismatch, node paused, wrong user namespace |
| Provider missing from selector | `GET /api/ai/providers?agent_scope=...`, node provider report, provider-mode local/master config |
| Generated JSON upload failed | backend validator logs, App MinIO health, upload credentials, object path permissions |
| IM token 500 | OpenIM service health, backend OpenIM env, OpenIM admin token/API reachability |

Preferred diagnostic order:

```bash
myapp-ctl status
myapp-ctl agent-node ls
myapp-ctl agent ls
myapp-ctl log backend -n 200
myapp-ctl log ai-worker -n 200
myapp-ctl log agent-node -n 200
curl -fsS http://127.0.0.1:5566/api/ai/providers
curl -fsS http://127.0.0.1:5590/health
```
