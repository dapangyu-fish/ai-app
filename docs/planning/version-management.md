# RFC: 版本号管理（Version Management）

- **状态**: ✅ **P1 已实现 + 77 闭环验证通过**（见 §8，commit `aea665e`，不可变镜像 `1.2.0-aea665e`）；P2-P4 待排期。仅 GHA 首跑 gated 于 Environment 名确认。
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
| FaaS helper ABI | **A 轻量**：部署时把运行时 `image@sha256` 记到 service；冷唤醒按**记录的 digest** 跑、**永不 rebase** → 漂移彻底消失。（不做 API-version + 兼容闸，需要"不 redeploy 推整队补丁"时再叠 B） | §3.5 |
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
- `pubspec.yaml`、后端 `/version`、CLI `--version`、镜像 tag 都从它派生；release 打 git tag `vX.Y.Z`。

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

### 3.5 FaaS 运行时 helper ABI（新发现，high）【已决策：A 轻量】
存量函数依赖 `myapp_db/myapp_auth/myapp_data` 的 API,但它们随 `faas-runtime:edge` 浮动,**冷唤醒静默 rebase 到当前镜像 → helper 签名一改、老函数下次唤醒即坏**。
- **A（采纳）：运行时镜像 `image@sha256` 记到每个 service**（与 `active_commit` 并列存 `faas_deployments`）;**冷唤醒/recreate 跑这个记录的 digest，不是 `:edge` → 每个函数永远跑在它构建时的 helper 镜像上、漂移彻底消失**。本质=把"钉不可变 digest、别跑移动 tag"精确到每个 service。代价:老函数不 redeploy 收不到运行时补丁、主机攒多版本镜像(占盘)。
- **B（暂不做，可后续叠加）**：再烤 `MYAPP_FAAS_RUNTIME_API` 版本 + 记到 service + 冷唤醒兼容闸（兼容→可升、不兼容→标记需重部署）。仅当需要"不逐个 redeploy 就给整队推运行时补丁"时才加。
- helper 公开签名任何变更 = MAJOR;`c_`+HMAC 假名、`base64(json).hmac[:32]` token、`owner` 列等**冻结的 on-disk 契约**：要改就**前缀版本号**（`c1_/c2_`）+ 数据迁移,绝不原地改。

### 3.6 数据 / Schema / 对象存储
- **平台 DB 加 `schema_migrations` 表**（id/applied_at/checksum）+ 确定性 runner 按序跑 `backend/migrations/00N_*.sql` 并记录;停止并行手改 `schema.sql` 与 migrations。deploy CLI 已有 supabase-auth 迁移机制（`deploy.py:592`）可复用扩展到平台库。盖一行 `schema_version`。
- **FaaS per-user schema 记指纹**（schema.sql hash）到 `faas_deployments`,re-deploy 改了已存在表列类型时 warn/拒（`CREATE TABLE IF NOT EXISTS` 改不动）;明确"additive-only"或给属主授权的 ALTER 路径。
- **`_index.json` 的 `version` 字段真正启用**：`_load_index` 读它、不匹配则升级/拒（现在只在空 init 写、从不校验,而它是最 load-bearing 的存储文档）。
- **对象存储键格式**（`{app_id}/{name}-{version}.json`、asset-pack `{slug}/{version}/manifest.json` + `metadataVersion`）视为冻结契约,改格式即版本化迁移、别孤立旧对象。

### 3.7 DSL 契约：纯 semver + additive/reserve 纪律【已决策：semver，不用 SchemaVer】
DSL 是「stored documents 必须持续可渲染」的 schema 问题,但为**全项目一套心智**（registry 包 + 平台 VERSION + 依赖都 semver、`dsl` 现就是 `3.x`、`semver.dart` 直接可用）决定用 **纯 semver**，把 SchemaVer 的"已发布 App 还渲染吗"作为 **MAJOR 判定规则吸收进来**。
- **版本规则**：**MAJOR**=破坏 DSL 契约（**任何已发布 App 可能渲染坏**/改语义/删控件）;**MINOR**=向后兼容新增（新控件/内置/新可选字段，旧 App 不受影响）;**PATCH**=引擎修复不动契约。`JSON-DSL.md` 即 SemVer 要求的"公开 API"。
- **客户端载入闸**：加 `kSupportedDsl='3.3'`（+ min/max 窗口）常量,`loadConfig` 顶部解析 `config['dsl']`：MAJOR 不匹配硬拒（"需升级客户端"）、MINOR-ahead 仅 warn——复用现成 `lib/json_ui/semver.dart`。删掉 `json_app_builder.py` 那处孤儿 `dsl != '3.3'`。
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
| **P4** | **DSL 载入期兼容闸**（客户端 `kSupportedDsl` + semver.dart 复用）+ 发布期强制 + additive/reserve 纪律入 `JSON-DSL.md` + 删孤儿判等;CLI `--version`;`CHANGELOG.md`。 | 中/中 |

