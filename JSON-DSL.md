# Flutter JSON Low-Code DSL 完整开发文档 v3.2（附 Trae 创建提示词）

**文档版本**：v3.2  
**制定日期**：2026年4月  
**状态**：正式发布（已完全解除性能限制 + 支持控件位置描述）  
**适用范围**：Flutter 跨平台 GUI 客户端（iOS / Android / Web / Desktop）  
**目标**：一套**纯 JSON 配置驱动**的低代码 Flutter 应用，支持动态下发 UI 与业务逻辑，同时完全规避 App Store / Google Play 对动态下发可执行代码的限制。  
**核心特性**：每个控件可在 JSON 中明确描述自己的位置（position），基础控件（页面、按钮、输入框等）已封装完成。

**作者**：Grok 低代码平台设计团队（基于用户完整需求迭代完成）  
**使用说明**：本文件为**单一完整 Markdown**，可直接保存为 `DSL_SPEC_v3.2.md`，供团队、Trae 或开发使用。

---

## 1. 文档目的与设计原则

- 实现 **Server-Driven UI + 业务流程编排**：云端下发 JSON，App 内置解释器实时渲染界面并执行逻辑。
- 支持无需重新提交 App Store / Google Play 即可更新界面与流程。
- **图灵完备**：支持 `@while`、递归、`@set` 可变状态。
- **安全合规**：所有解释器代码静态编译进 APK/IPA，JSON 仅为数据配置。
- **零性能限制**：DSL 不对页面层级、Widget 数量、循环次数、递归深度等设置任何上限，性能由 Flutter 引擎和设备硬件决定。
- **位置描述能力**：每个控件均可通过 `position` 字段精确描述自己在页面中的位置。

---

## 2. 系统架构概述

```text
[云端 / 后台] ── JSON 配置 ──→ [Flutter App]
│
[内置 JSON 解释器 (Dart)]
│
├── 执行业务逻辑 (steps)
├── 解析并渲染 UI (ui.screens + position)
└── 响应用户交互 (actions → 触发 steps)
```

- **解释器核心**：纯 Dart 实现（`JsonInterpreter` 类）。
- **状态管理**：推荐 Riverpod / Provider + ValueNotifier。
- **网络层**：dio 或 http 拉取最新 JSON。

---

## 3. JSON DSL 规范（v3.2）

### 3.1 顶级结构

```json
{
  "version": "3.2",
  "meta": {
    "name": "示例应用",
    "description": "动态表单 + 数据看板",
    "author": "dev@example.com",
    "version": "1.2.3",
    "timeout_seconds": 300
  },
  "global": { ... },
  "steps": [ ... ],
  "ui": { ... }
}
```

### 3.2 global（全局定义区）

```json
"global": {
  "variables": { ... },
  "functions": { ... }
}
```

（规则同 v2.1，支持递归，自定义函数可调用 `$.ui.refresh()` 触发 UI 重绘）

### 3.3 steps（业务逻辑入口）

支持三种类型：

- **函数调用**：`{ "call": "...", "args": {...}, "assign": "..." }`
- **表达式**：`{ "expression": {JsonLogic}, "assign": "..." }`
- **控制流**：`if`、`while`、`for_each`、`loop_by_num`、`try_catch`

**内置函数（必须实现）**：

`@post`、`@print`、`@set`、`@if`、`@while`、`@for_each`、`@loop_by_num`、`@try_catch`

**表达式引擎**：JsonLogic。

### 3.4 ui（UI 定义区）—— 重点：position 位置描述

```json
"ui": {
  "screens": [
    {
      "id": "home",
      "title": "首页",
      "layout": "stack",
      "padding": 16,
      "children": [
        {
          "type": "text",
          "value": "欢迎 {{ $.global.username }}",
          "position": {
            "type": "absolute",
            "top": 100,
            "left": 20
          },
          "style": { "fontSize": 24 }
        },
        {
          "type": "button",
          "label": "提交",
          "position": {
            "type": "absolute",
            "bottom": 30,
            "right": 20
          },
          "action": { "call": "@global.submitForm" }
        },
        {
          "type": "input",
          "placeholder": "请输入姓名",
          "bind": "$.global.username",
          "position": {
            "type": "flex",
            "flex": 2
          }
        }
      ]
    }
  ]
}
```

**position 字段规则**：

| 属性 | 说明 |
|------|------|
| `type` | `"relative"`（顺序排列，默认）/ `"absolute"`（需 `layout=stack`）/ `"flex"`（弹性布局） |
| 绝对定位 | `top`、`left`、`bottom`、`right`（单位 dp） |
| 弹性布局 | `flex`（数字） |

> 不写 `position` 时默认 `relative` 顺序堆叠。

### 3.5 Widget 类型映射表（基础控件已封装）

| type | Flutter Widget | 必填字段 | 支持属性 |
|------|----------------|----------|----------|
| `text` | `Text` | `value` | `style` |
| `button` | `ElevatedButton` | `label` | `action` |
| `input` | `TextField` | `placeholder` / `bind` | - |
| `list` | `ListView.builder` | `source` / `item_template` | - |
| `card` | `Card` | `children` | - |
| `image` | `Image.network` | `url` | `fit` |
| `container` | `Container` | `children` | `color`, `padding` |

### 3.6 action 与双向绑定

**action 格式**：

```json
"action": {
  "type": "call",
  "call": "@global.xxx",
  "args": { ... }
}
```

**双向绑定**：`bind: "$.global.xxx"` 实现输入框与变量实时同步。

---

## 4. Flutter 端实现指南（控件封装）

### 4.1 项目结构建议

```text
lib/json_ui/
├── widget_builder.dart
├── widgets/
│   ├── base_widget.dart
│   ├── text_widget.dart
│   ├── button_widget.dart
│   ├── input_widget.dart
│   ├── position_handler.dart
│   └── screen_layout.dart
└── interpreter.dart
```

### 4.2 核心封装代码框架（直接复制使用）

**base_widget.dart**

```dart
abstract class JsonBaseWidget {
  Widget build(BuildContext context, Map<String, dynamic> json, JsonInterpreter interpreter);
}
```

**position_handler.dart**

```dart
Widget applyPosition(Widget child, Map<String, dynamic>? pos) {
  if (pos == null) return child;
  final type = pos['type'] ?? 'relative';
  if (type == 'absolute') {
    return Positioned(
      top: pos['top']?.toDouble(),
      left: pos['left']?.toDouble(),
      bottom: pos['bottom']?.toDouble(),
      right: pos['right']?.toDouble(),
      child: child,
    );
  } else if (type == 'flex') {
    return Expanded(flex: pos['flex'] ?? 1, child: child);
  }
  return child;
}
```

> `text_widget.dart` / `button_widget.dart` / `input_widget.dart`（示例逻辑同前文描述）

**screen_layout.dart**

```dart
Widget buildScreen(Map<String, dynamic> screen, List<Widget> children) {
  switch (screen['layout']) {
    case 'stack': return Stack(children: children);
    case 'row': return Row(children: children);
    case 'column': 
    default: return Column(children: children);
  }
}
```

**interpreter.dart**：负责解析 JSON → Context → 递归构建 Widget 树 → 执行 action/steps。
