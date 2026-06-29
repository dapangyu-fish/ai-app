# RFC: 版本号管理（Version Management）

- **状态**: 草案 / 待评审
- **范围**: 跨域（`deploy/production/`、`scripts/myapp_ctl/`、`backend/`、`pubspec.yaml`、`JSON-DSL.md`、`backend/migrations/`）
- **作者**: Claude（基于 2026-06-29 对全仓 **63 个版本/依赖耦合面**的审计 + 对抗式核实 + 四类锁定最佳实践调研）
- **起始版本**: **`1.2.0`**（承接 `pubspec.yaml` 现有线，不另起 1.0.0）
- **缘起**: PgBouncer 落地把后端镜像 push 到了共享可变 tag `:agent-control-plane`（见 [pgbouncer-jsonapp-postgres.md](pgbouncer-jsonapp-postgres.md)）。深挖后发现这只是冰山一角——本项目**可部署制品、构建工具链、运行时 ABI、持久化格式**几乎全无版本锁定。

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

### 3.2 容器镜像：不可变 tag + digest（本项目两处都要钉）
- 构建时给自建镜像打**双 tag** 并都 push：不可变 `:{VERSION}-{git-sha}`（sha 已在 `core.py:666` 算好、只是没当 tag 用）+ 可变频道 `:agent-control-plane`（降级为纯 dev 便利指针，**生产/测试部署禁止直接钉它**）。
- **两个浮动源都要钉**：`ctl.json` 的 `images.*` map（`myapp-ctl deploy --build` 的 `--build-arg BASE_IMAGE` 实际取这里，`core.py:805`）**和** `Dockerfile.*:1` 的 `ARG BASE_IMAGE` 默认（手动/CI 兜底）——只钉一处会被另一处覆盖。
- **base 镜像 digest 钉 + 锁工具链**：`FROM python:3.11-slim@sha256:…` / `ubuntu:24.04@sha256:…`;`Dockerfile.*-base` 里 `claude-code`/`opencode-ai`/`google-chrome-stable` 改成**显式版本**（现仅 `codex@0.136.0`、`codex-relay==0.3.3` 钉了）;`node setup_22.x` 钉到具体 minor。
- 部署钉不可变 tag/digest → `deploy --pull` 任意时刻拉到同一镜像;**回滚 = `images` map / `MYAPP_*_IMAGE` env 重指上一个 `:{VERSION}-{sha}`**。
- 第三方：`postgres:15.8`/`redis:7.4-alpine`/`nginx:1.27-alpine` 是浮动 minor，建议升级为 digest 钉（中等优先）;`minio RELEASE.*`、supabase 精确 tag 已 OK。
- > 最佳实践（cited）：tag 可变、digest 是内容哈希「每次拉到完全相同镜像」;多架构钉 **manifest-list digest** 而非平台 digest;digest 钉锁的是**输入**而非 bit 级输出（如需 bit 级再加 `SOURCE_DATE_EPOCH` + BuildKit `rewrite-timestamp`）;digest 不自动收安全补丁→配 Renovate/Dependabot 主动升。[Docker digests](https://docs.docker.com/dhi/core-concepts/digests/) · [why pin by SHA](https://candrews.integralblue.com/2023/09/always-use-docker-image-digests/) · [reproducible builds GH Actions](https://docs.docker.com/build/ci/github-actions/reproducible-builds/)

### 3.3 Python 依赖：引入 lockfile（喂 3+ 镜像的根因修复）
- 采用 **lockfile**：`uv lock`（`uv.lock` 跨 OS/arch/py 单文件，CI `uv sync --locked` 漂移即失败）或 `pip-tools`（`requirements.in` → `requirements.lock`）。
- **hash 钉**：`--generate-hashes` + `pip install --require-hashes`（全有或全无强制，含传递依赖）。
- `requirements.txt` 留作人编输入,镜像从 lock 构建并**提交 lock**;`Dockerfile.agent-node-base` 的无界 `flask/gunicorn/requests` 先补边界、最终进 lock;`faas-runtime-base` 把 `psycopg2-binary/requests` 等 helper 实际 import 的依赖钉死（现 `flask==3.0.3` 已钉，其余 `>=`）。
- > 这是**最高杠杆**：一个 lock 喂 backend/registry/worker + agent-runtime + faas-runtime 多个镜像;没有它，任何 `MYAPP_BUILD_COMMIT` 都无法对应"实际装了哪些版本"。[pip hash-checking](https://pip.pypa.io/en/stable/topics/secure-installs/) · [uv lockfile](https://pydevtools.com/handbook/how-to/how-to-use-a-uv-lockfile-for-reproducible-python-environments/)

### 3.4 Flutter / Dart：保持 lock + 锁工具链
- **`pubspec.lock` 已提交——保持，永不进 `.gitignore`**（app 包的正确做法;若将来抽出可发布的组件库，库包反而不提交 lock）。caret 范围对 app 无害（lock 是真相源）。
- 缺口：**Flutter/Dart 工具链未锁**（无 FVM/`.tool-versions`/CI 钉）——lock 钉的是包不是编译器,不同 channel 会产出不同二进制/生成码。引入 **FVM + 提交 `.fvmrc`**（或 `.tool-versions`）。
- CI 跑 `flutter pub get --enforce-lockfile`（resolution 偏离即失败）;`intl: any` 收成有界。
- > [dart.dev: 提交 app 的 lock、不提交库的 lock](https://dart.dev/tools/pub/private-files)

### 3.5 FaaS 运行时 helper ABI（新发现，high）
存量函数依赖 `myapp_db/myapp_auth/myapp_data` 的 API,但它们随 `faas-runtime:agent-control-plane` 浮动,**冷唤醒静默 rebase**。
- 引入 **`MYAPP_FAAS_RUNTIME_API`**（如 `1`）烤进运行时镜像 **并在部署时记到 service 元数据**（`faas_deployments`）。
- **运行时镜像按 digest 钉、并记到每个 service**（`image@sha256` 与 `active_commit` 并列）→ 存量函数代码与它构建时的 helper ABI 可复现配对。
- 冷唤醒/recreate 的 staleness 判断**改为 API-version-aware**：新镜像 helper API 与 service 部署时记录的版本不兼容 → 不 rebase、标记"需重新部署",而非静默替换。
- helper 公开签名任何变更 = MAJOR;`c_`+HMAC 假名、`base64(json).hmac[:32]` token、`owner` 列等**冻结的 on-disk 契约**：要改就**前缀版本号**（`c1_/c2_`）+ 数据迁移,绝不原地改。

### 3.6 数据 / Schema / 对象存储
- **平台 DB 加 `schema_migrations` 表**（id/applied_at/checksum）+ 确定性 runner 按序跑 `backend/migrations/00N_*.sql` 并记录;停止并行手改 `schema.sql` 与 migrations。deploy CLI 已有 supabase-auth 迁移机制（`deploy.py:592`）可复用扩展到平台库。盖一行 `schema_version`。
- **FaaS per-user schema 记指纹**（schema.sql hash）到 `faas_deployments`,re-deploy 改了已存在表列类型时 warn/拒（`CREATE TABLE IF NOT EXISTS` 改不动）;明确"additive-only"或给属主授权的 ALTER 路径。
- **`_index.json` 的 `version` 字段真正启用**：`_load_index` 读它、不匹配则升级/拒（现在只在空 init 写、从不校验,而它是最 load-bearing 的存储文档）。
- **对象存储键格式**（`{app_id}/{name}-{version}.json`、asset-pack `{slug}/{version}/manifest.json` + `metadataVersion`）视为冻结契约,改格式即版本化迁移、别孤立旧对象。

### 3.7 DSL 契约：semver **不够**,叠加 schema 兼容纪律
DSL 是「stored documents 必须持续可渲染」的 schema 问题,不是普通库 API。两层：
- **A. 引擎版本走 semver**：MAJOR=破坏 DSL 契约（旧 App 渲染坏）;MINOR=向后兼容新增（新控件/内置）;PATCH=修复。`JSON-DSL.md` 即 SemVer 要求的"公开 API"。
- **B. DSL schema 用 schema 兼容方案 + 文档内版本字段**：
  - **客户端加 `kSupportedDsl='3.3'`（+ min/max 窗口）常量**,`loadConfig` 顶部加**载入闸**：解析 `config['dsl']`,MAJOR 不匹配硬拒（"需升级客户端"）、MINOR-ahead 仅 warn——复用现成的 `lib/json_ui/semver.dart`。删掉 `json_app_builder.py` 那处孤儿 `dsl != '3.3'`。
  - **发布期强制**：Registry 校验/盖 `dsl` 在支持窗口内（之后不可变,给每个 stored 版本冻结契约目标）。
  - **additive + reserve 纪律**（借 protobuf/GraphQL）：新键可选、旧键永不复用语义、删掉的 widget 类型名 reserve 不重用、不改字段类型 → 旧 JSON 在新引擎仍渲染、新 JSON 在旧引擎优雅降级（引擎已忽略未知键）。
  - **链式迁移** `v1→v2→v3`(而非 N 个"任意旧→最新"),作升级/回滚网。
  - 可考虑 **SchemaVer `MODEL-REVISION-ADDITION`**（专为"历史文档须仍有效"设计:MODEL=对所有历史文档破坏;REVISION=对部分破坏;ADDITION=全兼容）——比 semver 更贴切,每次改都逼问"已发布的 JSON-App 还渲染吗"。
  - 修订 `JSON-DSL.md`（v3.4 vs 3.3 脱节）。
  - > [SchemaVer](https://docs.snowplow.io/docs/api-reference/iglu/common-architecture/schemaver/) · [protobuf dos-donts](https://protobuf.dev/programming-guides/dos-donts/) · [semver.org](https://semver.org/)

### 3.8 构建溯源 + CLI
- 后端加 **`GET /version`** 返回 `{version, build_commit, build_version, image_ref, dsl_supported}`（值已在 env,`agent_node_service.py:68` 已自报,只是 backend `app.py` 无端点）;启动日志打一行。
- `myapp-ctl --version` / `version` 打 `VERSION` + 构建 sha（`cli.py` trivial）。

### 3.9 git tag / release / CHANGELOG
- release checklist：bump `VERSION`(+`pubspec`) → 更新 `CHANGELOG.md` → `git tag vX.Y.Z` → 构建并 push **不可变 tag** 镜像（含 base + Python lock + 工具链）→ `ctl.json` images 钉到该 tag → `deploy`。
- 新增 `CHANGELOG.md`(Keep-a-Changelog)。
- 可选引入 GitHub Actions（当前无 `.github/workflows`）做自动 sha-tag/构建/lock 校验。

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
| **P1（先做）** | `VERSION=1.2.0` + 自建镜像**双 tag（不可变 `:{ver}-{sha}`）** + ctl.json/Dockerfile 两处 base 钉 + 后端 `/version` + git tag。直接消除"可变共享镜像、不可回滚"。 | 高/低 |
| **P2** | **Python lockfile（uv/pip-tools + hash）** 喂所有镜像 + base 镜像 digest 钉 + base 内 CLI/@latest 钉死 + Flutter 工具链 FVM 钉。复现性根因。 | 高/中 |
| **P3** | **FaaS helper ABI 版本 + 运行时镜像 digest 钉到 service + 冷唤醒兼容闸**;平台 `schema_migrations` 表 + tracked runner;`_index.json` 版本启用。 | 高/中 |
| **P4** | **DSL 载入期兼容闸**（客户端 `kSupportedDsl` + semver.dart 复用）+ 发布期强制 + additive/reserve 纪律入 `JSON-DSL.md` + 删孤儿判等;CLI `--version`;`CHANGELOG.md`;CI 自动化。 | 中/中 |

## 6. 开放问题
- 镜像不可变钉点：release 用 `:{VERSION}`、CI/dev 用 `:{VERSION}-{sha}`、生产叠 `@digest` —— 三层都要还是择一？
- `:agent-control-plane` 历史频道名是否改 `:edge`/`:main`（避免"分支名当频道名"误解）。
- Python 选 `uv`（更快、universal lock）还是 `pip-tools`（产出原生 requirements.txt，改动最小）？
- DSL 版本方案：纯 semver vs **SchemaVer**（MODEL-REVISION-ADDITION，更贴 stored-doc 兼容）？
- 是否引入 GitHub Actions 落地 P1-P4 的自动化（当前无 CI）。

## 7. 一句话总结
项目包侧 semver 已成熟,但**制品/工具链/运行时 ABI/持久化格式 63 个面几乎全无锁定**——`VERSION=1.2.0` 作真相源,把同样纪律延伸开：镜像不可变 tag/digest（可秒级回滚）、Python hash-lock、Flutter 工具链钉、**FaaS helper ABI 版本化 + 运行时镜像 digest 钉到 service**、schema 迁移版本表、DSL 载入期兼容闸 + additive/reserve 纪律。每个 bump 都是可 review 的 diff = 复现保证 + 回滚单元。分四期，P1 即解当前可变镜像 tag 风险。
