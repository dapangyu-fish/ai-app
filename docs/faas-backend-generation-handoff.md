# FaaS Backend Generation Handoff

Date: 2026-06-15

Branch: `feat/agent-control-plane`

## Current Status

The backend-generation feature is partially implemented and usable in
`local-docker` mode. The goal has been intentionally stopped before real
external faasd/OpenFaaS validation.

Current verified shape:

- FaaS invoke auth is disabled by default: `FAAS_REQUIRE_AUTH=0`.
- Agent runtime only writes artifacts; it does not receive Git, Docker registry,
  OpenFaaS, or `/etc/myapp` secrets.
- Backend owns validation, durable code writes, optional Git commit/push, and
  deployment.
- Default deploy mode is `local-docker`.
- OpenFaaS/faasd mode exists, but only fake/compatible gateway tests have passed.
- Real external faasd gateway smoke is not complete.

Do not claim the feature is complete until a real external faasd/OpenFaaS
gateway passes `myapp-ctl faas openfaas-gateway-smoke --yes`.

## Implemented Architecture

Agent-generated backend services use this artifact protocol:

```text
$AI_APP_WORKSPACE/faas_bundle.json
$AI_APP_WORKSPACE/client_actions.json
```

`client_actions.json` contains:

```json
{
  "client_actions": [
    {"type": "server_deploy_faas_service", "path": "faas_bundle.json"}
  ]
}
```

The backend action resolver deploys the bundle and returns an agent-visible
system message/action result. Invalid bundles return a `faas_service_failed`
action instead of creating a runnable service.

Durable code layout:

```text
/mnt/myapp/faas/code/users/<uid[0:2]>/<uid[2:4]>/<uid>/services/<service_id>/
  app.py
  requirements.txt
  service.json
  README.md
```

The OpenFaaS mode does not build one Docker image per user service. It deploys
the same generic runtime image for every service:

```text
dapangyu/myapp-faas-runtime:agent-control-plane
```

That runtime downloads the validated bundle from:

```text
<backend>/api/faas/runtime_bundle/<service_id>
```

The runtime bundle endpoint requires the per-service HMAC token derived from
`FAAS_RUNTIME_TOKEN`, so raw runtime bundle fetches without the correct token
are rejected.

## Main Files

- `backend/faas.py`: FaaS HTTP API, invoke proxy, runtime bundle endpoint.
- `backend/faas_store.py`: validation, storage, Git, local Docker, OpenFaaS
  adapter.
- `backend/faas_runtime_server.py`: generic Python/Flask runtime entrypoint.
- `backend/ai_session.py`: resolves `server_deploy_faas_service`.
- `backend/schema.sql` and `backend/migrations/006_faas_services.sql`: DB
  tables.
- `scripts/faas_smoke_test.py`: deploy/invoke/cleanup smoke.
- `scripts/faas_ai_action_smoke.py`: simulates Agent artifacts and deploy action.
- `scripts/faas_git_backend_smoke.py`: verifies backend-owned Git push.
- `scripts/faas_openfaas_runtime_compat_test.py`: fake gateway + real runtime
  container contract smoke.
- `scripts/faas_openfaas_backend_smoke.py`: temporarily switches deployed
  backend to OpenFaaS mode against a compatibility gateway.
- `scripts/faas_openfaas_gateway_check.py`: real gateway preflight.
- `scripts/faas_openfaas_gateway_smoke.py`: real gateway smoke.
- `scripts/myapp_ctl.py`: CLI commands under `myapp-ctl faas`.
- `docs/faas-backend-generation.md`: main design/operations document.

## Current Validation Rules

The service bundle is restricted to Python/Flask:

- Only allowed files: `app.py`, `requirements.txt`, `service.json`, `README.md`,
  and `tests/*`.
- Dependencies are currently limited to `flask`, `pydantic`, and
  `python-dateutil`.
- Imports are restricted to an allowlist.
- `app.py` must expose `app` or `application` as a Flask instance.
- Declared `service.routes` must be implemented via literal Flask decorators.
- Top-level runtime side effects are blocked.
- Simple model classes are allowed, but only with simple fields and literal
  defaults.
- Reserved runtime route `/__myapp_faas_health` is rejected if declared or
  implemented by generated code.

The reserved route check is important because both `local-docker` and OpenFaaS
use `/__myapp_faas_health` to decide whether the generated runtime is healthy.

## myapp-ctl Commands

Useful commands:

```bash
myapp-ctl faas health
myapp-ctl faas config
myapp-ctl faas ls --user-id <user-id>
myapp-ctl faas ls --user-id <user-id> --all
myapp-ctl faas disable <service-id> --user-id <user-id>
myapp-ctl faas smoke
myapp-ctl faas ai-action-smoke
myapp-ctl faas ai-action-smoke --include-invalid
myapp-ctl faas git-backend-smoke --yes
myapp-ctl faas openfaas-runtime-smoke --pull-image
myapp-ctl faas openfaas-backend-smoke --yes
myapp-ctl faas faasd-host-preflight --expect-empty-ports
```

