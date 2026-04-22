# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Terminology — 需求类型约定

沟通时使用以下术语区分三类需求，避免混淆：

| 术语 | 含义 | 代码范围 |
|------|------|----------|
| **客户端需求** | 原生 Flutter 客户端，即 JSON-DSL 框架本身的需求（登录、悬浮球、UI 框架等） | `lib/main.dart`, `lib/auth/`, `lib/designer/`, `lib/json_ui/` |
| **后端需求** | Python Flask 服务的需求（鉴权代理、AI 对话、市场接口等） | `tools/ai_server.py` |
| **JSON-APP 需求** | 基于 JSON-DSL 框架开发的、通过 JSON 配置下发的应用 | `templates/*.json`, `JSON-DSL.md` |

## Project Overview

A Flutter **Server-Driven UI** low-code engine that renders UI and executes business logic from JSON configuration files (DSL v3.2). Users pick a JSON file at runtime; the app interprets it to build screens, handle interactions, and manage state — no recompilation needed. Targets iOS, Android, Web, macOS, Linux, and Windows.

## Framework Stability Principle

**框架应该是稳定可靠的。** 修改框架代码前必须遵守以下原则：

1. **JSON-DSL.md 是契约**：框架的行为由 `JSON-DSL.md` 定义。任何框架改动都必须同步更新 JSON-DSL.md，任何 JSON 编写都必须遵循 JSON-DSL.md 的规范。
2. **不因数据格式变化而改框架**：框架应能处理任意合法 JSON 数据（如 HTTP 响应的各种格式）。如果某种数据导致框架崩溃，说明框架设计有缺陷需要修复；如果只是用法不对，应修改 JSON 配置。
3. **明确区分表达式和数据**：
   - `{ "op": [...] }` 形式的 Map → jsonlogic 表达式，由引擎求值
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
python3 tools/ai_server.py   # 启动 Flask 后端（鉴权/AI对话/市场，端口 5566）
python3 tools/video_server.py --dir ~/Movies  # 启动本地视频流媒体服务器
```

## Architecture

### Data Flow

```
JSON file (picked by user or loaded from network)
  → JsonInterpreter.loadConfig()   parse config, init variables/functions
  → JsonInterpreter.executeSteps() run startup business logic (async, supports HTTP)
  → JsonInterpreter.buildWidget()  recursively build Flutter widget tree
```

### Value Resolution Pipeline

```
JSON args 中的值
  ├── 原始值 (string/number/bool/array)  → _resolveArgs 处理模板后直接使用
  ├── "{{ path }}" 模板                   → resolveExpression → 返回变量原始类型
  ├── "混合 {{ path }} 文本"              → resolveTemplate → 返回 String
  └── { "op": [...] } JsonLogic 表达式    → _evaluateExpression → jsonlogic 引擎求值
```

### Key Modules (`lib/`)

- **`main.dart`** — App entry point. Riverpod `ChangeNotifierProvider<JsonInterpreter>`, file-picker launch screen, JSON rendering page.

- **`json_ui/interpreter.dart`** — Core async engine. Manages:
  - Variables: `global.xxx` / `loop.item` / `params.xxx` (nested paths supported: `global.user.name`)
  - Template: `{{ global.xxx }}` → original type; `"text {{ x }}"` → String
  - Expression: jsonlogic standard package + 15 custom operators via `jl.add()`
  - 30+ built-in functions: HTTP, JSON, string, array, control flow, UI feedback
  - `@parallel` for concurrent execution
  - **`@set` value 规则**: 原始值是 Map → jsonlogic 求值; 其他 → 直接赋值

- **`json_ui/widget_builder.dart`** — Registry dispatcher. Registered types: `text`, `button`, `input`, `list`, `container`, `divider`, `image`, `image_picker`, `spacer`, `switch`, `video`.

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

## MinIO 对象存储操作

服务器上的 MinIO 用于存储模型文件、JSON-APP 等静态资源。

### 连接信息

- 服务器内网地址: `127.0.0.1:9000`（仅服务器本地访问）
- 公网地址: `https://app-oss-endpoint.dapangyu.work`
- Access Key: `m3wZkIA5EgmEwkctueZM`
- Secret Key: `m9M7M70F6SpsQxTZZ6roLklq33AUMV8mzAm1RJGk`
- Bucket 列表: `json-app`、`json-component`、`models`

