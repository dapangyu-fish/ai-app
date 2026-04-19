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
