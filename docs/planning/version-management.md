# RFC: 版本号管理（Version Management）

- **状态**: 草案 / 待评审
- **范围**: 跨域（`deploy/production/`、`scripts/myapp_ctl/`、`backend/`、`pubspec.yaml`、`JSON-DSL.md`）
- **作者**: Claude（基于 2026-06-29 对全仓版本面的调研）
- **缘起**: PgBouncer 落地把后端镜像 push 到了共享可变 tag `:agent-control-plane`（见 [pgbouncer-jsonapp-postgres.md](pgbouncer-jsonapp-postgres.md) §9 遗留 #3）。本质是**项目缺乏严格的版本号管理**——本 RFC 给出统一方案。

---

## 1. 现状盘点（调研结论）

项目呈「**半边成熟、半边裸奔**」：

### ✅ 已成熟：Registry 包（JSON-App / 组件）
- **严格 semver** `x.y.z`：`registry_server.py:344` `_validate_version` 正则 `^\d+\.\d+\.\d+$`，发布时校验（:924）。
- **发布即不可变**：同名同版本拒绝覆盖（:981-997），且**强制单调递增**（:1003 `_parse_ver(version) <= latest` → 409）。
- **范围解析** `^`/`~`/`>=`/`*`：服务端 `registry_server.py:350-413` + `/resolve`（:482），客户端 `lib/json_ui/semver.dart:54-104` + `lib/json_ui/cache_manager.dart`（`name@version` 缓存 SWR）。
- **复合身份**：`namespace/name` + `version` + UUID `appid`（rename 安全）；对象键 `{appid}/{name}-{version}.json`（`store.py:252/281`）。

**结论：包侧无需改，它就是要推广到全局的模型。**

### ❌ 裸奔：可部署制品 + 平台本身
| 面 | 现状 | 证据 |
|---|---|---|
| **Docker 镜像** | 所有自建服务 + base 共用**一个可变 tag** `:agent-control-plane`，每次 push 覆盖，无 digest 钉、无回滚 | `core.py:690/697`、`ctl.json` `images` map、compose `${MYAPP_*_IMAGE:-...:agent-control-plane}` |
| **构建溯源** | `MYAPP_BUILD_COMMIT/VERSION` = git HEAD sha，烤进镜像，但**无 /version 端点、不打日志** | `core.py:666-684/782-810`；`agent_node_service.py:68-77` 读但不暴露 |
| **平台版本** | **无单一真相源**：无 `VERSION` 文件、无 git tag、无 release、无 CHANGELOG | `git tag` 为空；仅 `pubspec.yaml:19` `1.2.0+1`（仅前端） |
| **DSL 版本** | `dsl:"3.3"` 只校验**存在**、不校验兼容/范围，无正式 bump 流程；文档已 v3.4 与运行时线 3.3 脱节 | `validate_json_app.py:437`；`JSON-DSL.md:1-9` |
| **后端 API** | 无 `/api/v1` 前缀、无兼容/弃用约定 | `backend/app.py` 全 `/api/...` |
| **CLI** | `myapp-ctl` 无 `--version` | `scripts/myapp_ctl/cli.py` |
| **客户端** | `pubspec 1.2.0+1` 手动 bump、**App 内不显示**、无 CI | `pubspec.yaml:19` |

---

## 2. 目标与原则

1. **单一真相源**：平台版本一处定义，制品/后端/客户端/CLI 都引用它。
2. **制品不可变 + 可回滚**：每次构建产出**内容寻址、永不覆盖**的镜像引用；部署钉不可变引用；回滚=重指旧引用。
3. **可溯源**：任何运行实例都能自报「我是哪个版本 / 哪个 commit / 哪个 digest」。
4. **复用既有模型与钩子**：semver（同包侧）；`ctl.json` `images` map + `MYAPP_*_IMAGE` env + `MYAPP_BUILD_VERSION` + `.myapp-build-version` marker 已经是现成接入点，**不重造**。
5. **务实分级**：先解决「制品不可变 + 溯源」（高价值低成本），DSL/API/CI 后置。

---

## 3. 设计

### 3.1 平台版本：单一真相源
- 仓库根新增 **`VERSION`** 文件（纯 semver，如 `1.0.0`），platform 版本的唯一真相源。
- bump 规则：**MAJOR**=破坏性（API/DSL major/数据迁移）；**MINOR**=向后兼容新特性；**PATCH**=修复。
- 镜像构建、后端 `/version`、CLI `--version`、（可选）client `pubspec` 都从它派生；release 时打 git tag `vX.Y.Z` 与之对齐。
- 起始号待定（建议 `1.0.0` 作为"首个正式版本化 release"，client 沿用其 `1.2.0` 线另议——见 §5 开放问题）。

### 3.2 Docker 镜像：不可变 tag + digest 钉（**核心**）
构建时给每个镜像打**两类 tag** 并都 push：
- **不可变发布 tag**：`dapangyu/myapp-{svc}:{VERSION}`（如 `:1.0.0`）——**永不覆盖**（push 前校验已存在则拒绝/换号）。
- **不可变构建 tag**：`dapangyu/myapp-{svc}:{VERSION}-{shortsha}`（每次构建唯一，便于精确溯源）。
- **可变频道 tag**（保留便利）：`:agent-control-plane` 降级为**纯 dev/edge 频道**（"这条线最新"），**生产/测试部署不得直接钉它**。

