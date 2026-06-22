# Self-managed Docker FaaS (faasd replacement)

OpenFaaS Community Edition caps at **15 functions** (EULA), which blocks a
multi-user FaaS ecosystem. We replace faasd/OpenFaaS with a self-managed Docker
runtime: each service is a Docker container, the control plane owns the full
lifecycle (deploy, route, cold-wake, scale-to-zero), and there is **no
function-count cap** (Docker manages arbitrarily many services).

Switch a host: `myapp-ctl faas mode local-docker` (sets FAAS_DEPLOY_MODE +
runtime image + network + code root + scale-to-zero knobs), then
`myapp-ctl deploy backend --build`.

## How it works

- **Deploy** (`deploy_bundle` → `_deploy_service`, docker branch): writes the
  service code under FAAS_CODE_ROOT, commits to git, and (FAAS_LOCAL_DOCKER_
  START_ON_DEPLOY=1) starts a container from the runtime image
  (`dapangyu/myapp-faas-runtime`, which carries psycopg2 + the `myapp_db`
  helper) on the shared `myapp_default` network, with the whole code root
  mounted read-only and `MYAPP_FAAS_SERVICE_DIR` pointing at this service. The
  scoped per-user `MYAPP_DB_DSN` is injected. No public gateway.
- **Routing**: the backend invoke proxy (`/api/faas/invoke/<id>/...`) is the
  single front door. `ensure_local_docker_runtime_for_service` resolves the
  container and the proxy forwards to `http://<container>:8080`.
- **Cold-wake**: if the container is stopped (scaled to zero) the invoke proxy
  `container.start()`s it (fast; the original env incl. the DB DSN is preserved)
  and waits for `/__myapp_faas_health`; if it is absent it recreates it,
  re-injecting the owner's scoped DSN. ~1–2s cold start.
- **Scale-to-zero**: every invoke touches `FAAS_DOCKER_STATE_DIR/<service_id>`.
  `faas_docker_reaper.py` (started from app.py in docker mode, flock-guarded so
  one worker reaps) stops containers idle past `FAAS_DOCKER_IDLE_SECONDS`
  (default 600s). The next invoke cold-wakes them. Stopped containers keep their
  definition (no slot cost).
- **Per-service routing** (`service_deploy_mode`): each service records its
  deploy mode in `meta_json.deploy.mode`; invoke + disable honor it, so
  faasd-era services keep routing to faasd while new services use Docker — a
  non-disruptive migration.

## Config (faas.env, managed by `myapp-ctl faas mode local-docker`)

- `FAAS_DEPLOY_MODE=local-docker`
- `FAAS_LOCAL_DOCKER_IMAGE`, `FAAS_LOCAL_DOCKER_NETWORK=myapp_default`
- `FAAS_LOCAL_DOCKER_HOST_CODE_ROOT` (host path), `FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT`
- `FAAS_DOCKER_SCALE_ZERO=1`, `FAAS_DOCKER_IDLE_SECONDS=600`,
  `FAAS_DOCKER_REAPER_INTERVAL=60`, `FAAS_DOCKER_STATE_DIR=/mnt/myapp/faas/state`

The backend needs the Docker socket (mounted) and the `docker` Python lib
(already in requirements).

## Verified on 77 (2026-06-22)

- routing/invoke ✅; **16 services / 18 containers running at once (>15, no cap)** ✅;
- scale-to-zero (reaper stops idle containers) + cold-wake (re-invoke starts,
  ~1.4s) ✅; DB-backed service (schema.sql + myapp_db) CRUD ✅.

## Migration / decommission

Switching the mode routes NEW services to Docker; existing faasd services keep
working via per-service routing. To fully decommission faasd: redeploy remaining
services (they pick up docker mode) or let them expire, then stop faasd.
