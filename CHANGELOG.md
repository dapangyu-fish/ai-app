# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与 [语义化版本 SemVer](https://semver.org/)。
平台版本的单一真相源是仓库根的 `VERSION` 文件。版本管理方案见
[docs/planning/version-management.md](docs/planning/version-management.md)。

## [Unreleased]

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
