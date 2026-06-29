# RFC: 给 jsonapp-postgres 接入 PgBouncer 连接池（双实例）

- **状态**: ✅ 已落地并在 77 端到端验证通过（仓库改动未提交，见 §9 遗留）
- **范围**: 后端需求（`backend/`、`deploy/production/`）
- **目标环境**: 77（`root@77.237.233.229`，测试环境，手动迁移）；正式生产尚未部署，不考虑生产迁移
- **作者**: Claude（基于 2026-06-29 对 77 现网的只读核实）
- **本版变更**: 范围扩大为「**后端常规链路 + FaaS 运行时链路都进池**」；采用 **2 个专用 PgBouncer 按信任边界拆**（`pgbouncer-faas` / `pgbouncer-platform`）；**3 类特殊连接直连旁路**。

---

## 1. 背景与现状

当前所有数据库连接都是**直连**，没有任何连接池。整个部署里有**两套独立的 Postgres 集群**：

| 集群 | 镜像 / 容器 | 网络 | 端口 | 用途 | 现有池子 |
|------|------------|------|------|------|----------|
| **A. supabase-db** | `supabase/postgres:15.8.1.085` / `supabase-db` | `supabase_default` | 经 supavisor（默认 15432） | Auth/PostgREST/Realtime/Storage/Analytics | ✅ 已有 **supavisor**（transaction） |
| **B. jsonapp-postgres** | `postgres:15.8` / `myapp-jsonapp-postgres` | `myapp_default`（容器 IP `172.18.0.3`） | `172.18.0.1:5432`（仅 docker 网桥网关，非 0.0.0.0） | **平台库 `jsonapp`** + **FaaS 用户库 `userdata`** | ❌ 无 |

**集群 A 已有 supavisor，本 RFC 不动它。** 本 RFC 只给**集群 B（jsonapp-postgres）**加池，它一套实例承载两个库——这也是"有多个数据库"的来源：

- **`jsonapp` 库**：平台元数据（registry、store、`faas_user_databases` 等），后端以超级用户 `jsonapp` 短连接读写。
- **`userdata` 库**：FaaS 每用户数据，**schema 隔离**——每服务组一个 `s_<hash>` schema + 一对角色 `u_<hash>`(LOGIN, 随机口令, `CONNECTION LIMIT 8`) / `o_<hash>`(NOLOGIN, schema owner)。

### 1.1 连接来源盘点（决定池化策略的关键）

| # | 连接方 | 代码 / 运行容器 | 目标库 | 角色 | 连接特征 | 会话级特性 |
|---|--------|----------------|--------|------|----------|-----------|
| 1 | 后端常规查询 | `database.py` / `registry_catalog.py`（backend/registry/ai-worker/faas-push-worker） | jsonapp | `jsonapp`(超级用户) | **每查询新建/关闭**（无池） | 无（自包含，池化安全） |
| 2 | Registry 选主 | `registry_enrich.py:40`（**registry** 容器后台线程） | jsonapp | `jsonapp` | **worker 生命周期长连接** | `pg_try_advisory_lock` ⚠️**会话级** |
| 3 | FaaS 库 provision/迁移 | `faas_userdb._admin_conn`（**backend**+**ai-worker**：经 `faas.py`/`faas_store.py`/`ai_session.py`） | jsonapp/userdata/postgres | `jsonapp`(超级用户) | 短连接 autocommit | `CREATE DATABASE/ROLE`、迁移时 `SET ROLE`+`SET search_path` ⚠️**会话级** |
| 4 | **FaaS 运行时 `myapp_db`** | `faas_runtime_db.py`（**函数容器内**，独立网络） | **userdata** | **`u_<hash>`** | thread-local 长连接 + `tx()` | 角色级 `search_path`/`statement_timeout` 默认值 |
| 5 | **FaaS 网关 `myapp_data`** | `faas_data.py`（**backend** 中介） | **userdata** | **`u_<hash>`** | **每操作新建/关闭** autocommit | 同上 |

**两类连接，两种诉求**：
- **租户面（#4/#5，`u_*` → userdata）**：连接随用户/函数线性增长（77 已 12 个 `u_`），是真正的**连接风暴源**；语义上 autocommit + 单事务，**适合 transaction 池**。
- **平台面（#1/#2/#3，超级用户 → jsonapp/userdata）**：连接数**有界**（固定 worker 数），但 #1 是高频建连 churn，#2/#3 带 **advisory lock 与 `SET ROLE`/DDL** 等**强会话依赖**。

> 77 现网实测：`userdata` 有 **9 个 `o_` + 12 个 `u_` 角色**；`max_connections=100`、`password_encryption=scram-sha-256`、当前活动连接仅 6。

