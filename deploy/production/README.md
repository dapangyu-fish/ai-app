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
- `<data-root>/myapp-config.json`: restorable permission-protected bundle,
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
```

`agent ls` is intentionally local-only and current-only. It shows active
runtime containers on the machine where the command runs. Historical per-run
JSONL logs remain under `<data-root>/agent-node/logs/`; use `myapp-ctl log
agent-node` for the service log.

## Command Reference

`myapp-ctl` writes host config under `/etc/myapp`, manages Docker, and creates
bind-mounted data paths under the configured data root. Run it as root or with
equivalent privileges on deployment hosts.

Core service operations:

```bash
myapp-ctl status [service ...] [--json]
myapp-ctl deploy [service|group ...] [--build|--pull|--plan|--dry-run]
myapp-ctl deploy --group infra|supabase|openim|agent|core [--build|--pull]
myapp-ctl restart [service|group ...]
myapp-ctl log <service> [-n 120] [-f]
myapp-ctl update [--source <checkout>] [--no-pull]
myapp-ctl uninstall --yes [--purge] [--volumes] [--images] [--remove-ctl]
```

Configuration and secrets:

```bash
myapp-ctl setup [--host <host>] [--data-root /mnt/myapp] [--force]
myapp-ctl setup [--no-ai] [--no-asr] [--no-email] [--no-push]
myapp-ctl secret init-stack [--host <host>] [--data-root /mnt/myapp] [--force]
myapp-ctl secret ls
myapp-ctl secret get <group> <key> [--show]
myapp-ctl secret set <group> KEY=value [KEY2=value2 ...]
myapp-ctl secret generate <group> KEY [KEY2 ...] [--bytes 32]
myapp-ctl secret rm <group> KEY [KEY2 ...]
myapp-ctl config view [--show-secrets]
myapp-ctl config export --out <path.json|path.yaml> [--redacted]
myapp-ctl config import <path.json|path.yaml> --yes
myapp-ctl config lang [zh|en|de|es]
myapp-ctl domain ls
myapp-ctl domain set <name> <url>
myapp-ctl domain rm <name>
myapp-ctl client-env [--host <host>] [--name <name>] [--json] [--terminal-qr]
```

Image operations:

```bash
myapp-ctl image ls
myapp-ctl image build [all|backend|agent-node|agent-runtime]
myapp-ctl image pull [all|backend|agent-node|agent-runtime]
myapp-ctl image push [all|backend|agent-node|agent-runtime]
```

Agent operations:

```bash
myapp-ctl agent ls
myapp-ctl agent-node ls [--json] [--no-probe]
myapp-ctl agent-node status [node-id] [--json] [--no-probe]
myapp-ctl agent-node add --backend <url> --host <host> --node-id <id> [--pull|--build]
myapp-ctl agent-node join --backend <url> --node-id <id> --agent-token <token> --registration-token <token>
myapp-ctl agent-node pause [node-id] [--reason <text>]
myapp-ctl agent-node resume [node-id]
myapp-ctl agent-node limits --capacity <n> --queue-max <n> [--force]
myapp-ctl agent-node rm <node-id>
```

`myapp-ctl agent add` and `myapp-ctl agent register` are deprecated aliases for
`agent-node add` and `agent-node register`.

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

## Multi-Host Agent Nodes

The default AI execution mode is pull-based: the backend writes queued jobs to
Redis, each agent-node polls the backend from its own host, then streams JSONL
events and generated artifacts back to the backend. The client SSE path stays
`client -> backend`; the agent host never needs an inbound public port.

Node registration lives in Postgres `agent_nodes`. Redis is used for short-lived
job queues, heartbeats, stream fan-out, and active-run display only.

Current scheduling is a global pull queue with best-effort session affinity:

1. The backend appends a job id to `ai:agent_pull:pending`.
2. Every online pull node calls `/api/ai/agent_pull/acquire` with its
   `active_runs`, `capacity`, `queue_max`, version, labels, and provider mode.
3. If the node is not paused and `active_runs < capacity`, the backend scans the
   pending queue for a job that this node can take.
4. After a node takes a session, later turns of the same session wait for that
   node while it is online and not paused. If the node is stale, removed, or
   paused, another node can take the job and refresh the binding.
5. If the node is full, it keeps heartbeating but receives `204 No Content`.

This means a full node naturally stops taking jobs and another available node
can pull the next queued job. It is not strict least-loaded scheduling, but
same-session app iteration stays on one agent host under normal conditions so
the local workspace and CLI session state remain continuous.

Register an agent node:

```bash
myapp-ctl agent-node register \
  --url pull://myapp-agent-2 \
  --node-id myapp-agent-2 \
  --capacity 4 \
  --label host=<agent-hostname-or-ip>
