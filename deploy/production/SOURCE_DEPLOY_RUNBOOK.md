# Source Deployment Runbook

This runbook describes a clean source deployment on a backend host using
`myapp-ctl`. It intentionally lists secret names only. Do not paste real token
values into this file, shell history, or Git.

## Scope

Validated on `77.237.233.229` with:

- local source tree at `/opt/myapp/current-agent-control-plane`
- Docker + Docker Compose already installed
- production AI provider, Supabase, OpenIM, APNs, FCM, ASR, and Getui secrets
  imported into host-local env files
- newly generated database, Redis, MinIO, Flask, Registry, Agent, Config Center,
  and User Center secrets

OpenIM and Supabase are listed in `services.json` as external Docker containers
for status/log visibility. The `deploy --build` flow deploys MyApp infra,
agent-node, backend, ai-worker, registry, config-center, and user-center.

## Clean Host Flow

Install or refresh the control CLI:

```bash
cd /opt/myapp/current-agent-control-plane
./deploy/production/install_ctl.sh
```

Optional destructive cleanup:

```bash
myapp-ctl uninstall --yes --purge
./deploy/production/install_ctl.sh
```

Generate host-local secrets that do not need human-provided values:

```bash
myapp-ctl secret generate backend \
  JSONAPP_DB_PASSWORD BACKEND_REDIS_PASSWORD \
  APP_MINIO_ACCESS_KEY APP_MINIO_SECRET_KEY \
  REGISTRY_ADMIN_TOKEN FLASK_SECRET_KEY

myapp-ctl secret set backend \
  PUBLIC_HOST=<public-ip-or-domain> \
  MYAPP_IMAGE_TAG=agent-control-plane \
  JSONAPP_DB_USER=jsonapp \
  JSONAPP_DB_NAME=jsonapp \
  AI_WORKER_MAX_CONCURRENCY=20 \
  AI_WORKER_QUEUE_MAX=100 \
  DEEPSEEK_AI_WORKER_MAX_CONCURRENCY=20 \
  DEEPSEEK_AI_WORKER_QUEUE_MAX=100 \
  MINIMAX_AI_WORKER_MAX_CONCURRENCY=5 \
  MINIMAX_AI_WORKER_QUEUE_MAX=20

myapp-ctl secret generate agent AGENT_NODE_TOKEN AGENT_NODE_REGISTRATION_TOKEN
myapp-ctl secret set agent \
  AGENT_NODE_ID=<stable-node-id> \
  AGENT_NODE_CONTAINER_CPUS=2 \
  AGENT_NODE_CONTAINER_MEMORY=2g

myapp-ctl secret generate config-center \
  CONFIG_CENTER_ADMIN_PASSWORD CONFIG_CENTER_SESSION_SECRET
myapp-ctl secret set config-center CONFIG_CENTER_ADMIN_USERNAME=admin

myapp-ctl secret generate user-center \
  USER_CENTER_ADMIN_PASSWORD USER_CENTER_SESSION_SECRET
myapp-ctl secret set user-center USER_CENTER_ADMIN_USERNAME=admin
```

Import or set human-provided production secrets into these groups:

- `ai-providers.env`: `AI_PROVIDER_IDS`, `AI_DEFAULT_PROVIDER`,
  `AI_DEFAULT_AGENT`, `DEEPSEEK_*`, `MINIMAX_*`.
- `backend.env`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
  `SUPABASE_SERVICE_KEY`, `OPENIM_API_URL`, `OPENIM_WS_URL`,
  `OPENIM_SECRET`, `OPENIM_WEBHOOK_SECRET`, `BYTEDANCE_ASR_*`.
- `push.env`: `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`, `FCM_SERVICE_ACCOUNT_PATH`,
  `FCM_PROJECT_ID`, `GETUI_*`.
- `user-center.env`: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`.

Install push credential files outside Git:

```bash
install -d -m 700 /etc/apns /etc/fcm
install -m 600 AuthKey_<key-id>.p8 /etc/apns/AuthKey_<key-id>.p8
install -m 600 service-account.json /etc/fcm/service-account.json
```

Inspect configured keys without revealing values:

```bash
myapp-ctl secret ls
```

Deploy from source:

```bash
myapp-ctl deploy --plan
myapp-ctl deploy --build
```

## Verification

Run:

```bash
myapp-ctl status
curl -fsS http://127.0.0.1:5566/api/ai/providers
curl -fsS http://127.0.0.1:3254/health
curl -fsS http://127.0.0.1:5000/api/v1/public
myapp-ctl agent ls
```

Expected MyApp services after a successful source deployment:

- `agent-node`: running, health `ok`
- `agent-runtime`: image present
- `jsonapp-postgres`: running, health `healthy`
- `ai-session-redis`: running, health `healthy`
- `backend`: running, health `healthy`
- `registry`: running, health `healthy`
- `config-center`: running, health `ok`
- `ai-worker`, `app-minio`, `user-center`: running

Expected provider API shape:

- `deepseek`: configured, `supported_agents=["claude"]`,
  worker limits `20/100`
- `minimax`: configured, `supported_agents=["claude","codex"]`,
  worker limits `5/20`

For a runtime smoke test, submit a tiny agent-node run with a real UUID
`session_id`. Claude CLI rejects non-UUID session IDs.

## Issues Fixed During The 2026-06-03 Drill

- Compose interpolation did not read service `env_file` values. `myapp-ctl` now
  passes `/etc/myapp/secrets.d/*.env` as Docker Compose `--env-file` inputs.
- Config Center did not receive local MinIO settings. The production compose now
  injects MinIO public URL, internal endpoint, access key, and secret.
- Backend MinIO client could only derive its endpoint from public URL. It now
  supports `MINIO_ENDPOINT` and `MINIO_SECURE` overrides for internal Docker
  networking.
- Gunicorn 26 removed the eventlet worker path used by backend. Backend
  requirements now pin `gunicorn>=21.2.0,<26.0.0`.
- Dockerfile backend used unquoted pip version constraints. They are now quoted.
- `myapp-ctl secret ls` no longer shows any token suffix; it only prints length
  and a short SHA-256 digest.

## Validated Result

After a purge and fresh secret import, `myapp-ctl deploy --build` completed in
one pass on `77.237.233.229`. Health checks passed for backend, registry,
config-center, PostgreSQL, Redis, and agent-node. A direct DeepSeek/Claude
agent-node smoke run completed with `returncode=0`.