---

## 2. 设计决策

### D1 — 只纳管 jsonapp-postgres，supabase 不动
集群 A 已有 supavisor。本 RFC 只为集群 B 加池。

### D2 — 动态角色 ⇒ 用 `auth_query`，不存任何业务角色明文
`u_<hash>` 角色随用户持续新增、口令随机且 Fernet 加密存平台库，PgBouncer 维护不了静态 userlist。
**两个池都用 `auth_query`**：建最小权限角色 `pgbouncer_auth` + `SECURITY DEFINER` 查找函数（属主超级用户，可读 `pg_authid.rolpassword`）。`auth_type=scram-sha-256`，客户端用明文口令以 SCRAM 握手 → PgBouncer 凭 auth_query 校验 + **SCRAM pass-through**（≥1.15，从客户端 proof 还原 ClientKey）登录后端服务器。**`userlist.txt` 只放 `pgbouncer_auth` 一行明文**（它需自登录才能跑 auth_query，是唯一鸡生蛋例外；该角色除查找函数外无任何权限）。`jsonapp` 超级用户同样走 pass-through，**不落明文**。

### D3 — 用 **2 个专用 PgBouncer**，按信任边界拆（核心）
不用「一个实例 + per-db pool_mode」，因为单实例会被迫把**超级用户能力的端点暴露到租户网桥**、且把租户/平台的爆炸半径耦合在一个单线程进程上。改为：

| | **pgbouncer-faas**（租户面） | **pgbouncer-platform**（平台面） |
|---|---|---|
| 服务库 | **仅 `userdata`** | **仅 `jsonapp`** |
| pool_mode | **transaction** | **session** |
| 认证 | `auth_query`（动态 `u_*`），`auth_dbname=userdata` | `auth_query`（单一 `jsonapp`），`auth_dbname=jsonapp` |
| 网络暴露 | **发布 `172.18.0.1:6432`**（函数容器跨网络可达） | **不发布**，仅 `myapp_default`，后端经 DNS `pgbouncer-platform:6432` |
| 客户端 | 函数容器 `MYAPP_DB_DSN`（#4）+ 网关 `myapp_data`（#5） | 后端常规 CRUD（#1） |
| 关键性质 | **没有 `jsonapp` 条目** → 拿到凭据也路由不到平台库 | **超级用户池永不出 `myapp_default`** |

收益：租户面**结构性无法触达平台库**（不是靠口令拦，是没路由）；平台超级用户池**不暴露在网桥**；两边可独立调参/重启；单线程瓶颈在本规模无压力（PgBouncer 单进程可扛数千客户端连接，未来真到瓶颈再上 SO_REUSEPORT 多进程）。成本可忽略（每个 ~几 MB）。

### D4 — 3 类特殊连接**直连旁路**（不进任何池）
DDL/provisioning（#3）和 advisory-lock（#2）既不能进 transaction 池（`SET ROLE`/锁会被打散/串号），进 session 池又会**常驻占槽**，且 provision 要连 `userdata` 而 platform 池根本没有该库条目。**正确形态是让它们直连 `jsonapp-postgres:5432`**。

为此加一对**向后兼容**的环境旁路开关（默认 = 现有 `DB_HOST/DB_PORT`，**默认行为不变**），需改 3 个文件（纯增量）：

| 文件 | 改动 |
|------|------|
| `backend/config.py` | 新增 `DB_DIRECT_HOST = env("DB_DIRECT_HOST", DB_HOST)`、`DB_DIRECT_PORT = env("DB_DIRECT_PORT", DB_PORT)` |
| `backend/faas_userdb.py` | `_admin_conn` 的 `ADMIN_HOST/PORT` 改读 `DB_DIRECT_HOST/PORT`（#3 旁路） |
| `backend/registry_enrich.py` | advisory-lock 连接（:107 附近）改读 `DB_DIRECT_HOST/PORT`（#2 旁路） |

> 注：#3 的 `save_enrich`/普通写仍走 `registry_catalog._conn`（→ platform 池），只有那条 advisory-lock 长连接旁路。

### D5 — pool_mode 路由矩阵（汇总）
| 连接类 | 走向 | pool_mode | 理由 |
|--------|------|-----------|------|
| #4/#5 `u_*` → userdata | **pgbouncer-faas** | **transaction** | 扩容压力点；autocommit + `tx()` 单事务落单 server 连接，安全；角色级默认值经 `DISCARD ALL`/`RESET ALL` 重新套用不丢 |
| #1 超级用户常规 CRUD → jsonapp | **pgbouncer-platform** | **session** | 消除每查询建连 churn、收敛连接数；保守用 session（后端连接基数低，多路复用收益次要） |
| #2 advisory-lock / #3 DDL·迁移 | **直连 `jsonapp-postgres:5432`** | — | 会话级锁 + `SET ROLE`/`CREATE DATABASE`，绝不进池 |

