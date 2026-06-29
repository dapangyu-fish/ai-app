# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与 [语义化版本 SemVer](https://semver.org/)。
平台版本的单一真相源是仓库根的 `VERSION` 文件。版本管理方案见
[docs/planning/version-management.md](docs/planning/version-management.md)。

## [Unreleased]

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
