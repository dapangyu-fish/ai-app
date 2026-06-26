# Step 2: Translate Dart Plan To JSON-DSL

完成 `$AI_APP_WORKSPACE/app_dart_plan.dart` 后，立即转换为 `$AI_APP_WORKSPACE/app.json`。

转换规则（widget 类型只能用 `lib/json_ui/widget_builder.dart` 的 `_builders` 里有的，
自创类型 validator 会判 ERROR、客户端会渲染成红色"未知类型"框）：

- `Screen` -> JSON-DSL screen（`ui.screens[]`，内容放 `children`）。
- **没有 `row`/`column`/`flex` 这些类型**，布局一律用 `container` + `layout`：
  - `Column([...])` -> `{"type":"container","layout":"column","children":[...]}`
  - `Row([...])` -> `{"type":"container","layout":"row","children":[...]}`
  - `Stack([...])` -> `{"type":"stack","children":[...]}`
  - 按比例撑开用 `expanded` / `flexible`，**不要**写 `flex`。
- `Scroll` / `ListView` -> `list`；`GridView` -> `grid`。
- `State({...})` -> JSON-DSL state/data。
- `Button` -> `button`；`Input` / `TextField` -> `input`（**不是** `text_input`）；
  `Switch` -> `switch`；`Dropdown` -> `dropdown`；并配 action。
- `Action.*` -> JSON-DSL action/builtin。
- Dart helper 必须展开为 JSON，不能留下 Dart 引用。
- Dart plan 中的文案、多语言、状态名、屏幕 id 必须完整迁移。
- 不要把 Flutter/CSS 字段直接写进 JSON，例如 `marginTop`、`body`、`boxShadow`、`onPressed`、`childrenBuilder`。

转换后必须自检：

- JSON 顶层结构合法。
- 所有 screen id、state path、action target 都存在。
- 列表/滚动区域能够展示长内容。
- 所有 widget 类型都在 `_builders` 中（没有 `row`/`column`/`flex`/`text_input` 等未注册控件）。
- 不存在 validator 未支持字段。
- 不存在把 Dart 代码字符串塞进 JSON 的情况。