**部署钉法**：`ctl.json` 的 `images` map（或 `MYAPP_*_IMAGE` env）从可变 tag 改为**不可变 tag 或 `@sha256:digest`**。
- `myapp-ctl deploy --pull` 拉钉死的引用 → 不同时间拉到的镜像一定一致。
- **回滚** = 把 `images` map 重指上一个不可变 tag/digest，`deploy` 即回退（镜像层多已缓存，秒级）。

> 落地钩子已就绪：`_deploy_images`（`core.py`）已用 `MYAPP_BUILD_VERSION` 构建，只需扩成「构建后额外 `docker tag` + `docker push` 不可变 tag」；`images` map 已是部署钉点。本 RFC 不要求一次到位——可先手动按本节钉（如本次 pgbouncer 镜像即已用 `@sha256:f6d6419…` digest 钉法，见 pgbouncer RFC §9）。

### 3.3 构建溯源：运行时自报版本
- 后端加 **`GET /version`**（或扩 `/healthz`）返回 `{version, build_commit, build_version, image_ref}`；`MYAPP_BUILD_COMMIT/VERSION` 已在 env（`agent_node_service.py:68`），暴露即可。
- 启动日志打一行 `myapp backend vX.Y.Z (commit abc123)`。
- `myapp-ctl --version` / `myapp-ctl version` 打 `VERSION` + 构建 sha（`cli.py` 加，trivial）。

### 3.4 DSL 版本策略
- 明确 `dsl` 为**兼容线**（`MAJOR.MINOR`）：**MINOR**=向后兼容新增（新控件/内置函数，旧 App 不受影响）；**MAJOR**=破坏性（旧 App 需迁移）。
- 框架记录**支持的最高 dsl 版本**；加载时：App 声明 `dsl` 的 **MAJOR > 支持** → 明确报错/降级提示（当前是静默放行）；MINOR 高于支持 → warn 但尝试运行。
- 同步修订 `JSON-DSL.md`（文档 v3.4 vs 运行时 3.3 的脱节），并在框架改动时按 [[CLAUDE.md 框架稳定性原则]] 同步 bump `dsl`。

### 3.5 Git tag / release 流程
- release = 一张轻量 checklist：bump `VERSION`（+ 视情况 `pubspec`）→ 更新 `CHANGELOG.md` → `git tag vX.Y.Z` → 构建并 push **不可变 tag** 镜像 → `ctl.json` images 钉到该 tag → `deploy`。
- 新增 `CHANGELOG.md`（Keep-a-Changelog 风格）。

### 3.6 API 与客户端
- **API**：内部同发布列车消费（client↔backend 同版本），`/api/v1` 前缀属低价值 churn。**决策：保持无前缀，但落一份兼容约定**——同 MAJOR 内只做加法；破坏性变更 bump 平台 MAJOR + 协调 client release；可选加 `X-MyApp-Version` 响应头便于排障。
- **客户端**：`pubspec` 版本随 release bump；设置/关于页显示版本（小 UI 补丁）；build number 由 CI 设。

---

## 4. 分期

| 期 | 内容 | 价值/成本 |
|---|---|---|
| **P1（先做，解 #3）** | `VERSION` 文件 + 镜像不可变 tag/digest（构建双 tag、部署钉不可变）+ 后端 `/version` + git tag `vX.Y.Z` | 高/低——直接消除"可变共享 tag、不可回滚"风险 |
| **P2** | DSL 版本兼容校验 + `CHANGELOG.md` + `myapp-ctl --version` + client 版本显示 | 中/中 |
| **P3** | API 兼容约定文档 + CI 自动 bump/打 tag/构建推送 + base 镜像同样不可变化 | 中/中 |

## 5. 开放问题
- 平台版本起始号：`1.0.0`（全新计数）还是承接 `pubspec 1.2.0`？client 与 platform 版本是否锁步、还是各自独立线？
- 镜像不可变 tag 用 `:{VERSION}`（人读）还是直接 `@digest`（最强）作为部署钉点？建议 release 用 `:{VERSION}`、CI/dev 用 `:{VERSION}-{sha}`，生产可叠加 digest 锁。
- `:agent-control-plane` 这个历史频道名是否改成更中性的 `:edge`/`:main`（避免"分支名当频道名"的误解）。
- 是否引入 CI（GitHub Actions）做自动化——当前仓库无 `.github/workflows`。

## 6. 一句话总结
包侧（Registry）的 semver+不可变+范围解析模型已成熟；本 RFC 把同样的纪律延伸到**镜像与平台**：`VERSION` 单一真相源 + 镜像**不可变 tag/digest**（部署钉死、可秒级回滚）+ 运行时 `/version` 自报 + DSL/CLI/客户端/release 流程补齐，分三期落地，P1 即可消除当前"可变共享镜像 tag"的风险。
