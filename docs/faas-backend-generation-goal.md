# Goal — AI-Generated FaaS Backends (All-in-One / Git-Pull-Mount Revision)

> 📌 **存档说明(2026-06):OpenFaaS/faasd 已被完全移除,唯一运行时为自研 Docker FaaS(详见 `docs/faas-docker-runtime.md`)。本文档仅作历史记录保留。**

Date: 2026-06-15
Branch: `feat/agent-control-plane`
Status: APPROVED DIRECTION — pending implementation

This `/goal` supersedes the runtime-delivery and host-topology assumptions in
`docs/faas-backend-generation.md` and `docs/faas-backend-generation-handoff.md`.
The validation/security/quota model already built there is kept; the runtime
substrate, code-delivery direction, node-management surface, and git-push
isolation are revised per the four decisions below.

## Locked Decisions (source of this revision)

1. **Runtime substrate (Q1 = "test coexistence first").** 77 is all-in-one.
   Phase 0 empirically tests whether real single-node **faasd** can co-locate
   safely with the existing MyApp Docker Compose stack (shared
   containerd / iptables / CNI). If clean → faasd/OpenFaaS is the runtime. If it
   conflicts → fall back to the already-built `local-docker` runtime. Everything
   else in this goal is identical for both outcomes.
2. **Git role (Q2 = "strict git-pull-mount").** The single GitHub repo
   `git@github.com:dapangyu-fish/myapp-faas-services.git` is the **runtime source
   of truth**. The backend NEVER serves code from a local write to the runtime;
   it pushes to GitHub, the faas-node `git pull`s, mounts the exact service path,
   and starts the service. This inverts the built model (local FS was the source,
   git was an optional mirror).
3. **Node management (Q3 = "thin single-node now").** Add
   `myapp-ctl faas node ls/status` over the single 77 node and keep
   `myapp-ctl faas ls` for services. Defer the full agent-node-style registry
   (join / capacity / pause / private / multi-node routing); when added, reuse
   the existing `agent_node_registry` pattern rather than inventing a parallel
   one.
4. **Push isolation (Q4 = "isolated worker + per-user subtree + retry").** Git
   push runs in a dedicated worker outside the backend request path AND outside
   any Agent container. Each operation commits only the one user's subtree.
   Pushes to the shared repo are serialized through a queue with retry/backoff.
   A single user's failure is logged and skipped without blocking others. The
   deploy key lives only in the worker (`/etc/myapp/secret-files`, referenced by
   path); Agent runtimes never receive it.

## Goals (目标)

G1. A user can ask the AI Agent to generate an APP that also needs backend logic.
    The Agent emits only artifacts (`faas_bundle.json` + `client_actions.json`);
    the backend validates, stores, pushes, and deploys. (Built — keep.)

G2. All AI-generated FaaS code lives in ONE GitHub repo
    (`myapp-faas-services`), Python + Flask only, laid out as the **repo
    contract**:

    ```text
    <uid[0:2]>/<uid[2:4]>/<uid>/<service_id>/
      app.py
      requirements.txt
      service.json
      README.md
    ```

    Example user root for uid `9aebdab8-3318-4dfa-99ff-54973bd28cf4`:

    ```text
    9a/eb/9aebdab8-3318-4dfa-99ff-54973bd28cf4/
    ```

    GitHub is the runtime source of truth. (Re-align the existing
    `users/.../services/...` layout to this contract; see C8.)

G3. 77 runs all-in-one: a single faas-node (faasd if Phase 0 passes, else
    local-docker) co-located with the main backend, both manageable by
    `myapp-ctl`.

G4. The faas-node is manageable like agent-node, at single-node scope now:
    `myapp-ctl faas node ls`, `myapp-ctl faas node status`, plus the existing
    `myapp-ctl faas ls` / `disable` / `health` for services. The faas-node image
    is built on 77 via `--build` now; a Docker Hub image is published later.

G5. Strict git-pull-mount runtime: `deploy → isolated push worker commits the
    user subtree → push to GitHub → faas-node git pull → mount the exact
    `<uid>/<service_id>/` path into a fixed-environment runtime → start`. Update =
    pull + restart that one service. No per-service image build; the runtime
    environment is fixed.