### 上传文件到 MinIO

通过 SSH 登录服务器，使用 Python minio SDK 上传：

```bash
ssh root@app-backend.dapangyu.work

/opt/miniconda3/bin/python3 << 'EOF'
from minio import Minio

c = Minio('127.0.0.1:9000',
          access_key='m3wZkIA5EgmEwkctueZM',
          secret_key='m9M7M70F6SpsQxTZZ6roLklq33AUMV8mzAm1RJGk',
          secure=False)

# 上传单个文件
c.fput_object('models', 'sherpa-onnx/xxx/model.onnx', '/本地路径/model.onnx')

# 列出 bucket 内容
for obj in c.list_objects('models', recursive=True):
    print(f'{obj.object_name}  {obj.size/1048576:.1f}MB')
EOF
```

### 上传大文件（如 ASR 模型）的标准流程

1. 先将文件下载到服务器 `/mnt/storage00/`（服务器带宽大，比本地快）
2. 如果是压缩包，在服务器上解压（`tar xjf xxx.tar.bz2 --exclude='test_wavs'`）
3. SSH 到服务器，用 minio SDK 将解压后的**单个文件**逐个上传到对应 bucket 和路径
4. 客户端代码按单个文件从 `https://app-oss-endpoint.dapangyu.work/<bucket>/<path>` 下载

**注意**: 不要上传压缩包本身，客户端是按单个文件下载的。上传前先看客户端代码确认需要哪些文件和目录结构。

## 发布 JSON-APP / 组件到市场

### 发布方式

**推荐方式：通过 Registry API 发布**

所有包（官方包和用户包）统一通过 Registry 服务发布，支持命名空间管理和版本控制。

#### 1. 官方包发布（admin 专用）

官方包无命名空间（如 `common-ui`, `data-utils`），只有 admin 角色可以发布。

```bash
curl -X POST https://registry.dapangyu.work/publish \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <admin_token>" \
  -d @templates/lib_common_ui.json
```

#### 2. 用户包发布

用户包必须带命名空间（如 `mycompany/app-name` 或 `mycompany/frontend/ui-kit`）。

**首次发布前，创建命名空间**：
```bash
curl -X POST https://registry.dapangyu.work/namespace/create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <user_token>" \
  -d '{
    "namespace": "mycompany",
    "sub_namespace": "frontend"
  }'
```

**发布包**：
```bash
curl -X POST https://registry.dapangyu.work/publish \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <user_token>" \
  -d '{
    "json_content": {
      "dsl": "3.3",
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

- **域名**: https://registry.dapangyu.work
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
3. 脚本使用测试 token（`test-token`），具有 admin 权限
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

## Antigravity AI 上下文同步

AI 编程助手 Antigravity 的上下文数据存储在 `~/.gemini/antigravity/`，通过私有 Git 仓库在多台开发机之间同步。

**仓库地址**: `git@github.com:dapangyu-fish/antigravity.git`

### 推送上下文（当前电脑 → 远端）

在结束工作时**手动**执行：

```bash
cd ~/.gemini/antigravity
git add .
git commit -m "sync: $(date '+%Y-%m-%d %H:%M') from $(hostname)"
git push
```

### 拉取上下文（远端 → 当前电脑）

在另一台电脑开始工作前**手动**执行：

```bash
cd ~/.gemini/antigravity
git pull
```

### 首次在新电脑上设置

```bash
git clone git@github.com:dapangyu-fish/antigravity.git ~/.gemini/antigravity
```

> **注意**: `installation_id` 已被 `.gitignore` 忽略，每台机器会自动生成自己的 ID，无需同步。