OpenFaaS real gateway commands:

```bash
OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-check \
  --gateway http://<real-faasd-gateway>:8080 \
  --bundle-base-url https://<backend-domain> \
  --password-env OPENFAAS_PASSWORD

OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-smoke --yes \
  --gateway http://<real-faasd-gateway>:8080 \
  --bundle-base-url https://<backend-domain> \
  --password-env OPENFAAS_PASSWORD
```

## Verified Evidence

Local tests run before handoff:

```bash
python3 backend/test_faas_store_controls.py
python3 backend/test_faas_invoke_routes.py
python3 backend/test_faas_ai_session_owner.py
python3 backend/test_faas_git_store.py
python3 backend/test_faas_runtime_bundle_endpoint.py
python3 backend/test_faas_runtime_server_bundle.py
python3 backend/test_faas_openfaas_adapter.py
python3 backend/test_faas_openfaas_gateway.py
python3 backend/test_faas_openfaas_gateway_check.py
python3 backend/test_faas_openfaas_gateway_smoke_restore.py
python3 -m py_compile backend/faas_store.py backend/test_faas_store_controls.py
python3 -m py_compile scripts/myapp_ctl.py
```

77 machine state checked before this handoff:

```text
backend: running / healthy
ai-worker: running
myapp-ctl faas health:
  ok=True
  deploy_mode=local-docker
  auth_required=False
  openfaas_gateway=-
  tables=True
active agent runs: 0
```

77 has also previously passed:

```bash
myapp-ctl faas smoke --base-url http://127.0.0.1:5566
myapp-ctl faas ai-action-smoke --include-invalid --base-url http://127.0.0.1:5566
myapp-ctl faas git-backend-smoke --yes --base-url http://127.0.0.1:5566
myapp-ctl faas openfaas-backend-smoke --yes
```

The last attempted 77 redeploy rebuilt `backend` and `faas-runtime` and briefly
hit a `502` through default nginx routing, but a follow-up check showed
`backend` healthy and both `myapp-ctl faas health --base-url http://127.0.0.1:5566`
and default `myapp-ctl faas health` passing.

## Real faasd/OpenFaaS Gap

`myapp-pre-de-openfaas.dapangyu.work` currently does not point to a real
OpenFaaS gateway:

- HTTPS `/healthz` returned nginx `404`.
- Port `8080` timed out.
- On 77, `faasd` and `faasd-provider` were inactive.

`myapp-ctl faas faasd-host-preflight --expect-empty-ports --json` correctly
fails on 77 with:

```text
docker-colocation: docker daemon is reachable
```

This is expected. faasd should not be installed on the same host as the MyApp
Docker Compose stack because faasd and Docker both use containerd, iptables, and
CNI. Use a dedicated host for real faasd validation.

## Remaining Work

1. Provision or choose a dedicated host that is not running Docker.
2. Install `myapp-ctl` on that host.
3. Run:

   ```bash
   myapp-ctl faas faasd-host-preflight --expect-empty-ports
   ```

4. Install faasd following official OpenFaaS Edge/faasd documentation.
5. Ensure the faasd host can pull:

   ```text
   dapangyu/myapp-faas-runtime:agent-control-plane
   ```

6. Ensure functions on faasd can reach:

   ```text
   https://myapp-pre-de-backend.dapangyu.work/api/faas/runtime_bundle/<service_id>
   ```

7. Run real gateway check and smoke from a MyApp backend host:

   ```bash
   OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-check \
     --gateway http://<real-faasd-gateway>:8080 \
     --bundle-base-url https://myapp-pre-de-backend.dapangyu.work \
     --password-env OPENFAAS_PASSWORD

   OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-smoke --yes \
     --gateway http://<real-faasd-gateway>:8080 \
     --bundle-base-url https://myapp-pre-de-backend.dapangyu.work \
     --password-env OPENFAAS_PASSWORD
   ```

8. Document the exact observed commands and outputs.
9. Only then consider the real OpenFaaS/faasd path complete.

## Notes for the Next Agent

- Do not install faasd on 77 while it is running the MyApp Docker Compose stack.
- Do not put OpenFaaS/Git/registry secrets into Agent runtime containers.
- Keep the generated-code validator strict. If more Python features are needed,
  add narrow AST permissions and negative tests.
- If changing FaaS deploy mode during a smoke test, always restore
  `/mnt/myapp/secrets.d/faas.env` and redeploy `--group faas`.
- Prefer local `http://127.0.0.1:5566` for backend smoke on 77 to avoid nginx
  routing ambiguity.
- The feature remains intentionally incomplete until real external faasd smoke
  passes.
