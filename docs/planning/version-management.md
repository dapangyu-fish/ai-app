# RFC: 版本号管理（Version Management）

- **状态**: ✅ **P1 完成 + 上线**（GHA→Hub→77 全管线，77 现跑 CI 镜像 `1.2.2-ff1cd41`，见 §8/§10）；🟢 **P2 代码完成**（Python uv-lock + CLI 钉 + base digest 钉 + FVM）——但 **base 镜像未重建、当前 dormant**（app 仍 FROM 旧 `:edge` base，见 §11.1-#1）；🟢 **P4 大部分**（客户端 DSL 闸 + 后端发布 gate + JSON-DSL 纪律）；🟡 **P3 部分**（_index 闸 + schema_migrations runner 已 live 基线 + 自动迁移护栏；FaaS digest 仅记录、冷唤醒策略待决）。**综合评估见 §11，本轮按 §11 落地的修复见 §11.7。剩余见 §9。**
- **范围**: 跨域（`deploy/production/`、`scripts/myapp_ctl/`、`backend/`、`pubspec.yaml`、`JSON-DSL.md`、`backend/migrations/`）
- **作者**: Claude（基于 2026-06-29 对全仓 **63 个版本/依赖耦合面**的审计 + 对抗式核实 + 四类锁定最佳实践调研）
- **起始版本**: **`1.2.0`**（承接 `pubspec.yaml` 现有线，不另起 1.0.0）
- **缘起**: PgBouncer 落地把后端镜像 push 到了共享可变 tag `:agent-control-plane`（见 [pgbouncer-jsonapp-postgres.md](pgbouncer-jsonapp-postgres.md)）。深挖后发现这只是冰山一角——本项目**可部署制品、构建工具链、运行时 ABI、持久化格式**几乎全无版本锁定。

---

## 0. 已决策（2026-06-29 快问快答）

| # | 决策 | 落点 |
|---|------|------|
| 起始版本 | **`VERSION=1.2.0`**（承接 pubspec，不另起 1.0.0） | §3.1 |
| 镜像不可变引用 | **`:{版本}-{sha}` 双 tag**：每次构建出不可变 `:1.2.0-<sha>`（**部署钉它**、回滚=重指上一个）+ release 打 `:{版本}`；**部署绝不钉移动 tag** | §3.2 |
| 镜像 redesign | **8 个 repo 不变、不新建 Docker Hub 镜像**；移动频道 `:agent-control-plane` → **`:edge`**（dev 便利、部署不用）；`myapp-backend` 一镜像多入口（backend/ai-worker/faas-push-worker/registry/config-center/user-center）保留；cutover 期 `:agent-control-plane` 短期并存兜底 77，稳定后弃用 | §3.2 |
| Python 锁 | **uv**（`uv.lock` universal + `uv sync --locked` CI 漂移闸） | §3.3 |
| DSL 版本 | **纯 semver**（MAJOR=已发布 App 可能渲染坏 / MINOR=向后兼容新增 / PATCH=修复）+ additive/reserve 纪律；**不用 SchemaVer** | §3.7 |
| CI | **GitHub Actions**：`v*` tag + 手动 `workflow_dispatch` 触发；base/app 拆两条（base 仅其 Dockerfile 改时建）；4 镜像 | §3.9 |
| FaaS helper ABI | ~~A 轻量：钉记录 digest、永不 rebase~~ → **改判（2026-06-30）：X-G3 用最新运行时镜像**（冷唤醒 rebase 到当前 `FAAS_LOCAL_DOCKER_IMAGE`，安全补丁自动覆盖存量函数；digest 仅记录作溯源）。helper 破坏性改动靠前缀版本号纪律兜底 | §3.5 |
| 部署钉点 | **B：`myapp-ctl deploy --image-version <tag>` flag**（钉 + 写进 ctl.json）；升级/回滚都一条命令 | §3.9 |
| `:agent-control-plane` 弃用 | **切完立即停推**：P1 落地 + 77 验证在不可变 tag 后即停（只有 77、未上生产，风险低） | §3.2 |

> **全部已决策**（见 §6）。

---

## 1. 现状：半边成熟、半边裸奔

| | 包侧（Registry / JSON-App / 组件） | 制品 + 平台 + 运行时 + 数据 |
|---|---|---|
| 版本纪律 | ✅ 严格 semver、发布即不可变、强制单调递增、`^/~/>=` 范围解析（`registry_server.py` + `lib/json_ui/semver.dart`） | ❌ 见下 63 面 |

**审计覆盖 6 维度、确认 63 个耦合面**（完整清单见 §4）。最致命的几类：

1. **自建镜像全部走一个共享可变 tag** `:agent-control-plane`（8 个 app+base 镜像）——每次构建 push 覆盖，**从不保留第二个 tag/digest**，无回滚目标，两台机器拉"同一 tag"可能跑不同代码。`MYAPP_BUILD_COMMIT` 已算出却**从未用作 tag**（`core.py:802-816`）。
2. **Python 全仓无 lockfile**，`requirements.txt` 几乎全是 `>=` 浮动；`Dockerfile.agent-node-base` 的 `flask/gunicorn/requests` **完全无界**；更糟：**base 镜像 `npm i -g @anthropic-ai/claude-code opencode-ai` 无版本（=@latest）**、`node setup_22.x`、`ubuntu/python-slim` 无 digest——**即便刻意重建 base 也不可复现**，而 AI 生成质量直接依赖这些 CLI 版本。
3. **FaaS 运行时 helper ABI 随可变镜像漂移**：`myapp_db/myapp_auth/myapp_data` 烤进 `faas-runtime:agent-control-plane`;**冷唤醒会把已部署函数静默 rebase 到当前 helper 镜像**——helper 签名一改，所有存量函数下次唤醒即坏，且无任何版本闸。
4. **平台 schema 无迁移版本表**：`schema.sql` 仅首次 init 跑一次，之后靠手写 `backend/migrations/00N_*.sql`（无 tracking 表、idempotent-DDL-only、无 down）；FaaS per-user schema 每次部署重跑、`CREATE TABLE IF NOT EXISTS` 改不了已存在列类型。
5. **DSL 契约形同虚设**：`dsl:"3.3"` 发布期只校验**存在**、客户端**完全忽略**;有一处 `dsl != '3.3'` 严格判等却是**孤儿代码**（`json_app_builder.py`，链路里没接）;文档 v3.4 与运行时 3.3 脱节。

好消息：**`pubspec.lock` 已提交**（Dart 侧做对了，是要推广的正例）；`edoburu/pgbouncer@sha256:…` 已 digest 钉（项目其实会这招、只是没用在自家镜像上）；`registry_packages.summary_prompt_version` 是个可用的数据版本正例。

---

## 2. 目标与原则

1. **单一真相源**：平台版本一处定义（`VERSION=1.2.0`），制品/后端/客户端/CLI 引用它。
2. **每次 bump 都是一个可 review 的 diff，diff 同时是复现保证与回滚单元**（digest / lock / pubspec.lock / dsl 版本）。
3. **四类锁要一起动**：Docker base digest 与 Python hash-lock 是**互相独立但必须同步**的两把锁——base 浮动会悄悄毁掉一个本来可复现的 Python 环境。
4. **DSL 是 schema-against-stored-data，不是普通 API**：单靠 semver 不够，需叠加 **additive + reserve 纪律 + 文档内版本字段 + 链式迁移**（详见 §3.7）。
5. **复用既有钩子与正例**：semver（同包侧）、`pubspec.lock`、`MYAPP_BUILD_VERSION`/marker、`ctl.json` images map、`summary_prompt_version` 模式——不重造。
6. **不过度锁**：第三方 minio/supabase 精确 tag 已够；low-risk 浮动（dev compose、demo 回放格式）可暂不动。

