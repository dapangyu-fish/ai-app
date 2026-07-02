# MyApp Deployment Guide

This is the only supported backend deployment guide. Older supervisor,
standalone IM, test-environment, and one-off migration paths have been removed
from the documentation.

The supported entrypoint is `myapp-ctl`, installed from this directory.

## Read This First

Use this document for backend hosts only. Client usage is documented in
[../../docs/USER_GUIDE.md](../../docs/USER_GUIDE.md), and runtime architecture
is documented in [../../backend/ARCHITECTURE.md](../../backend/ARCHITECTURE.md).

Recommended paths:

| Goal | Path |
|---|---|
| Bring up a new all-in-one test or production host | `install_ctl.sh` -> `myapp-ctl setup` -> `myapp-ctl deploy --build|--pull` |
| Update backend code only | `myapp-ctl update` -> `myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user` |
| Update agent execution code | `myapp-ctl update` -> `myapp-ctl deploy agent-node agent-runtime --build --no-setup --no-test-user` |
| Add a second public agent host | Master runs `agent-node add`; new host runs the printed `agent-node join` command |
| Add a user-private agent host | App creates a one-time join token; private host runs `agent-node private join` |
| Move/recover a host with existing data | Restore `/etc/myapp` or import `<data-root>/myapp-config.json`, then redeploy |

## Prerequisites

Host requirements:

- Ubuntu 24.04 or a compatible Linux host.
- Root access, or equivalent Docker and `/etc/myapp` write privileges.
- Docker Engine with the Compose plugin.
- Git if deploying from source with `--build`.
- Outbound HTTPS access for image pulls, Git pulls, and AI provider calls.
- Enough disk under the selected data root. `/mnt/myapp` is the default and is
  intentionally outside `/etc/myapp`.

Network expectations for an all-in-one backend:

| Port | Service | External use |
|---|---|---|
| `5566` | Backend API | Required by clients and pull-mode agent hosts |
| `3254` | Registry | Required by clients unless fronted/proxied |
| `5000` | Config Center | Required by clients |
| OpenIM HTTP/WS ports | OpenIM | Required for IM on mobile/Web |
| `80`, `443` | edge-nginx | Recommended public ingress when `myapp-ctl ingress` is enabled |
| `5590` | Agent Node | Local/internal in pull mode; do not expose unless using direct mode |

If a reverse proxy or domain layer is used, point clients at the public HTTPS
URLs through `myapp-ctl domain set ...` or by generating the correct
`client-env` payload.

## What It Deploys

`myapp-ctl` manages one single-host stack:

- MyApp core: backend API, AI worker, Registry, Config Center, User Center
- Infra: JSON app Postgres, AI session Redis, App MinIO
- Auth/storage: self-hosted Supabase compose group
- IM: OpenIM compose group
- Public ingress: optional Docker-managed `edge-nginx`
- AI execution: agent-node plus isolated Ubuntu agent runtime containers
- AI-generated backend services: FaaS control path and code repository under
  `/mnt/myapp/faas` (see
  [../../docs/faas-backend-generation.md](../../docs/faas-backend-generation.md))

The backend image is shared by `backend`, `ai-worker`, `registry`,
and `config-center` (user management lives in the config-center dashboard). Agent execution is split into:

- `myapp-agent-node`: host service that owns Docker and starts runtime containers
- `myapp-agent-runtime`: Ubuntu 24.04 image used for Claude/Codex/OpenCode runs

## Security Model

Host and service secrets live outside Git:

- `/etc/myapp/ctl.json`: host-local control configuration
- `/etc/myapp/services.json`: service inventory installed by `install_ctl.sh`
- `/etc/myapp/secrets.d/*.env`: durable host deployment config and the last
  generated cluster secret set, mode `600`
- `/etc/myapp/secrets.d/files/**`: APNs/FCM file secrets copied by setup
- `<data-root>/secrets.d/*.env`: runtime copy consumed by Docker Compose,
  regenerated from `/etc/myapp/secrets.d` on every deploy