> session vs transaction（platform）：因 #2/#3 已旁路，platform 池残留的只剩自包含的 #1，**理论上也可 transaction**；但后端连接基数低（eventlet+阻塞 psycopg2 ≈ 每 worker 1 个在途查询），session 更保守、差异无关紧要。**默认 session**。

### D6 — 网络与端口
两个 PgBouncer 都挂 `myapp_default`，上游都用 DNS `jsonapp-postgres:5432`（内网，不经网桥）。
- `pgbouncer-faas`：**发布 `172.18.0.1:6432`**。函数容器在独立网络，今天就靠 `172.18.0.1:5432` 连库，故 `172.18.0.1:6432` 同样可达；后端网关也可经网桥网关或 DNS 访问。
- `pgbouncer-platform`：**无 `ports`**，仅内网；后端经 DNS `pgbouncer-platform:6432`。
- `jsonapp-postgres:5432` **保持发布**（旁路直连、手动 psql、回滚都要它）。

### D7 — 连接预算（保护 Postgres）
| 池 | `default_pool_size` | `min_pool_size` | `max_db_connections` | 说明 |
|----|--------------------|-----------------|----------------------|------|
| faas (userdata) | 5 | **0** | 50 | 每 (user,db) ≤ 角色 `CONN LIMIT 8`；空闲用户不占连接 |
| platform (jsonapp) | 25 | 0 | 40 | 覆盖 4 个服务的并发查询 |
| 直连旁路 | — | — | ~15 | advisory(每 worker 1)+provision 短连接 |

最坏 ≈ 50+40+15 = 105 > 当前 `max_connections=100`。**因此双实例方案下，建议把 `jsonapp-postgres` 的 `max_connections` 提到 200**（测试环境也建议做，避免 `too many connections`）。

---

## 3. 部署步骤（精确到 77）

### Step 0 — 前置（已核实，无需操作）
77：`jsonapp-postgres` 在 `myapp_default`、发布 `172.18.0.1:5432`、`scram-sha-256`、有 `jsonapp`/`userdata` 两库；网桥网关 `172.18.0.1/16`；无既存 pgbouncer。

### Step 1 — Postgres 侧 SQL bootstrap（77 手动，一次性）
建 auth 角色（集群全局，建一次）+ 在 **`userdata` 和 `jsonapp` 两个库**各建一份查找函数（各自 `auth_dbname` 自包含）：

```bash
# 77 上：准备 pgbouncer_auth 口令（记录到 secrets，Step 2 userlist 要用）
PGB_AUTH_PW="$(openssl rand -hex 24)"
echo "pgbouncer_auth password = $PGB_AUTH_PW"

# 1) 角色（全局，建一次；先连 jsonapp 库执行 CREATE ROLE 即可）
docker exec -i myapp-jsonapp-postgres psql -U jsonapp -d jsonapp -c \
  "CREATE ROLE pgbouncer_auth LOGIN PASSWORD '${PGB_AUTH_PW}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;"

# 2) 在 userdata 和 jsonapp 各建查找函数 + 授权（循环两库）
for DB in userdata jsonapp; do
docker exec -i myapp-jsonapp-postgres psql -U jsonapp -d "$DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION jsonapp;
CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(
  IN i_username text, OUT uname text, OUT phash text
) RETURNS record
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT rolname::text, rolpassword::text
  FROM pg_catalog.pg_authid WHERE rolname = i_username;
$$;
REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM public;
GRANT USAGE   ON SCHEMA pgbouncer             TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;
SQL
done
```

> `pgbouncer_auth` 除执行该函数外**无任何库权限**；SCRAM 校验串不可逆推明文，且只有 PgBouncer 进程能调用。

### Step 2 — 两份配置文件（入仓库 `deploy/production/pgbouncer/`）

**`pgbouncer/faas.ini`**（租户面）：
```ini
[databases]
userdata = host=jsonapp-postgres port=5432 dbname=userdata pool_mode=transaction

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type   = scram-sha-256
auth_file   = /etc/pgbouncer/userlist.txt
auth_user   = pgbouncer_auth
auth_dbname = userdata
auth_query  = SELECT uname, phash FROM pgbouncer.user_lookup($1)

pool_mode               = transaction
default_pool_size       = 5
min_pool_size           = 0
reserve_pool_size       = 3
reserve_pool_timeout    = 3
max_db_connections      = 50
max_client_conn         = 2000
server_idle_timeout     = 30
server_lifetime         = 1800
server_reset_query      = DISCARD ALL
server_reset_query_always = 0
ignore_startup_parameters = extra_float_digits,options
admin_users = pgbouncer_auth
stats_users = pgbouncer_auth
```

