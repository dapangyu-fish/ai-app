# MyApp Deployment Guide

This is the only supported backend deployment guide. Older supervisor,
standalone IM, test-environment, and one-off migration paths have been removed
from the documentation.

The supported entrypoint is `myapp-ctl`, installed from this directory.

## What It Deploys

`myapp-ctl` manages one single-host stack:

- MyApp core: backend API, AI worker, Registry, Config Center, User Center
- Infra: JSON app Postgres, AI session Redis, App MinIO
- Auth/storage: self-hosted Supabase compose group
- IM: OpenIM compose group
- AI execution: agent-node plus isolated Ubuntu agent runtime containers

The backend image is shared by `backend`, `ai-worker`, `registry`,
`config-center`, and `user-center`. Agent execution is split into:

- `myapp-agent-node`: host service that owns Docker and starts runtime containers
- `myapp-agent-runtime`: Ubuntu 24.04 image used for Claude/Codex runs

## Security Model

Host and service secrets live outside Git:

- `/etc/myapp/ctl.json`: host-local control configuration
- `/etc/myapp/services.json`: service inventory installed by `install_ctl.sh`
- `/etc/myapp/secrets.d/*.env`: service secrets, mode `600`
- `/etc/myapp/secrets.d/files/**`: APNs/FCM file secrets copied by setup
- `<data-root>/myapp-config.json`: restorable encrypted-by-permission bundle,
  mode `600`

The default data root is `/mnt/myapp`.

Agent runtime containers do not receive backend, Supabase, OpenIM, push, or real
provider keys. They receive a run payload and short-lived provider-proxy tokens.
Claude/Codex talk to `http://agent-node:5590/proxy/<token>`; agent-node rewrites
that request to DeepSeek/MiniMax and revokes the proxy token after the run.

The runtime image includes the source needed for JSON-DSL inspection:
`backend/`, `lib/`, `assets/`, `test/`, `templates/`, `docs/`, `scripts/`,
`JSON-DSL.md`, and Flutter metadata. It does not include `.git`, build outputs,
website sources, or host-local secrets.

## First Install

Start from a source checkout on the host:

```bash
cd ~/ai-app  # or any real git checkout of this repository
./deploy/production/install_ctl.sh
```

`install_ctl.sh` records the checkout path in `/etc/myapp/ctl.json` as
`paths.source`; later `myapp-ctl deploy --build` uses that path as the Docker
build context.

First interactive use asks for the CLI language once: `zh`, `en`, `de`, or
`es`. Change it later with:

```bash
myapp-ctl config lang zh
```

Run setup:

```bash
myapp-ctl setup --host <public-ip-or-domain> --data-root /mnt/myapp
```

Setup generates local stack secrets, then asks for human-provided values:

- AI providers: DeepSeek, MiniMax, or custom Anthropic-compatible providers
- Optional ASR: ByteDance/Doubao speech recognition
- Optional email: Supabase SMTP/auth email settings
- Optional push: APNs, FCM, and GeTui

AI provider config is required for app generation. ASR, email, and push are
optional; skipping them only disables those channels.

For APNs and FCM, either paste the secret content or enter a server-local file
path such as `/etc/apns/AuthKey_8NM9U7CJCJ.p8`. `myapp-ctl` copies files into
`/etc/myapp/secrets.d/files/` and writes container-visible paths into `push.env`.

Inspect configured keys without revealing values:

```bash
myapp-ctl secret ls
```

## Full Deploy

Build images from local source:

```bash
myapp-ctl deploy --plan
myapp-ctl deploy --build
```

Or pull images on an image-based host:

```bash
myapp-ctl deploy --pull
```

If AI provider config is missing, interactive deploy starts the setup wizard. In
non-interactive shells it fails and tells you to run setup explicitly.

A full deploy:

- creates the complete data-root directory tree up front
- starts infra, Supabase, OpenIM, agent-node, backend, worker, Registry, Config
  Center, and User Center
- writes `<data-root>/state/client-environment.json`
- writes `<data-root>/state/client-environment.png` if `qrencode` is installed
- prints a copyable client environment JSON and terminal QR code
- can create/update a test user

