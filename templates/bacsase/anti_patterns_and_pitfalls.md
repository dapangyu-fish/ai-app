# JSON DSL 开发易错点与反面教材记录

本文档主要记录在使用 AI 自动生成或手动编写本项目的 JSON DSL（UI/逻辑配置文件）时，容易犯的“想当然”错误以及对应的 Flutter 崩溃（白屏）日志。作为知识库反面教材，供后续参考与避坑。

---

## 1. 布局约束丢失：默认 Row 嵌套与非法 Flex

### 🚨 崩溃日志表现
```text
Another exception was thrown: RenderFlex children have non-zero flex but incoming width constraints are unbounded.
```
或
```text
Another exception was thrown: RenderFlex children have non-zero flex but incoming height constraints are unbounded.
```
这会导致整个页面由于布局断言失败而**彻底白屏**。

### 💔 反面教材分析
1. **漏写 `layout` 字段导致的灾难**：
   在 `container_widget.dart` 中，如果未指定 `layout` 字段，框架默认会给 `row` (`json['layout'] ?? 'row'`)。很多时候，我们用 `container` 当作一个页面的外层卡片（本意是垂直流式排布 Column），却因为漏写了 `layout: "column"` 变成了 `Row`。
   如果内部子控件试图使用 `position: { "type": "flex", "flex": 1 }`（对应 Flutter 的 `Expanded`）来均分宽度，而由于它是被一层意外的“无边界 Row”包裹，就会因为**宽度无约束（unbounded width）**导致渲染直接崩溃。
   
2. **在滚动视图内误用垂直 Flex**：
   在 Tab 的直接子层级中，如果不包含 `list`，页面会被框架默认包裹在 `SingleChildScrollView -> Column` 中（意味着垂直高度是无限的）。如果在这种无限高度的 Column 中直接放入一个带有 `"position": { "type": "flex" }` 的 `button` 或 `container`，`Expanded` 控件会试图在无限高的父容器里填满“剩余空间”，从而报出**高度无约束（unbounded height）**崩溃。

### ✅ 正确姿势 / 避坑指南
* **永远显式声明布局**：在写 `container` 时，务必明确写出 `"layout": "column"` 或 `"layout": "row"`，不要依赖默认行为。
* **Flex 约束环境**：使用 `type: flex` 时，必须确保其父容器在主轴方向上是有固定尺寸或被强制约束尺寸的（例如屏幕宽度的 Row 内，或者有固定高度的 Column 内）。
* **不在 ScrollView 里拉伸**：不要在可滚动容器的直接子元素上使用 `flex` 占位。

---

## 2. 表达式错用：强制类型转换导致的直接崩溃

### 🚨 崩溃日志表现
```text
Another exception was thrown: type '_Map<String, dynamic>' is not a subtype of type 'String?' in type cast
```

### 💔 反面教材分析
AI 在生成 JSON 时，为了实现高级效果（比如：根据当前选中的类型高亮某个 Tab），往往会“想当然”地在静态属性中使用 JSONLogic 的字典表达式。
例如，给 `color` 和 `border` 传了一个 Map：
```json
"color": {
  "if": [
    { "==": [ "{{ global.selectedType }}", "running" ] },
    "#E8F5E9",
    "#FFFFFF"
  ]
}
```
或者给列表的 `source` 传入了排序 Map 表达式：
```json
"source": { "sort": [ "{{ global.allWorkouts }}", { "var": "loop.item.timestamp" }, true ] }
```

**框架盲区**：
在底层的 Dart 框架中，解析诸如 `color`、`border` 等属性时，是硬编码进行强转的，例如：`Color? bgColor = _parseColor(json['color'] as String?);`。框架并未在渲染 Widget 前统一处理所有的 Map 表达式。当解析器遇到 `{"if": ...}`（一个 Map）并试图强转为 `String?` 时，就会立刻抛出上述的 Type Cast 类型转换异常，导致 Tab 加载失败。

### ✅ 正确姿势 / 避坑指南
* **认清静态与动态边界**：UI 控件的样式属性（如 `color`, `border`, `width` 等）在当前 DSL 框架中只接受**基本数据类型**（String, Number），**绝不能传入 Map 对象或 JSONLogic 表达式字典**。
* **数据源表达式限制**：列表的 `source` 也应当使用字符串插值（例如 `"{{ global.allWorkouts }}"`），若需排序，应在触发动作的 `@list_sort` 等 logic 层完成，而不是在声明 UI 的 `source` 字段里写 Map。
* **需要状态切换的场景**：要么引擎层支持解析，要么在生成期放弃复杂样式条件表达式，退而使用基础的静态默认颜色。

---

## 3. 依赖声明格式错误：List vs Map

### 🚨 崩溃日志表现
```text
Another exception was thrown: type 'List<dynamic>' is not a subtype of type 'Map<String, dynamic>?' in type cast
```

### 💔 反面教材分析
在 JSON App 顶部声明外部组件依赖时，AI 经常会顺手写成数组（List）格式：
```json
"dependencies": [
  {
    "name": "lib_database",
    "version": "^1.0.0"
  }
]
```
**框架盲区**：
在底层的 `interpreter.dart` 依赖加载逻辑中，强行使用了 `_config['dependencies'] as Map<String, dynamic>?` 进行类型转换。这就意味着 `dependencies` 必须是一个**字典（Map）**。如果写成数组，App 在启动加载依赖时就会立刻触发类型转换异常，直接白屏奔溃。

### ✅ 正确姿势 / 避坑指南
* **依赖必须是字典 Map**：正确的依赖声明必须是 Key-Value 的结构，其中 Key 是依赖的名称，Value 是版本约束。
```json
"dependencies": {
  "lib_database": "^1.0.0"
}
```

---

## 4. 控制流参数命名错误：`@if` 错用 `cond`

### 🚨 运行时异常表现
数据查询或逻辑判断似乎“永远走 false / else 分支”，且无任何明显报错（逻辑静默失败返回 null 或空数据）。

### 💔 反面教材分析
在编写业务逻辑配置时，容易“想当然”地使用 `"cond"` 作为 `@if` 判断的参数键值：
```json
{
  "call": "@if",
  "args": {
    "cond": { ">": [ ... ] },
    "then": [ ... ],
    "else": [ ... ]
  }
}
```
**框架盲区**：
在底层的 `interpreter.dart` 解析 `@if` 内置函数时，它严格取值 `args['condition']`，如果取不到，则判定为 null。而 Dart 中的 `_evaluateBool(null)` 会返回 `false`。因此，错用 `"cond"` 会导致判断条件完全丢失，永远静默执行 `else` 分支的逻辑，极难排查。

### ✅ 正确姿势 / 避坑指南
* **严格遵守关键字**：在使用 `@if` 时，条件字段必须且只能写成 `"condition"`。
```json
{
  "call": "@if",
  "args": {
    "condition": { ">": [ ... ] },
    "then": [ ... ],
    "else": [ ... ]
  }
}
```
