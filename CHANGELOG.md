# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与 [语义化版本 SemVer](https://semver.org/)。
平台版本的单一真相源是仓库根的 `VERSION` 文件。版本管理方案见
[docs/planning/version-management.md](docs/planning/version-management.md)。

## [Unreleased]

## [1.2.8] - 2026-06-30
### Changed
- **demo 选择列表改为服务端下发**：把客户端写死的 demo 目录搬到后端做单一真相源
  （`demo_replay.DEMO_PROMPTS` + `GET /api/ai/demo/list`），客户端 `_demoPrompts` 改为
  `AiChatService.fetchDemoList()` 拉取 + 缓存 + 极小兜底（FutureBuilder 渲染）。以后加一个 demo
  只改后端（`DEMO_PROMPTS` + `DEMO_SESSIONS` + 录制文件），**不用客户端发版**。客户端从硬编码改
  拉取是一次性改动，需重建客户端一次。

## [1.2.7] - 2026-06-30
### Changed
- **论坛 demo 录制改为全量合并**：`community_forum_0023`（…0023）录制从 15 事件精简子集改为
  **30 事件全量完整叙事**（保留全部思考/叙述，忠于真实生成过程），全局 status 去重剔除 429
  限流造成的 `ai_engine_started` 刷屏（4687→1）+ 重复 retry 状态。把 v1.2.6 里录制好的 30 事件版
  正式烘焙进镜像（此前是热加载进运行容器）。

## [1.2.6] - 2026-06-30
### Added
- **「广场社区」全栈论坛 demo**（免登录回放 UUID `…0023` → base `community_forum_0023`）：把一次
  真实成功的论坛 FaaS 生成（session e9535d98，验证了 invoke 鉴权修复）做成录制回放 + 单独部署
  公开 FaaS 服务组 `demo-forum`（demo 账号持有、`access_policy=public`、15 路由 + Postgres）。
  未登录用户回放后可真创建板块/发帖/楼中楼/加好友私信；app.json `global.svc` 收口到 `demo-forum`。
  `forum_0001` 占位保留不动。

## [1.2.5] - 2026-06-30
### Fixed
- **FaaS 自测死循环**：agent 生成后端后用 `faas_invoke.sh` 自测，但它 auth-free、`invoke_service`
  只认 `Authorization:Bearer`，函数里 `myapp_auth.current_user()` 恒为匿名 → 凡「写需登录」的
  后端（论坛 `POST /zones` 等）匿名调用 401，而 playbook 要求验证写操作 → agent 拿到解不开的 401
  死循环。修：`invoke_service` 无 Bearer 时用 agent-node 已转发的 run token（HMAC 不可伪造）的
  owner 当调用者 → 写路由可自证（real client 走 JWT、Bearer 优先，不受影响）；`X-MyApp-Faas-Anon`
  可显式走匿名自证拒绝；`faas_invoke.sh` 加 `FAAS_INVOKE_ANON`；playbook 讲清自测身份。
- **FaaS run token 过期**：默认 TTL 1h 且不续签，长 run（常破 1h）中途 deploy/invoke 失效。改 6h。
- **config-center `/admin` 500**：一行 `ai_generation_pipeline` 配置的 `updated_at` 被外部工具
  写成 ISO 字符串（违反 INTEGER schema），`ts_local` 调 `time.localtime(str)` 崩。`ts_local` 改为
  容错任意时间戳（int/数字串/ISO/None/越界都不抛）。线上坏数据已就地归一化，本版本部署防复发。

### Changed（客户端，需重新构建客户端生效，不随后端部署）
- 客户端落地页「版本号+commit」标签全端生效（iOS/Android/桌面，不只 Web）；版本号单一真相源
  收敛到 `pubspec.yaml`，修正陈旧常量 `1.1.0+18`→`1.2.0+1`。
- 悬浮球字幕打字机改为「自适应正文到达速度」，消除「冲一段→停一阵」突兵感；速度有界（~23–1250 字/秒）。

## [1.2.4] - 2026-06-30
### Fixed
- **P2 CLI 钉真正生效**：发现 base 镜像常规 rebuild 命中 Docker 层缓存，导致钉死的
  `claude-code@2.1.195`/`opencode-ai@1.17.11` 被装回旧版（2.1.175/1.17.4）。改用
  `--no-cache` 重建 backend-base + agent-runtime-base（确认装上 2.1.195/1.17.11），
  `images-base.yml` 加 `no-cache: true` 防复发；app 镜像 FROM 修正后的 base 重建。

## [1.2.3] - 2026-06-30
### Changed
- **§11 综合评估修复**：DSL 版本收敛到 `backend/dsl_contract.py` 单一真相源（消除多处 `'3.3'` 硬编码）；
  registry `/health` 增 `platform_version`/`build_commit` 溯源；`migrate.py` 加自动基线（存量主机首跑安全）
  + checksum 漂移校验；deploy 自动迁移改阻断（失败中止）；本地 `--build` 注入 `MYAPP_VERSION`；
  `install_ctl.sh` 把存量 `:agent-control-plane` 镜像 pin 平移到 `:edge`。
- **P2 base 镜像重建**：4 个 base 用 uv-lock/`--require-hashes`/CLI 钉/digest 钉重建并推送，P2 复现性由 dormant 转为生效。
- **FaaS**：部署记录运行时 `image@sha256`（溯源）；冷唤醒策略定为 X-G3（用最新运行时镜像）。

## [1.2.2] - 2026-06-30
### Added
- `myapp-ctl deploy` 部署后自动应用平台 schema 迁移（`backend/migrate.py`，非阻断）——
  新迁移随部署生效（`_run_platform_migrations`）。

## [1.2.1] - 2026-06-30
### Added
- **P2 复现性**：Python 依赖全 uv-lock（`backend/requirements.lock` + faas-runtime/agent-node base 各一份，`pip --require-hashes`）；CLI 钉 `claude-code@2.1.195`/`opencode-ai@1.17.11`；base 镜像 FROM digest 钉；Flutter `.fvmrc`=3.41.8。
- **P4 DSL 契约**：客户端 `loadConfig` DSL 载入闸（`kSupportedDsl`）；后端 `json_app_builder`/`validate_json_app` 发布期 dsl 窗口 gate；`JSON-DSL.md` 版本纪律。
- **P3**：`registry _index.json` schema 版本闸；`backend/migrate.py` 平台 schema 迁移 runner（自举 `schema_migrations`）。

## [1.2.0] - 2026-06-29
### Added
- **版本管理 P1**：引入 `VERSION` 单一真相源（`1.2.0`）。
- 镜像不可变 tag 方案：CI 产出 `:{版本}-{sha}` + `:{版本}`，移动频道 `:edge` 取代 `:agent-control-plane`。
- 后端 `GET /version` 端点：自报 `version` / `build_commit` / `build_version` / `dsl_supported`。
- `myapp-ctl --version`（读 `VERSION`）。
- `myapp-ctl deploy --image-version <tag>`：把 app 镜像钉到不可变 tag（写 ctl.json + backend/faas env），升级/回滚一条命令。
- GitHub Actions：`images-app.yml` + `images-base.yml`（`v*` tag + 手动 dispatch 触发，build & push 到 Docker Hub）。

### Changed
- `ctl.json` / compose / `Dockerfile.*` / `core.py` 的镜像默认从 `:agent-control-plane` 改为 `:edge`。

### 此前（未版本化）
- PgBouncer 双实例接入 jsonapp-postgres（faas/platform）+ 1 万 DAU 调优（psycogreen 等）。详见 git 历史与 `docs/planning/pgbouncer-jsonapp-postgres.md`。