- `<data-root>/secrets.d/files/**`: runtime copy mounted into services that
  need secret files
- `<data-root>/myapp-config.json`: optional explicit export target created by
  `myapp-ctl config export`, mode `600`

The default data root is `/mnt/myapp`.

`/etc/myapp` is the recovery source of truth. If the data root is deleted, a
subsequent `myapp-ctl deploy` recreates `<data-root>/secrets.d` from
`/etc/myapp/secrets.d`, then starts a fresh cluster with empty service data but
the same deployment config and preserved cluster credentials.

Agent runtime containers do not receive backend, Supabase, OpenIM, push, or real
provider keys. They receive a run payload and short-lived provider-proxy tokens.
Claude/Codex/OpenCode talk to `http://agent-node:5590/proxy/<token>`;
agent-node rewrites that request to DeepSeek/MiniMax and revokes the proxy token
after the run.

The runtime image includes the source needed for JSON-DSL inspection:
`backend/`, `lib/`, `assets/`, `test/`, `templates/`, `docs/`, `scripts/`,
`JSON-DSL.md`, and Flutter metadata. It does not include `.git`, build outputs,
website sources, or host-local secrets.

## First Install From Source

Start from a source checkout on the host:

```bash
cd ~/ai-app  # or any real git checkout of this repository
./deploy/production/install_ctl.sh
```

`install_ctl.sh` records the checkout path in `/etc/myapp/ctl.json` as
`paths.source`; later `myapp-ctl deploy --build` uses that path as the Docker
build context.

First interactive use asks for the CLI language once: `zh`, `en`, `de`, `es`,
`fr`, `pt`, `ca`, `hi`, `ko`, `ja`, or `it`. Change it later with:

```bash
myapp-ctl config lang zh
```

Run setup:

```bash
myapp-ctl setup --host <public-ip-or-domain> --data-root /mnt/myapp
```

Setup is safe to rerun. It generates local stack secrets when missing, preserves
existing values by default, and asks for human-provided values:

- AI providers: DeepSeek, MiniMax, or custom providers
- Optional ASR: ByteDance/Doubao speech recognition
- Optional email: Supabase SMTP/auth email settings
- Optional push: APNs, FCM, and GeTui

AI provider config is required for app generation. ASR, email, and push are
optional; skipping them only disables those channels.

Provider setup behavior:

- Built-in DeepSeek and MiniMax prompts ask for the Anthropic-compatible values
  needed by Claude Code, then write Codex and OpenCode adapter values.
- OpenCode uses provider-specific AI SDK packages. DeepSeek and MiniMax both
  default to `@ai-sdk/openai-compatible`; MiniMax uses
  `https://api.minimaxi.com/v1` because its Anthropic streaming endpoint does
  not reliably emit text deltas for OpenCode.
- Custom providers can add Claude Code, Codex, OpenCode, or a mix of them.
- The provider can also advertise supported agents, for example `claude` only
  or `claude,codex,opencode`.
- Provider keys are written only to host-local env files; they must never be
  committed to Git.

For APNs and FCM, either paste the secret content or enter a server-local file
path such as `/etc/apns/AuthKey_8NM9U7CJCJ.p8`. `myapp-ctl` copies files into
`/etc/myapp/secrets.d/files/`; deploy syncs them into
`<data-root>/secrets.d/files/` and writes container-visible paths into
`push.env`.

Inspect configured keys without revealing values:

```bash
myapp-ctl secret ls
```

Reveal one value only when operating on the host:

```bash
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

Use a Docker Hub mirror prefix when the host cannot pull directly from Docker
Hub:

```bash
myapp-ctl deploy --pull --mirror=mirror.houlang.cloud/dh
```

With `--mirror`, `myapp-ctl` pulls images through the mirror prefix, then tags
them back to their original image names before starting Compose services. This
applies to MyApp images and Compose-managed images such as Supabase, Postgres,
Redis, MinIO, and OpenIM.

If AI provider config is missing, interactive deploy starts the setup wizard. In
non-interactive shells it fails and tells you to run setup explicitly.

A full deploy:

- creates the complete data-root directory tree up front
- materializes `<data-root>/secrets.d` from `/etc/myapp/secrets.d`
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

The client import JSON is the supported way to connect Web/iOS/Android clients
to this backend. Do not hand-edit client constants for normal environment
switching.

## Managed Edge Nginx

`myapp-ctl` can manage a Dockerized nginx ingress instead of modifying the host
nginx service. The component is `edge-nginx` in group `edge`.

Interactive setup:

```bash
myapp-ctl ingress setup
myapp-ctl deploy --group edge --pull
```

Non-interactive example:

```bash
myapp-ctl ingress setup --yes \
  --website-domain myapp.example.com \
  --webapp-domain myapp-web.example.com \
  --backend-domain myapp-backend.example.com \
  --auth-domain myapp-auth.example.com \
  --oss-domain myapp-oss.example.com \
  --oss-console-domain myapp-oss-console.example.com \
  --registry-domain myapp-registry.example.com \
  --config-center-domain myapp-config.example.com \
  --openim-domain myapp-im.example.com \
  --crt /etc/ssl/myapp/fullchain.pem \
  --key /etc/ssl/myapp/privkey.pem
myapp-ctl deploy --group edge --pull
```

The generated config lives under `<data-root>/edge-nginx/`. Certificate files
are copied into `<data-root>/edge-nginx/certs/` and mounted read-only into the
container. If no cert/key is configured, `edge-nginx` renders HTTP-only config.

`edge-nginx` supports:

- WebSocket upgrade headers for OpenIM and Supabase realtime
- SSE-friendly proxying with buffering disabled
- large upload/download defaults via `client_max_body_size 2g` and long proxy
  timeouts
- static mounts for `<data-root>/static/website` and `<data-root>/static/webapp`

Host-based routing needs distinct domains for production. If every domain is
left as the same IPv4, `myapp-ctl` prints a warning because a single `443`
listener cannot distinguish all services by hostname.

## Source Build vs Image Pull

`--build` and `--pull` are deliberately explicit:

| Mode | Use when | Behavior |
|---|---|---|
| `--build` | Development/test host or source-controlled production host | Builds images from the checkout recorded in `/etc/myapp/ctl.json` |
| `--build --base` | Dependency/runtime update | Builds base images first, then builds code images from those bases |
| `--pull` | Image-based production host | Pulls configured images and starts containers |
| `--pull --base` | New build host that also needs local base tags | Pulls base images and final images |
| `--pull --mirror=<prefix>` | Image-based host behind slow or blocked Docker Hub access | Pulls `<prefix>/<image>` and tags it back to `<image>` |
| no flag | Component already has an image locally | Starts/restarts without building or pulling |

The three deployable images are split into base and code layers:

- `dapangyu/myapp-backend-base:<tag>` -> `dapangyu/myapp-backend:<tag>`
- `dapangyu/myapp-agent-node-base:<tag>` -> `dapangyu/myapp-agent-node:<tag>`
- `dapangyu/myapp-agent-runtime-base:<tag>` -> `dapangyu/myapp-agent-runtime:<tag>`

Use the base build only when apt packages, Python requirements, npm tooling,
Chrome, Claude/Codex/OpenCode, or other runtime dependencies changed. For
normal Python/Dart/JSON prompt/code updates, build only the final code images.

Refresh the installed control CLI and compose definitions before routine
updates:

```bash
myapp-ctl update
```

`myapp-ctl update` can pull the recorded source checkout unless `--no-pull` is
passed, then reruns `install_ctl.sh` so the installed CLI and service inventory
match the branch.

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

Agent runtime image, including Claude/Codex/OpenCode tooling,
`agent_runner.py`, or files the isolated runtime needs under `/app`:

```bash
myapp-ctl deploy agent-runtime --build --no-setup --no-test-user
```

This includes the visual review tool used by image-capable Agent/model runs:

```bash
myapp-visual-review "$AI_APP_WORKSPACE/app.json" --capture-small
```

The tool renders through the hosted Flutter Web JSON interpreter, writes
`visual_review/report.md`, `report.json`, and screenshots, and does not call a
separate vision API. The running Agent reads the screenshots itself when its
model supports image input.

Both agent-node and runtime changed:

```bash
myapp-ctl agent ls
myapp-ctl deploy agent-node agent-runtime --build --no-setup --no-test-user
```

Runtime dependency change, for example a new apt package or agent CLI version:

```bash
myapp-ctl deploy agent-runtime --build --base --no-setup --no-test-user
```

For image-based hosts, use `--pull` after pushing images:

```bash
myapp-ctl update
myapp-ctl deploy backend ai-worker --pull --no-setup --no-test-user
myapp-ctl deploy agent-node agent-runtime --pull --no-setup --no-test-user
myapp-ctl deploy --pull --mirror=mirror.houlang.cloud/dh --no-setup --no-test-user
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
myapp-ctl deploy --group edge --pull
myapp-ctl deploy --group faas --pull
```

The FaaS group updates the backend-owned FaaS control path. Generated Flask
services run in separate `myapp-faas-*` containers created by the backend, with
generated code mounted read-only from the data root
(`FAAS_DEPLOY_MODE=local-docker`). The backend control plane owns deploy,
routing, cold-wake, and scale-to-zero for each service. See
`../../docs/faas-docker-runtime.md` for the authoritative runtime
documentation.

Generated service smoke test:

```bash
myapp-ctl faas health
myapp-ctl faas smoke
myapp-ctl faas git-backend-smoke --yes
myapp-ctl faas ai-action-smoke --include-invalid
```

`git-backend-smoke` uses a temporary local bare Git remote under the shared
FaaS data root. It verifies that the deployed backend, not the Agent runtime,
can commit and push generated service code, then restores the previous FaaS
configuration.

The current production deployment is all-in-one on host 77.

List or disable generated services. Disabled services are hidden unless `--all`
is passed:

```bash
myapp-ctl faas ls --user-id <user_id>
myapp-ctl faas ls --user-id <user_id> --all
myapp-ctl faas disable <service_id> --user-id <user_id>
```

Configure backend-owned Git storage for generated service code:

```bash
myapp-ctl faas git --enable --remote git@github.com:<org>/<repo>.git \
  --branch main --push --ssh-key-file /root/.ssh/myapp-faas-deploy-key \
  --known-hosts-file /root/.ssh/known_hosts
