# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Terminology — 需求类型约定

沟通时使用以下术语区分三类需求，避免混淆：

| 术语 | 含义 | 代码范围 |
|------|------|----------|
| **客户端需求** | 原生 Flutter 客户端，即 JSON-DSL 框架本身的需求（登录、悬浮球、UI 框架等） | `lib/main.dart`, `lib/auth/`, `lib/designer/`, `lib/json_ui/` |
| **后端需求** | Python Flask 服务、AI 队列、agent-node、Registry、部署控制面等需求 | `backend/`, `deploy/production/`, `scripts/myapp_ctl/` |
| **JSON-APP 需求** | 基于 JSON-DSL 框架开发的、通过 JSON 配置下发的应用 | `templates/*.json`, `JSON-DSL.md` |

## Project Overview

A Flutter **Server-Driven UI** platform that renders UI and executes business logic from JSON configuration files (DSL v3.3). Users can run published JSON Apps, load local JSON for debugging, or ask AI to generate JSON Apps that run inside the precompiled client capability boundary. The backend stack provides auth, IM, Registry, object storage, AI generation, resumable SSE, and isolated agent-node execution. Targets iOS, Android, Web, macOS, Linux, and Windows.

## Framework Stability Principle

**框架应该是稳定可靠的。** 修改框架代码前必须遵守以下原则：

1. **JSON-DSL.md 是契约**：框架的行为由 `JSON-DSL.md` 定义。任何框架改动都必须同步更新 JSON-DSL.md，任何 JSON 编写都必须遵循 JSON-DSL.md 的规范。
2. **不因数据格式变化而改框架**：框架应能处理任意合法 JSON 数据（如 HTTP 响应的各种格式）。如果某种数据导致框架崩溃，说明框架设计有缺陷需要修复；如果只是用法不对，应修改 JSON 配置。
3. **明确区分表达式和数据**：
   - `{ "if": [...] }`、`{ "+": [...] }` 等标准单 key Map → jsonlogic 表达式，由引擎求值
   - `"{{ path }}"` 模板 → 解析为变量原始类型
   - 其他值（字符串/数字/布尔/数组）→ 直接使用，不做二次求值
   - 运行时数据（如 HTTP 响应体）→ 永远不会被当作 jsonlogic 表达式执行
4. **新功能优先通过 JSON 配置实现**：只有现有原子控件和内置函数无法满足时，才新增框架代码。

## Build & Development Commands

```bash
flutter pub get              # Install dependencies
flutter run                  # Run on default device
flutter run -d macos         # Run on macOS
flutter run -d chrome        # Run on web
flutter analyze              # Lint (uses flutter_lints via analysis_options.yaml)
flutter test                 # Run all tests
flutter test test/widget_test.dart   # Run a single test file
python3 backend/validate_json_app.py templates/<app>.json
python3 -m py_compile backend/app.py backend/claude_chat.py backend/ai_session.py
./deploy/production/install_ctl.sh
myapp-ctl setup --host <public-host> --data-root /mnt/myapp
myapp-ctl deploy --build
```

## Architecture

### Data Flow

```
JSON file (picked by user or loaded from network)
  → JsonInterpreter.loadConfig()   parse config, init variables/functions
  → JsonInterpreter.executeSteps() run startup business logic (async, supports HTTP)
  → JsonScreenView + JsonWidgetBuilder recursively build Flutter widget tree
```

### Value Resolution Pipeline

```
JSON args 中的值
  ├── 原始值 (string/number/bool/array)  → _resolveArgs 处理模板后直接使用
  ├── "{{ path }}" 模板                   → resolveExpression → 返回变量原始类型
  ├── "混合 {{ path }} 文本"              → resolveTemplate → 返回 String
  └── { "+": [...] } 等标准单 key JsonLogic 表达式 → _evaluateExpression → jsonlogic 引擎求值
```

### Key Modules (`lib/`)

- **`main.dart`** — App entry point. Riverpod `ChangeNotifierProvider<JsonInterpreter>`, auth/startup gates, market/my-apps entry, `JsonScreenView` rendering page.