---

## 3. 设计（按锁定类）

### 3.1 平台版本：单一真相源
- 仓库根新增 **`VERSION` = `1.2.0`**，平台 semver 唯一真相源。
- bump：**MAJOR**=破坏性（API/DSL major/数据迁移）；**MINOR**=向后兼容新特性；**PATCH**=修复。
- 后端 `/version`、CLI `--version`、镜像 tag 都从它派生；release 打 git tag `vX.Y.Z`。
- **`pubspec.yaml` 例外**：客户端版本独立演进（现 `1.2.0+1`），**有意不与平台 `VERSION` 同步**（§8.4 决策；客户端发版节奏≠后端制品）——故"单一真相源"指**后端/制品**一侧，`pubspec` 解耦，不声称从 `VERSION` 派生（修正早期措辞，见 §11.3-#7）。

### 3.2 容器镜像：不可变 tag + digest（本项目两处都要钉）【已决策】
- **tag 方案**（取代 `:agent-control-plane`）：每次构建打不可变 **`:{VERSION}-{git-sha}`**（如 `1.2.0-a1b2c3d`，sha 已在 `core.py:666` 算好、只是没当 tag 用）+ release 打 **`:{VERSION}`**（如 `1.2.0`）；移动频道改为 **`:edge`**（dev 便利指针，**生产/测试部署禁止直接钉它**）。
- **8 个 repo 不变、不新建 Docker Hub 镜像**（tag 在现有 repo 里加）；`myapp-backend` 一镜像多入口（backend/ai-worker/faas-push-worker/registry/config-center/user-center 同镜像不同启动命令）保留。cutover 期 `:agent-control-plane` 短期并存兜底 77 现网，`ctl.json` 重指 `:{VERSION}-{sha}` 稳定后弃用。
- **两个浮动源都要钉**：`ctl.json` 的 `images.*` map（`myapp-ctl deploy --build` 的 `--build-arg BASE_IMAGE` 实际取这里，`core.py:805`）**和** `Dockerfile.*:1` 的 `ARG BASE_IMAGE` 默认（手动/CI 兜底）——只钉一处会被另一处覆盖。
- **base 镜像 digest 钉 + 锁工具链**：`FROM python:3.11-slim@sha256:…` / `ubuntu:24.04@sha256:…`;`Dockerfile.*-base` 里 `claude-code`/`opencode-ai`/`google-chrome-stable` 改成**显式版本**（现仅 `codex@0.136.0`、`codex-relay==0.3.3` 钉了）;`node setup_22.x` 钉到具体 minor。
- 部署钉不可变 tag/digest → `deploy --pull` 任意时刻拉到同一镜像;**回滚 = `images` map / `MYAPP_*_IMAGE` env 重指上一个 `:{VERSION}-{sha}`**。
- 第三方：`postgres:15.8`/`redis:7.4-alpine`/`nginx:1.27-alpine` 是浮动 minor，建议升级为 digest 钉（中等优先）;`minio RELEASE.*`、supabase 精确 tag 已 OK。
- > 最佳实践（cited）：tag 可变、digest 是内容哈希「每次拉到完全相同镜像」;多架构钉 **manifest-list digest** 而非平台 digest;digest 钉锁的是**输入**而非 bit 级输出（如需 bit 级再加 `SOURCE_DATE_EPOCH` + BuildKit `rewrite-timestamp`）;digest 不自动收安全补丁→配 Renovate/Dependabot 主动升。[Docker digests](https://docs.docker.com/dhi/core-concepts/digests/) · [why pin by SHA](https://candrews.integralblue.com/2023/09/always-use-docker-image-digests/) · [reproducible builds GH Actions](https://docs.docker.com/build/ci/github-actions/reproducible-builds/)

### 3.3 Python 依赖：引入 lockfile（喂 3+ 镜像的根因修复）【已决策：uv】
- 采用 **uv**：`uv lock` 产出 **`uv.lock`**（跨 OS/arch/py 单文件 universal lock），镜像构建 `uv sync --locked`（**漂移即失败**），CI 同样用 `--locked` 做闸。uv 极快，对 base 重镜像的 CI 构建提速明显。
- **hash 钉**：uv 的 lock 自带 hash 校验；安装走锁定解析、不再即时 re-resolve（含传递依赖，全有或全无）。
- `requirements.txt` 留作人编输入,镜像从 lock 构建并**提交 lock**;`Dockerfile.agent-node-base` 的无界 `flask/gunicorn/requests` 先补边界、最终进 lock;`faas-runtime-base` 把 `psycopg2-binary/requests` 等 helper 实际 import 的依赖钉死（现 `flask==3.0.3` 已钉，其余 `>=`）。
- > 这是**最高杠杆**：一个 lock 喂 backend/registry/worker + agent-runtime + faas-runtime 多个镜像;没有它，任何 `MYAPP_BUILD_COMMIT` 都无法对应"实际装了哪些版本"。[pip hash-checking](https://pip.pypa.io/en/stable/topics/secure-installs/) · [uv lockfile](https://pydevtools.com/handbook/how-to/how-to-use-a-uv-lockfile-for-reproducible-python-environments/)

### 3.4 Flutter / Dart：保持 lock + 锁工具链
- **`pubspec.lock` 已提交——保持，永不进 `.gitignore`**（app 包的正确做法;若将来抽出可发布的组件库，库包反而不提交 lock）。caret 范围对 app 无害（lock 是真相源）。
- 缺口：**Flutter/Dart 工具链未锁**（无 FVM/`.tool-versions`/CI 钉）——lock 钉的是包不是编译器,不同 channel 会产出不同二进制/生成码。引入 **FVM + 提交 `.fvmrc`**，**钉 `{"flutter":"3.41.8"}`**（= `claude.dapangyu.work` 构建机版本，也是 web 验证环境；用户本地 3.41.9，3.41.8 可接受）。
- CI 跑 `flutter pub get --enforce-lockfile`（resolution 偏离即失败）;`intl: any` 收成有界。
- **客户端改动验证路径**：本机无 flutter，但可 `ssh fish@claude.dapangyu.work`（flutter 3.41.8）**编译 web 端验证**（web 过即可，其它平台问题不大）——故 P4 客户端 DSL 闸等 Flutter 侧改动**可构建可验证**，不是纯盲写。
- > [dart.dev: 提交 app 的 lock、不提交库的 lock](https://dart.dev/tools/pub/private-files)

### 3.5 FaaS 运行时 helper ABI（新发现，high）【已决策：X-G3 用最新镜像（2026-06-30 改判）】
存量函数依赖 `myapp_db/myapp_auth/myapp_data` 的 API,它们随 `faas-runtime` 镜像走。冷唤醒时镜像该用哪个?

> **决策（2026-06-30 用户拍板）：用最新的运行时镜像（= 现有 X-G3 实现），不钉历史 digest。** 即函数冷唤醒时若当前 `FAAS_LOCAL_DOCKER_IMAGE` 解析出的镜像比容器新 → recreate 到**当前/最新**镜像（`faas_store._image_is_stale` → `_wake_replica_zero`）。**好处：helper 的安全/数据网关补丁自动覆盖所有存量函数，无需逐个 redeploy。代价：helper 公开签名做破坏性改动会让按旧签名调用的存量老函数下次唤醒报错——故 helper ABI 必须遵守下面的冻结契约纪律（破坏性改动=前缀版本号 + 数据迁移，绝不原地改）。**
>
> 这**推翻了本文档早期（§0）的 §3.5-A『按记录 digest 跑、永不 rebase』**。`faas_deployments.runtime_image_digest`（部署时 `_resolve_runtime_digest()` 解析记录）**保留但仅作溯源/审计**（"该函数上次部署对的是哪个运行时 digest"），**不再用于钉冷唤醒镜像**。
>
> ~~A（已弃，仅留作记录）：把 `image@sha256` 记到 service、冷唤醒按记录 digest 跑、永不 rebase——稳定但安全补丁覆盖不到老函数。~~
- helper 公开签名任何变更 = MAJOR;`c_`+HMAC 假名、`base64(json).hmac[:32]` token、`owner` 列等**冻结的 on-disk 契约**：要改就**前缀版本号**（`c1_/c2_`）+ 数据迁移,绝不原地改。**（在 X-G3 下这条尤其关键：因为新镜像会自动覆盖存量函数。）**
- helper 公开签名任何变更 = MAJOR;`c_`+HMAC 假名、`base64(json).hmac[:32]` token、`owner` 列等**冻结的 on-disk 契约**：要改就**前缀版本号**（`c1_/c2_`）+ 数据迁移,绝不原地改。

### 3.6 数据 / Schema / 对象存储
- **平台 DB 加 `schema_migrations` 表**（id/applied_at/checksum）+ 确定性 runner 按序跑 `backend/migrations/00N_*.sql` 并记录;停止并行手改 `schema.sql` 与 migrations。deploy CLI 已有 supabase-auth 迁移机制（`deploy.py:592`）可复用扩展到平台库。盖一行 `schema_version`。
- **FaaS per-user schema 记指纹**（schema.sql hash）到 `faas_deployments`,re-deploy 改了已存在表列类型时 warn/拒（`CREATE TABLE IF NOT EXISTS` 改不动）;明确"additive-only"或给属主授权的 ALTER 路径。
- **`_index.json` 的 `version` 字段真正启用**：`_load_index` 读它、不匹配则升级/拒（现在只在空 init 写、从不校验,而它是最 load-bearing 的存储文档）。
- **对象存储键格式**（`{app_id}/{name}-{version}.json`、asset-pack `{slug}/{version}/manifest.json` + `metadataVersion`）视为冻结契约,改格式即版本化迁移、别孤立旧对象。

### 3.7 DSL 契约：纯 semver + additive/reserve 纪律【已决策：semver，不用 SchemaVer】
DSL 是「stored documents 必须持续可渲染」的 schema 问题,但为**全项目一套心智**（registry 包 + 平台 VERSION + 依赖都 semver、`dsl` 现就是 `3.x`、`semver.dart` 直接可用）决定用 **纯 semver**，把 SchemaVer 的"已发布 App 还渲染吗"作为 **MAJOR 判定规则吸收进来**。
- **版本规则**：**MAJOR**=破坏 DSL 契约（**任何已发布 App 可能渲染坏**/改语义/删控件）;**MINOR**=向后兼容新增（新控件/内置/新可选字段，旧 App 不受影响）;**PATCH**=引擎修复不动契约。`JSON-DSL.md` 即 SemVer 要求的"公开 API"。
- **客户端载入闸**：加 `kSupportedDsl='3.3'`（+ min/max 窗口）常量,`loadConfig` 顶部解析 `config['dsl']`：MAJOR 不匹配硬拒（"需升级客户端"）、MINOR-ahead 仅 warn。删掉 `json_app_builder.py` 那处孤儿 `dsl != '3.3'`。〔落地修正（§11.3）：解析实为 `interpreter.dart` 内联 `split('.')+int.tryParse`，**未**复用 `lib/json_ui/semver.dart`；MAJOR 比对够用，如要与包侧统一心智可后续重构。〕
- **发布期强制**：Registry 校验/盖 `dsl` 在支持窗口内（之后不可变,给每个 stored 版本冻结契约目标）。
- **additive + reserve 纪律**（借 protobuf/GraphQL）：新键可选、旧键永不复用语义、删掉的 widget 类型名 reserve 不重用、不改字段类型 → 旧 JSON 在新引擎仍渲染、新 JSON 在旧引擎优雅降级（引擎已忽略未知键）。
- **链式迁移** `v1→v2→v3`(而非 N 个"任意旧→最新"),作升级/回滚网。修订 `JSON-DSL.md`（v3.4 vs 3.3 脱节）。
- > [semver.org](https://semver.org/) · [protobuf dos-donts](https://protobuf.dev/programming-guides/dos-donts/)（reserve 纪律） · [GraphQL additive evolution](https://oneuptime.com/blog/post/2026-01-24-graphql-api-versioning/view)

### 3.8 构建溯源 + CLI
- 后端加 **`GET /version`** 返回 `{version, build_commit, build_version, image_ref, dsl_supported}`（值已在 env,`agent_node_service.py:68` 已自报,只是 backend `app.py` 无端点）;启动日志打一行。
- `myapp-ctl --version` / `version` 打 `VERSION` + 构建 sha（`cli.py` trivial）。

### 3.9 CI（GitHub Actions）+ release / CHANGELOG【已决策：用 GHA】
- **触发**：`v*` tag（发版自动构建不可变镜像）+ `workflow_dispatch`（手动）；**不挂 push-to-main**（base 重，不每次 commit 烧 CI）。
- **拆两条 workflow**：`images-base.yml`（仅 `deploy/production/Dockerfile.*-base` 变更时构建 4 个 base + push）+ `images-app.yml`（4 个 app 镜像，从已发布 base 构建）。
- 用官方三件套 `docker/login-action` + `docker/metadata-action` + `docker/build-push-action`；checkout 给全仓→build context 天然正确（不用 worktree/rsync）；产出 `:{VERSION}-{sha}` + `:{VERSION}` + `:edge`。
- **GitHub 凭据（已确认，2026-06-29）**：挂在名为 **`DOCKERHUB`** 的 **Environment** 下——Environment **secret** `DOCKERHUB_TOKEN` + Environment **variable** `DOCKERHUB_USERNAME`（值 `dapangyu`）。因此两条 workflow 的 job **必须声明 `environment: DOCKERHUB`**，再用 `${{ vars.DOCKERHUB_USERNAME }}` + `${{ secrets.DOCKERHUB_TOKEN }}` 引用。
  - ⏳ **待办（下一步）**：给 `images-app.yml`/`images-base.yml` 的 `build` job 取消注释/加上 `environment: DOCKERHUB`（当前 YAML 里是占位注释 `# environment: <name>`）。
- 部署仍分离：CI 只 build+push，77 走 **`myapp-ctl deploy --image-version <tag>`**（新增 flag：钉到该不可变 tag + 写进 `ctl.json` images）；升级/回滚都一条命令（回滚=`--image-version <上一个>`）；**不让 GHA 直接 SSH 部署 77**。
- **顺手治好 77 镜像站缓存坑**：拉从没见过的 `:{VERSION}-{sha}`/digest，镜像站必须回源，不会给旧的。
- release checklist：bump `VERSION`(+`pubspec`) → 更新 `CHANGELOG.md` → `git tag vX.Y.Z`（触发 CI 出不可变镜像）→ `ctl.json` images 钉到该 tag → `deploy --pull`。新增 `CHANGELOG.md`(Keep-a-Changelog)。
- > [build-push-action](https://github.com/docker/build-push-action) · [reproducible builds GH Actions](https://docs.docker.com/build/ci/github-actions/reproducible-builds/)

---

## 4. 完整版本锁定面清单（63 项，已对抗式核实）

> 状态：`locked`=已不可变钉 / `floating`=tag/range 会漂 / `unversioned`=无版本概念。下表列 **high/medium**;low 见脚注。

### 4.1 容器镜像
| 面 | 状态 | 风险 |
|---|---|---|
| 自建 8 镜像共用可变 `:agent-control-plane`（app×4 + base×4） | floating | **high** |
| Dockerfile `ARG BASE_IMAGE` 默认 = `-base:agent-control-plane`（且被 ctl.json 覆盖,两处都要钉） | floating | **high** |
| agent-runtime-base：`ubuntu:24.04` + 未钉 apt/npm/pip（claude-code/opencode **@latest**、chrome latest） | floating | **high** |
| backend-base / agent-node-base / faas-runtime-base：`python:3.11-slim` 无 digest + CLI 工具链浮动 | floating | medium |
| agent-node `AGENT_NODE_RUNTIME_IMAGE` 默认 `:latest` | floating | medium |
| `postgres:15.8` / `redis:7.4-alpine` / `nginx:1.27-alpine` 第三方浮动 minor | floating | medium/low |
| `edoburu/pgbouncer@sha256:…`（已 digest 钉,正例） | locked | low |
| `minio RELEASE.*` / supabase 精确 tag（已够） | locked/floating | low |

### 4.2 Python 依赖
| 面 | 状态 | 风险 |
|---|---|---|
| **全仓无 lockfile**（pip freeze/constraints/poetry/Pipfile 皆无）——根因 | unversioned | **high** |
| `backend/requirements.txt` 几乎全 `>=`（喂 backend/registry/worker + agent-runtime + faas-runtime） | floating | **high** |
| `Dockerfile.agent-node-base` `flask/gunicorn/requests` **完全无界** | unversioned | **high** |
| `faas-runtime-base` helper 依赖（psycopg2-binary/requests）`>=` | floating | **high** |
| `agent-runtime-base` 携 backend requirements 全套浮动（仅 codex-relay==0.3.3 钉） | floating | **high** |
| 容器 base（python-slim/ubuntu）无 digest | floating | **high** |

### 4.3 Dart / Flutter
| 面 | 状态 | 风险 |
|---|---|---|
| `pubspec.lock` 已提交（**正例,保持**） | locked | （正） |
| Flutter/Dart 工具链未钉（无 FVM/.tool-versions/CI） | unversioned | **high** |
| SDK 约束与 lock 内 SDK 不一致 | floating | medium |
| native-plugin caret-major（firebase/webview/openim/camera/permissions） | floating | medium |
| `intl: any` 无约束 | unversioned | low |

### 4.4 跨服务运行时契约
| 面 | 状态 | 风险 |
|---|---|---|
| FaaS helper API（myapp_db/auth/data）烤进 faas-runtime 镜像 | unversioned | **high** |
| 冷唤醒静默 rebase 已部署函数到当前 helper 镜像 | unversioned | **high** |
| faas-runtime 镜像 tag `:agent-control-plane`（helper 载体） | floating | **high** |
| 假名格式 `c_`+HMAC(secret, app_id\0uid) + owner 列 | unversioned | **high** |
| myapp_data↔backend `/api/faas/data` 协议 / 后端→函数 header 契约 / agent-node↔backend 协议 / Registry HTTP API | unversioned/floating | medium |
| data/run-token 签名格式 | unversioned | low |

### 4.5 数据 / Schema / 对象存储
| 面 | 状态 | 风险 |
|---|---|---|
| 平台 `schema.sql` 无迁移版本表 | unversioned | **high** |
| `migrations/00N_*.sql` 手动/无 tracking/idempotent-only | floating | **high** |
| FaaS per-user schema 每次重跑、idempotent-only、无 down | unversioned | **high** |
| `_index.json` `version` 字段写而不校验 | floating | **high** |
| 已发布 App 的 `dsl` 契约（presence-only、客户端忽略） | floating | **high** |
| FaaS 存储代码(active_commit) vs 可变运行时镜像 的 ABI 边界 | floating | **high** |
| 对象存储键格式 / asset-pack manifest 布局（硬编码无版本） | unversioned/floating | medium |
| `summary_prompt_version`（可用数据版本,正例） | locked | （正） |

### 4.6 DSL 框架契约
| 面 | 状态 | 风险 |
|---|---|---|
| 客户端无 supported-DSL 常量（interpreter/widget_builder） | unversioned | **high** |
| 客户端无载入期 `dsl` 兼容闸 | unversioned | **high** |
| 每 App 契约 pin = `dsl` 字段（端到端从不强制） | unversioned | **high** |
| Registry 发布期 `dsl` 闸（仅校验存在） | unversioned | medium |
| `json_app_builder.py` 孤儿 `dsl != '3.3'` 严格判等 | locked | medium |
| `JSON-DSL.md` 文档 v3.4 vs 运行时 3.3 | floating | medium |

> **low / 暂不锁**：dev/legacy compose（`backend/docker-compose.yml`）、`claude-sadbox`（ubuntu:26.04，实验孤儿）、demo 回放 jsonl 格式、无 dependency_overrides/git/path 依赖（负向确认）等。

---

## 5. 分期

| 期 | 内容 | 价值/成本 |
|---|---|---|
| **P1（先做）** | `VERSION=1.2.0` + 自建镜像**双 tag（不可变 `:{ver}-{sha}` + `:{ver}`，`:edge` 移动）** + ctl.json/Dockerfile 两处 base 钉 + 后端 `/version` + git tag + **GHA images-app/base 两条 workflow**。直接消除"可变共享镜像、不可回滚"。 | 高/低 |
| **P2** | **Python uv.lock（`uv sync --locked`）** 喂所有镜像 + base 镜像 digest 钉 + base 内 CLI/@latest 钉死 + Flutter 工具链 FVM 钉。复现性根因。 | 高/中 |
| **P3** | **FaaS 运行时镜像 digest 钉到 service + 按记录 digest 冷唤醒（A 轻量，永不 rebase）**;平台 `schema_migrations` 表 + tracked runner;`_index.json` 版本启用。 | 高/中 |
| **P4** | **DSL 载入期兼容闸**（客户端 `kSupportedDsl`，实为内联解析、非 semver.dart——见 §11.3）+ 发布期强制 + additive/reserve 纪律入 `JSON-DSL.md` + 删孤儿判等;CLI `--version`;`CHANGELOG.md`。 | 中/中 |

## 6. 开放问题
> **全部已决策**（见 §0 决策表）。FaaS ABI 取 A 轻量、部署钉点取 B（`--image-version` flag）、`:agent-control-plane` 切完立即停推。后续若需"不逐个 redeploy 推整队运行时补丁"，再叠 FaaS ABI 的 B（API 版本 + 兼容闸）。

## 7. 一句话总结
项目包侧 semver 已成熟,但**制品/工具链/运行时 ABI/持久化格式 63 个面几乎全无锁定**——`VERSION=1.2.0` 作真相源,把同样纪律延伸开：镜像不可变 tag/digest（可秒级回滚）、Python hash-lock、Flutter 工具链钉、**FaaS helper ABI 版本化 + 运行时镜像 digest 钉到 service**、schema 迁移版本表、DSL 载入期兼容闸 + additive/reserve 纪律。每个 bump 都是可 review 的 diff = 复现保证 + 回滚单元。分四期，P1 即解当前可变镜像 tag 风险。

---

## 8. P1 落地状态（✅ 全部完成：实现 + 77 闭环 + GHA 首跑 + 完整管线 · 2026-06-29）

> 实现 commit `aea665e` + GHA env `5146e38`（分支 `feat/version-management`，`v1.2.0` tag）。
> **77 现跑 CI 构建的 `dapangyu/myapp-backend:1.2.0-5146e38`**（早期手工 `1.2.0-aea665e` 仍在 Hub）。

**已验证（77 live）**：
- `myapp-ctl --version` → `myapp-ctl 1.2.0`。
- `myapp-ctl deploy --image-version 1.2.0-aea665e` → 钉 ctl.json + force 写 backend/faas env → 经镜像站拉到**全新 tag**（回源成功，治好缓存坑）→ 4 服务 healthy、运行镜像 = `1.2.0-aea665e`。
- 后端 `GET /version` → `{version:1.2.0, build_version:1.2.0-aea665e, build_commit:aea665e…, dsl_supported:3.3}`。
- **回滚闭环**：`--image-version agent-control-plane` → `/version` HTTP 404（旧镜像无端点，证明镜像真切切换）→ 前滚 `1.2.0-aea665e` → `/version` 200。
- 8 镜像（4 app + 4 base）已在 Docker Hub：backend 真构建，其余 imagetools 重打 tag（`:1.2.0-aea665e`/`:1.2.0`/`:edge`）。

### 8.1 P1 已完成清单（逐项核对）
| # | 项 | 状态 | 落点 / 证据 |
|---|----|------|------------|
| 1 | `VERSION`=1.2.0 + `CHANGELOG.md` | ✅ | 仓库根 |
| 2 | GHA `images-app.yml`（4 app，`v*` tag + dispatch）+ `images-base.yml`（4 base，仅 dispatch）；出 `:{ver}-{sha}`+`:{ver}`+`:edge` | ✅ **首跑成功**：`v1.2.0`→CI（`environment: DOCKERHUB`）~2min 构建 4 app 镜像并 push `:1.2.0-5146e38`/`:1.2.0`/`:edge` | `.github/workflows/` |
| 3 | 后端 `GET /version` + 启动日志；`Dockerfile.backend` 加 `MYAPP_VERSION` | ✅ live 返回 `version:1.2.0` | `backend/app.py` |
| 4 | `myapp-ctl deploy --image-version <tag>`（钉 ctl.json + force 写 backend/faas env + pull） | ✅ live 升级/回滚均验证 | `deploy.py:_pin_image_version` |
| 5 | 默认 `:agent-control-plane`→`:edge` | ✅ | ctl.json/compose/core.py/4×Dockerfile/services.json/config.py（留 `core.py:2288` 迁移比较） |
| 6 | `CHANGELOG.md` + `myapp-ctl --version` | ✅ → `myapp-ctl 1.2.0` | `cli.py` |
| 7 | cutover 77 到不可变 tag | ✅ backend 家族 + agent-node 跑 `:1.2.0-aea665e`，restarts=0 | 见 8 顶部验证 |
| 8 | 打 `v1.2.0` git tag | ✅ `v1.2.0`@`5146e38` 已推 → 触发 CI 首跑 | git tag |

### 8.2 镜像发布流程（本机无 docker/gh；已验证可行）
backend **真构建**于 `claude.dapangyu.work`（`git worktree --detach origin/<branch>`，不碰其 WIP；`--build-arg BASE_IMAGE=...-base:agent-control-plane` 兜底 + `MYAPP_VERSION`/`MYAPP_BUILD_*`）→ push `:1.2.0-<sha>`/`:1.2.0`/`:edge`。**未改的镜像**（3 app + 4 base）用 `docker buildx imagetools create -t NEW1 -t NEW2 SRC` 在 Hub 服务端**重打 tag**（无需拉层）。77 = `git checkout feat/version-management` + `install_ctl.sh` + `myapp-ctl deploy --image-version <tag> ...`（镜像站对全新 tag 回源）。

### 8.3 GHA 首跑 + 完整管线（✅ 已打通并验证）
**Environment** = **`DOCKERHUB`**（Environment secret `DOCKERHUB_TOKEN` + Environment variable `DOCKERHUB_USERNAME`=`dapangyu`）；两条 workflow 的 job 已加 `environment: DOCKERHUB`（commit `5146e38`）。
- 推 `v1.2.0`@`5146e38` → `images-app.yml` 跑 4-job matrix（`environment: DOCKERHUB` 成功读到凭据）→ **~2min 内**把 `dapangyu/myapp-{backend,agent-node,agent-runtime,faas-runtime}:1.2.0-5146e38` + `:1.2.0` + `:edge` 全部 push 到 Docker Hub（backend `:1.2.0-5146e38`=`:1.2.0`=`:edge` 同 manifest `d0f4212…`）。
- **77 切到 CI 镜像**：`deploy --image-version 1.2.0-5146e38` → 运行 `dapangyu/myapp-backend:1.2.0-5146e38`，`/version` → `build_commit:5146e383…(完整sha)、build_version:1.2.0-5146e38、version:1.2.0`，backend/registry healthy。
- **完整管线闭环**：`git tag v1.2.0 → GHA(env=DOCKERHUB) 构建 4 镜像 → push Docker Hub → 77 --image-version 拉 CI 镜像运行 → /version 确认`。
> base 镜像（`images-base.yml`）仅手动 dispatch（其 Dockerfile 变更或 P2 锁工具链时）。`:agent-control-plane` 已停推（保留作历史回滚目标）。

### 8.4 既定范围与默认（备查）
**范围**：第一轮只 P1；P2（uv lock + base digest + Flutter FVM 3.41.8）、P3（FaaS 运行时 digest + schema 迁移表，改 77 现网）、P4（DSL 载入闸）各自单独一轮。
**分支**：`feat/version-management`（基于 main 07c0774；**未合 main**，待 review）。
**已锁默认**：amd64-only；base GHA 仅手动 dispatch；`/version` 公开无鉴权；committed `ctl.json` 默认 `:edge`（真实部署用 `--image-version` 钉）；`--image-version` 钉 4 app 镜像；`pubspec` 维持 `1.2.0+1`。
**客户端验证**：`ssh fish@claude.dapangyu.work`（flutter 3.41.8）编 web。

---

## 9. P2-P4 推进进度（2026-06-29，分批同步推进）

> 用户指示「能推进到什么程度推进到什么程度，做不到的记录下来统一处理」。下面分 ✅已做 / ✍️已写待生效 / ⏳待办（带精确计划）。

### ✅ 已做（本轮提交）
| 期 | 项 | 落点 |
|---|----|------|
| P2 | Flutter 工具链钉：`.fvmrc` = `{"flutter":"3.41.8"}` | 仓库根 |
| P2 | base 镜像 FROM **digest 钉**：`python:3.11-slim@sha256:506f2951…`（backend/agent-node/faas-runtime-base）+ `ubuntu:24.04@sha256:023f8a75…`（agent-runtime-base） | 4×`Dockerfile.*-base` |
| P4 | 客户端 **DSL 载入闸**：`loadConfig` 加 `kSupportedDsl='3.3'`，App dsl MAJOR > 支持 → 硬拒、MINOR 超前 → 告警；头部注释 v3.2→v3.3 | `lib/json_ui/interpreter.dart` |
| P4 | 后端 **发布期 dsl gate**：`assert_required_fields` 改用 `SUPPORTED_DSL_VERSIONS={"3.3"}`（取代硬编码 `!="3.3"`） | `backend/json_app_builder.py` |
| P4 | `JSON-DSL.md` 加「版本与兼容」纪律（semver bump 规则 + additive/reserve + 端到端强制） | `JSON-DSL.md` |

### ✍️ 已写、待下次 backend 镜像构建才生效
- P4 后端 gate（`json_app_builder`）= backend 镜像代码，**py_compile 通过**，但 77 现网要等下次 CI 构建/`--image-version` 切到新镜像才生效（本轮未再重建 backend）。
- 客户端 DSL 闸：编译验证见本轮 claude `flutter analyze`；**运行期行为**（真拒一个 dsl 4.x App）需客户端实测，未做。

### ✅ 已做（续，commit `58c2a3e`+`e06ac89`+`4a236f7`）
- **P2 Python uv.lock（全 4 base 上下文完成）**：主 `backend/requirements.txt`（收编 flask-caching）→ **`backend/requirements.lock`**（1727 行+hash，喂 backend/agent-runtime base）；`deploy/production/requirements/faas-runtime-base.{txt,lock}`（484 行）+ `agent-node-base.{txt,lock}`（417 行）。4 个 `Dockerfile.*-base` 全改 `pip install --require-hashes -r …lock`（装不需 uv）。**三份 lock 均在 python:3.11-slim 端到端安装验证（带 hash 全装上、无 mismatch）。**
- **P2 CLI 钉**：`claude-code@2.1.195` + `opencode-ai@1.17.11`（backend/agent-runtime base，取代 `@latest`）。
- **P4 后端发布期 gate**：`json_app_builder.assert_required_fields` 用 `SUPPORTED_DSL_VERSIONS` + `validate_json_app` 加 dsl 窗口校验（py_compile 通过）。
- **P3 `_index.json` 版本闸**：`registry_server` 加 `INDEX_SCHEMA_VERSION` + `_load_index` 加载期 MAJOR 不符告警。
- **P3 `schema_migrations` runner**：`backend/migrate.py`（自举 tracking 表，按序应用 `00N_*.sql`，`--mark`/`--status`，走 DB_DIRECT 绕池）。**已在 77 跑 `--mark` 建基线并验证：`schema_migrations` 表建好、001-007 全标记已应用、pending 清空（只建表+7 行、未动现有数据）。**

> P2 复现性至此**全覆盖**（Python 依赖全锁 + CLI 钉 + base digest 钉 + Flutter FVM）。

### ⏳ 剩余待办（带精确计划，供统一处理）
1. **整 base 镜像重建验证**：以上 base 改动（lock/CLI/digest）走 `images-base.yml` 手动 dispatch 重建一遍冒烟（本轮只验了 pip 安装步，base 还含 Node/CLI/Chrome 等无关重层）。注 lock 解出的版本与原 `>=` 可能不同（如 gunicorn 25.3.0）。
2. **backend 代码 gate 上线**：本轮后端改动（`json_app_builder`/`validate_json_app`/`registry _index`/`migrate.py`）= 镜像代码，**py_compile 通过但 77 现网要等下次 backend 镜像构建**（推 `v1.2.x` tag 触发 CI，或 `--image-version` 切新镜像）才生效；migrate.py 本轮是 `docker cp` 进容器跑的基线。
3. **migrate.py wiring 进 deploy**：让 `myapp-ctl deploy` 末尾自动 `docker exec myapp-backend python /app/backend/migrate.py`（仿 `deploy.py:_run_supabase_auth_migrations`），新迁移随部署自动应用。
4. **`google-chrome-stable` 钉**：apt 只供最新 stable，难钉具体版（已知缺口）；`node setup_22.x` 可钉具体 minor。
5. **P3 FaaS 运行时 digest 钉到 service**（残留小、改现网）：实测**冷唤醒=`container.start()` 不 rebase**；`runtime_image` 已记录（tag 非 digest）；P1 `--image-version` 已钉 `FAAS_LOCAL_DOCKER_IMAGE`。残留=部署时记**解析后 digest**、recreate 用记录 digest。**改 77 现网 FaaS，单独一轮。** 重量版（`MYAPP_FAAS_RUNTIME_API`+兼容闸）按 §3.5 标 B 暂不做。
6. **P4 客户端闸运行期实测**：`dart analyze` 已过；真拒一个 dsl 4.x App 的运行期行为需 web 端实测。

---

## 10. 自主发布-部署测试记录

### Round 1 — v1.2.1（commit `1bf5e4a`，2026-06-30）✅ 无问题
全自动跑通 `git tag v1.2.1 → GHA(env=DOCKERHUB)构建4 app镜像 → push Hub(1.2.1-1bf5e4a，~1min) → myapp-ctl deploy --image-version 1.2.1-1bf5e4a → 77`：
- **7 个 app 服务**（backend/ai-worker/faas-push-worker/registry/agent-node/config-center/user-center）全切 `1.2.1-1bf5e4a`，running、restarts=0，backend/registry healthy。
- **`/version`** → `{version:1.2.1, build_version:1.2.1-1bf5e4a, build_commit:1bf5e4a9…}`；`myapp-ctl --version`→1.2.1。
- **数据/配置全保留**：deploy 前后对比 `schema_migrations=7 / public tables=17 / userdata s_* schemas=6` 一致；secrets 内容保留（DB/Redis/MinIO 连接全 healthy 即证密钥未变；`--image-version` 仅改 backend.env 的 `MYAPP_*_IMAGE` pin 行，故 mtime 变但内容只更新镜像 pin）；postgres/minio/openim 等 volume 未动。
- **新代码已在镜像**：`migrate.py`/`SUPPORTED_DSL_VERSIONS` 烤进镜像；`migrate.py --status`→7 applied/0 pending。
- **真实功能正常**：registry /health ok；FaaS e2e（provision 直连旁路 + faas 池 `u_*@userdata:6432`）通过。
- **5 服务近 3min 日志 0 error**；无服务掉队（无残留 agent-control-plane/1.2.0 的运行容器）。
- 唯一非问题项：4 个 scale-to-zero 的旧 FaaS 函数容器仍在 `faas-runtime:agent-control-plane`——**正确**（冷唤醒=`container.start` 不 rebase，老函数留在原运行时；新部署才用 1.2.1 运行时）。
- **结论：无需修复 → 无 v1.2.2。** 发布-部署闭环（保留数据配置）验证通过。

> 已知未经此环测试的项（需 `images-base.yml` 手动 dispatch，无 gh 触发不了）：P2 base 镜像重建（lock/CLI/digest 当前 dormant，app 镜像 FROM 旧 `:edge` base）。见 §9 剩余待办。

### Round 2 — v1.2.2（commit `ff1cd41`，2026-06-30）✅ 无问题
新增 `_run_platform_migrations`（deploy 后自动跑 `migrate.py`）后再跑一轮：
- `git tag v1.2.2 → CI(env=DOCKERHUB) 4 镜像 1.2.2-ff1cd41(~1min) → 77 git pull + install_ctl(新 ctl 含 wiring) + deploy --image-version`。
- **7 app 服务全 1.2.2-ff1cd41**、healthy、restarts=0；`/version`=1.2.2；`myapp-ctl --version`=1.2.2。
- **部署后自动迁移 wiring 触发**：`+ docker exec myapp-backend python migrate.py`（0 pending→无操作、非阻断、无告警）。
- 数据保留：`schema_migrations=7 / tables=17 / userdata schemas=6` 不变；backend 近 2min 0 error。
- **迁移 apply 路径定论测试**：临时塞 `008_vtest_selftest.sql` → `migrate.py` apply（建表+记录、count=8）→ 再跑幂等（0 pending 不重复）→ 清理还原到 7。**schema_migrations runner 端到端可用。**

### 结论
两轮发布-部署闭环（`git tag → GHA(env=DOCKERHUB) → Docker Hub → myapp-ctl deploy --image-version → 77`）**全自动跑通、数据/配置全保留、零 error、可重复**；新功能（DSL gate / schema 迁移 runner + 自动迁移）均验证可用。**未发现需修复的问题**，77 现跑 `1.2.2-ff1cd41`。唯一未经此环测的是 P2 base 镜像重建（需 `images-base.yml` 手动 dispatch，本环境无 `gh` 触发不了；base 改动当前 dormant，见 §9）。

---

## 11. 综合评估（feat/version-management 改造 · 2026-06-30）

> 对本分支改造做了一次对照真实代码 + 文档 + 77 现网状态的多维度评估（完成度 / 风险 / 全局影响 / 漏评），逐条对抗式核实（24 条确认），并对标业界 rollout 最佳实践。**总评：P1 真实落地且闭环验证（可信）；P2/P3/P4 代码就位但有几处"代码完成≠生效/≠达成设计目标"的落差，以及对"非-77 主机"的真实雷。** 下面按"先看这几条"排序。

### 11.1 最该先处理的（高杠杆，已核实）

1. **【漏评·中】P2 base 改动全程 dormant → 复现性"假绿"。** 4 个 `Dockerfile.*-base` 钉了 `FROM python:3.11-slim@sha256…` + `--require-hashes` + CLI 版本，但 **app 镜像 build 时 `BASE_IMAGE=…-base:edge`（移动 tag），而 `:edge` base 从未经 `images-base.yml` 重建**（仅 workflow_dispatch、无 gh 触发不了）。即：lock/digest/CLI 钉死的是一个**app 构建永不拉取**的镜像。**P2"复现性全覆盖"目前是 code-only、未经 build 验证**——文档措辞要从"全覆盖"收敛为"代码完成、base 未重建（dormant）"。**修复**：手动在构建机 `docker build` 4 个 base + push `:edge`，再触发 `images-app.yml`；并把 `images-app.yml` 的 `BASE_IMAGE` 从 `:edge` 改钉 base 的不可变 `:{ver}-{sha}`（否则即便重建，app 仍 FROM 移动 tag）。

2. **【overclaim·中】FaaS 运行时 digest 钉（§3.5-A 核心"永不 rebase"）根本没实现。** 实现只把 `FAAS_LOCAL_DOCKER_IMAGE`（一个 tag 字符串，默认还是移动 `:edge`）原样写进 `faas_deployments.runtime_image`，**从未 `docker inspect` 解析 `RepoDigests` 得到 `image@sha256`**，recreate/冷启路径也不读 `runtime_image` 去强制按 digest pull。§9 说"残留小"是**低估**：当前"不 rebase"只是 `container.start` 的副作用，**一旦 recreate 即破**。文档 §9 待办 5 应从"残留小"改为"A 核心未实现"。

3. **【全局影响·中】deploy 后自动跑 `migrate.py`（裸跑、无 `--mark`）会在"已有 schema 但无 `schema_migrations` 表"的非-77 主机上崩。** 77 安全只因 §10 手动跑过 `--mark` 建基线（pending=0）。其它存量主机：`device_tokens` 早被旧手动 psql 流程迁过（`platform` 列已删），但从没建过 tracking 表 → 首次 backend 部署 `_run_platform_migrations` 裸跑 → `002` 回填语句引用不存在的列 → **崩**。**修复**：`_run_platform_migrations` 首次遇"无 tracking 表但平台表已存在"应先自动 `--mark` 建基线；至少把 `002` 回填改成 `to_regclass`/`information_schema` 守卫使重跑幂等。

4. **【全局影响·中】`install_ctl.sh` 的 `deep_merge`（existing 覆盖 default）使存量主机保留 `:agent-control-plane` 镜像 pin；CI 停推该 tag 后这些主机 `deploy --pull` 拉不到镜像。** `ctl.json.images.*` 与 `services.json` 的 faas-runtime/agent-runtime 仍是旧 tag（existing 胜出、不更新）。**修复**：`install_ctl.sh` 对 images map 做一次性 legacy 迁移（仿 `core.py:_should_replace_env_value` 对 backend.env 已做的），把废弃 `:agent-control-plane` 覆盖为 `:edge`；停推前发迁移说明。

### 11.2 迁移安全（中，对标业界 DB-migration rollout）

5. **`migrate.py` 记 `checksum` 列却从不校验** → 已应用迁移文件被改写会静默漂移、永不报警（checksum 是 write-only 死数据）。**应**：加载期回读 checksum 比对，不一致则告警/非零退出。
6. **`_run_platform_migrations` 非阻断（失败只告警）**会**静默放过坏迁移**，且不区分"0 pending 无操作"（正常）与"迁移执行失败"（致命）。业界共识：迁移是部署最高风险环，应**阻断式**（迁移成功才放新实例），且**迁移须对在跑的旧代码向后兼容**（expand/contract）、**迁移前备份 + 演练过回滚**。当前无 down/无备份/无白名单、以 jsonapp **库 owner**（注:非集群超级用户，爆破半径限本库）跑任意 `migrations/[0-9]*.sql` DDL。**建议**：失败升级为阻断;迁移目录加连续编号白名单;文档化"平台迁移 additive-only"。

### 11.3 单一真相源未达成 + 文档不自洽（低，但影响可信度）

7. **【overclaim·低】"VERSION 单一真相源"未达成**：`VERSION=1.2.2` 与 `pubspec 1.2.0+1` / `registry /health 1.0.0`（死值）/ `_index 1.0` / `dsl '3.3'`（**5+ 处硬编码**：app.py:112、json_app_builder.py:983、validate_json_app.py:444、interpreter.dart:573…）彼此漂移。且 §3.1"pubspec 从 VERSION 派生" vs §8.4"pubspec 维持 1.2.0+1" **自相矛盾**。**建议**：release 脚本校验 pubspec 主版本==VERSION（或文档化解耦理由、停止声称派生）;`registry /health.version` 改读 `MYAPP_VERSION`;后端三处 `3.3` 收敛到 `SUPPORTED_DSL_VERSIONS` 单一常量。
8. **【overclaim·低】P4 客户端闸"复用 semver.dart"不实**：实际是 `interpreter.dart:576-587` 内联 `split('.')+int.tryParse` 手写解析，与 `semver.dart` 零关联。要么真改用 `semver.dart`，要么删文档措辞。
9. **文档陈旧版本号散布多处**（§line3 `1.2.0-5146e38`、§8 顶部、§8.3、§9 Round1 `1.2.1-1bf5e4a`）落后于现网 `1.2.2-ff1cd41`，需统一。

### 11.4 其余已核实项（低 / 已知边界）

- **本地 `deploy --build` 不传 `MYAPP_VERSION` → 本地构建镜像 `/version` 永远 `unknown`**（仅 GHA 路径有溯源）;`build_production_images.sh` 默认 `TAG=agent-control-plane` 未改。**建议** `core.py:_deploy_images` 的 build cmd 加 `--build-arg MYAPP_VERSION=$(cat VERSION)`。
- **多架构未评估**：产物全 amd64;base FROM 钉的是**平台 digest 非 manifest-list**（§3.2 自己 cite 的最佳实践没采纳）;`agent-runtime-base` 的 chrome apt 源写死 `arch=amd64`（arm64 直接构建失败）。文档应显式记为已知边界。
- **lock 纪律漏 Node 上下文**：`website/`(Vite)、`web_openim_bridge/`(npm) 的 `package-lock.json` 未进任何 CI `npm ci` 闸;`pubspec` 的 `--enforce-lockfile`（§3.4 计划）实际**未接进 CI**——Dart"正例"也只是 lock 存在、未强制。
- **DSL 闸不在 Registry `/resolve` 运行期**：存量 App 与客户端兼容只在"下载整个 JSON 后进 loadConfig"才暴露;`/resolve` 响应不带包的 `dsl`。客户端对 `dsl` 为空**完全静默放行**（无 warn）。
- **`:edge` 仍被 CI 每次 push 覆盖**（移动 tag）;`services.json` 对 faas-runtime/agent-runtime 硬编码 `:edge`（被 IMAGE_TARGETS 成员资格遮蔽，潜在陷阱）。生产靠纪律不钉 `:edge`，建议变成机器闸（检测到部署仍指 `:edge` 则 warn/要 `--allow-edge`）。

### 11.5 业界最佳实践对照（cited，印证上面）

- **按 digest 部署、非 tag**：tag（含 semver、`:edge`）默认可变，存在 TOCTOU（扫描通过→实际拉取之间 tag 被重推）。我们 `--image-version` 钉 `:{ver}-{sha}` 不可变 tag 已大幅缓解;更强可叠加 `@sha256` digest 钉 + Docker Hub 逐仓库 immutable-tag(`v*`) 配置。([Sysdig TOCTOU](https://www.sysdig.com/blog/toctou-tag-mutability) · [Docker immutable tags](https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/))
- **hash-lock 与 base 必须原子同步**：base 的 Python 小版本/平台一变，lock 的 wheel hash 即失配、`pip install` 整批 fail（全有或全无）。印证 11.1-#1 的 dormant 风险 + base digest 钉的必要。([uv platform drift](https://github.com/astral-sh/uv/issues/8746))
- **自动 DB 迁移**：业界共识是**迁移先于新实例（阻断 Job/init-container 排序）+ 向后兼容 expand/contract + 迁移前备份 + 演练回滚**;应用启动时自动迁移的硬伤是多副本并发迁移 + 应用需高权限 DB 凭据。印证 11.2。([andrewlock K8s migrations](https://andrewlock.net/deploying-asp-net-core-applications-to-kubernetes-part-7-running-database-migrations/))

### 11.6 总评

- **P1**：实打实落地、两轮发布-部署闭环验证（含回滚 + 数据保留）——**可信、可上生产路径**。
- **P2**：代码完整且 lock 已 python:3.11-slim 装验，但 **base 未重建 → 当前未生效（dormant）**，需一次 base 重建才"真绿"。
- **P3**：`_index` 闸 + `schema_migrations` runner 真实可用（77 已基线 + apply 路径验证过），但**自动迁移的安全护栏不足**（非阻断/无 checksum 校验/非-77 主机首跑会崩）+ **FaaS digest 核心未实现**。
- **P4**：双端 gate 真实接入、孤儿判等已清，**功能 done**;瑕疵是**多处 `3.3` 硬编码 + "复用 semver.dart" overclaim**。
- **跨切**：单一真相源未达成、文档多处陈旧/自相矛盾、非-77 主机迁移与镜像 pin 两个真实雷。
- **优先级**：先补 11.1 的 4 条（dormant base 重建 + FaaS digest 真实现 + 迁移首跑基线守卫 + install_ctl legacy 迁移）→ 再 11.2 迁移护栏 → 11.3 真相源收敛/文档修正。本评估**不阻断 P1 合 main**，但上述项应在"声称 P2-P4 完成/上生产"前补齐。

### 11.7 本轮按 §11 落地的修复（2026-06-30，分支 feat/version-management）

> 按 §11 发现开始补，已落地以下（全部 `py_compile`/`bash -n`/import 自检通过；后端类改动随**下次 backend 镜像构建**在 77 生效）：

**批次1（后端安全 + 单一真相源，commit `bbe2661`）**
- §11.3 **DSL 真相源收敛**：新增 `backend/dsl_contract.py`（`SUPPORTED_DSL_VERSIONS`/`PRIMARY_DSL_VERSION`），`app.py:/version`、`json_app_builder`、`validate_json_app` 全引用它，消除多处 `'3.3'` 硬编码（客户端 `kSupportedDsl` 跨进程无法共享，仍需手动同步）。`registry /health` 增 `platform_version`+`build_commit`（原死值 `1.0.0` 监控不可溯源）。
- §11.1-#3 **`migrate.py` 自动基线**：tracking 表本次新建 + 平台库已有 schema 时**自动 `--mark`**（不重放）→ 修复存量主机首次 `deploy` 裸跑 `migrate.py` 撞已删列而崩。
- §11.2-#5 **checksum 漂移校验**：已应用迁移被改写时告警（`--status` 非零退出）。
- §11.2-#6 **自动迁移改阻断**：`migrate.py` 在镜像内但执行失败 → 中止部署（老镜像缺 `migrate.py` 仍优雅跳过）。

**批次2（构建溯源 + 存量主机迁移，commit `4dbf554`）**
- §11.4 本地 `deploy --build` 注入 `MYAPP_VERSION`（`core.py` 读 `source/VERSION`）+ `build_production_images.sh` 默认 TAG `agent-control-plane→edge` 且传 `MYAPP_VERSION`——本地构建镜像 `/version` 不再 `unknown`。
- §11.1-#4 `install_ctl.sh` 一次性 legacy 迁移：存量 `ctl.json` images 的 `:agent-control-plane` 平移到 `:edge`，避免 CI 停推后拉不到镜像。

**FaaS digest（commit `aa3d8af`）**
- §11.1-#2 部署时 `_resolve_runtime_digest()` 把 `FAAS_LOCAL_DOCKER_IMAGE` 解析到 `image@sha256` 记进 `runtime_image_digest`（溯源，additive）。
- **重要修正**：核查代码发现实现的 **X-G3 冷唤醒**（`_image_is_stale`→镜像变了就 recreate **以传播运行时安全改动**）与 §0/§3.5-A 决策**"按记录 digest 跑、永不 rebase"正好相反**。这不是"忘了实现 digest"，而是**两种对立策略**：A=稳定（钉 digest、老函数不收运行时补丁）vs X-G3=安全传播（rebase、但 helper ABI 改了会破老函数）。**需产品决策二选一**——本轮只补 digest 记录，不擅自翻转线上冷唤醒语义。

### 11.8 剩余（需重活/产品决策/CI，未在本轮做）
1. **【高】P2 base 镜像重建**（§11.1-#1）：手动在构建机 build 4 个 base + push，再把 `images-app.yml` 的 `BASE_IMAGE` 从 `:edge` 改钉 base 不可变 `:{ver}-{sha}`，让 lock/CLI/digest 真正进 app 镜像（当前 dormant）。
2. ~~【产品决策】FaaS 冷唤醒策略~~ **已决（2026-06-30）：X-G3 用最新运行时镜像**（保持现有实现，无需改码；digest 仅作溯源）。见 §3.5。
3. **后端类修复上线**：批次1/FaaS digest 是镜像代码，需推 `v1.2.3` 触发 CI 构建 + `--image-version` 切到新镜像才在 77 生效。
4. **【低】** semver.dart 真复用（客户端重构，需 dart 验证）;`website/`+`web_openim_bridge` 的 `npm ci` + `pubspec --enforce-lockfile` 接进 CI;`/resolve` 响应带包 `dsl` 供下载前比对;多架构边界（amd64-only、平台 digest 非 manifest-list、chrome 源写死 amd64）文档化;`:edge` 部署机器闸（检测到钉移动 tag 则 warn/要 `--allow-edge`）。