G6. Per-user fault-isolated push: concurrent deploys from different users cannot
    interfere; one user's bad commit/push is contained to that user's subtree and
    never corrupts or blocks another user's code or another service. No key leak;
    push isolated outside Agent containers.

G7. AI sees the user's existing services (ids, routes, descriptions) under their
    repo path and decides per request whether to **create a new service** or
    **append routes to an existing one**; only creates new when under the
    per-user cap.

G8. Default 5 services/user, backend-adjustable. (Built — keep.)

## Definition of Done (完成标准)

D0. **Phase 0 coexistence gate has a recorded verdict.** Documented, reproducible
    commands + outputs showing whether faasd co-exists with the Docker stack on
    77, and which runtime was therefore selected. `/etc/myapp` backed up and
    restorable before any destructive step.

D1. `myapp-faas-services` repo initialized (README, `main` branch) and reachable
    by the push worker (write) and the faas-node (read) with separate keys/access
    scopes.

D2. **Strict source-of-truth proven:** a generated service reaches the running
    runtime ONLY via GitHub. Backend writes nothing executable to the runtime's
    filesystem directly; disabling the GitHub pull path makes new code NOT appear
    at runtime (negative test).

D3. End-to-end happy path: conversation generates an APP with a backend → service
    pushed to GitHub at the contract path → faas-node pulls + mounts + starts →
    `/api/faas/invoke/<service_id>/<route>` returns the expected result with route
    and method enforcement intact.

D4. **Update path:** redeploying the same `service_id` pushes a new commit, the
    faas-node pulls and restarts only that service, and the new behavior is
    observed. Other services on the node are undisturbed.

D5. **Push isolation proven:** a smoke that deploys for two users concurrently
    where one user's push is forced to fail shows the failure logged and skipped
    while the other user's service deploys successfully. Deploy key present only
    in the worker; absent from backend request handlers and all Agent containers.

D6. `myapp-ctl faas node ls` and `myapp-ctl faas node status` report the 77 node
    (runtime mode, last-pulled commit, active service count, health). `faas ls`
    lists services. The faas-node image deploys on 77 via
    `myapp-ctl deploy --group faas --build`.

D7. AI create-vs-append works: the generator is given the user's existing service
    inventory; appending routes to an existing service does not consume a new
    quota slot; creating a 6th service for one user is still rejected.

D8. Disable releases a quota slot and stops/removes the running service (existing
    `DELETE /api/faas/services/<service_id>` behavior preserved).

D9. Regression: existing JSON-APP generation (no backend) is unaffected; existing
    FaaS unit tests still pass (re-pointed where the runtime model changed); new
    tests cover the git-pull-mount path and the isolated push worker.

D10. Docs updated: `docs/faas-backend-generation.md` reflects the all-in-one /
     git-pull-mount runtime and the new `faas node` commands; the handoff doc's
     "co-location forbidden" and "HTTP-bundle is the runtime" statements are
     corrected for the chosen path.

## Constraints (约束)

C1. **Agent runtime isolation (hard):** Agent containers never receive Git
    (push or pull) keys, Docker, OpenFaaS, registry, or `/etc/myapp` secrets.
    They only write `faas_bundle.json` + `client_actions.json`.

C2. **Python + Flask only**, enforced by the existing strict AST validator (file
    allowlist, dependency allowlist `flask`/`pydantic`/`python-dateutil`, import
    allowlist, required Flask `app`/`application`, no top-level side effects,
    reserved `/__myapp_faas_health` rejected, declared `service.routes` must be
    implemented by literal Flask decorators). Keep strict; widen only via narrow
    AST permissions plus negative tests.

C3. **One shared repo, per-user subtree isolation.** One user's invalid code or
    failed push must not corrupt or block another user's code, another service,
    or the shared repo's overall pushability.

C4. **Do not break the existing 77 Docker stack.** faasd is installed only if the
    Phase 0 coexistence test passes. `/etc/myapp` (especially secrets) is backed
    up and restorable before any destructive action. Destructive validation on 77
    is allowed provided the host is restored afterward.

