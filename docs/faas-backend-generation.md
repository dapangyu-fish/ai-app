# AI Generated FaaS Backends

The FaaS runtime is the self-managed Docker FaaS (`FAAS_DEPLOY_MODE=local-docker`):
each service is a Docker container, the control plane owns the full lifecycle
(deploy/route/cold-wake/scale-to-zero/扩缩容), and there is no function-count cap.
See `faas-docker-runtime.md` for the authoritative runtime details.

This document tracks the backend-generation path for JSON-APPs. It is aligned
with the current `agent-control-plane` architecture: Agent containers generate
artifacts only; backend-owned services perform validation, Git writes, and
deployment.

## Goal

Users can ask the AI Agent to generate an APP that also needs backend logic. The
Agent may create a restricted Python/Flask FaaS service bundle, and the MyApp
backend deploys it without exposing GitHub, Docker registry, or `/etc/myapp`
secrets to the Agent runtime.

The first supported runtime shape is:

- Python/Flask only.
- One service bundle per generated backend service.
- Default per-user limit: 5 active services.
- Auth-free invoke path for now.
- Backend-owned Git commit/push and deployment.
- Self-managed Docker FaaS deployment through a backend-controlled adapter
  (see `faas-docker-runtime.md`).
- A backend API to disable a service and release its quota slot.

## Artifact Protocol

When an APP needs backend code, the Agent writes:

```text
$AI_APP_WORKSPACE/faas_bundle.json
$AI_APP_WORKSPACE/client_actions.json
```

`client_actions.json` must include:

```json
{
  "client_actions": [
    {"type": "server_deploy_faas_service", "path": "faas_bundle.json"}
  ]
}
```

If the generated JSON APP also needs upload, include the existing
`server_upload_app_json` action as usual.

The invoke proxy enforces `service.routes`: calls to undeclared paths return
404 and calls with undeclared HTTP methods return 405. Any endpoint the JSON APP
will call must be declared in the bundle, including dynamic Flask-style routes
such as `/items/<item_id>` or `/files/<path:tail>`.

The validator also checks that every declared `service.routes` path/method is
implemented in `app.py` through a literal Flask decorator:
`@app.get/post/put/patch/delete/options(...)` or
`@app.route(..., methods=[...])`. A bundle that declares `/items` `POST` but
only implements `@app.get('/items')` is rejected before deployment.

`app.py` is intentionally restricted to a statically verifiable module shape.
At top level it may contain imports, `app = Flask(__name__)` or
`application = Flask(...)`, literal constants/lists/dicts for small seed state,
route functions, and an optional `if __name__ == '__main__': app.run()` guard.
Top-level loops, file/network IO, background threads, and arbitrary function
calls are rejected so generated code cannot hang or perform side effects while
the runtime imports the module. Function default arguments, annotations, and
decorators are also import-time code: defaults must be literals, annotations
must not call runtime code, and decorators must be literal Flask route
decorators.

## Bundle Shape

```json
{
  "service": {
    "service_id": "todo-api",
    "slug": "todo-api",
    "routes": [
      {"path": "/items", "methods": ["GET", "POST"], "description": "List or create items"}
    ]
  },
  "files": {
    "app.py": "from flask import Flask, jsonify\napp = Flask(__name__)\n...",
    "requirements.txt": "flask==3.0.3\n"
  }
}
```

If the JSON APP calls the service, `service.service_id` must be stable because
the frontend route is:

```text
/api/faas/invoke/<service_id>/<route>
```

JSON-DSL HTTP builtins (`@http_get`, `@http_post`, `@http_put`,
`@http_delete`, `@http_sse`) resolve `/...` relative URLs against the active
MyApp backend URL, so generated apps should prefer the relative path above
instead of hard-coding an environment-specific host.

To disable a service and free one active-service quota slot:

```text
DELETE /api/faas/services/<service_id>
```

## Storage Layout

The durable code root is controlled by `FAAS_CODE_ROOT`, default:

```text
/mnt/myapp/faas/code
```