Default test user:

- email: `test@example.com`
- username: `test`
- password: entered interactively by the deploy operator

Skip test user creation:

```bash
myapp-ctl deploy --build --no-test-user
```

Use a non-interactive password without putting it in shell history:

```bash
MYAPP_TEST_USER_PASSWORD='change-me' myapp-ctl deploy --build
myapp-ctl deploy --build --test-user-password-file /root/test-user-password.txt
```

Show the client import payload again:

```bash
myapp-ctl client-env --host <public-ip-or-domain> --name "MyApp Test"
myapp-ctl client-env --host <public-ip-or-domain> --terminal-qr
cat /mnt/myapp/state/client-environment.json
```

## Routine Updates

Refresh installed control files first:

```bash
myapp-ctl update
```

`install_ctl.sh` refreshes managed compose/service definitions but preserves
host-local values such as public IP, data root, domains, image names, and
language preference.

Then redeploy only the changed runtime surface. Do not use a full deploy for
ordinary backend or agent code changes.

Backend HTTP routes only:

```bash
myapp-ctl deploy backend --build --no-setup --no-test-user
```

AI worker, prompts, validators, upload helpers, or shared backend helpers:

```bash
myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user
```

Agent-node control service:

```bash
myapp-ctl agent ls
myapp-ctl deploy agent-node --build --no-setup --no-test-user
```

Agent runtime image, including Claude/Codex tooling, `agent_runner.py`, or files
the isolated runtime needs under `/app`:

```bash
myapp-ctl deploy agent-runtime --build --no-setup --no-test-user
```

Both agent-node and runtime changed:

```bash
myapp-ctl agent ls
myapp-ctl deploy agent-node agent-runtime --build --no-setup --no-test-user
```

For image-based hosts, use `--pull` after pushing images:

```bash
myapp-ctl update
myapp-ctl deploy backend ai-worker --pull --no-setup --no-test-user
myapp-ctl deploy agent-node agent-runtime --pull --no-setup --no-test-user
```

Auth, Redis, Postgres, OpenIM, Supabase, and MinIO should stay up unless their
own config, image, schema, or persistent storage layout changed.

## Component Operations

Inspect status:

```bash
myapp-ctl status
myapp-ctl status backend ai-worker agent-node
```

Deploy one group only when that group really changed:

```bash
myapp-ctl deploy --group infra --pull
myapp-ctl deploy --group supabase --pull
myapp-ctl deploy --group openim --pull
myapp-ctl deploy --group agent --pull
myapp-ctl deploy --group core --pull
```

Restart without rebuilding:

```bash
myapp-ctl restart backend ai-worker
```

Logs:

```bash
myapp-ctl log backend -n 120
myapp-ctl log backend -f -n 120
```

Images:

```bash
myapp-ctl image ls
myapp-ctl image build backend
myapp-ctl image push backend
myapp-ctl image pull backend
```

Agent runs:

```bash
myapp-ctl agent ls
myapp-ctl agent ls --history --limit 20
```

`agent ls` hides historical runs by default so a busy host does not print a
large table for every completed chat turn.

## Configuration Backup And Restore

View config:

```bash
myapp-ctl config view
```

Export restorable config:

```bash
myapp-ctl config export --out /mnt/myapp/myapp-config.json
myapp-ctl config export --out /root/myapp-config.json
myapp-ctl config export --out /root/myapp-config.yaml
```

Export redacted config for review:

```bash
myapp-ctl config export --redacted --out /root/myapp-config.redacted.json
```

Restore:

```bash
myapp-ctl config import /root/myapp-config.json --yes
```

If `/etc/myapp` is missing but `/mnt/myapp/myapp-config.json` exists,
`myapp-ctl deploy --data-root /mnt/myapp ...` imports the bundle before starting
services. If service data under `/mnt/myapp` is still present, the cluster starts
from the same local state.

Persistent service data is bind-mounted from the data root. Docker named volumes
are not used for MyApp databases or object stores.

Important paths:

- `/mnt/myapp/jsonapp-postgres/data`
- `/mnt/myapp/ai-session-redis/data`
- `/mnt/myapp/app-minio/data`
- `/mnt/myapp/config-center/data`
- `/mnt/myapp/agent-node/{state,workspaces,logs}`
- `/mnt/myapp/supabase-db/{data,config}`
- `/mnt/myapp/supabase-storage/data`
- `/mnt/myapp/openim-*`

Agent runtime workspaces:

- editable current workspace:
  `<data-root>/agent-node/workspaces/<user-id>/<session-id>/current`
- per-turn snapshots:
  `<data-root>/agent-node/workspaces/<user-id>/<session-id>/runs/<job-id>`

## Verification

After deploy or update:

```bash
myapp-ctl status
curl -fsS http://127.0.0.1:5566/api/ai/providers
curl -fsS http://127.0.0.1:3254/health
curl -fsS http://127.0.0.1:5000/api/v1/public
curl -fsS http://127.0.0.1:5590/health
curl -fsS -H "apikey: $(myapp-ctl secret get supabase ANON_KEY --show)" \
  http://127.0.0.1:18000/auth/v1/health
myapp-ctl agent ls
```

Expected MyApp state:

- `backend`: running, health `healthy`
- `ai-worker`: running
- `registry`: running, health `healthy`
- `config-center`: running, health `ok`
- `user-center`: running
- `agent-node`: running, health `ok`
- `agent-runtime`: image present
- `jsonapp-postgres`: running, health `healthy`
- `ai-session-redis`: running, health `healthy`
- `app-minio`: running
- `supabase-*`: running; healthy where upstream images define checks
- `openim-*`: running; `openim-server` should be reachable

Provider API expectations:

- `deepseek`: configured when available, usually supports `claude`
- `minimax`: configured when available, supports `claude` and `codex`
- DeepSeek default worker limits: `20/100`
- MiniMax default worker limits: `5/20`

## Uninstall

Stop and remove managed services while preserving data root:

```bash
myapp-ctl uninstall --yes --purge
```

This removes containers, legacy named volumes, host-local `/etc/myapp` runtime
files, installed compose/config files, and MyApp images. It does not delete the
persistent data root. The command prints the explicit `rm -rf -- <data-root>`
line to run manually if you intentionally want to destroy all local data.

## Multi-Host Direction

The current stack is single-host first. Worker scheduling supports a multi-node
shape through static `AGENT_NODE_URLS`, registered Postgres `agent_nodes`
records, and session-to-node assignment so later turns keep using the same node.
Redis is not the source of truth for node registration; it is only a short-lived
compatibility heartbeat cache.

Register an agent node:

```bash
myapp-ctl agent-node register --url http://agent-node:5590 --capacity 4 --label gpu=false
```

Generate a bootstrap script for a new agent host from the master backend host:

```bash
myapp-ctl agent-node add \
  --backend http://<master-host>:5566 \
  --host <new-agent-host> \
  --node-id myapp-agent-2 \
  --capacity 2 \
  --provider-mode master
```

Provider modes:

- `master`: the master backend sends provider config to agent-node for each run;
  agent-node mints a short-lived local proxy token before starting the runtime.
  This is the simplest mode and does not require provider keys on the new agent
  host.
- `local`: the agent host loads `/etc/myapp/secrets.d/ai-providers.env` and
  uses its own provider keys before minting the runtime proxy token. Nodes
  registered with this mode do not receive the master provider token. Use this
  to split provider quota/keys by host.

`capacity` is a scheduler weight. Existing sessions keep their node assignment
for later turns; new sessions are distributed across registered URLs according
to weight.

Cluster node operations:

```bash
myapp-ctl agent-node ls
myapp-ctl agent-node status myapp-agent-2
myapp-ctl agent-node rm myapp-agent-2
```

`myapp-ctl agent ls` remains local-only: it shows the currently running agent
containers on the machine where the command is executed.

All-in-one hosts also self-register through the same registry path. Deploying
`agent-node` installs `myapp-agent-register.timer`, which runs
`myapp-ctl agent-node register` every 60 seconds. The registered URL is the
backend-reachable service URL, for example `http://agent-node:5590`; the physical
machine IP is stored as the `host=<ip>` label for display.