**`pgbouncer/platform.ini`**（平台面）：
```ini
[databases]
jsonapp = host=jsonapp-postgres port=5432 dbname=jsonapp pool_mode=session

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type   = scram-sha-256
auth_file   = /etc/pgbouncer/userlist.txt
auth_user   = pgbouncer_auth
auth_dbname = jsonapp
auth_query  = SELECT uname, phash FROM pgbouncer.user_lookup($1)

pool_mode               = session
default_pool_size       = 25
min_pool_size           = 0
reserve_pool_size       = 5
max_db_connections      = 40
max_client_conn         = 500
server_idle_timeout     = 60
server_lifetime         = 1800
ignore_startup_parameters = extra_float_digits,options
admin_users = pgbouncer_auth
stats_users = pgbouncer_auth
```

**`userlist.txt`**（**只一行**，明文走 secrets，**不入 git**；仓库放 `userlist.txt.example`）：
```
"pgbouncer_auth" "<PGB_AUTH_PW>"
```

### Step 3 — 两个 compose 服务（`docker-compose.core.yml` 新增）
```yaml
  pgbouncer-faas:
    image: edoburu/pgbouncer@sha256:4c1ca296ef525f108f5d3552cc337c0c09587cf8dae7f0067fd93349e47dc1cd  # 1.25.2（≥1.15 SCRAM pass-through）；77 镜像站仅缓存 :latest，故钉 digest
    container_name: myapp-pgbouncer-faas
    restart: unless-stopped
    depends_on:
      jsonapp-postgres: { condition: service_healthy }
    volumes:
      - ./pgbouncer/faas.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ${MYAPP_RUNTIME_SECRETS_DIR:-/mnt/myapp/secrets.d}/pgbouncer-userlist.txt:/etc/pgbouncer/userlist.txt:ro
    ports:
      - "${JSONAPP_PG_BIND_ADDR:-172.18.0.1}:6432:6432"   # 发布到网桥，函数容器可达
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U pgbouncer_auth || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

  pgbouncer-platform:
    image: edoburu/pgbouncer:v1.23.1
    container_name: myapp-pgbouncer-platform
    restart: unless-stopped
    depends_on:
      jsonapp-postgres: { condition: service_healthy }
    volumes:
      - ./pgbouncer/platform.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ${MYAPP_RUNTIME_SECRETS_DIR:-/mnt/myapp/secrets.d}/pgbouncer-userlist.txt:/etc/pgbouncer/userlist.txt:ro
    # 不发布端口：仅 myapp_default 内可达
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U pgbouncer_auth || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
```
并在 `install_ctl.sh` 把 `deploy/production/pgbouncer/` 一起 `cp` 到安装根（参照 `edge-nginx`/`supabase` 同步逻辑），让 `myapp-ctl deploy` 能找到 `./pgbouncer/*.ini`。

### Step 4 — 代码侧加 `DB_DIRECT_*` 旁路开关（向后兼容，3 文件）
见 **D4** 表：`config.py` 新增 `DB_DIRECT_HOST/PORT`（默认回落 `DB_HOST/PORT`）；`faas_userdb._admin_conn` 与 `registry_enrich` 的 advisory-lock 连接改读它。**不设这两个 env 时行为与今天完全一致**。

### Step 5 — env 切换（4 个后端服务：backend / ai-worker / faas-push-worker / registry）
每个服务 `environment` 改 / 加：
```yaml
      DB_HOST: pgbouncer-platform          # 原 jsonapp-postgres，常规 CRUD 进 platform 池
      DB_PORT: "6432"
      DB_DIRECT_HOST: jsonapp-postgres      # DDL/provision/advisory 直连旁路
      DB_DIRECT_PORT: "5432"
      FAAS_USER_DB_RUNTIME_HOST: "172.18.0.1"   # FaaS 运行时 → faas 池
      FAAS_USER_DB_RUNTIME_PORT: "6432"
```
> 4 个服务都要设 `DB_DIRECT_*`：provision 在 backend/ai-worker，advisory 在 registry；faas-push-worker 设了也无害。`FAAS_USER_DB_RUNTIME_*` 只有构造 DSN 的后端真正读取（函数容器拿的是构造好的 `MYAPP_DB_DSN`）。