myapp-ctl deploy --group faas --pull
```

The deploy key is copied into MyApp secret-files and mounted read-only into the
backend containers. Agent runtime containers do not receive this key.

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
myapp-ctl image build faas-runtime --base
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
myapp-ctl deploy [service|group ...] [--build|--pull] [--mirror <prefix>] [--plan|--dry-run]
myapp-ctl deploy --group infra|supabase|openim|agent|core|edge [--build|--pull] [--mirror <prefix>]
myapp-ctl restart [service|group ...]
myapp-ctl log <service> [-n 120] [-f]
myapp-ctl update [--source <checkout>] [--no-pull]
myapp-ctl uninstall --yes [--volumes] [--remove-ctl]
```

Configuration and secrets:

```bash
myapp-ctl setup [--host <host>] [--data-root /mnt/myapp] [--force]
myapp-ctl setup [--no-ingress] [--no-ai] [--no-asr] [--no-email] [--no-push]
myapp-ctl secret init-stack [--host <host>] [--data-root /mnt/myapp] [--force]
myapp-ctl secret ls
myapp-ctl secret get <group> <key> [--show]
myapp-ctl secret set <group> KEY=value [KEY2=value2 ...]
myapp-ctl secret generate <group> KEY [KEY2 ...] [--bytes 32]
myapp-ctl secret rm <group> KEY [KEY2 ...]
myapp-ctl config view [--show-secrets]
myapp-ctl config export --out <path.json|path.yaml> [--redacted]
myapp-ctl config import <path.json|path.yaml> --yes
myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]
myapp-ctl domain ls
myapp-ctl domain set <name> <url>
myapp-ctl domain rm <name>
myapp-ctl ingress setup [--host <host>] [--crt <fullchain.pem>] [--key <privkey.pem>]
myapp-ctl ingress render [--dry-run]
myapp-ctl ingress reload
myapp-ctl ingress status
myapp-ctl client-env [--host <host>] [--name <name>] [--json] [--terminal-qr]
```