`FAAS_CODE_ROOT` is the backend container path. In `local-docker` mode,
`FAAS_LOCAL_DOCKER_HOST_CODE_ROOT` is the matching host path that Docker mounts
into each generated-service runtime container.

Per-user layout:

```text
users/<uid[0:2]>/<uid[2:4]>/<uid>/services/<service_id>/
  app.py
  requirements.txt
  service.json
  README.md
```

Example:

```text
users/9a/eb/9aebdab8-3318-4dfa-99ff-54973bd28cf4/services/todo-api/
```

## Security Boundary

- Agent runtime does not receive GitHub keys.
- Agent runtime does not receive Docker registry credentials.
- Agent runtime does not write the durable code repository.
- Optional Git push is configured only on the backend host through
  `myapp-ctl faas git`. Deploy keys live under MyApp secret-files and are
  mounted read-only into backend containers; they are never mounted into Agent
  runtime containers.
- The backend validates and writes only files under the current user's service
  path.
- Static validation currently blocks dangerous imports/calls and restricts
  dependencies.

## Deploy Mode

`FAAS_DEPLOY_MODE=local-docker` is the runtime mode installed by `myapp-ctl`. It
validates, writes, and commits service code, then starts a backend-owned runtime
container named `myapp-faas-*` using the configured `faas-runtime` image on the
shared `myapp_default` network. The generated service directory is mounted
read-only into that runtime. Agent containers never receive Docker or GitHub
credentials. See `faas-docker-runtime.md` for routing, cold-wake, and
scale-to-zero behavior.

On every successful deployment the backend records non-secret deployment
metadata under `faas_services.meta_json.deploy`, including the deploy mode and
runtime image.

## myapp-ctl

FaaS config is stored in:

```text
/etc/myapp/secrets.d/faas.env
/mnt/myapp/secrets.d/faas.env
```

The data-root layout includes:

```text
/mnt/myapp/faas/code
/mnt/myapp/faas/logs
/mnt/myapp/faas/tmp
```

Useful commands:

```bash
myapp-ctl secret init-stack
myapp-ctl faas config
myapp-ctl faas health
myapp-ctl faas ls --user-id <user-id>
myapp-ctl faas ls --user-id <user-id> --all
myapp-ctl faas disable <service-id> --user-id <user-id>
myapp-ctl faas mode local-docker
myapp-ctl faas git --enable --remote git@github.com:<org>/<repo>.git \
  --branch main --push --ssh-key-file /root/.ssh/myapp-faas-deploy-key \
  --known-hosts-file /root/.ssh/known_hosts
myapp-ctl image build faas-runtime --base
myapp-ctl deploy --group faas --build
myapp-ctl status faas-control faas-worker
myapp-ctl log backend -n 200
myapp-ctl log ai-worker -n 200
myapp-ctl faas smoke
myapp-ctl faas git-backend-smoke --yes
myapp-ctl faas ai-action-smoke
myapp-ctl faas ai-action-smoke --include-invalid
python3 backend/test_faas_store_controls.py
python3 backend/test_faas_invoke_routes.py
python3 backend/test_faas_ai_session_owner.py
python3 backend/test_faas_git_store.py
python3 backend/test_faas_runtime_bundle_endpoint.py
python3 backend/test_faas_runtime_server_bundle.py
```

`faas-control` and `faas-worker` are service-inventory aliases for the existing
backend and ai-worker containers. This lets operators update the FaaS control
path without inventing a second HTTP API in v0.

## 77 Test Gate

Before destructive testing on `ssh root@77.237.233.229`, back up host config:

```bash
tar -C / -czf /root/myapp-etc-backup-$(date +%Y%m%d-%H%M%S).tar.gz etc/myapp
myapp-ctl config export --out /root/myapp-config-backup-$(date +%Y%m%d-%H%M%S).json
```

Minimum verification:

- `myapp-ctl deploy --group faas --build` succeeds.
- `/api/faas/health` returns `ok`.
- A valid bundle creates a service row and code files.
- `scripts/faas_smoke_test.py` can deploy, invoke, and disable a test service.
- Invoking `/api/faas/invoke/<service_id>/...` starts or reuses the
  corresponding `myapp-faas-*` runtime container.
