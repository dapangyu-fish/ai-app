# 后端服务迁移计划：app-backend → myapp-backend

**生成时间**: 2026-05-02
**状态**: 待审批 — 在你明确批准前，不会对生产做任何改动

---

## 0. 总体目标与硬约束

将 5 个对外服务从老机 `app-backend.dapangyu.work` (103.233.254.179) 整体迁移到新机 `myapp-backend.dapangyu.work` (38.76.199.232，与 OpenIM 同机)，并：

| 老域名 | 新域名 |
| --- | --- |
| `app-backend.dapangyu.work` | `myapp-backend.dapangyu.work` |
| `app-auth.dapangyu.work` | `myapp-auth.dapangyu.work` |
| `app-oss-console.dapangyu.work` | `myapp-oss-console.dapangyu.work` |
| `app-oss-endpoint.dapangyu.work` | `myapp-oss-endpoint.dapangyu.work` |
| `registry.dapangyu.work` | `myapp-registry.dapangyu.work` |

**硬约束**:
1. 老机暂不下线（fallback）；不做破坏性改动。
2. 新机 OpenIM 一动不动（已占 22/53/10001-10009/11001-11002/12379-12380；OpenIM 自带 `minio`、`mongo`、`redis`、`kafka`、`etcd`）。
3. 所有自管密钥/Token 全部轮换；外部第三方密钥（doubao/deepseek/glm/cc）保持原值，等你最后手动替换。
4. `backend/.env` 从 git 仓库中移除（保留磁盘文件），靠 scp 传入新机。
5. 生产环境不可出错 — 任何破坏性步骤前都必须先在新机验证通过。

---

## 1. 关键决策（请重点 review）

### 1.1 新机容器命名（避开与 OpenIM 冲突）

| 用途 | 新容器名 | 镜像 | 备注 |
| --- | --- | --- | --- |
| App MinIO | `app-minio` | `minio/minio:RELEASE.2025-xx`（与老机一致或就近 LTS） | OpenIM 已占 `minio` |
| jsonapp Postgres | `jsonapp-postgres` | `postgres:16` | 老机就独立部署，沿用 |
| Supabase 全套 | 沿用 `supabase-*` | `supabase/postgres-meta` 等 | 命名不冲突 |

### 1.2 新机端口分配（全部仅绑 127.0.0.1，对外靠 nginx）

| 服务 | 容器内 | 宿主机 (127.0.0.1) | 对外 |
| --- | --- | --- | --- |
| App MinIO API | 9000 | **19000** | nginx → `myapp-oss-endpoint` |
| App MinIO Console | 9090 | **19001** | nginx → `myapp-oss-console` |
| Supabase Kong | 8000 / 8443 | **18000 / 18443** | nginx → `myapp-auth` |
| Supabase Postgres | 5432 | **15432** | 仅本机 (Studio 用) |
| jsonapp Postgres | 5432 | **15433** | 仅 Flask + Registry 用 |
| Flask ai-app | 5566 | **5566** | nginx → `myapp-backend` |
| Registry | 3254 | **3254** | nginx → `myapp-registry` |

低于 19000 的端口段以 `1xxxx` 命名，避免和 OpenIM 的 `1000x/1100x/1238x` 冲突，肉眼可分辨。

### 1.3 Supabase 迁移策略

不迁活容器，**重新 docker-compose up，再恢复数据**：
- 老机做 `pg_dumpall` + `tar` 卷打包，scp 到新机。
- 新机重写 `.env`（生成全新 JWT_SECRET、ANON_KEY、SERVICE_ROLE_KEY、密码、各类 token），先 `docker compose up -d db`，psql 恢复 dump，再 up 全栈。
- 这样能顺手把老机上几个未设置的 placeholder（VAULT_ENC_KEY / PG_META_CRYPTO_KEY / LOGFLARE_*）补齐。

### 1.4 SSL 证书

- 老机有 `*.dapangyu.work` 通配符证书（letsencrypt + Cloudflare DNS challenge），cron 每天 12:00 续签 + reload nginx。
- 新机**重新签发同一通配符证书**，使用相同 cloudflare.ini，独立 cron。两台机器并存通配符证书没有冲突（ACME 支持同名多次签发）。
- 老机的 `0 3 * * * rsync ... :/etc/ssl/dapangyu.work` 这条 cron 是把证书推回自己（端口 6022），是历史脚手架，**不迁移**。

### 1.5 必须轮换的密钥（自管）清单