## 6. 开放问题
> **全部已决策**（见 §0 决策表）。FaaS ABI 取 A 轻量、部署钉点取 B（`--image-version` flag）、`:agent-control-plane` 切完立即停推。后续若需"不逐个 redeploy 推整队运行时补丁"，再叠 FaaS ABI 的 B（API 版本 + 兼容闸）。

## 7. 一句话总结
项目包侧 semver 已成熟,但**制品/工具链/运行时 ABI/持久化格式 63 个面几乎全无锁定**——`VERSION=1.2.0` 作真相源,把同样纪律延伸开：镜像不可变 tag/digest（可秒级回滚）、Python hash-lock、Flutter 工具链钉、**FaaS helper ABI 版本化 + 运行时镜像 digest 钉到 service**、schema 迁移版本表、DSL 载入期兼容闸 + additive/reserve 纪律。每个 bump 都是可 review 的 diff = 复现保证 + 回滚单元。分四期，P1 即解当前可变镜像 tag 风险。

---

## 8. P1 落地状态（✅ 已实现 + 77 闭环验证通过 · 2026-06-29）

> 实现 commit `aea665e`（分支 `feat/version-management`）。不可变镜像 = **`1.2.0-aea665e`**（backend digest `sha256:487af6d…`）。

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
| 2 | GHA `images-app.yml`（4 app，`v*` tag + dispatch）+ `images-base.yml`（4 base，仅 dispatch）；出 `:{ver}-{sha}`+`:{ver}`+`:edge` | ✅ 写好+YAML 校验通过；**首跑待触发**（见 8.3） | `.github/workflows/` |
| 3 | 后端 `GET /version` + 启动日志；`Dockerfile.backend` 加 `MYAPP_VERSION` | ✅ live 返回 `version:1.2.0` | `backend/app.py` |
| 4 | `myapp-ctl deploy --image-version <tag>`（钉 ctl.json + force 写 backend/faas env + pull） | ✅ live 升级/回滚均验证 | `deploy.py:_pin_image_version` |
| 5 | 默认 `:agent-control-plane`→`:edge` | ✅ | ctl.json/compose/core.py/4×Dockerfile/services.json/config.py（留 `core.py:2288` 迁移比较） |
| 6 | `CHANGELOG.md` + `myapp-ctl --version` | ✅ → `myapp-ctl 1.2.0` | `cli.py` |
| 7 | cutover 77 到不可变 tag | ✅ backend 家族 + agent-node 跑 `:1.2.0-aea665e`，restarts=0 | 见 8 顶部验证 |
| 8 | 打 `v1.2.0` git tag | ⏳ 待 8.3（触发 GHA 首跑） | — |

### 8.2 镜像发布流程（本机无 docker/gh；已验证可行）
backend **真构建**于 `claude.dapangyu.work`（`git worktree --detach origin/<branch>`，不碰其 WIP；`--build-arg BASE_IMAGE=...-base:agent-control-plane` 兜底 + `MYAPP_VERSION`/`MYAPP_BUILD_*`）→ push `:1.2.0-<sha>`/`:1.2.0`/`:edge`。**未改的镜像**（3 app + 4 base）用 `docker buildx imagetools create -t NEW1 -t NEW2 SRC` 在 Hub 服务端**重打 tag**（无需拉层）。77 = `git checkout feat/version-management` + `install_ctl.sh` + `myapp-ctl deploy --image-version <tag> ...`（镜像站对全新 tag 回源）。

### 8.3 下一步（待用户 go）——把 GHA 首跑接通
**Environment 已确认**：名为 **`DOCKERHUB`**，含 Environment secret `DOCKERHUB_TOKEN` + Environment variable `DOCKERHUB_USERNAME`（值 `dapangyu`）。
1. 给 `images-app.yml` + `images-base.yml` 的 `build` job 加一行 **`environment: DOCKERHUB`**（当前是占位注释）。提交。
2. 推 **`v1.2.0`** git tag（或手动 `workflow_dispatch`）触发 `images-app.yml` 首跑。
3. 验证 CI 成功 = Docker Hub 上 `:1.2.0`/`:1.2.0-<新sha>`/`:edge` 被 CI 重新 push（可 `docker manifest inspect` 对比 digest，无需 gh）。
> base 镜像（`images-base.yml`）仅在其 Dockerfile 变更或要锁工具链（P2）时手动 dispatch。

### 8.4 既定范围与默认（备查）
**范围**：第一轮只 P1；P2（uv lock + base digest + Flutter FVM 3.41.8）、P3（FaaS 运行时 digest + schema 迁移表，改 77 现网）、P4（DSL 载入闸）各自单独一轮。
**分支**：`feat/version-management`（基于 main 07c0774；**未合 main**，待 review）。
**已锁默认**：amd64-only；base GHA 仅手动 dispatch；`/version` 公开无鉴权；committed `ctl.json` 默认 `:edge`（真实部署用 `--image-version` 钉）；`--image-version` 钉 4 app 镜像；`pubspec` 维持 `1.2.0+1`。
**客户端验证**：`ssh fish@claude.dapangyu.work`（flutter 3.41.8）编 web。