### Step 6 — 拉起、切流、（建议）提 max_connections
```bash
# 77
myapp-ctl deploy     # 起两个 pgbouncer + 用新 env 重建 4 个后端服务
# 建议：jsonapp-postgres 提 max_connections 到 200（compose command 或 ALTER SYSTEM + 重启）
```
> **存量函数**容器内 `MYAPP_DB_DSN` 仍是旧 `:5432`，继续直连（仍可用）；**新部署/冷唤醒**才拿到 `:6432`。测试环境可逐个 redeploy 全量切换。

---

## 4. 验证清单
1. **两池自检**：`docker exec -it myapp-pgbouncer-faas psql -h 127.0.0.1 -p 6432 -U pgbouncer_auth pgbouncer -c 'SHOW DATABASES; SHOW POOLS;'`；platform 同理（容器内执行，因其不发布）。
2. **租户路由隔离**：从 platform 池**连不到** userdata（`\c userdata` 应失败 / 无此 db）；从 faas 池**连不到** jsonapp（验证 D3 的"没路由"性质）。
3. **`u_*` 经 faas 池**：`psql "postgresql://u_xxx:<pw>@172.18.0.1:6432/userdata" -c "select current_user, current_setting('search_path');"` → 角色与 schema 正确（auth_query + 角色级默认值生效）。
4. **后端常规链路经 platform 池**：后端读写正常；`SHOW POOLS` 见 jsonapp 池 server 连接复用、`sv_active` 合理、空闲随 `server_idle_timeout` 回落。
5. **旁路仍直连**：部署一个带 `schema.sql`+`myapp_db` 的 FaaS app（provision/迁移走直连）成功；registry enrich 选主正常（advisory 直连）。
6. **端到端**：经 `/api/faas/invoke` 跑 INSERT+SELECT，数据落隔离 schema；faas 池见复用。
7. **隔离不回归**：跨租户读、写 public、连平台库仍被拒（沿用现有 `faas_userdb` 安全测试）。

## 5. 回滚
1. 4 个服务 env 还原（`DB_HOST=jsonapp-postgres:5432`，去掉 `DB_DIRECT_*`/`FAAS_USER_DB_RUNTIME_*`）→ `myapp-ctl deploy` → 全链路回直连。代码侧 `DB_DIRECT_*` 是惰性默认，留着无副作用。
2. `docker compose ... rm -sf pgbouncer-faas pgbouncer-platform`。
3. （可选）`DROP FUNCTION/SCHEMA pgbouncer; DROP ROLE pgbouncer_auth;`（两库）。
全程不动 Postgres 数据，纯增量、可瞬时回退。

## 6. 风险与开放问题
- **SCRAM pass-through 版本依赖**：PgBouncer ≥1.15（用 1.23.x）。部署前用验证步骤 3 证伪。
- **存量函数旧 DSN**：见 Step 6，需 redeploy 全量切换；测试环境可渐进。
- **`max_connections=100` 余量**：双实例下建议提到 200（Step 6）。
- **角色级 `idle_in_transaction_session_timeout=10s` 与 transaction 池**：`myapp_db.tx()` 内长事务空闲超 10s 会被中断——既有行为，与池无关，保持事务短小。
- **跨容器 env 覆盖**：4 个后端服务都要正确设 `DB_DIRECT_*`，否则 provision→userdata 会误打到 platform 池（无该库条目而失败）——部署后用验证步骤 5 兜底。

## 7. 其他数据库链路优化点（审计结论）

对 DB 链路做了一次 5 维度代码审计（驱动并发 / 事务语义 / schema 与索引 / 最小权限 / 韧性可观测），逐条对抗式核实，确认 22 项。**最关键的发现：PgBouncer 解决"连接"，但解决不了下面 P0-1 这个"并发天花板"**——它和接池同等重要，甚至更优先。

### P0 — 高优先（建议与 PgBouncer 同批做）

