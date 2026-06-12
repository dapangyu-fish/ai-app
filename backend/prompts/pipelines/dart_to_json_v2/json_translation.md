# Step 2: Translate Dart Plan To JSON-DSL

完成 `$AI_APP_WORKSPACE/app_dart_plan.dart` 后，立即转换为 `$AI_APP_WORKSPACE/app.json`。

转换规则：

- `Screen` -> JSON-DSL screen。
- `Column/Row/Stack/Scroll/ListView/GridView` -> JSON-DSL 已支持布局。
- `State({...})` -> JSON-DSL state/data。
- `Button/Input/Switch/Dropdown` -> JSON-DSL 组件 + action。
- `Action.*` -> JSON-DSL action/builtin。
- Dart helper 必须展开为 JSON，不能留下 Dart 引用。
- Dart plan 中的文案、多语言、状态名、屏幕 id 必须完整迁移。
- 不要把 Flutter/CSS 字段直接写进 JSON，例如 `marginTop`、`body`、`boxShadow`、`onPressed`、`childrenBuilder`。

转换后必须自检：

- JSON 顶层结构合法。
- 所有 screen id、state path、action target 都存在。
- 列表/滚动区域能够展示长内容。
- 不存在 validator 未支持字段。
- 不存在把 Dart 代码字符串塞进 JSON 的情况。

