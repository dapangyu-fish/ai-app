# Self-managed Docker FaaS

This is the authoritative FaaS runtime doc. The FaaS runtime is a self-managed
Docker runtime: each service is a Docker container, the control plane owns the
full lifecycle (deploy, route, cold-wake, scale-to-zero), and there is **no
function-count cap** (Docker manages arbitrarily many services).

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
  `faas_docker_reaper.py` (started from app.py, flock-guarded so one worker
  reaps) stops containers idle past `FAAS_DOCKER_IDLE_SECONDS` (default 600s).
  The next invoke cold-wakes them. Stopped containers keep their definition (no
  slot cost).

## Config (faas.env)

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