- **`json_ui/interpreter.dart`** — Core async engine. Manages:
  - Variables: `global.xxx` / `loop.item` / `params.xxx` (nested paths supported: `global.user.name`)
  - Template: `{{ global.xxx }}` → original type; `"text {{ x }}"` → String
  - Expression: jsonlogic standard package + 28 custom operators via `jl.add()` (string/array/type/math; see `_knownJsonLogicOps`)
  - 100+ built-in functions (`@`-prefixed): HTTP, DB, IM, file, clipboard, game, JSON, string, array, control flow, UI feedback
  - `@parallel` for concurrent execution
  - **`@set` value 规则**: 原始值是 Map → jsonlogic 求值; 其他 → 直接赋值

- **`json_ui/builtins/launcher_bridges.dart`** — Launcher 内置函数桥接（`@my_apps_list` / `@launch_app` / `@market_list` / `@set_framework_locale` 等）。interpreter 的 `_handleCall` 默认分支 fall-through 到这里。

- **`json_ui/security/token_authorizer.dart`** — 框架层敏感能力授权器：`@get_auth_token` / `@get_user_info` 等按 appId 弹窗授权、fail-closed。

- **`json_ui/widget_builder.dart`** — Widget dispatcher. Registered types include core UI (`text`, `button`, `input`, `list`, `container`, `image`, `video`), forms/layout (`checkbox`, `dropdown`, `radio`, `grid`, `stack`, `tab_view`), platform/media (`webview`, `qr_code`, `chart`, `map`, `camera`), game/animation (`flame_game`, `analog_stick`, Rive/animated primitives), and launcher/overlay primitives.

- **`json_ui/widgets/`** — All extend `JsonBaseWidget`:
  - `button_widget.dart` — 3 variants (filled/outlined/text), icon support. **Important**: pre-resolves `{{ }}` in `action` args at build time (loop context is popped before `onPressed`)
  - `image_widget.dart` — Network URL / local file / base64 / GIF auto-detection
  - `image_picker_widget.dart` — Cross-platform image picker (gallery/camera)
  - `video_widget.dart` — StatefulWidget wrapping video_player + chewie. Uses `AspectRatio` for fixed size in ScrollView
  - `list_widget.dart` — `ListView.builder` with loop context (`loop.item`, `loop.index`, supports nested: `loop.item.name`)
  - `icon_registry.dart` — 100+ Material icon name→IconData mapping

### State Management

Riverpod `ChangeNotifierProvider<JsonInterpreter>`. The interpreter calls `notifyListeners()` on variable changes and navigation.

### DSL Specification

`JSON-DSL.md` is the single source of truth for the DSL contract. All JSON files must follow it, all framework changes must update it.

## Adding a New Widget Type

1. Create `lib/json_ui/widgets/<name>_widget.dart` extending `JsonBaseWidget`
2. Register it in `JsonWidgetBuilder._builders` map in `widget_builder.dart`
3. The interpreter's `buildWidget` → `applyPosition` pipeline handles positioning automatically
4. Update `JSON-DSL.md` widget type table

## Object Storage

MyApp uses object storage for JSON Apps, components, generated temporary JSON,
media, APK releases, model files, and asset packs. The self-hosted stack starts
App MinIO; production deployments may front it with an OSS/domain layer.

Rules:

1. Do not commit bucket credentials, signed URLs, or host-local env files.
2. Read credentials only on the deployment host through `myapp-ctl secret`.
3. JSON Apps should reference asset manifest URLs or public object URLs, never
   host-local filesystem paths.
4. Large model/media uploads should store individual runtime files, not
   compressed archives that clients cannot consume directly.

Host-local inspection:

```bash
myapp-ctl secret get backend APP_MINIO_ACCESS_KEY --show
myapp-ctl secret get backend APP_MINIO_SECRET_KEY --show
myapp-ctl status app-minio
myapp-ctl log app-minio -n 120
```

Generic upload pattern from a deployment host:

```bash
set -a && source /etc/myapp/secrets.d/backend.env && set +a
python3 <<'PY'
from minio import Minio
import os

# backend.env 提供 APP_MINIO_ACCESS_KEY / APP_MINIO_SECRET_KEY / APP_MINIO_PUBLIC_URL / APP_MINIO_PORT
# （没有 ENDPOINT/SECURE 变量）。从部署主机的容器网络内访问 MinIO 用 app-minio:9000（明文）。
client = Minio(
    "app-minio:9000",
    access_key=os.environ["APP_MINIO_ACCESS_KEY"],
    secret_key=os.environ["APP_MINIO_SECRET_KEY"],
    secure=False,
)

# backend 自动创建/使用的桶：json-app / json-component / ai-chat-temp / im-media / app / demo。
# models / APK / asset-pack 等桶属部署主机侧手动上传，backend 不自动创建。
client.fput_object("models", "path/in/bucket/file.onnx", "/local/path/file.onnx")
PY
```

## FaaS 服务组权限模型（Service Group）

每个 **服务组 (Service Group) = 1 个 FaaS 服务 + 可选 1 个数据库**，1:1 锁死绑定；服务一建出来
就是它自己的组（**没有 per-owner 默认组**），简单工具型服务可以没有 DB。角色：**Owner**（唯一
所有者，改代码/改 schema/设策略/删服务组）、**Consumer**（框架已登录用户，经服务以**不可伪造的
组内假名**读写**自己的**数据）；`Maintainer`（可发版/扩缩容）作为休眠能力保留，默认不在产品里暴露。
**JSON-App 前端解耦**：它只是按需调用方（M:N，受访问策略放行），不属于任何服务组。核心代码：
`backend/faas.py`、`faas_store.py`、`faas_userdb.py`、`faas_data.py`，运行时内置 helper
`faas_runtime_auth.py`(=`myapp_auth`)、`faas_runtime_data.py`(=`myapp_data`)。

约定与不变量：
- **schema 续写只能经 deploy 迁移**：运行时 DB 角色**非属主**（仅 DML），DDL 只在部署期由属主
  角色执行；`schema.sql` **禁止 SERIAL/BIGSERIAL**（用 `uuid ... DEFAULT gen_random_uuid()`）。
- **消费者身份**：invoke 后端验 JWT → 注入**组作用域签名假名**（`HMAC(密钥, app_id‖uid)`；新服务组
  `app_id=service_id` 即每组独立假名，历史默认组沿用 owner 域假名保持稳定），函数用
  `myapp_auth.current_user()` 读；客户端伪造的 `x-myapp-*` 头被前缀剥离；原始 token/anon-key **不进函数**。
- **消费者数据隔离**：多租户表必须带 `owner text` 列，函数用 `myapp_data`（后端中介，平台强制
  `owner=caller`，函数**不持 DSN**）；裸 `myapp_db` 仅限 Owner 自有/非消费者数据。
- **DB 隔离**：**每个服务组一个 schema**（`_db_tenant_key`：新服务组=service_id 各自独立库；历史默认组
  `appd-<owner>` 仍复用 owner 旧库 → 零迁移、零数据丢失）；口令随机 + Fernet 加密存储
  （`FAAS_USER_DB_ENC_KEY`，回落 `AGENT_NODE_TOKEN`）；容器加固（cap_drop ALL + no-new-privileges + pids/mem 限）。
- **访问策略（组级，3 档）**：`access_policy` ∈ {owner-only(默认)/allowlist/public}（已去掉
  install-required，等价收敛为 allowlist），invoke 每次查 live grant（`faas_app_consumer_grants`，
  服务端校验）。**默认门禁关** `FAAS_ENFORCE_ACCESS_POLICY=0`（避免破坏现有开放调用，按部署开启）。
- **可信部署**：所有特权变更入 `faas_audit_log`；后端可签发 run 作用域令牌
  （`FAAS_RUN_TOKEN_SECRET`，agent-node 转发 `X-MyApp-Faas-Run-Token`），开
  `FAAS_REQUIRE_RUN_TOKEN=1` 后裸 `AGENT_NODE_TOKEN` 不能再冒充任意 owner（默认关）。
- **客户端**：设置页「我的服务组 (FaaS + 数据库)」(`lib/designer/faas_apps_page.dart`) 经
  `/api/faas/apps*`（路径 id 即服务组 id）owner-scoped 管理：看库用量、改 3 档策略、管白名单、按组单独删。
  AI 生成 FaaS 必读 `docs/playbooks/faas-jsonapp.md`（已含 UUID/`myapp_auth`/`myapp_data`）。
  设计/落地目标见 `~/faas-app-permission-*.md`，网络锁定运维手册见 `~/faas-b2g2-network-runbook.md`。