Image operations:

```bash
myapp-ctl image ls
myapp-ctl image build [all|backend|faas-runtime|agent-node|agent-runtime] [--base]
myapp-ctl image pull [all|backend|faas-runtime|agent-node|agent-runtime] [--base]
myapp-ctl image push [all|backend|faas-runtime|agent-node|agent-runtime] [--base]
```

Agent operations:

```bash
myapp-ctl agent ls
myapp-ctl agent-node ls [--namespace public|all|<user-id>] [--json] [--no-probe]
myapp-ctl agent-node status [node-id] [--namespace public|all|<user-id>] [--json] [--no-probe]
myapp-ctl agent-node add --backend <url> --host <host> --node-id <id> --name <name> [--pull|--build] [--base]
myapp-ctl agent-node join --backend <url> --node-id <id> --name <name> --agent-token <token> --registration-token <token>
MYAPP_PRIVATE_AGENT_JOIN_TOKEN=<token> myapp-ctl agent-node private join --backend <url> --node-id <id> --name <name>
myapp-ctl agent-node pause [node-id] [--reason <text>]
myapp-ctl agent-node resume [node-id]
myapp-ctl agent-node limits --capacity <n> --queue-max <n>
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

If `/etc/myapp` is missing but a legacy `/mnt/myapp/myapp-config.json` exists,
`myapp-ctl deploy --data-root /mnt/myapp ...` can still import the bundle before
starting services. This is a compatibility path only; new backups should be
created explicitly with `myapp-ctl config export --out /root/myapp-config.json`.

Persistent service data is bind-mounted from the data root. Docker named volumes
are not used for MyApp databases or object stores.

Operational rule:

- `myapp-ctl uninstall --yes` removes managed containers and networks only.
- `myapp-ctl uninstall --yes --volumes` additionally removes legacy Docker
  named volumes. MyApp databases and object stores use bind paths under the
  data root, so they are still preserved.
- Uninstall always preserves `/etc/myapp`, installed service inventory,
  compose files, Docker images, and the data root.
- If `/etc/myapp` still exists, a data-root wipe can be reconstructed by running
  `myapp-ctl deploy` again; data is lost, but deployment config and preserved
  cluster credentials are reused.
- Destroying local service data is always a separate explicit manual command.
  Host config and cached images are preserved by uninstall and are not part of
  the uninstall cleanup flow.

Important paths:

- `/mnt/myapp/jsonapp-postgres/data`
- `/mnt/myapp/ai-session-redis/data`
- `/mnt/myapp/app-minio/data`
- `/mnt/myapp/edge-nginx/{nginx.conf,conf.d,certs,logs}`
- `/mnt/myapp/static/{website,webapp}`
- `/mnt/myapp/config-center/data`
- `/mnt/myapp/agent-node/{state,workspaces,logs}`
- `/mnt/myapp/faas/{code,logs,tmp}`
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
curl -fsS http://127.0.0.1/edge-healthz
curl -fsS -H "apikey: $(myapp-ctl secret get supabase ANON_KEY --show)" \
  http://127.0.0.1:18000/auth/v1/health
myapp-ctl agent ls
```

Expected MyApp state:

- `backend`: running, health `healthy`
- `ai-worker`: running
- `registry`: running, health `healthy`
- `config-center`: running, health `ok`
- `agent-node`: running, health `ok`
- `agent-runtime`: image present
- `faas-control`: running, health `ok`
- `jsonapp-postgres`: running, health `healthy`
- `ai-session-redis`: running, health `healthy`
- `app-minio`: running
- `supabase-*`: running; healthy where upstream images define checks
- `openim-*`: running; `openim-server` should be reachable

Provider API expectations:

- `deepseek`: configured when available, usually supports `claude`
- `minimax`: configured when available, supports `claude` and `codex`
- Backend API default gunicorn workers: `10`
- Default agent-node local limits: `capacity=10`, `queue_max=100`
- Default generated FaaS service limit: `FAAS_MAX_SERVICES_PER_USER=5`
- Default generated FaaS runtime mode: `FAAS_DEPLOY_MODE=local-docker`
- DeepSeek default worker limits: `20/100`
- MiniMax default worker limits: `5/20`

## Uninstall

Stop and remove managed services while preserving data root:

```bash
myapp-ctl uninstall --yes
```

This removes managed containers and networks only. It preserves `/etc/myapp`,
installed service inventory, compose files, MyApp Docker images, and the
persistent data root. The command prints an explicit manual cleanup command for
the data root only if you intentionally want to destroy local service data.

To also remove legacy Docker named volumes while still preserving bind-path
service data:

```bash
myapp-ctl uninstall --yes --volumes
```

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
  --name "GPU agent 2" \
  --capacity 4 \
  --label host=<agent-hostname-or-ip>
```

Generate a join command for a new agent host from the master backend host:

```bash
myapp-ctl agent-node add \
  --backend http://<master-host>:5566 \
  --host <new-agent-host-ip-or-name> \
  --node-id myapp-agent-2 \
  --name "GPU agent 2" \
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
- `local`: the agent node loads a node-local `ai-providers.env` from its own
  data directory before minting the runtime proxy token. For the singleton node
  the default path is `<data-root>/agent-node/ai-providers.env`; for additional
  same-host instances it is `<data-root>/agent-nodes/<node-id>/ai-providers.env`.
  Nodes registered with this mode do not receive the master provider token. Use
  this to split provider quota/keys by node, even when multiple nodes run on one
  physical machine.

`myapp-ctl agent-node ls` displays this value as `KEY_SRC` because it is the
source of provider keys, not the DeepSeek/MiniMax provider selected by a user
request.

`capacity` is both a scheduler weight and the pull-node local limit. The
default is `capacity=10` and `queue_max=100` for new deployments and new join
commands unless overridden. The agent-node counts Docker runtime containers plus
jobs it has just acquired but not fully started yet, so it does not over-pull
during container startup.

`--name` is the human-readable display name shown in dashboards and CLI tables.
The stable scheduler identity is still `--node-id`.

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

Hot-update the local pull-node concurrency:

```bash
# Run on the agent host. This writes local limits and updates the running
# agent-node process without restarting active agent containers.
myapp-ctl agent-node capacity 3 --queue-max 20
myapp-ctl agent-node limits --capacity 3 --queue-max 20
```

Increasing `capacity` lets the node acquire more runs on its next pull loop.
Decreasing `capacity` never aborts active runs; it only prevents the node from
accepting new work until `RUNS < CAP`. `queue-max` affects future queue
admission and does not clear already queued work. To stop accepting new work
before changing limits:

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
myapp-ctl agent-node ls --namespace all
myapp-ctl agent-node ls --namespace <user-id>
myapp-ctl agent-node status myapp-agent-2
myapp-ctl agent-node rm myapp-agent-2
```

`agent-node ls` defaults to the global/public namespace. Private user nodes are
hidden unless an admin explicitly passes `--namespace <user-id>` or
`--namespace all`. The table includes `NAME`, `NODE`, and `NS` so a single
physical machine can run multiple public and private agent nodes without
confusing their identities.

`myapp-ctl agent ls` remains local-only: it shows the currently running agent
containers on the machine where the command is executed.

All-in-one hosts use the same registry path. In the default pull mode,
deploying `agent-node` disables the old host-level `myapp-agent-register.timer`;
the agent-node container self-registers through its regular acquire heartbeat.
The registered URL is `pull://<node-id>`, and the physical machine IP is stored
as the `host=<ip>` label for display. Direct mode is the legacy inbound HTTP
path and can still use explicit registration when needed.

