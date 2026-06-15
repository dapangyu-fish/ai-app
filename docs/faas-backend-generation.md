# AI Generated FaaS Backends

This document tracks the backend-generation path for JSON-APPs. It is aligned
with the current `agent-control-plane` architecture: Agent containers generate
artifacts only; backend-owned services perform validation, Git writes, and
deployment.

## Goal

Users can ask the AI Agent to generate an APP that also needs backend logic. The
Agent may create a restricted Python/Flask FaaS service bundle, and the MyApp
backend deploys it without exposing GitHub, Docker registry, OpenFaaS, or
`/etc/myapp` secrets to the Agent runtime.

The first supported runtime shape is:

- Python/Flask only.
- One service bundle per generated backend service.
- Default per-user limit: 5 active services.
- Auth-free invoke path for now.
- Backend-owned Git commit/push and deployment.
- OpenFaaS/faasd integration through a backend-controlled adapter.
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
- Agent runtime does not receive OpenFaaS admin credentials.
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

## Deploy Modes

`FAAS_DEPLOY_MODE=local-docker` is the default v0 runtime mode installed by
`myapp-ctl`. It validates, writes, and commits service code, then starts a
backend-owned runtime container named `myapp-faas-*` using the configured
`faas-runtime` image. The generated service directory is mounted read-only into
that runtime. Agent containers never receive Docker, GitHub, or OpenFaaS
credentials.

`FAAS_DEPLOY_MODE=metadata` validates, writes, and commits service code, then
marks the service ready without starting a runtime. It is useful only for
control-plane tests.

`FAAS_DEPLOY_MODE=script` calls:

```text
$FAAS_DEPLOY_SCRIPT <service_dir> <function_name> <service_id> <commit_sha>
```

Use this for host-specific experiments. The script can build or sync code using
whatever strategy a given faasd/OpenFaaS prototype needs.

`FAAS_DEPLOY_MODE=openfaas` deploys the same generic runtime image for every
generated service via the OpenFaaS REST API:

```text
PUT $FAAS_OPENFAAS_GATEWAY/system/functions
```

The runtime image does not contain user code. Instead, it starts with
`MYAPP_FAAS_BUNDLE_URL=/api/faas/runtime_bundle/<service_id>` and
`MYAPP_FAAS_RUNTIME_TOKEN=<token>`, downloads the backend-validated bundle, and
loads `app.py`. This avoids per-user Docker image builds and keeps registry and
OpenFaaS credentials outside Agent containers.

On every successful deployment the backend records non-secret deployment
metadata under `faas_services.meta_json.deploy`, including the deploy mode,
OpenFaaS gateway, runtime image, and bundle base URL. In `openfaas` mode,
invocation and disable/delete operations prefer the gateway recorded on the
service and fall back to the current global `FAAS_OPENFAAS_GATEWAY`. This keeps
the current single-gateway behavior unchanged while leaving a migration path for
multiple single-node faasd gateways and backend-side routing later.

Important deployment constraint: the OpenFaaS Edge/faasd prerequisites state
that faasd must not be co-located with Docker because both use containerd,
iptables, and CNI. Since the current MyApp stack is Docker Compose based, the
safe production shape is:

```text
MyApp backend host/container  ->  external OpenFaaS/faasd gateway host
```

On a MyApp Docker host such as the current 77 test machine, use
`FAAS_DEPLOY_MODE=local-docker` for full backend-generation validation, or use
`FAAS_DEPLOY_MODE=openfaas` only against an external gateway. Do not install
faasd on the same host that is running the MyApp Docker Compose stack unless
that host is being repurposed exclusively for faasd.

Required OpenFaaS mode settings:

```text
FAAS_DEPLOY_MODE=openfaas
FAAS_OPENFAAS_GATEWAY=http://<gateway>:8080
FAAS_OPENFAAS_USERNAME=admin
FAAS_OPENFAAS_PASSWORD=<gateway-password>
FAAS_OPENFAAS_RUNTIME_IMAGE=dapangyu/myapp-faas-runtime:agent-control-plane
FAAS_RUNTIME_BUNDLE_BASE_URL=https://<backend-domain>
FAAS_RUNTIME_TOKEN=<random-secret>
```

External faasd host bring-up checklist:

1. Use a dedicated host that is not running the MyApp Docker Compose stack.
2. Install faasd following the OpenFaaS Edge/faasd documentation, keep the
   gateway reachable from the MyApp backend host, and record the generated
   gateway password outside Git.
3. Ensure the faasd host can pull `FAAS_OPENFAAS_RUNTIME_IMAGE`.
4. Ensure the faasd function runtime can reach
   `FAAS_RUNTIME_BUNDLE_BASE_URL/api/faas/runtime_bundle/<service_id>`.