```
POSTGRES_PASSWORD                  # supabase db
JWT_SECRET                         # supabase auth - 重生成后必须重算 ANON_KEY + SERVICE_ROLE_KEY
ANON_KEY                           # supabase 客户端 key (重算)
SERVICE_ROLE_KEY                   # supabase 服务端 key (重算)
DASHBOARD_USERNAME / _PASSWORD     # supabase studio
SECRET_KEY_BASE                    # supabase realtime
VAULT_ENC_KEY                      # supabase vault (老机为 placeholder)
PG_META_CRYPTO_KEY                 # pg-meta (老机为 placeholder)
LOGFLARE_PUBLIC_ACCESS_TOKEN       # logflare (老机为 placeholder)
LOGFLARE_PRIVATE_ACCESS_TOKEN      # logflare (老机为 placeholder)
MINIO_ROOT_USER / MINIO_ROOT_PASSWORD   # app-minio root
MINIO_ACCESS_KEY / MINIO_SECRET_KEY     # app 用 minio 应用 key (轮换 m3wZkIA5EgmEwkctueZM)
S3_PROTOCOL_ACCESS_KEY_ID / _SECRET     # supabase storage 走 minio 用
DB_PASSWORD                        # jsonapp postgres
SECRET_KEY                         # Flask
OPENIM_WEBHOOK_SECRET              # afterSendSingleMsg webhook (要同步到 OpenIM 容器配置)
REGISTRY_ADMIN_TOKEN               # 老机 test-token，必须替换
APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID  # 这些是外部凭据，**不轮换**，保持原值
```

**保持不变**: `DEEPSEEK_API_KEY`, `GLM_*`, `DOUBAO_*`, `CC_*`, APNs 凭据。

### 1.6 切换顺序

不做 DNS 切换（新域名是新名字，DNS 已配好独立 A 记录），**不存在剪裁老机的瞬间**。客户端通过发版把默认 URL 切到 `myapp-*`。老机继续承接老版本客户端流量，直到统计上无活跃请求再下线。

---

## 2. 操作清单（分阶段 / 含回滚）

> 标注 ⚠️ 的是破坏性 / 不可逆步骤，需要二次确认。

### Phase 1 — 新机基础设施 (无风险)

1. `apt update && apt install -y nginx certbot python3-certbot-dns-cloudflare supervisor`
2. `mkdir -p /etc/ssl/dapangyu.work /var/log/registry /opt/supabase /opt/app-minio /opt/jsonapp-postgres /root/ai-app`
3. 从老机 scp `/etc/ssl/dapangyu.work/cloudflare.ini` 到新机（保留 600 权限）。
4. 从老机 scp 老的 `/etc/nginx/conf.d/{app-auth,app-backend,app-oss-console,app-oss-endpoint,app-registry}.conf` 到 `/root/migration/nginx-old/` 仅作参考。
5. `git clone git@github.com:<repo>.git /root/ai-app` (拉同 repo)。

**回滚**: 直接 `apt remove`，不影响 OpenIM。

### Phase 2 — 签发新机通配符证书 (无风险)

1. 编辑 `/etc/letsencrypt/cli.ini`（或直接命令行）。
2. 运行：
   ```bash
   certbot certonly \
     --dns-cloudflare \
     --dns-cloudflare-credentials /etc/ssl/dapangyu.work/cloudflare.ini \
     -d 'dapangyu.work' -d '*.dapangyu.work' \
     --agree-tos -m <你的邮箱> --non-interactive
   ```
3. 添加 deploy hook 把 `fullchain.pem` / `privkey.pem` 复制到 `/etc/ssl/dapangyu.work/dapangyu.work.{crt,key}` 并 reload nginx。
4. 加 cron: `0 12 * * * /usr/bin/certbot renew --quiet --deploy-hook "..." && systemctl reload nginx 2>&1 | logger -t certbot-renew`

**回滚**: 删除新机证书目录，老机不受影响。

### Phase 3 — App MinIO（先空载起来）

1. 写 `/opt/app-minio/docker-compose.yml`，端口绑 `127.0.0.1:19000:9000`、`127.0.0.1:19001:9090`，root user/pwd 用新生成值。
2. `docker compose -f /opt/app-minio/docker-compose.yml up -d`。
3. `mc alias set app-minio-new http://127.0.0.1:19000 <root> <pwd>`，创建 4 个 bucket: `json-app`、`json-component`、`models`、`ai-chat-temp`。
4. 创建 application access key: `mc admin user svcacct add ...`（生成 MINIO_ACCESS_KEY/SECRET_KEY）。

**回滚**: `docker compose down -v`，无影响。

### Phase 4 — App MinIO 数据迁移 ⚠️ (耗时，但只读老机)