C5. **Fixed runtime environment, no per-user/per-service image build.** One
    generic runtime image serves all services; user code is delivered by
    pull-mount (or, under faasd constraints, a scoped per-service slice — see N2),
    never baked into an image.

C6. **Read-key scope.** The faas-node host may hold a read deploy key to pull the
    repo (it is backend-controlled infra, not an Agent container), but individual
    function containers must NOT hold any git key and must see ONLY their own
    `<uid>/<service_id>/` path — never other users' code.

C7. **Out of scope this pass:** multi-node faasd + backend secondary routing,
    user-private faas-nodes, invoke auth (`FAAS_REQUIRE_AUTH` stays 0), and the
    Docker Hub faas-node image (build-on-77 now, publish later).

C8. **Repo layout is a contract.** Reconcile the built
    `users/<compact-uid>/services/<service_id>/` path to the agreed
    `<uid[0:2]>/<uid[2:4]>/<uid>/<service_id>/` (drop `users/` and `services/`
    segments). Keep a deterministic, path-safe transform for uids; document the
    final layout before the first push.

## Notes & Risks (注意 / 风险)

N1. **Co-location — RESOLVED (proven viable, now deployed).** The earlier
    `faasd-host-preflight` `docker-colocation` hard-fail was overly conservative
    and is now a non-blocking warning. Coexistence was empirically proven on both
    103 and 77: faasd and Docker share the one **system** containerd via separate
    namespaces (Docker `moby`, faasd `openfaas`/`openfaas-fn`) — no second
    containerd. The deployed architecture is **all-in-one on 77** (faasd
    co-located with the Docker stack), `FAAS_DEPLOY_MODE=openfaas` → local gateway.
    When the host `FORWARD` policy is `DROP`, add explicit `openfaas0` FORWARD
    `ACCEPT` rules; install faasd skipping its own containerd (reuse the system one).

N2. **faasd ↔ strict-mount wrinkle.** faasd functions cannot easily bind-mount
    arbitrary host paths the way `local-docker` can. If Phase 0 selects faasd,
    "mount the exact service path" is realized as: the **faas-node host** pulls
    the repo (holds the read key) and each function receives ONLY its own service
    slice — by host mount if faasd permits, otherwise by reusing the existing
    backend-validated **scoped** bundle endpoint (one service, no key in the
    function). GitHub remains the source of truth in both cases; this preserves
    C1/C6. Resolve the exact mechanism in Phase 0.

N3. **Keep the built openfaas HTTP-bundle path and its tests** as the future
    multi-node remote-fetch option; do not delete them when adding git-pull-mount.

N4. **Two local git trees on one host are fine:** the push worker has its own
    write working tree; the faas-node has a read-only pull checkout; both
    reconcile through GitHub. This is what makes "strict" honest on a single host.

## Phases (实施阶段 — high level)

P0. Back up `/etc/myapp`; run the faasd/Docker coexistence test on 77; record the
    verdict and select the runtime (faasd or local-docker).
P1. Initialize `myapp-faas-services`; finalize + document the repo-layout
    contract (C8); set up push-worker write access and faas-node read access.
P2. Build the isolated push worker (per-user subtree commit, serialized queue,
    retry/backoff, key isolation, fault containment).
P3. Build the faas-node: `git pull` → mount/deliver the exact service path into a
    fixed runtime → start; update = pull + restart one service; enforce
    GitHub-as-source-of-truth (no direct local serve).
P4. Add `myapp-ctl faas node ls/status`; wire the faas-node image into the `faas`
    deploy group; deploy on 77 via `--build`.
P5. AI generation side: surface the user's existing services to the generator and
    implement the create-vs-append decision under the quota cap.
P6. End-to-end smoke + 77 verification (happy path, update, push-isolation,
    disable) + docs update.

## 77 Test Gate (unchanged discipline)

Before destructive testing on `ssh root@77.237.233.229`:

```bash
tar -C / -czf /root/myapp-etc-backup-$(date +%Y%m%d-%H%M%S).tar.gz etc/myapp
myapp-ctl config export --out /root/myapp-config-backup-$(date +%Y%m%d-%H%M%S).json
```

Restore after any destructive step; never leave `/etc/myapp` secrets in a state
that needs manual human re-entry.
