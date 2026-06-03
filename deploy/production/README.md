# MyApp Production Control Plane

This directory is the first production-grade slice of the backend control plane.
It is designed for a single host first, then can grow into multiple agent hosts.

## Components

- `myapp-ctl`: host-level control CLI for backend, infra, OpenIM, Supabase, and agent services.
- `myapp-backend`: shared image for backend, ai-worker, registry, config-center, and user-center.
- `myapp-agent-node`: per-host service that owns Docker and starts isolated agent runtime containers.
- `myapp-agent-runtime`: Ubuntu 24.04 execution image used for Claude/Codex runs.

## Important Security Boundary

`AI_WORKER_EXECUTION_BACKEND=agent-node` keeps backend, FCM/APNs, Supabase, OpenIM, and registry
secrets out of the agent runtime container. The runtime receives a structured run payload and
per-run proxy tokens only.

Provider keys are held by backend/agent-node and rewritten by the agent-node provider proxy before
the runtime starts. Claude/Codex see `http://agent-node:5590/proxy/<token>` and a short-lived proxy
token; the real DeepSeek/MiniMax token is not written to payload files and is revoked from
agent-node memory when the run exits.

The default runtime network is `myapp_agent_runtime`, a dedicated Docker network shared only with
`agent-node`. Runtime containers can reach `agent-node` by Docker DNS for provider proxying, but do
not join the backend/Postgres/Redis compose network. They still have normal outbound access for OSS
upload URLs. `host.docker.internal` is not exposed unless `AGENT_NODE_ALLOW_HOST_GATEWAY=1`.

If you run agent-node outside this compose project, set both `AGENT_NODE_DOCKER_NETWORK` and
`AGENT_NODE_PROVIDER_PROXY_BASE_URL`.

## Single-Host IP Test

On `77.237.233.229`:

```bash
cd /opt/myapp/current-agent-control-plane
./deploy/production/install_ctl.sh

export PUBLIC_HOST=77.237.233.229
export MYAPP_IMAGE_TAG=agent-control-plane

myapp-ctl status
myapp-ctl deploy --plan
myapp-ctl deploy --build
myapp-ctl status
```

Backend services need real host-local secrets before they should be started:

```bash
myapp-ctl secret set backend FLASK_SECRET_KEY
myapp-ctl secret set backend SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY
myapp-ctl secret set ai-providers DEEPSEEK_ANTHROPIC_AUTH_TOKEN MINIMAX_ANTHROPIC_AUTH_TOKEN
myapp-ctl secret set agent AGENT_NODE_REGISTRATION_TOKEN
myapp-ctl secret set push APNS_KEY_ID APNS_TEAM_ID FCM_PROJECT_ID
```

Secret values are stored under `/etc/myapp/secrets.d/*.env` with mode `600`.
`myapp-ctl secret ls` prints only redacted digests.

## Deployment Commands

One-command local-source deployment on a test host:

```bash
myapp-ctl deploy --build
```

One-command Docker Hub deployment on a clean host:

```bash
myapp-ctl deploy --pull
```

Deploy one group:

```bash
myapp-ctl deploy --group infra --pull
myapp-ctl deploy --group agent --pull
myapp-ctl deploy --group core --pull
```

Deploy one component:

```bash
myapp-ctl deploy backend --pull
myapp-ctl deploy ai-worker --pull
myapp-ctl deploy agent-node --build
myapp-ctl restart backend
myapp-ctl log backend -f -n 120
```

Manage images directly:

```bash
myapp-ctl image ls
myapp-ctl image build
myapp-ctl image push
myapp-ctl image pull backend
```

## Multi-Host Direction

Worker scheduling combines static `AGENT_NODE_URLS` with registered Redis records and persists a
session-to-node assignment key so later turns keep using the same node.

```bash
myapp-ctl agent register --url http://agent-node:5590 --capacity 4 --label gpu=false
```