- `backend/test_faas_git_store.py` passes. This verifies backend-owned Git
  commit and push behavior against a local bare remote without exposing any key
  to Agent runtime.
- `myapp-ctl faas git-backend-smoke --yes` passes. This temporarily switches
  the deployed backend to `metadata` deploy mode with Git push enabled, deploys
  two versions of one service through `/api/faas/services`, verifies both
  commits reached a local bare remote, then restores the previous `faas.env`.
- `backend/test_faas_store_controls.py` passes. This verifies restricted bundle
  validation, per-user active service limits, cross-user `service_id`
  conflicts, declared Flask route coverage, restricted top-level module shape,
  disabling services, and runtime bundle materialization.
- `backend/test_faas_invoke_routes.py` passes. This verifies the invoke proxy
  only forwards routes and methods declared by the generated service contract
  while keeping empty-route legacy services compatible.
- `backend/test_faas_ai_session_owner.py` passes. This verifies FaaS deploy
  actions use the authenticated chat-session owner and can resolve agent-pull
  uploaded artifacts.
- `backend/test_faas_runtime_bundle_endpoint.py` passes. This verifies runtime
  bundle download is gated by the per-service runtime token before files are
  loaded.
- `backend/test_faas_runtime_server_bundle.py` passes. This verifies the generic
  runtime sends its token while downloading the validated bundle and only
  materializes allowed text files.
- `myapp-ctl faas ai-action-smoke` passes. This copies a smoke script into the
  deployed backend container, writes the same `faas_bundle.json` and
  `client_actions.json` artifacts an Agent would write, resolves
  `server_deploy_faas_service` through `ai_session._resolve_server_upload_actions`,
  invokes the generated service, and cleans it up.
- `myapp-ctl faas ai-action-smoke --include-invalid` passes. This also checks
  that an Agent-uploaded bundle with import-time side effects is rejected as a
  `faas_service_failed` action instead of creating a runnable service.
- `/api/faas/runtime_bundle/<service_id>` rejects missing or wrong runtime
  tokens and returns the validated service files with the correct token.
- A bundle with a forbidden import is rejected.
- The sixth active service for one user is rejected.
- `server_deploy_faas_service` works through agent-pull artifact upload.
- Existing JSON app generation still works.

## Executed production deployment — all-in-one on 77

The deployment is **all-in-one on a single host**. The live `myapp-ctl faas
smoke` passes, with generated code pushed to GitHub and served from the
git-pulled checkout.

- **77.237.233.229** = MyApp backend + the full Docker Compose stack, all
  co-located on one host. `FAAS_DEPLOY_MODE=local-docker`: each generated service
  runs as its own backend-owned `myapp-faas-*` Docker container on the shared
  `myapp_default` network, with the backend invoke proxy as the single front
  door. The isolated git push worker runs in `ai-worker`; service containers use
  the runtime image from Docker Hub
  (`dapangyufish/myapp-faas-runtime:agent-control-plane`).

Cold-start handling: the runtime (`faas_runtime_server.py`) listens immediately
and blocks the first request until the generated app loads; the invoke proxy
(`faas.py`) cold-wakes a stopped (scaled-to-zero) container and waits for the
service health endpoint before forwarding, so the first scale-from-zero invoke
never hits a connection error.

Strict git-source-of-truth (LIVE): the isolated push worker
(`backend/faas_push_worker.py`, default-on via `FAAS_GIT_ASYNC_PUSH`) commits the
user subtree and pushes to `myapp-faas-services`; a serve checkout
(`FAAS_BUNDLE_SERVE_ROOT`) pulls from GitHub and the runtime bundle is served from
that git checkout (not the local write). The backend image installs
`openssh-client` so the worker can push over SSH. The agent receives existing
services WITH source in `faas_services.json` to append routes without consuming a
new quota slot.

`myapp-ctl faas ls` and `myapp-ctl faas health` report the deployed services and
the running `myapp-faas-*` runtime containers.