1. 在新机：`mc alias set app-minio-old https://app-oss-endpoint.dapangyu.work <老 access> <老 secret>`。
2. `mc mirror --watch=false --overwrite app-minio-old/json-app app-minio-new/json-app`（4 个 bucket 同样操作）。
3. 用 `mc ls --recursive` 比对每个 bucket 的对象数 / 总大小。
4. 因为老机继续运行，期间增量需要再 `mc mirror` 一遍，最终切换前再做一次同步。

**回滚**: 只读老机，无风险；新机 bucket 重建即可。

### Phase 5 — jsonapp Postgres ⚠️

1. 在老机：
   ```bash
   docker exec <jsonapp-pg-container> pg_dump -U <user> -F c -f /tmp/jsonapp.dump <db>
   scp /tmp/jsonapp.dump root@myapp-backend...:/root/migration/
   ```
2. 在新机起 `jsonapp-postgres` 容器 (端口 `127.0.0.1:15433:5432`)，用新密码。
3. `pg_restore` 到新容器。
4. 抽样查表行数比对老机。

**回滚**: drop 新容器即可。

### Phase 6 — Supabase 全栈 ⚠️

1. scp 老机 `/opt/supabase/docker/docker-compose.yml` + `volumes/api/`、`volumes/functions/` 到新机 `/opt/supabase/docker/`。
2. **重写** `/opt/supabase/docker/.env`（全新密钥，端口改成 `127.0.0.1:18000:8000` / `127.0.0.1:18443:8443` / `127.0.0.1:15432:5432`）。
3. `docker compose up -d db`，等待 healthy。
4. 老机 `pg_dumpall -U postgres > supabase.sql`，scp 过来，psql 恢复到新 db。
5. `tar czf storage.tgz /opt/supabase/docker/volumes/storage`，scp 解压到新机同位置（让 storage-api 能读到原 metadata）。
6. `docker compose up -d` 拉起其余服务。
7. 用 `curl http://127.0.0.1:18000/auth/v1/health` 验通。

**回滚**: `docker compose down -v` + 删除 `/opt/supabase/docker/.env`。

### Phase 7 — Flask ai-app + Registry ⚠️

1. 在新机生成完整的 `/root/ai-app/backend/.env`（用新数据库密码、新 MinIO key、新 OPENIM_WEBHOOK_SECRET、新 REGISTRY_ADMIN_TOKEN，外部 key 沿用老值）。
2. 由本地（开发机）`scp /home/fish/ai-app/backend/.env root@myapp-backend:/root/ai-app/backend/.env`，权限 600。
3. 写 `/etc/supervisor/conf.d/ai-app.conf` 和 `registry.conf`（参考老机配置，路径调整）。
4. `supervisorctl reread && supervisorctl update`。
5. `curl http://127.0.0.1:5566/health`、`curl http://127.0.0.1:3254/health`。

**回滚**: `supervisorctl stop ai-app registry`，删除 `.env` 与 conf。

### Phase 8 — Nginx vhost ⚠️

1. 在新机写入 5 个 vhost：
   - `myapp-backend.conf` → `proxy_pass http://127.0.0.1:5566`
   - `myapp-registry.conf` → `proxy_pass http://127.0.0.1:3254`
   - `myapp-oss-endpoint.conf` → `proxy_pass http://127.0.0.1:19000`（注意 `client_max_body_size`、`proxy_request_buffering off`）
   - `myapp-oss-console.conf` → `proxy_pass http://127.0.0.1:19001`
   - `myapp-auth.conf` → `proxy_pass http://127.0.0.1:18000`
2. 共用 SSL: `ssl_certificate /etc/ssl/dapangyu.work/dapangyu.work.crt;`
3. `nginx -t && systemctl reload nginx`。

**回滚**: 删除 vhost 文件 + reload。

### Phase 9 — 外部联通验证 (无风险)

```bash
# 从开发机
for d in myapp-backend myapp-registry myapp-oss-endpoint myapp-oss-console myapp-auth; do
  echo "=== $d ==="
  curl -sI https://$d.dapangyu.work/ | head -3
done
# 业务级
curl https://myapp-backend.dapangyu.work/health
curl https://myapp-registry.dapangyu.work/health
curl -X POST https://myapp-registry.dapangyu.work/registry/list -H "Content-Type: application/json" -d '{}'
```

### Phase 10 — 仓库代码改动 (隔离 PR，不直接 push main)

仅改默认值和文档，把 5 个老域名替换为 myapp-* 对应值。涉及文件（基于 grep 实查）：