```

Generate a join command for a new agent host from the master backend host:

```bash
myapp-ctl agent-node add \
  --backend http://<master-host>:5566 \
  --host <new-agent-host-ip-or-name> \
  --node-id myapp-agent-2 \
  --capacity 2 \
  --mode pull \
  --provider-mode master
```

This prints a single `myapp-ctl agent-node join ...` command for the new host.
The command writes the agent-node secret config, installs only the agent-node
and agent-runtime services, enables pull mode, registers
`pull://myapp-agent-2`, and starts polling the backend. The new host only needs
outbound HTTP access to `<master-host>:5566`.

Image handling is explicit:

- no image flag: require the agent images to already exist locally
- `--pull`: pull the configured agent-node/runtime images during join
- `--build`: build the configured agent-node/runtime images from local source

If you intentionally want the old backend-to-agent direct path, opt in:

```bash
myapp-ctl agent-node add \
  --backend http://<master-host>:5566 \
  --host <new-agent-host> \
  --mode direct \
  --provider-mode master
```

Direct mode exposes nginx on the agent host and registers an HTTP URL that the
backend can call. It is useful for controlled networks but is not the default.

Provider modes:

- `master`: the master backend sends provider config to agent-node for each run;
  agent-node mints a short-lived local proxy token before starting the runtime.
  This is the simplest mode and does not require provider keys on the new agent
  host.
- `local`: the agent host loads `/etc/myapp/secrets.d/ai-providers.env` and
  uses its own provider keys before minting the runtime proxy token. Nodes
  registered with this mode do not receive the master provider token. Use this
  to split provider quota/keys by host.

`myapp-ctl agent-node ls` displays this value as `KEY_SRC` because it is the
source of provider keys, not the DeepSeek/MiniMax provider selected by a user
request.

`capacity` is both a scheduler weight and the pull-node local limit. The
agent-node counts Docker runtime containers plus jobs it has just acquired but
not fully started yet, so it does not over-pull during container startup.

Pause or resume scheduling for a node without stopping existing runs:

```bash
# On the agent host itself; node id defaults to local AGENT_NODE_ID.
myapp-ctl agent-node pause --reason "maintenance"
myapp-ctl agent-node resume

# From the master host, pass an explicit node id.
myapp-ctl agent-node pause myapp-agent-2 --reason "maintenance"
myapp-ctl agent-node resume myapp-agent-2
```

Paused pull nodes keep heartbeating and stay visible in `agent-node ls`, but the
backend does not assign new runs to them. Existing runs are not aborted.

Change the local pull-node concurrency:

```bash
# Run on the agent host. This writes local limits and restarts agent-node.
myapp-ctl agent-node capacity 3 --queue-max 20
myapp-ctl agent-node limits --capacity 3 --queue-max 20
```

The command refuses to restart while local agent runs are active unless
`--force` is passed. A safer maintenance sequence is:

```bash
myapp-ctl agent-node pause --reason "resize capacity"
myapp-ctl agent ls
myapp-ctl agent-node limits --capacity 3 --queue-max 20
myapp-ctl agent-node resume
```

In `myapp-ctl agent-node ls`, `RUNS` is the active runtime count, `CAP` is this
node's max concurrency, `QUEUE` is the current backend pull queue depth visible
to online pull nodes, and `QMAX` is the max pull queue capacity reported by the
node. The summary prints `queued=<current>` and `qmax=<available>/<total>`.

Cluster node operations:

```bash
myapp-ctl agent-node ls
myapp-ctl agent-node status myapp-agent-2
myapp-ctl agent-node rm myapp-agent-2
```

`myapp-ctl agent ls` remains local-only: it shows the currently running agent
containers on the machine where the command is executed.

All-in-one hosts use the same registry path. In the default pull mode,
deploying `agent-node` disables the old host-level `myapp-agent-register.timer`;
the agent-node container self-registers through its regular acquire heartbeat.
The registered URL is `pull://<node-id>`, and the physical machine IP is stored
as the `host=<ip>` label for display. Direct mode is the legacy inbound HTTP
path and can still use explicit registration when needed.