| # | 问题 | 证据 | 修复 | 与 PgBouncer 关系 |
|---|------|------|------|------------------|
| **P0-1** | **psycopg2(C/libpq) 不配合 eventlet**：`app.py:14` 只 `eventlet.monkey_patch()` 了 stdlib socket，psycopg2 的网络 IO 在 C 层绕过补丁。**每条查询阻塞整个 worker hub**，`-w 10` 全平台只能同时跑 ~10 条查询，一个慢查询 head-of-line 卡住所有 greenlet（含 SocketIO/SSE） | `app.py:14`；`requirements.txt:5`(psycopg2-binary)；全仓 grep `psycogreen/wait_callback`=0；`database.py:40`/`faas_data.py:74` 阻塞 `cur.execute` | `eventlet.monkey_patch()` 后加 `psycogreen.eventlet.patch_psycopg()`（装 libpq wait_callback，网络等待时让出 hub）。**2 行，影响巨大** | **PgBouncer 不解决此问题**（execute 仍阻塞 hub）。务必单独做。注：仅影响 `app:app`（eventlet）；`registry` 是 `-k gthread` 不受影响，`faas_runtime` 在函数容器内 |
| **P0-2** | 后端超级用户连接**无 statement_timeout / idle_in_tx / connect_timeout**：失控查询或挂死主机**永久占住连接（叠加 P0-1 即占住整个 worker）** | `database.py:14`、`registry_catalog.py:38`、`registry_init.py:36` 的 `connect()` 均无 timeout | 给后端角色 `ALTER ROLE jsonapp SET statement_timeout='15s'` + `idle_in_transaction_session_timeout='30s'`；所有 `connect()` 加 `connect_timeout=5`。**advisory-lock 那条连接豁免 statement/idle 超时** | connect_timeout 之后作用于 backend↔PgBouncer（本地、快）；另配 PgBouncer 的 `server_connect_timeout` |
| **P0-3** | **后端所有常规 CRUD 都以集群超级用户 `jsonapp` 执行**，无最小权限应用角色 | `config.py` DB_USER=jsonapp(超级用户)；`database.py`/`store.py`/`registry_catalog.py` 全用它 | 拆凭据：超级用户**只**留给 provision/DDL（`faas_userdb`/`registry_init`），请求路径换一个 `NOSUPERUSER NOCREATEDB NOCREATEROLE` 登录角色，仅授 `CONNECT + DML + 序列 USAGE` | 正好**强化**"runtime 非属主、DDL 仅部署期属主"不变量（平台库目前违反） |

### P1 — 中优先（接池后续批次）

| # | 问题 | 修复要点 | 备注 |
|---|------|---------|------|
| **P1-1** | 后端角色**无 CONNECTION LIMIT**，查询风暴可耗尽 `max_connections=100` | `ALTER ROLE jsonapp CONNECTION LIMIT <N>`，并给 provision 路径独立小限角色 | 与 PgBouncer 收敛 server 连接互补 |
| **P1-2** | userdata 多租户**无 RLS**，隔离仅靠 schema+role+应用层 WHERE | 部署期以 `o_*` 属主 `ENABLE/FORCE ROW LEVEL SECURITY` + `POLICY USING (owner = current_setting('myapp.caller',true))`；`faas_data.run_data_op` 每次 `SET LOCAL myapp.caller=<假名>` | `o_/u_` 拆分 + `owner` 列**当初就是为 FORCE RLS 设计的**，这是补全 |
| **P1-3** | FaaS 多租户表**热 `owner` 过滤列无索引**（模板/playbook 都没带） | playbook 范例加 `CREATE INDEX ... (owner)`（理想 `(owner, created_at)`）；`run_user_migration` 对带 owner 列的表自动建索引 | 部署期属主 DDL，合规 |
| **P1-4** | `record_install` 在**实时请求路径跑 CREATE TABLE/INDEX + 回填 INSERT...SELECT**（超级用户身份所以没报错） | 移进 schema.sql / 部署迁移，从请求路径删 `_ensure_install_event_table` | ⚠️**违反**"DDL 仅部署期属主"不变量 |
| **P1-5** | `faas_runtime_db` thread-local 连接缓存整进程生命周期，仅判 `closed!=0`，**暖容器复用时 stale 连接/search_path 漂移会存活** | 复用前 `SELECT 1` 探活、异常即 drop 重连；`tx` 出错把缓存连接置空关闭 | 也让其对 PgBouncer server 回收更健壮 |
| **P1-6** | **无启动/瞬断重试退避**：PG 短暂不可用直接抛裸 500 | `get_db_connection`/`_conn` 包重试（50/150/400ms+jitter）；区分 53300(too many conn) → 干净 503 + Retry-After | |
| **P1-7** | **零慢查询可观测**：postgres 跑默认配置 | postgres `command`/conf 加 `shared_preload_libraries=pg_stat_statements`、`log_min_duration_statement=500ms`、`auto_explain`；schema.sql 加 `CREATE EXTENSION pg_stat_statements` | 部署期 DDL，合规 |
| **P1-8** | **healthcheck 不探 DB**：DB 挂了后端仍报 healthy | 加 `/health/ready`（短超时 `SELECT 1`，含 PgBouncer 可达性），容器/LB 指向它 | |

### P2 — 低优先 / 清理

