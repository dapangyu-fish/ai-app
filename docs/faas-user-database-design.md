# Per-user FaaS database (schema isolation) — design

> **更新（FaaS 服务组权限模型）**：本文是最初的 per-USER schema 设计。现已演进为**服务组
> (Service Group) 模型**：每个服务组 = 1 个 FaaS + 可选 1 个 DB（1:1）；DB 租户键 `_db_tenant_key`
> 改为 **per-服务组**（新服务组 = service_id 各自独立库；历史默认组 `appd-<owner>` 仍复用 owner 旧
> schema，零迁移）；运行时角色改为**非属主**（仅 DML，DDL 仅部署期）；口令改为**随机 + Fernet
> 加密存储**（不再确定性派生，明文 DSN 列清空）；新增**后端中介数据访问层 `myapp_data`**（平台强制
> `owner=调用者`，函数不持 DSN）与**可信组内假名身份 `myapp_auth`**；`schema.sql` 禁 SERIAL（用 UUID）；
> 访问策略（组级 3 档：owner-only/allowlist/public）+ grant + 容器加固。详见 `CLAUDE.md`「FaaS 服务组权限模型」、
> `docs/playbooks/faas-jsonapp.md`，及 `~/faas-app-permission-*.md`。下文保留为底层 schema
> 隔离机制的原始设计参考。

Goal: give each user their own Postgres space so generated JSON-APP + FaaS
backends can persist real data (orders, listings, …), isolated per user by
**Postgres schema**, with a hard security boundary between tenants and away from
platform data. Target: DB-backed JSON-APPs at the complexity of a housing
(回家) or food-delivery (饿了么) app.

## Topology (grounded in 77)

- Cluster `myapp-jsonapp-postgres` (PG 15.8). Superuser role `jsonapp` owns the
  platform DB `jsonapp` (faas_services, chat_quotas, namespaces, …). The backend
  connects as `jsonapp` (superuser) → it can provision.
- **New dedicated database `userdata`** holds ALL user schemas, physically
  separate from the platform `jsonapp` DB. User roles can connect ONLY to
  `userdata`.

## Provisioning (idempotent, per user)

Triggered lazily on the first deploy of a DB-enabled FaaS service (bundle has
`db.enabled` or a `schema.sql`). Run by the backend as superuser `jsonapp`:

1. one-time: `CREATE DATABASE userdata`; `REVOKE ALL ON DATABASE userdata FROM PUBLIC`;
   in userdata `REVOKE ALL ON SCHEMA public FROM PUBLIC`; lock platform DBs:
   `REVOKE CONNECT ON DATABASE jsonapp, postgres FROM PUBLIC`.
2. role `u_<h>` where `h = sha256(user_id)[:16]`:
   `CREATE ROLE u_<h> LOGIN PASSWORD '<rand>' NOSUPERUSER NOCREATEDB NOCREATEROLE
   NOINHERIT CONNECTION LIMIT 8;`
3. schema `s_<h>` in userdata `AUTHORIZATION u_<h>` (role owns its schema).
4. grants + guards (least privilege):
   - `GRANT CONNECT ON DATABASE userdata TO u_<h>;`
   - `GRANT USAGE, CREATE ON SCHEMA s_<h> TO u_<h>;`
   - `ALTER ROLE u_<h> SET search_path = s_<h>;` (no `public`)
   - `ALTER ROLE u_<h> SET statement_timeout = '5s';`
   - `ALTER ROLE u_<h> SET idle_in_transaction_session_timeout = '10s';`
   - role has NO grant on any other schema, NO connect to platform DBs, NO
     superuser/file/role/extension powers.
5. store mapping in platform DB `faas_user_databases(user_id PK, db_name,
   schema_name, role_name, dsn_enc, created_at)`. `dsn_enc` = the scoped DSN
   (Fernet-encrypted with a host key; falls back to plaintext if no key — it is
   already a least-priv scoped cred).

## Access path from FaaS

- Backend injects the scoped DSN into the FaaS runtime as env `MYAPP_DB_DSN`
  (NOT bridged into the public `current_app.config["MYAPP"]`), only when the
  owner has a provisioned DB. DSN:
  `postgresql://u_<h>:<pw>@jsonapp-postgres:5432/userdata` (search_path pinned at
  role level; belt-and-suspenders `SET search_path` on connect too).
- The faas-runtime image carries `psycopg2-binary` + a baked helper module
  `myapp_db` exposing a tiny safe API:
  - `myapp_db.query(sql, params=None) -> list[dict]`
  - `myapp_db.execute(sql, params=None) -> int` (rowcount)
  - `myapp_db.queryone(sql, params=None) -> dict | None`
  - `myapp_db.tx()` context manager for multi-statement transactions
  - connects from `MYAPP_DB_DSN`, sets `search_path` + `statement_timeout`,
    returns dict rows; raises a clear error if DB not provisioned.
- Generated `app.py` does `import myapp_db` and never sees the raw DSN. The AST
  validator whitelists `myapp_db` (and `psycopg2` for power users; both are
  confined by the scoped role).

## DDL / migrations

- A DB-backed bundle declares `schema.sql` (idempotent DDL: `CREATE TABLE IF NOT
  EXISTS …` in the user's schema — no schema-qualified cross-schema refs needed,
  search_path handles it). Generated apps do NOT run DDL at request time.
- On deploy, after provisioning, the backend runs `schema.sql` against `userdata`
  **as the scoped role** (`SET ROLE u_<h>`) so objects land in `s_<h>` owned by
  the role. Caps: size ≤ 64 KB, ≤ 100 statements, statement_timeout. Validated
  to be DDL/DML only (no role/extension/COPY/…); even if abused, the role can
  only touch its own schema.

## Security boundary (threat model)

- **Cross-tenant**: role scoped to its own schema; no USAGE on others; public
  locked; can't connect to platform DBs → reading another tenant's data is
  impossible. Verified empirically on 77 before shipping.
- **Platform data**: separate DB + no CONNECT → unreachable from a user role.
- **SQL injection** in generated code: confined to the owner's own schema (only
  their own data at risk); no superuser, no `pg_read_server_files`/COPY-to-file,
  no `CREATE EXTENSION`. Helper encourages params.
- **DoS**: `statement_timeout=5s`, `connection limit=8`/role,
  `idle_in_transaction_session_timeout`. (Per-schema disk quota = follow-up.)
- **Secret exposure**: only the user's own least-priv scoped DSN reaches their
  own runtime; the platform superuser never does. Invoke proxy already strips
  sensitive request headers.

## Per-user quota

`FAAS_USER_DB_*` config: enable flag, max schemas (1/user for now), conn limit,
statement timeout. Provisioning is idempotent and cheap.

## Status

Design validated on 77 (isolation proof) → implemented in backend provisioning +
runtime helper + agent contract → exercised end-to-end (deepseek/minimax/glm)
building a 回家-style and a 饿了么-style JSON-APP.