When a host already has the singleton compose service `myapp-agent-node`
running and a join command is executed for a different `--node-id`, pull-mode
join starts an additional Docker container instead of overwriting the singleton.
The extra container name is `myapp-agent-node-<safe-node-id>` and its persistent
state lives under `<data-root>/agent-nodes/<safe-node-id>/`. Use
`--replace-existing-agent-node` only when intentionally replacing the singleton
configuration on that host.

## User-Private Agent Nodes

Private agent nodes are for ordinary users who want their own AI provider keys,
capacity, and workspace state on their own machine. They are always pull-mode
nodes, so the private host only needs outbound access to the backend.

Security invariants:

- The provider key stays in the private node's local data directory, for example
  `/mnt/myapp/agent-node/ai-providers.env` for the singleton node or
  `/mnt/myapp/agent-nodes/<node>/ai-providers.env` for an additional same-host
  instance.
- The private node signing key stays under the user's local data root, for
  example `/mnt/myapp/agent-node/private/<node>.key.pem` for the singleton node
  or `/mnt/myapp/agent-nodes/<node>/private/<node>.key.pem` for an additional
  same-host instance.
- The backend stores only the public key, node metadata, heartbeat, and capacity.
- A private node can only pull jobs for its owning user.
- A private job does not fall back to public nodes unless the client explicitly
  sends another request with public scope.

Join a private node:

```bash
export MYAPP_PRIVATE_AGENT_JOIN_TOKEN='<short-lived token copied from app settings>'

myapp-ctl agent-node private join \
  --backend https://<backend-host> \
  --node-id my-private-agent \
  --name "My private Mac Studio" \
  --provider deepseek \
  --agent claude \
  --capacity 2 \
  --queue-max 10 \
  --pull
```

The command generates an RSA keypair locally, registers the public key through
`/api/ai/private_agent/nodes`, consumes the one-time join token, writes
`agent.env`, prompts for local AI provider configuration if it is missing, and
deploys only `agent-node` plus `agent-runtime`.
If the host is already running a different `myapp-agent-node`, `myapp-ctl`
starts an additional private instance instead of overwriting it. This supports
mixed public/private nodes on one machine, or multiple private nodes owned by
different users. Use `--replace-existing-agent-node` only when intentionally
converting the singleton node on that host.

The app settings page has a Private Agent Nodes view. It lists only the
logged-in user's private nodes and can create a new join token by calling
`POST /api/ai/private_agent/join_token`. It is intentionally read-only after a
node has joined: pause, resume, capacity, queue, and removal are controlled from
the agent-node host with `myapp-ctl`, because the running node owns the local
provider keys and runtime limits. The join-token response includes both
`join_token` and a ready-to-copy `join_command`; the command includes the
currently selected provider and agent. The token is short-lived and one-time.
The long-lived private provider keys remain only on the user's agent-node host.
The join-token API accepts `image_mode` as `pull`, `build`, or `none`; app
settings use the default `pull` command for released images, while branch or
source-based validation can request `build` so the private host builds the
current checkout before starting the node.

On a private agent host, `myapp-ctl agent-node private ls` and
`agent-node private status` use the local agent-node signing key to query
`/api/ai/private_agent/nodes/self`, so they show only that private node. Generic
`myapp-ctl agent-node ls` remains the admin cluster view and defaults to public
nodes. Passing a logged-in user `--auth-token` to the private subcommand is
required only when the user wants to list all private nodes owned by the same
account. The local helper endpoint that signs this short JWT is protected by the
host's `AGENT_NODE_TOKEN`.

The client settings page exposes `Agent routing` / `Agent 调度` with two
explicit modes: `public` and `private`. Chat start requests send the selected
value as:

```json
{
  "agent_scope": "private"
}
```

Supported scopes are:

- `public`: use the platform agent pool.
- `private`: use only the logged-in user's private nodes; fail with
  `AI_PRIVATE_AGENT_OFFLINE` if none is online.

Provider and agent selectors are scoped too. In public mode, the client shows
providers reported by online public nodes. In private mode, it shows only
providers reported by the signed-in user's private nodes. Private mode never
falls back to public automatically; the user must switch routing back to
`public` if they want to use the platform pool.