- **enrich leader 连接生命周期**：transaction 池会静默打断会话级 advisory-lock 选主——**本 RFC 的 D4 直连旁路已规避**；顺手把该连接显式 `autocommit=True` + 每轮 `SELECT 1` 探活、重连后复核锁。
- **component 列表查询**（type+is_public, ORDER BY name）缺复合索引；**device_tokens** JSONB/长文本无约束。
- **`chat_quotas` 等平台表用 SERIAL/BIGSERIAL 主键**——与"禁 SERIAL、用 `gen_random_uuid`"不变量**不一致**（修复方向是对齐不变量）。
- **`get_user_profile` N+1**（逐行相关子查询）+ `resolve_author` 每次阻塞 HTTP。
- **userdata DSN 明文口令以 `MYAPP_DB_DSN` env 注入函数容器**（泄露面）——可改挂载短时凭据。
- **所有连接无 `application_name`**：`pg_stat_activity` 与未来 PgBouncer 池无法按组件归因——所有 `connect()` 加 `application_name`（接池后尤其有用）。
- **psycopg3（async/pipeline）**：策略级升级，但 psycogreen 已能以极低成本拿下大部分收益，暂不必。

### PgBouncer 计划已覆盖/已规避的项
- **每查询建连 churn**（无应用级池）：session 池暖复用 + 免去每次对真库的 scram/fork，**基本由本方案覆盖**；剩余只需补 `connect_timeout`（见 P0-2）。
- **transaction 池打断 advisory-lock**：D4 直连旁路已规避。

### 建议节奏
**与 PgBouncer 同批**：P0-1（psycogreen，独立且最高收益）、P0-2（timeouts，配合接池）、P1-8（健康检查）、P2 的 `application_name`。
**接池稳定后下一批**：P0-3（最小权限角色）、P1-1（conn-limit）、P1-7（慢查询可观测）、P1-4（DDL 移出请求路径）。
**单独排期**：P1-2（RLS 纵深防御）、P1-3（owner 索引）、P1-5/P1-6（运行时健壮性）。

## 8. 一句话总结
给**集群 B** 加 **2 个专用 PgBouncer**：`pgbouncer-faas`（userdata/transaction/发布网桥/auth_query，租户面）+ `pgbouncer-platform`（jsonapp/session/内网/auth_query，平台面）；**DDL·provision·advisory-lock 三类连接直连旁路**（加惰性默认的 `DB_DIRECT_*` 开关）；supabase 的 supavisor 不动。租户面结构性无法触达平台库，超级用户池不出内网。

---

## 9. 落地进展（2026-06-29）

### 仓库改动（已就位，本地校验通过，未提交）
- `backend/config.py`：新增 `DB_DIRECT_HOST/PORT`（默认回落 `DB_HOST/PORT`）。
- `backend/faas_userdb.py`：`_admin_conn` 的 `ADMIN_HOST/PORT` 改读 `DB_DIRECT_*`（provision/迁移直连旁路）。
- `backend/registry_enrich.py`：advisory-lock 连接改读 `DB_DIRECT_*` + 加 `connect_timeout=5`。
- `deploy/production/pgbouncer/{faas.ini,platform.ini,userlist.txt.example}`：两份池配置 + userlist 示例。
- `deploy/production/docker-compose.core.yml`：新增 `pgbouncer-faas`/`pgbouncer-platform` 两服务；4 个后端服务（backend/ai-worker/faas-push-worker/registry）env 切到 `DB_HOST=pgbouncer-platform:6432` + `DB_DIRECT_*` + `FAAS_USER_DB_RUNTIME_*=...:6432`。
- `deploy/production/install_ctl.sh`：把 `pgbouncer/` 同步到安装根。`.gitignore`：忽略真实 `userlist.txt`。
- 三个后端文件 `py_compile` 通过；compose YAML 解析通过；`install_ctl.sh bash -n` 通过。

### Phase A — 池子本体（77 live 验证 ✅，零后端扰动）
用独立 compose 起两个 stock edoburu 容器（未触碰后端栈），实证：
- **镜像**：77 镜像站仅缓存 `edoburu/pgbouncer:latest`（按 tag 拉 `v1.x` 报 403）→ 已钉其 digest；实测版本 **PgBouncer 1.25.2**（支持 SCRAM pass-through）。edoburu 在不设 `DATABASE_URL` 时直接用挂载的 `/etc/pgbouncer/pgbouncer.ini`。
- **Step 1 SQL**：`pgbouncer_auth`（login/非超级）+ `pgbouncer.user_lookup` SECURITY DEFINER 已建于 `userdata` 与 `jsonapp` 两库，execute grant 就绪；userlist 落 `/mnt/myapp/secrets.d/pgbouncer-userlist.txt`（644，单行）。
- **auth_query + SCRAM pass-through**：临时 `u_*` 风格角色经 faas 池连 `userdata` → `PASS testpgb@userdata`；`jsonapp` 超级用户经 platform 池连 `jsonapp` → OK。`SHOW POOLS` 见 server 连接复用。
- **双向路由隔离**：faas 池 → `jsonapp` 无路由（拒）；platform 池 → `userdata` 无路由（拒）。**核心安全属性成立**。
- **学到的点**：`userdata` 库已对 PUBLIC 撤销 CONNECT（FaaS 隔离加固），真实 `u_*` 在 provision 时被显式授 CONNECT，故池路径无需额外授权；测试角色需手动授 CONNECT 才能正向验证。