5. Run `myapp-ctl faas openfaas-gateway-check` before changing backend mode.
6. Run `myapp-ctl faas openfaas-gateway-smoke --yes` on a disposable/test
   environment before promoting the gateway.

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
myapp-ctl faas mode script --deploy-script /opt/myapp/faas/deploy-service.sh
myapp-ctl faas mode openfaas --gateway http://<openfaas-gateway>:8080 \
  --bundle-base-url https://<backend-domain> \
  --password-env OPENFAAS_PASSWORD
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
myapp-ctl faas openfaas-runtime-smoke --pull-image
myapp-ctl faas openfaas-backend-smoke --yes
OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-check \
  --gateway http://<real-faasd-gateway>:8080 \
  --bundle-base-url https://<backend-domain> \
  --password-env OPENFAAS_PASSWORD
OPENFAAS_PASSWORD=<password> myapp-ctl faas openfaas-gateway-smoke --yes \
  --gateway http://<real-faasd-gateway>:8080 \
  --bundle-base-url https://<backend-domain> \
  --password-env OPENFAAS_PASSWORD
python3 backend/test_faas_store_controls.py
python3 backend/test_faas_invoke_routes.py
python3 backend/test_faas_ai_session_owner.py
python3 backend/test_faas_git_store.py
python3 backend/test_faas_runtime_bundle_endpoint.py
python3 backend/test_faas_runtime_server_bundle.py
python3 backend/test_faas_openfaas_gateway.py
python3 backend/test_faas_openfaas_gateway_check.py
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
- In `local-docker` mode, invoking `/api/faas/invoke/<service_id>/...` starts or
  reuses the corresponding `myapp-faas-*` runtime container.
- `backend/test_faas_openfaas_gateway.py` passes. This verifies the backend
  OpenFaaS adapter against an HTTP fake gateway and checks create/update/delete
  method selection and runtime payload shape.
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
  while keeping empty-route legacy services compatible, and verifies
  service-recorded OpenFaaS gateways take precedence in `openfaas` mode.
- `backend/test_faas_ai_session_owner.py` passes. This verifies FaaS deploy
  actions use the authenticated chat-session owner and can resolve agent-pull
  uploaded artifacts.
- `backend/test_faas_runtime_bundle_endpoint.py` passes. This verifies runtime
  bundle download is gated by the per-service runtime token before files are
  loaded.
- `backend/test_faas_runtime_server_bundle.py` passes. This verifies the generic
  runtime sends its token while downloading the validated bundle and only
  materializes allowed text files.
- `myapp-ctl faas openfaas-runtime-smoke` passes. This starts a local
  OpenFaaS-compatible test gateway backed by Docker, deploys the generic
  runtime image with the same payload shape used for OpenFaaS, verifies the
  runtime downloads its bundle with the per-service token, invokes the function,
  updates it, and deletes it. This is a runtime contract test, not a substitute
  for a real faasd/OpenFaaS gateway test.
- `myapp-ctl faas openfaas-backend-smoke --yes` passes on a disposable/test
  host. This temporarily switches the deployed backend to `FAAS_DEPLOY_MODE=openfaas`,
  restarts the FaaS control services, runs the public FaaS smoke test through a
  local OpenFaaS-compatible gateway, then restores the previous `faas.env`. It
  does not pull stack images unless `--pull-stack` is supplied.
- `myapp-ctl faas ai-action-smoke` passes. This copies a smoke script into the
  deployed backend container, writes the same `faas_bundle.json` and
  `client_actions.json` artifacts an Agent would write, resolves
  `server_deploy_faas_service` through `ai_session._resolve_server_upload_actions`,
  invokes the generated service, and cleans it up.
- `myapp-ctl faas ai-action-smoke --include-invalid` passes. This also checks
  that an Agent-uploaded bundle with import-time side effects is rejected as a
  `faas_service_failed` action instead of creating a runnable service.
- `myapp-ctl faas openfaas-gateway-smoke --yes --gateway <real-gateway>
  --bundle-base-url <backend-url>` passes against a real external faasd/OpenFaaS
  gateway. This temporarily switches the deployed backend to the real gateway,
  runs the public FaaS smoke test, then restores the previous `faas.env`.
- `myapp-ctl faas openfaas-gateway-check --gateway <real-gateway>
  --bundle-base-url <backend-url>` passes before the destructive gateway smoke.
  This does not change backend configuration; it checks gateway health,
  `/system/functions` authentication, and backend FaaS health reachability from
  the operator host.
- In `openfaas` mode, OpenFaaS lists the generated function and invocation via
  `/api/faas/invoke/<service_id>/...` reaches the generic runtime image.
- `/api/faas/runtime_bundle/<service_id>` rejects missing or wrong runtime
  tokens and returns the validated service files with the correct token.
- A bundle with a forbidden import is rejected.
- The sixth active service for one user is rejected.
- `server_deploy_faas_service` works through agent-pull artifact upload.
- If `FAAS_DEPLOY_MODE=script` fails, only that service deployment is marked
  failed.
- Existing JSON app generation still works.

Do not mark this feature complete until `openfaas-gateway-smoke` is proven
against a real external faasd/OpenFaaS gateway and the deploy path is documented
with the observed commands.
