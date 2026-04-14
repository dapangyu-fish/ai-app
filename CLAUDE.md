# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Flutter **Server-Driven UI** low-code engine that renders UI and executes business logic from JSON configuration files (DSL v3.2). Users pick a JSON file at runtime; the app interprets it to build screens, handle interactions, and manage state — no recompilation needed. Targets iOS, Android, Web, macOS, Linux, and Windows.

## Build & Development Commands

```bash
flutter pub get              # Install dependencies
flutter run                  # Run on default device
flutter run -d macos         # Run on macOS
flutter run -d chrome        # Run on web
flutter analyze              # Lint (uses flutter_lints via analysis_options.yaml)
flutter test                 # Run all tests
flutter test test/widget_test.dart   # Run a single test file
```

## Architecture

### Data Flow

```
JSON file (picked by user or loaded from network)
  → JsonInterpreter.loadConfig()   parse config, init variables/functions
  → JsonInterpreter.executeSteps() run startup business logic
  → JsonInterpreter.buildWidget()  recursively build Flutter widget tree
```

### Key Modules (`lib/`)

- **`main.dart`** — App entry point. Defines `interpreterProvider` (Riverpod `ChangeNotifierProvider<JsonInterpreter>`), the file-picker launch screen (`FilePickerPage`), and the rendering page (`JsonScreenView`) that watches the interpreter and rebuilds on state changes.

- **`json_ui/interpreter.dart`** — Core engine (`JsonInterpreter extends ChangeNotifier`). Manages:
  - Global variables (`$.global.*`), loop context (`$.loop.item/index`), function params (`$.params.*`)
  - Template resolution (`{{ $.global.xxx }}`)
  - JsonLogic expression evaluation (`cat`, `filter`, `var`, `==`, `!=`)
  - Built-in functions: `@print`, `@set`, `@if`, `@while`, `@for_each`
  - Custom function execution (defined in `global.functions`, invoked via `@global.<name>`)
  - TextField controller caching (keyed by bind path)
  - Screen navigation (`navigateTo` + `notifyListeners`)

- **`json_ui/widget_builder.dart`** — Registry-based dispatcher. Maps JSON `type` string to a widget builder instance. Currently registered: `text`, `button`, `input`, `list`, `container`.

- **`json_ui/widgets/`** — Individual widget implementations, all extend `JsonBaseWidget`:
  - `text_widget.dart` — Renders `Text` with template-resolved `value` and optional `style`
  - `button_widget.dart` — `ElevatedButton`. **Important**: pre-resolves `{{ }}` templates in `action` args at build time because the loop context stack is popped before `onPressed` fires
  - `input_widget.dart` — `TextField` with two-way binding via `bind` path
  - `list_widget.dart` — `ListView.builder` driven by `source` data; uses `buildWidgetInLoopContext` to push/pop loop context for each item; auto-wraps in `Expanded`
  - `container_widget.dart` — Recursive container with `children`, `color`, `padding`
  - `position_handler.dart` — Wraps widgets in `Positioned` (absolute), `Expanded` (flex), or pass-through (relative) based on `position.type`
  - `screen_layout.dart` — Selects `Column`, `Row`, or `Stack` layout per screen config

### State Management

Riverpod with a single global `ChangeNotifierProvider<JsonInterpreter>`. The interpreter calls `notifyListeners()` on variable changes and navigation, triggering `ConsumerWidget` rebuilds.

### DSL Specification

`JSON-DSL.md` contains the full v3.2 spec: top-level structure (`version`, `meta`, `global`, `steps`, `ui`), widget type mappings, position system, action/binding rules, and JsonLogic expression syntax.

`test_collector.json` is a sample DSL config (text favorites app) useful as a reference for valid JSON structure.

## Adding a New Widget Type

1. Create `lib/json_ui/widgets/<name>_widget.dart` extending `JsonBaseWidget`
2. Register it in `JsonWidgetBuilder._builders` map in `widget_builder.dart`
3. The interpreter's `buildWidget` → `applyPosition` pipeline handles positioning automatically