### Phase B — 后端重指（✅ 已完成，77 验证通过）
经用户选定「rsync 工作树 + 立即 deploy」执行：
1. 新增 `pgbouncer-faas`/`pgbouncer-platform` 到 `services.json`（ctl 纳管，group=infra）。
2. rsync 工作树（3 个 .py + compose + services.json + install_ctl + pgbouncer/）到 77 `/root/ai-app`，跑 `install_ctl.sh` 同步到安装根并注册服务（`paths.source=/root/ai-app`）。
3. `myapp-ctl deploy --build backend ai-worker faas-push-worker registry pgbouncer-faas pgbouncer-platform`：从 `Dockerfile.backend` 重建 backend 镜像（含 `DB_DIRECT` 新代码）+ 起两个真实 pgbouncer + 重建 4 个后端服务。

**验证结果**：
- 6 个服务 `restarts=0` 稳态，`myapp-backend (healthy)`；其余服务（supabase/openim/agent-node 等）零误伤。
- 后端 env 确认 `DB_HOST=pgbouncer-platform:6432` / `DB_DIRECT=jsonapp-postgres:5432` / `FAAS_USER_DB_RUNTIME=172.18.0.1:6432`。
- **直连旁路**：容器内 `provision_user_db` 成功（CREATE SCHEMA/ROLE DDL 经 `_admin_conn` 直连——若误走 platform 池会因无 userdata 路由失败，故反证旁路生效）。
- **faas 池端到端**：真实 `u_*` 角色经 `172.18.0.1:6432` 连入 → `(u_81933e68…, userdata, s_81933e68…)`，角色级 `search_path` 池化后存活；池 `SHOW STATS` 见真实流量。已 `drop_user_db` 清理。
- **platform 池**：后端 healthy + live query 穿池到达 postgres（auth_query + SCRAM passthrough）。
- enrich/advisory 在 77 因 `BACKEND_INTERNAL_URL` 未配置而 skip，`DB_DIRECT` 旁路代码未被触发但无害。

**遗留**：(1) 77 的 `/root/ai-app` 现为 rsync 后的 **dirty 工作树**——后续合 main + `myapp-ctl update`(git pull --ff-only) 前需先 `git checkout -- <files>` 复位。(2) userlist 明文在 `/mnt/myapp/secrets.d/pgbouncer-userlist.txt`。

### Phase C — 1 万 DAU 容量调优（psycogreen + 池/max_connections）
评估：1 万 DAU 对本架构是轻量级（峰值真正打 jsonapp 库 ~2-10 并发连接），DB 负载不是瓶颈；**真实连接由两池 `max_db_connections` 之和封顶（加副本也不增长）**，故 `max_connections` 无需 300，150 足够。改动：
- **psycogreen（最高杠杆）**：`backend/app.py` 在 `monkey_patch()` 后 `patch_psycopg()`，让 eventlet worker 的阻塞查询让出 hub（解决 §7 P0-1，PgBouncer 救不了的并发天花板）。`requirements.txt` + `Dockerfile.backend` 加 `RUN pip install psycogreen`（Dockerfile.backend 不跑 pip，故 app 层单独装，免重建 base）。
- `pgbouncer/platform.ini`：`default_pool_size 25→30`。
- `docker-compose.core.yml`：jsonapp-postgres `command: postgres -c max_connections=150`（一次性重启 postgres）。
- 镜像在 `claude.dapangyu.work`（Docker Hub 登录态 dapangyu）构建 `dapangyu/myapp-backend:agent-control-plane` 并 push，77 拉取部署。
> ⚠️ 该镜像 push 到了**共享可变 tag** `:agent-control-plane`（覆盖式、不可回滚）。这是项目级版本管理缺失的症状——根治方案见 [version-management.md](version-management.md)（镜像不可变 tag/digest + VERSION 真相源）。本次已临时用 `@sha256:f6d6419…` digest 钉法部署。