- **必改**:
  - `lib/config/app_config.dart` — 4 个 `defaultValue`
  - `lib/main.dart` — 3 处 hardcoded registry URL
  - `lib/demo_for_test/main_test_sherpa.dart` — `_ossBase`
  - `backend/config.py` — SUPABASE_URL / MINIO_PUBLIC_URL 默认值
  - `backend/store.py`, `backend/registry_server.py`, `backend/migrate_templates.py`, `backend/publish_script.py`, `backend/test_publish_user_package.py`, `backend/upload_with_signature.sh`, `backend/deploy_registry.sh`
  - 文档：`SPEC.md`, `CLAUDE.md`, `OPENIM_DEPLOY.md`, `PUSH_ARCHITECTURE.md`, `REGISTRY_IMPLEMENTATION.md`, `REGISTRY_TESTING_GUIDE.md`, `REGISTRY_TEST_RESULTS.md`, `BACKEND_DEPLOY.md`, `REGISTRY_README.md`, `.env.example`, `backend/prompts/generate_app_prompt.md`, `.claude/plans/user-mgmt-ai-app-design.md`

- **`.env` 移出 git**（仅一次）：
  ```bash
  git rm --cached backend/.env       # 保留磁盘文件
  echo "backend/.env" >> .gitignore   # 已在 *.log 等之后追加
  git commit -m "chore: untrack backend/.env (transferred manually via scp)"
  ```
  **历史里的旧值已经泄漏**，所以**所有这些密钥都必须轮换**（这正是本次迁移要做的）。我**不会**对历史做 BFG/git filter-repo 重写（会破坏所有已发出的 PR/克隆）；记入安全债。

### Phase 11 — Flutter 客户端验证

1. `flutter analyze` 确认无报错。
2. `flutter run`（本地 chrome / macos 即可）打开应用，登录、市场、聊天、推送一条龙跑通。
3. 移动端 release 构建 + TestFlight / 内部分发；旧版本继续打老机不受影响。

### Phase 12 — OpenIM 端配合改动

1. 在 OpenIM 容器（同一机器）的 webhook 配置里更新 secret（与新 `.env` 一致）。
2. webhook URL 从 `https://app-backend.dapangyu.work/openim/webhook/...` 改为 `https://myapp-backend.dapangyu.work/...`。
3. 重启 openim-server。
4. 用真实 IM 推一条消息，验证 APNs 收到。

### Phase 13 — 老机收尾（不在本次迁移内执行）

观察 1-2 周 myapp-* 流量稳定 + 旧客户端版本占比下降后，分两步：
1. 先停老机 supervisor 服务（保留容器与数据）。
2. 再停容器（保留数据卷镜像快照）。
3. 最后下机器。

---

## 3. 风险与对冲

| 风险 | 对冲 |
| --- | --- |
| Supabase auth 用户表 JWT 失效（密钥变了） | 所有现有用户都要重新登录。预期内行为；客户端兜底了 401 重登。**需要在发版说明里告知用户**。 |
| MinIO presigned URL 失效 | 老 URL 用老 key 签的，迁后访问 myapp-oss-endpoint 会 403。受影响的：JSON-APP 中已写死带签名的 URL（如有）。**评估方式**：grep `app-oss-endpoint.dapangyu.work` in 已发布的 JSON-APP；如果只是公开 bucket，无影响。 |
| 老 .env 密钥已经在 git 历史里 | 全量轮换；历史内容作废即可，无需 rewrite history。 |
| 老/新 MinIO 同名 access key | 不同机器、不同 nginx 入口，互不影响。但 mc 别名要分清 `app-minio-old` / `app-minio-new`。 |
| OpenIM 同机被波及 | 我所有动作都只新增容器/服务，绝不动 openim-* / mongo / redis / kafka / etcd / minio (OpenIM 的) / openim 网络。 |
| nginx 端口 80/443 占用 | 新机目前**没装 nginx**，全新；不会和 OpenIM admin/web 前端冲突（那两个是 :11001/:11002）。 |
| 数据迁移期间老机继续写 | mc mirror 切换前最后再跑一次；postgres 用 logical replication 风险高，本次不上，靠"切前 pg_dump → pg_restore + 灰度发版"覆盖。 |

---

## 4. 待你确认的事

1. **新域名解析已完成**？（你已说"DNS 我已配好"，请确认 5 个 myapp-* 都能 `dig +short` 到 38.76.199.232。）
2. **认可上述端口分配**（19000+ 段，全部本机）？
3. **认可 Supabase 重建 + dump/restore** 路线（用户需要重新登录）？
4. **认可不重写 git 历史**（轮换密钥即可；老机的 `backend/.env` 我会 `git rm --cached` 保留磁盘）？
5. **认可"老机不下线，等观察期"** 节奏？
6. **OPENIM_WEBHOOK_SECRET 由我生成新值并在 OpenIM 配置同步更新**？
7. **是否需要单独的 release notes / 用户公告**（"需要重新登录"）？

确认后我会按 Phase 1 → Phase 13 顺序执行，每个 Phase 完成后给你写一个简短验证报告再进入下一个。
