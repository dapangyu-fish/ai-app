# Source Deployment Runbook

This runbook describes a clean source deployment on a backend host using
`myapp-ctl`. It intentionally lists secret names only. Do not paste real token
values into this file, shell history, or Git.

## Scope

Validated on `77.237.233.229` with:

- local source tree at `/opt/myapp/current-agent-control-plane`
- Docker + Docker Compose already installed
- production AI provider, SMTP email, APNs, FCM, ASR, and Getui secrets
  imported into host-local env files
- newly generated Supabase, OpenIM, database, Redis, MinIO, Flask, Registry,
  Agent, Config Center, and User Center secrets

Supabase and OpenIM are first-class `myapp-ctl` compose groups. A full
`deploy all` starts MyApp infra, Supabase, OpenIM, agent-node, backend,
ai-worker, registry, config-center, and user-center.

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

Run the first-run setup wizard:

```bash
myapp-ctl setup --host <public-ip-or-domain>
```

On the first interactive `myapp-ctl` run, choose the CLI language (`zh`, `en`,
`de`, or `es`). Change it later with:

```bash
myapp-ctl config lang zh
```

The wizard generates local stack secrets, then asks for human-provided
production secrets:

- `ai-providers.env`: `AI_PROVIDER_IDS`, `AI_DEFAULT_PROVIDER`,
  `AI_DEFAULT_AGENT`, `DEEPSEEK_*`, `MINIMAX_*`, or custom provider keys.
- `backend.env`: `BYTEDANCE_ASR_*`. Supabase/OpenIM URLs and keys are generated
  by `secret init-stack` for the local managed stack unless you intentionally
  override them.
- `supabase.env`: SMTP/auth email values such as `ENABLE_EMAIL_SIGNUP`,
  `ENABLE_EMAIL_AUTOCONFIRM`, `SMTP_ADMIN_EMAIL`, `SMTP_HOST`, `SMTP_PORT`,
  `SMTP_USER`, `SMTP_PASS`, and `SMTP_SENDER_NAME`.
- `push.env`: `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`, `FCM_SERVICE_ACCOUNT_PATH`,
  `FCM_PROJECT_ID`, `GETUI_*`.

AI provider config is required for the generation path. ByteDance ASR, SMTP
email, APNs, FCM, and GeTui are optional; skip them on hosts that do not need
speech recognition, auth email delivery, or push delivery. For APNs and FCM,
either paste the `.p8` private key / Firebase service-account JSON, or enter a
server-local file path such as `/etc/apns/AuthKey_8NM9U7CJCJ.p8`. `myapp-ctl`
stores those files under `/etc/myapp/secrets.d/files/` and writes the
container-visible paths into `push.env`.

If SMTP email is changed after Supabase is already running, apply it with:

```bash
myapp-ctl deploy --group supabase
```

If you skip setup and run `myapp-ctl deploy --build` from an interactive fresh
host, deploy launches the same wizard when AI provider config is missing. In
non-interactive shells it fails and asks you to run `myapp-ctl setup`.

Inspect configured keys without revealing values:

```bash
myapp-ctl secret ls
```

Deploy from source:

```bash
myapp-ctl deploy --plan
myapp-ctl deploy --build
```

Full deploys automatically write `/var/lib/myapp/client-environment.json`,
generate `/var/lib/myapp/client-environment.png` when `qrencode` is installed,
print the JSON, and print a terminal QR code in interactive terminals. Long
Docker/Compose steps print a heartbeat while running.

## Verification

Run:

```bash
myapp-ctl status
curl -fsS http://127.0.0.1:5566/api/ai/providers
curl -fsS http://127.0.0.1:3254/health
curl -fsS http://127.0.0.1:5000/api/v1/public
curl -fsS -H "apikey: $(myapp-ctl secret get supabase ANON_KEY --show)" \
  http://127.0.0.1:18000/auth/v1/health
myapp-ctl agent ls
```

Generate a client environment import JSON and QR code:

```bash
myapp-ctl client-env --host <public-ip-or-domain> --name "MyApp Test"
myapp-ctl client-env --host <public-ip-or-domain> --terminal-qr
cat /var/lib/myapp/client-environment.json
```

The JSON matches the client Service Environment import format used by the old
test-env bootstrap. If `qrencode` is installed, the command also writes
`/var/lib/myapp/client-environment.png`; otherwise it still writes and prints
the JSON.

## Configuration Backup

Inspect, export, and restore host-local configuration:

```bash
myapp-ctl config view
myapp-ctl config export --out /root/myapp-config.json
myapp-ctl config export --format yaml --out /root/myapp-config.yaml
myapp-ctl config import /root/myapp-config.json --yes
```

The restorable export includes `/etc/myapp/ctl.json`,
`/etc/myapp/services.json`, `/etc/myapp/secrets.d/*.env`, and
`/etc/myapp/secrets.d/files/**`. It is written with mode `600`. Use
`--redacted` for review-only bundles that should not restore secrets.

Expected MyApp services after a successful source deployment:

- `agent-node`: running, health `ok`
- `agent-runtime`: image present
- `jsonapp-postgres`: running, health `healthy`
- `ai-session-redis`: running, health `healthy`
- `backend`: running, health `healthy`
- `registry`: running, health `healthy`
- `config-center`: running, health `ok`
- `ai-worker`, `app-minio`, `user-center`: running
- `supabase-*`: running, with Docker health `healthy` where the upstream image
  defines a healthcheck
- `openim-*`: running; `openim-server` may return HTTP 400/401/404 at `/`, which
  is still enough to prove the API process is reachable

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
- Supabase and OpenIM are no longer `docker start` placeholders. They are
  deployed by `myapp-ctl` as real compose groups.
- `myapp-ctl secret init-stack` generates the local Supabase JWTs, OpenIM
  credentials, backend DB/Redis/MinIO secrets, and control-plane admin secrets.
- OpenIM v3.8 config extraction and patching is now a deploy hook, so
  `openim-server` receives the generated Mongo/Redis/Kafka/Etcd/MinIO/secret
  settings instead of ignoring env vars.
- `deploy all` now executes compose in ordered batches: MyApp infra, Supabase,
  OpenIM, then agent/core services.

## Validated Result

After a purge and fresh secret import, `myapp-ctl deploy --build` should
complete in one pass on `77.237.233.229`. Health checks must pass for backend,
registry, config-center, PostgreSQL, Redis, agent-node, Supabase, and OpenIM.
A direct DeepSeek/Claude agent-node smoke run should complete with
`returncode=0`.