## 发布 JSON-APP / 组件到市场

### 发布方式

**推荐方式：通过 Registry API 发布**

所有包（官方包和用户包）统一通过 Registry 服务发布，支持命名空间管理和版本控制。

#### 1. 官方包发布（admin 专用）

官方包无命名空间（如 `common-ui`, `data-utils`），只有 admin 角色可以发布。
推荐使用内置的 Python 发布工具，支持批量发布。**需先提供 admin token**：设环境变量
`REGISTRY_ADMIN_TOKEN`（建议放 `backend/.env`），或用 `--token` 覆盖；不提供会直接报错退出
（脚本已不再内置任何测试 token）：

```bash
export REGISTRY_ADMIN_TOKEN=<admin_token>

# 发布指定文件
python3 backend/publish_script.py lib_user.json demo_user_profile.json

# 批量发布 templates 目录下的所有组件
python3 backend/publish_script.py

# 或显式指定 token（覆盖环境变量）
python3 backend/publish_script.py lib_user.json --token <admin_token>
```

#### 2. 用户包发布

用户包必须带命名空间（如 `mycompany/app-name` 或 `mycompany/frontend/ui-kit`）。

**首次发布前，创建命名空间**：
```bash
curl -X POST https://myapp-registry.dapangyu.work/namespace/create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <user_token>" \
  -d '{
    "namespace": "mycompany",
    "sub_namespace": "frontend"
  }'
```

**发布包**：
```bash
curl -X POST https://myapp-registry.dapangyu.work/publish \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <user_token>" \
  -d '{
    "namespace": "mycompany/frontend",
    "name": "ui-kit",
    "appid": "08ad186c-0000-4000-8000-000000000000",
    "version": "1.0.0",
    "description": "Reusable UI kit",
    "type": "library",
    "json_content": {
      "dsl": "3.3",
      "appid": "08ad186c-0000-4000-8000-000000000000",
      "meta": {
        "name": "mycompany/frontend/ui-kit",
        "version": "1.0.0",
        "type": "library"
      },
      "global": { ... }
    }
  }'
```

### 命名空间规则

| 类型 | 格式 | 示例 | 权限 |
|------|------|------|------|
| 官方包 | 无 `/` | `common-ui`, `data-utils` | admin 专属 |
| 用户包（一级） | `namespace/app` | `mycompany/app-name` | 命名空间所有者 |
| 用户包（二级） | `namespace/sub/app` | `mycompany/frontend/ui-kit` | 命名空间所有者 |

### 依赖声明（简化格式）

发布后，其他应用可以通过简化格式引用：

```json
{
  "dependencies": {
    "common-ui": "^1.0.0",
    "mycompany/frontend/ui-kit": "~1.0.0"
  }
}
```

框架会自动通过 Registry 解析依赖 URL，无需手动填写完整的 MinIO 路径。

### Registry 服务信息

- **域名**: https://myapp-registry.dapangyu.work
- **端口**: 3254
- **文档**: `backend/REGISTRY_README.md`
- **健康检查**: `GET /health`

### 批量发布测试组件

使用 `backend/migrate_templates.py` 脚本可以批量发布 `templates/` 目录下的所有模板文件到 Registry：

```bash
# 在项目根目录执行
python3 backend/migrate_templates.py
```

**注意事项**：
1. 包名必须符合规范：小写字母、数字、`-` 和 `_`，不能包含中文或特殊字符
2. 每个 JSON 文件必须包含 `meta` 字段，包含 `name`、`version`、`type` 等信息
3. 脚本从环境变量 `REGISTRY_ADMIN_TOKEN`（建议放 `backend/.env`）读取 admin token，未设置会直接报错退出（已不再内置 test-token）
4. 已存在的版本会被跳过，不会覆盖

**脚本输出示例**：
```
处理: calculator.json
  名称: calculator
  版本: 1.0.0
  类型: app
  ✅ 发布成功

处理: lib_common_ui.json
  名称: common-ui
  版本: 1.0.0
  类型: library
  ⚠️  版本已存在: ['1.0.0']
```
