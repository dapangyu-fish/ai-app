# Restricted Dart UI Plan Subset

`app_dart_plan.dart` 必须是可读的 Flutter 风格伪代码，但只能使用以下受限表达。

允许：

- `class AppPlan`
- `final screens = [...]`
- `Screen(id, title, body)`
- `Column([...])`、`Row([...])`、`Stack([...])`
- `Scroll([...])`、`ListView(data, itemBuilder)`、`GridView(data, itemBuilder)`
- `Container(padding, color, radius, child)`、`Card(child)`、`SafeArea(child)`
- `Text(...)`、`Icon(...)`、`Image(...)`、`Avatar(...)`
- `Button(label, icon, onTap)`、`Input(value, onChanged)`、`Switch(value, onChanged)`
- `State({...})`、`Action.set(...)`、`Action.navigate(...)`、`Action.append(...)`、`Action.remove(...)`
- 简单 helper 函数只能用于减少重复 UI 结构，必须能机械展开。

禁止：

- `import package:flutter/...`
- `StatefulWidget` / `StatelessWidget` 真实实现。
- `BuildContext`、`setState(() {})`、`async` 网络请求、stream、controller、animation controller。
- 任意无法逐字转换成 JSON-DSL 的 Dart 语法。

设计稿必须包含：

- 屏幕清单。
- 关键状态结构。
- 每个主要按钮/手势对应动作。
- 空状态、加载/禁用状态、错误提示。
- 移动端首屏布局约束，优先 iPhone 标准屏，不能把主要内容挤到不可见区域。

