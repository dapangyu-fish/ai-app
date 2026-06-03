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
secrets out of the agent runtime container. The runtime container receives only the structured run
payload and the AI-provider CLI environment required for the selected agent.

Provider-key proxying is still the next security milestone. Until that proxy exists, any provider
token passed to Claude/Codex is visible to that agent process and can still be printed by that
agent. Do not treat containerization alone as a complete provider-key leak fix.

The default agent runtime network is `bridge` so Claude/Codex can reach DeepSeek/MiniMax during the
current transition. After a local provider proxy exists on each agent node, switch
`AGENT_NODE_DOCKER_NETWORK=none` and point provider base URLs at that proxy.

## Single-Host IP Test

On `77.237.233.229`:

```bash
cd /opt/myapp/current
./deploy/production/install_ctl.sh

export PUBLIC_HOST=77.237.233.229
export MYAPP_IMAGE_TAG=agent-control-plane

myapp-ctl status
myapp-ctl deploy agent-runtime
myapp-ctl deploy agent-node
myapp-ctl status agent-node
myapp-ctl log agent-node -n 80
```

Backend services need real host-local secrets before they should be started:

```bash
myapp-ctl secret set backend FLASK_SECRET_KEY
myapp-ctl secret set backend SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY
myapp-ctl secret set ai-providers DEEPSEEK_ANTHROPIC_AUTH_TOKEN MINIMAX_ANTHROPIC_AUTH_TOKEN
myapp-ctl secret set push APNS_KEY_ID APNS_TEAM_ID FCM_PROJECT_ID
```

Secret values are stored under `/etc/myapp/secrets.d/*.env` with mode `600`.
`myapp-ctl secret ls` prints only redacted digests.

## Build And Push

```bash
docker build -f deploy/production/Dockerfile.agent-runtime -t dapangyufish/myapp-agent-runtime:agent-control-plane .
docker build -f deploy/production/Dockerfile.agent-node -t dapangyufish/myapp-agent-node:agent-control-plane .
docker build -f deploy/production/Dockerfile.backend -t dapangyufish/myapp-backend:agent-control-plane .

docker push dapangyufish/myapp-agent-runtime:agent-control-plane
docker push dapangyufish/myapp-agent-node:agent-control-plane
docker push dapangyufish/myapp-backend:agent-control-plane
```

## Multi-Host Direction

The backend should eventually schedule jobs to registered agent nodes instead of one static
`AGENT_NODE_URL`. `myapp-ctl agent register` is reserved for a GitLab Runner-like registration
flow: node id, node token, capacity, running sessions, and heartbeat.
