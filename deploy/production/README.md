# MyApp Production Control Plane

This directory is the first production-grade slice of the backend control plane.
It is designed for a single host first, then can grow into multiple agent hosts.

## Components

- `myapp-ctl`: host-level control CLI for backend, infra, OpenIM, Supabase, and agent services.
- `myapp-backend`: shared image for backend, ai-worker, registry, config-center, and user-center.
- `myapp-agent-node`: per-host service that owns Docker and starts isolated agent runtime containers.
- `myapp-agent-runtime`: Ubuntu 24.04 execution image used for Claude/Codex runs.
- `supabase`: local self-hosted Supabase compose group for auth/profile/storage API support.
- `openim`: local OpenIM compose group for IM credentials and message transport.

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

# First interactive run asks for the CLI language: zh / en / de / es.
myapp-ctl setup --host "$PUBLIC_HOST"
myapp-ctl status
myapp-ctl deploy --plan
myapp-ctl deploy --build
myapp-ctl status
```

After a full `myapp-ctl deploy --build` / `--pull`, the CLI writes and prints the
client Service Environment import payload automatically. It also generates a QR
PNG, and prints an ANSI QR code when the terminal supports it. You can view or
regenerate the same payload later:

```bash
myapp-ctl client-env --host "$PUBLIC_HOST" --name "MyApp Test $PUBLIC_HOST"
myapp-ctl client-env --host "$PUBLIC_HOST" --terminal-qr
```

This writes `/var/lib/myapp/client-environment.json`, generates
`/var/lib/myapp/client-environment.png` when `qrencode` is installed, and prints
the copyable JSON. The payload contains URLs only, no secrets.

`myapp-ctl setup` generates local stack secrets, then interactively configures
the required AI provider credentials. DeepSeek and MiniMax are built-in choices;
custom Anthropic-compatible providers can be added without code changes.
ByteDance ASR, APNs, FCM, and GeTui are optional channels. If you skip them, the
core app and AI generation path still deploy; only speech recognition or push
delivery is unavailable.

You can also run setup separately at any time:

```bash
myapp-ctl setup --host "$PUBLIC_HOST"
myapp-ctl setup --no-ai       # only revisit optional ASR/push config
myapp-ctl setup --no-asr      # skip optional speech recognition config
myapp-ctl setup --no-asr --no-push  # only revisit AI provider config
```

Secret values are stored under `/etc/myapp/secrets.d/*.env` with mode `600`.
For APNs and FCM you can either paste the secret content or enter a server-local
file path, for example `/etc/apns/AuthKey_8NM9U7CJCJ.p8`. `myapp-ctl` copies
the file into `/etc/myapp/secrets.d/files/` and writes the container-visible
path into `push.env`.
`myapp-ctl secret ls` prints only redacted digests.

Host configuration can be inspected, backed up, and restored:

```bash
myapp-ctl config view
myapp-ctl config export --out /root/myapp-config.json
myapp-ctl config export --format yaml --out /root/myapp-config.yaml
myapp-ctl config import /root/myapp-config.json --yes
myapp-ctl config lang zh
```

The restorable export contains host-local secrets and is written with mode
`600`. Use `myapp-ctl config export --redacted --out ...` for review-only
bundles.

## Deployment Commands

Clean all managed services, volumes, state, logs, host-local secrets, installed
compose/config files, and MyApp images:

```bash
myapp-ctl uninstall --yes --purge
./deploy/production/install_ctl.sh
```

Run the first-run setup wizard. It generates local random secrets, asks for AI
provider credentials, and optionally accepts APNs, FCM, and GeTui push config:

```bash
myapp-ctl setup --host <public-ip-or-domain>
```

One-command local-source deployment on a test host:

```bash
myapp-ctl deploy --build
```

If AI provider config is missing, `deploy` starts the same setup wizard when run
from an interactive terminal. In non-interactive shells it fails with a clear
message instead of silently starting without an AI provider.
Long Docker/Compose steps print a heartbeat while running so SSH sessions do not
look idle.

One-command Docker Hub deployment on a clean host:

```bash
myapp-ctl deploy --pull
```

Deploy one group:

```bash
myapp-ctl deploy --group infra --pull
myapp-ctl deploy --group supabase --pull
myapp-ctl deploy --group openim --pull
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

For a full clean source deployment checklist, see
[`SOURCE_DEPLOY_RUNBOOK.md`](SOURCE_DEPLOY_RUNBOOK.md).

## Multi-Host Direction

Worker scheduling combines static `AGENT_NODE_URLS` with registered Redis records and persists a
session-to-node assignment key so later turns keep using the same node.

```bash
myapp-ctl agent register --url http://agent-node:5590 --capacity 4 --label gpu=false
```
