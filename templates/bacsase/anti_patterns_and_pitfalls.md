# JSON DSL 开发易错点与反面教材记录

本文档主要记录在使用 AI 自动生成或手动编写本项目的 JSON DSL（UI/逻辑配置文件）时，容易犯的“想当然”错误以及对应的 Flutter 崩溃（白屏）日志。作为知识库反面教材，供后续参考与避坑。

---

## 快速索引（按症状反查）

写 / 调 JSON-APP 出问题时先在这里找症状，跳到对应章节。

| 你看到的现象 | 看哪节 |
|------------|--------|
| 整页白屏 + `RenderFlex ... unbounded` | §1 |
| 整页白屏 + `Map ... is not a subtype of String?` | §2 |
| 整页白屏 + `Map ... is not a subtype of num?` | §5 |
| 整页白屏 + `List ... is not a subtype of Map` | §3 |
| 整页白屏 + `operator xxx not defined`（jsonlogic） | §6 |
| 整页白屏 + `Null is not a num` 但上游 `@set` 看似无害 | §8 |
| 数据查询永远走 else 分支 / 静默 false | §4 |
| UI 显示 `{{ t('xxx') }}` / `{{ global.xxx }}` 字面量 | §7 |
| UI 显示 `{op_name: ...}` 字面量（带大括号和冒号） | §12 |
| `@while` / `@for_each` 嵌套调用后循环索引诡异 | §10 |
| flame_game 里 `{{ loop.id }}` 拼路径返 null | §11 |
| atom 用 id 反查不命中 / jsonlogic var 直读 OK | §9 |
| 平台跳跃类游戏：关卡高差靠感觉摆，导致“差一点跳不上” | §13 |
| 关卡设计类问题：看起来能玩，实测路线/敌人/收集物/复活点不合理 | §14 |

如果症状对不上任何一条，往下顺读看类别能否匹配——按类别大致是：布局崩（§1）、
静态字段类型（§2/§5）、顶层结构（§3）、函数 args 命名（§4）、jsonlogic 求值
（§6/§8/§12 互相相关）、widget 模板（§7）、数据流模式（§9）、变量命名（§10）、
flame 专有（§11）、游戏关卡/数值设计（§13/§14）。

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

---

## 5. 方向性内边距/外边距：不支持的 Map 格式

### 🚨 崩溃日志表现
```text
Another exception was thrown: type '_Map<String, dynamic>' is not a subtype of type 'num?' in type cast
```
崩溃发生在 `JsonContainerWidget.build` 的 `padding` 或 `margin` 解析处（`container_widget.dart:17`），导致整个页面白屏。

### 💔 反面教材分析
在编写 UI 配置时，为了实现更精细的布局控制，容易"想当然"地使用方向性内边距/外边距（类似 CSS 的 `padding-left`, `padding-top` 等）：
```json
{
  "type": "container",
  "padding": { "left": 16, "right": 16, "top": 8, "bottom": 4 },
  "children": [...]
}
```
或者：
```json
{
  "type": "container",
  "margin": { "left": 12, "right": 12, "top": 2, "bottom": 2 },
  "children": [...]
}
```

**框架盲区**：
在底层的 `container_widget.dart` 中，`padding` 和 `margin` 的解析是硬编码进行强转的：
```dart
final padding = (json['padding'] as num?)?.toDouble() ?? 0;
final margin = (json['margin'] as num?)?.toDouble() ?? 0;
```
框架期望这些字段是**单个数字**（表示四个方向统一的内边距/外边距），而不是一个 Map 对象。当解析器遇到 `{ "left": 16, "right": 16, ... }`（一个 Map）并试图强转为 `num?` 时，就会立刻抛出类型转换异常，导致页面崩溃。

**为什么会犯这个错误**：
1. **CSS 思维惯性**：Web 开发中习惯了 `padding: 10px 20px 10px 20px` 或 `padding-left: 16px` 这样的语法
2. **Flutter API 误导**：Flutter 本身支持 `EdgeInsets.only(left: x, right: y, top: z, bottom: w)`，让人以为 JSON DSL 也应该支持
3. **AI 生成代码的"想当然"**：AI 在生成 JSON 时，为了实现更精细的布局，会自然地使用方向性内边距，但没有意识到框架的限制

### ✅ 正确姿势 / 避坑指南
* **只使用统一数值**：`padding` 和 `margin` 必须是单个数字，表示四个方向统一的内边距/外边距：
```json
{
  "type": "container",
  "padding": 12,
  "margin": 8,
  "children": [...]
}
```
* **需要方向性控制时的替代方案**：
  - 使用嵌套 `container` 来模拟不同方向的间距
  - 使用 `spacer` 控件在特定方向上添加空白
  - 等待框架升级支持方向性内边距（需要修改 `container_widget.dart`）
* **非统一值的妥协处理**：如果原本设计需要 `{ "left": 16, "right": 16, "top": 8, "bottom": 4 }`，可以取平均值 `12` 作为统一内边距，虽然不完美但至少不会崩溃

### 🔧 框架改进建议
如果需要支持方向性内边距/外边距，需要修改 `lib/json_ui/widgets/container_widget.dart`：
```dart
// 当前实现（只支持统一数值）
final padding = (json['padding'] as num?)?.toDouble() ?? 0;

// 改进后的实现（支持统一数值和方向性 Map）
EdgeInsets? padding;
final paddingValue = json['padding'];
if (paddingValue is num) {
  padding = EdgeInsets.all(paddingValue.toDouble());
} else if (paddingValue is Map<String, dynamic>) {
  padding = EdgeInsets.only(
    left: (paddingValue['left'] as num?)?.toDouble() ?? 0,
    right: (paddingValue['right'] as num?)?.toDouble() ?? 0,
    top: (paddingValue['top'] as num?)?.toDouble() ?? 0,
    bottom: (paddingValue['bottom'] as num?)?.toDouble() ?? 0,
  );
}
```
但根据 CLAUDE.md 的"框架稳定性原则"，这类改动需要同步更新 JSON-DSL.md 文档，并确保向后兼容。

---

## 6. JsonLogic / 数据 Map 混淆：数据键被当 operator

### 🚨 崩溃日志表现
```text
JsonlogicException: operator id not defined.
JsonlogicException: operator title not defined.
```
（任何 `operator <数据键名> not defined` 都属于这一类。）

### 💔 反面教材分析

AI 写 `@list_add` / `@http_post` body / 任何"我要传一个数据对象"类的 args 时，最容易写出这种 Map：
```json
{
  "call": "@list_add",
  "args": {
    "var": "global.moles",
    "item": {
      "id": "{{ loop.index }}",
      "display": "🐹",
      "bg": "#FF0000"
    }
  }
}
```

**根因（jsonlogic 引擎的两条评估规则）**：
- 单 key Map：`{"if": [...]}` → 把 key 当 operator 找；找不到就抛 `operator xxx not defined`
- 多 key Map：`{"a": ..., "b": ...}` → 当作隐式 AND，对每个键再走一遍单 key 规则 → 每个键都得是合法 op 才行

所以 `{"id": ..., "display": ..., "bg": ...}` 这种"只是想塞个数据对象"的 Map，无论几个键，**只要有任何一个键不在 op 集合里**，老代码无脑 `jl.apply()` 就直接抛崩溃。

老代码：
```dart
// _evaluateExpression
if (value is Map<String, dynamic>) {
  return _jl.apply(_resolveTemplatesInRule(value), _buildDataContext()); // 全员判死刑
}
```

修复后（commit `5f5e797` / `11e0c79`）：
```dart
if (value is Map<String, dynamic>) {
  if (_looksLikeJsonLogic(value)) {        // 单 key + key 在已知 op 白名单
    return _jl.apply(_resolveTemplatesInRule(value), _buildDataContext());
  }
  // 数据 Map：递归 evaluate 内部值，模板/嵌套表达式继续展开
  final out = <String, dynamic>{};
  value.forEach((k, v) => out[k] = _evaluateExpression(v));
  return out;
}
```

### ✅ 正确姿势 / 避坑指南

* **数据 Map 现在合法**：`@list_add args.item` / `@http_post args.body` 等位置可以放任意结构的对象（包括嵌套 `{{ }}` 模板），框架会按数据原样保留 + 模板展开。
* **想用 jsonlogic 表达式时**：明确写成单 key + 已知 op，比如 `{"if": [...]}`、`{"merge": [...]}`、`{"sort": [...]}`、`{"var": "..."}`。
* **危险地带 — 单 key 数据 Map 撞上 op 名**：如果数据键名恰好是 `if/var/merge/sort/in/cat/...` 等 op 集合里的词，**框架会优先把它当 jsonlogic 表达式走**。要么换键名（`item_in` 代替 `in`），要么塞进多 key 数据 Map（加个伴随键 `{"_kind": "data", "in": ...}`）以触发非 jsonlogic 分支。
* **AI 生成时的自检**：见 `backend/prompts/generate_app_prompt.md` 的"上传前自检 checklist" g 项 — `python3 -m json.tool` 走完后，再扫一遍单 key Map 看 key 是不是 op。

### 🔧 框架改进备忘

`_evaluateExpression` 现在用 `_knownJsonLogicOps` 静态白名单判断。未来在 `_createJsonLogic` 里 `jl.add('xxx', ...)` 注册新 op 时，**必须同步把 'xxx' 加到 `_knownJsonLogicOps` 集合**，否则该 op 写法会被当数据 Map，jsonlogic 求值不会触发。

**反向坑 → §12**：白名单解决了"数据 Map 被误判为 op"的崩溃，但**同时引入了反向的静默失败** —— 写一个**没注册**的 op 名（典型 `list_length` 当 jsonlogic op 用），命中不了白名单 → 退化为数据 Map → UI 直接显示 `{xxx: ...}` 字面量、不报任何异常。详见 §12。

---

## 7. 字符串字段塞模板，Widget 端却没跑 resolveTemplate

### 🚨 表现

UI 上某个文本位置直接显示**字面量** `{{ t('xxx.yyy') }}` 或 `{{ global.zzz }}`，
而不是渲染成解析后的内容。例如：

- 底部 Tab 栏文字写成 `t('screen.home.title')` 字面量，没翻译
- 列表空态显示 `{{ t('list.empty') }}` 几个字
- 输入框 placeholder 是 `{{ global.someHint }}` 没替换

### 💔 反面教材分析

JSON-DSL 有一条隐含契约：**任何最终被渲染成文本的字段，框架必须在
build 时跑一遍 `interpreter.resolveTemplate(...)`**，把 `{{ ... }}` 解析掉。
这条约定散落在每个 widget 里——`button.label` / `text.value` / 自定义
`appBar.title` 都自己调，没有集中处理。

历史上这块写得很乱：button / chip / app_bar 的 `label`/`title` 走 resolveTemplate，
但**同样性质的字段**漏调的不少（一次复审找出 8 处 + i18n 重构后又揪出 2 处）：

- `screen.title`（默认 AppBar，不是自定义 appBar）
- `screen.tabs[].title`（tab 内层 AppBar）
- `screen.tabs[].label`（底部 BottomNavigationBar 的 tab 文字）← regression-test 撞上的就是这个
- `input.placeholder`、`dropdown.placeholder`、`date_picker.placeholder`、
  `time_picker.placeholder`、`image_picker.placeholder`
- `list.emptyText`、`grid.emptyText`、`reorderable_list.emptyText`
- `dropdown.options[].label`、`radio.options[].label`（**嵌套坑**：见下）

判断的根因是：写 widget 代码的人脑子里"label / title / heading 是给人看的文本 →
模板"是直觉，但"placeholder / emptyText / tab 标签"在直觉里更像"配置"，
就忘了走 resolveTemplate。

#### 嵌套坑 — list-of-maps 里的 label

`dropdown.options` / `radio.options` 这种 `[{label, value}]` 结构特别容易漏，因为
widget 代码通常这么写：

```dart
final rawOptions = interpreter.resolveExpression(json['options']);  // ← 看上去解过了
for (final item in rawOptions) {
  final lab = item['label']?.toString() ?? '';  // ← 实际没解
  ...
}
```

**`resolveExpression` 对 List 是 `return raw` 不递归**（interpreter.dart `resolveExpression`），
里面每个 item 的 label 字符串原样保留。要么在循环里对 label 单独调
`interpreter.resolveTemplate(lab)`，要么改走能递归的 `_resolveValue`（但那是私有方法）。

i18n 重构（commit `1a2496e`）把 `lib_launcher_settings.json` 里的下拉 options 从
硬编码"系统/浅色/深色"改成 `{{ t('settings.theme_xxx') }}` 之后才暴露 —— 在那之前
硬编码字符串根本不需要解模板，bug 一直存在但没人撞上。这是典型的"潜伏 N 个月、
i18n 重构当晚出问题"。

**对比**：action args 走的 `_resolveArgs → _resolveValue` 是递归处理 List 的，
所以 `@show_choice_dialog` 的 `args.options` 同样形状不会踩这个坑。问题只在
widget 自己取 `json['options']` 这条路径上。

### ✅ 正确姿势 / 避坑指南

**新增任何 widget 字段时，问自己：这个字段最终会进 `Text(...)` 或类似
显示控件吗？**

- 是 → 必须在 widget 内取出后立刻 `interpreter.resolveTemplate(...)`
- 否（数字 / 颜色 / 布尔 / 路径）→ 不需要

不要靠 widget 调用方提前展开模板——`_resolveArgs` 只解 `args` 内的字符串，
**widget 拿到的 `json` 还是原始 raw map**，模板靠 widget 自己解。

模板检测一行 grep（CI 可以加）：

```bash
# 找出还在用裸 toString() 渲染显示文本的字段
grep -rn "json\['\(label\|title\|placeholder\|emptyText\|hint\|heading\|text\)'\]\?\.toString()" \
  lib/json_ui/widgets/ | grep -v resolveTemplate
```

### 🔧 框架改进备忘

如果以后 widget 数量继续涨，可以考虑把 resolveTemplate 提到 widget_builder
那一层做"显示文本字段白名单批量预处理"。但目前散落在各 widget 自己解的方式
仍然是契约——加新 widget 时务必参照已有 widget 的实现。

---

## 8. inline `{call: ...}` 嵌进 jsonlogic 规则的 operand 位置

### 🚨 表现

一个调用看起来"应该出数"，但下游用到这个值的地方静默失败 / 变成奇怪的值 /
直接抛 `TypeError: Null is not a num`：

```text
TypeError: Null check operator used on a null value
... in _buildEntity / @pixel.set_position / 任何把 list/map 字段强转 num 的地方
```

更阴险的是：**当帧 frame.logic 的后续步骤被中断**（包括把状态机切回 ready
那一步），导致 game 卡死在某个中间状态；下一帧 update 又跑同样的逻辑、
同样炸；连 reset 路径都救不回来（因为 reset 完之后再次进入同样的代码
路径还是炸）。

### 💔 反面教材分析

DSL 里两种 Map 表达式有完全不同的求值入口（`game_logic.dart` /
`interpreter.dart` 大同小异）：

```dart
// resolveExpression 对 Map 的两条互斥分支
if (m.containsKey('call')) {
  return runAction(m);          // (A) 框架自己的 dispatch — 走 GameActions / 内置 @action
}
if (m.length == 1 && _looksLikeJsonLogic(m.keys.first)) {
  return _evalJsonLogic(m);     // (B) 整块交给 jsonlogic 库
}
```

(A) 和 (B) 互不调用 — 一旦走 (B)，整棵子树由 **jsonlogic 库**自己递归
解析；jsonlogic 库**不认识 `"call"` 这个 op**，把内层 `{"call": ...}` 当
unknown op 吃掉，最坏返回 null（实现不同也可能抛，被外层 catch 吞）。

具体场景：

```jsonc
// ❌ 反面：把 inline action 嵌进 jsonlogic + 的 operand
{"call": "@set", "args": {
  "var": "vars._x",
  "value": {
    "+": [                                     // 命中分支 (B)，整块进 jsonlogic
      {"var": "vars.base"},                    // ✓ 标准 var
      {"call": "@random_int", "args": {...}}   // ✗ 被 jsonlogic 当 unknown op，返回 null
    ]
  }
}}
// 结果：vars._x = null（或 NaN，看 jsonlogic 实现）

// 一旦下游用 vars._x 做 (pos[0] as num) / 数组下标 / 比较，
// 大概率沿 runStep → runLogic → game.update 一路抛，整条 logic 链中断。
```

对比一下能用的写法：

```jsonc
// ✓ 正面：value 整块就是 inline call → 命中分支 (A) → runAction → 走框架 dispatch
{"call": "@set", "args": {
  "var": "vars._x",
  "value": {"call": "@random_int", "args": {"min": 1, "max": 100}}
}}
```

诊断表征：`null as num` / `null as int` / `RangeError (index)` 这类异常出现
在远离病灶的地方（@spawn / set_position / list 索引等），**而上游某个 @set
看似无害**——这时候 80% 是踩了这一坑。

### ✅ 正确姿势 / 避坑指南

**铁律**：`{"call": ...}` 只能作为整个 value / cond / arg 表达式的**根节点**，
不能放进 jsonlogic 规则（`{"+":[]}` / `{"-":[]}` / `{">":[]}` / `{"if":[]}` …）
的 operand 位置。

**正确套路**：

1. **算术 / 比较的 operand 全是 var / literal**：jsonlogic 自己能处理。

   ```jsonc
   {"+": [{"var": "vars.a"}, {"var": "vars.b"}]}                ✓
   {">": [{"var": "vars.score"}, 100]}                           ✓
   ```

2. **要把 inline action 算出的值喂给 jsonlogic**：先 @set 到一个临时 var，
   再用 var 引用。

   ```jsonc
   // ❌
   {"+": [{"var": "vars.a"}, {"call": "@random_int", "args": {...}}]}

   // ✓
   {"call": "@set", "args": {"var": "vars._tmp", "value":
     {"call": "@random_int", "args": {...}}
   }},
   {"call": "@set", "args": {"var": "vars.x", "value":
     {"+": [{"var": "vars.a"}, {"var": "vars._tmp"}]}
   }}
   ```

3. **能把"+ offset"推进 inline action 自己 args 的，优先这样**（少一个
   临时 var）：

   ```jsonc
   // ✓ random_int 的 args 走的是 _resolveMap，里面再嵌 jsonlogic + 是 OK 的
   //   （+ 的 operand 都是 var / literal）
   {"call": "@random_int", "args": {
     "min": {"+": [{"var": "vars.base"}, 160]},
     "max": {"+": [{"var": "vars.base"}, 280]}
   }}
   ```

4. **怀疑被这一条坑了时**：定位最近一次 @set 是不是在 jsonlogic 规则的
   operand 里塞了 inline call，验证 vars 拿到的是不是 null。

### 🔧 框架改进备忘

要彻底避免，框架可以在 `_evalJsonLogic` 之前递归预扫描 rule，把所有
内层 `{"call": ...}` 提前 dispatch、把结果替换回去再丢给 jsonlogic。
代价是每次 jsonlogic 求值多一遍 walk + 失去懒求值（如 `if-then-else`
里的 then/else 分支会被双方都执行）。当前选择不做这层：约定 + 文档
（这一条）成本更低。

---

## 9. id-roundtrip 反模式：scope 里已有的东西，不要导出 id 再让别人反查回来

### 🚨 表现

DSL 里同一份数据通常有多种取法。常见有三套独立的表达式系统并行：

- **jsonlogic 求值**（`{var: "..."}` / `{+: [...]}` …）— jsonlogic 库自己的引擎
- **模板字符串**（`"{{ x.y }}"`）— 框架的 `_resolveString`，单匹配返回原始类型、混合返回 String
- **原子 args 解析**（`_resolveMap` → `resolveExpression`）— 递归把每个 value 过一遍以上两套，再 `?.toString()` 等强转

同一个数据 D，本来在某个 scope 里直接读字段就能用，却被写成"先取 D 的 id
导出成字符串 → 把字符串塞进某个原子的 args → 原子内部用这个字符串反查
回原 scope 里那同一个 D"——一次毫无意义的"序列化-反序列化往返"。

典型症状：
- 静默 false / 静默 null —— 原子找不到对象常常返回合法零值不抛异常，看起来"逻辑没生效"
- 用 var 直读验证"数据本身是对的"，**改走原子反查就不命中**
- 加日志/调试时不知道在哪一道翻译里失真了（模板？toString？原子内 lookup？类型检查？）

### 💔 反面教材分析

跨表达式系统倒手数据 = 失败面叠加。每跨一套，就经一道翻译：

| 跨界点 | 翻译做了什么 |
|--------|--------------|
| jsonlogic 求值 → 外层 | 返回值类型由 jsonlogic 决定（数字 / String / null / bool） |
| 模板单匹配 `"{{ x }}"` | 返回 `getVariable(x)` 的**原始类型** |
| 模板混合 `"a {{ x }}"` | `x.toString()` 拼回 String，**原始类型丢了** |
| 进原子 args | 走 `_resolveMap`，每 value 再过一遍 resolveExpression |
| 原子内部用 args | 通常 `args[k]?.toString()`，再次强转 |
| 原子按 id 反查 scope | 大小写 / 命名空间 / 类型检查 / 时机（loop scope 是否还在）任一不对就 lookup miss |

短路径（直接 `{var: "scope.D.field"}`）只经第 1 行；长路径（id 导出 + 反查）
要趟过 3~5 行。**每多一道翻译就多一个静默失败点**——而且这些失败点彼此独立，
测试 A 路径过了不能保证 B 路径过。

更阴险的是：长路径里**任何一层升级、改类型、改解析顺序，都可能在不报错
的前提下让结果变形**。短路径少这层耦合。

跟 #8 区分：#8 是"嵌套位置错 → 必踩"的硬错误；#9 是"路径冗长 → 失败面扩大、
可能踩到不同的坑"的软问题。即便每一层暂时都没 bug，长路径也比短路径脆。

### ✅ 正确姿势 / 避坑指南

**一条铁律**：**已经持有对引用对象的访问能力，就别先导出它的 id 字符串，
再让下游用这个字符串反查回原 scope 里同一个对象**。

判断写法是不是踩了这一条，看这两个条件**同时**满足吗：

1. 数据 D 已经在某个 scope（vars / loop / event / entities …）里
2. 我现在要做的是"读 D 的字段做计算/判断"（而不是触发副作用）

如果都满足，就走 jsonlogic var 直读字段；不要写"`{{ scope.D.id }}` → 传给
某 atom → atom 内部反查 D"。

**什么时候 id 字符串不可避免**：当下游要做的是**副作用 + 命名指代**——
比如"删除这个对象"/"修改它的属性"——本质上需要把"谁"作为参数传入，
这时 id 字符串路径就是合理的。**只读的判断和计算不该走这条路**。

### 🔬 通用诊断技巧：特征值 + 终止动作 当"穷人版断点"

调 DSL 不像调代码可以打断点。当不确定多条候选写法哪条 work，又难加日志时：

1. 选一个**整个 app 都能看见的状态变量**（计分、显示用的 vars 字段、title 文本……）
2. 把每条候选包成独立 `@if`，命中时把状态变量设成一个**互不相同的特征值**
3. 紧跟一个**终止动作**（`@game_over` / `@navigate.back` / 弹一个 dialog 之类）冻住状态

特征值差距要够大、彼此正交，避免和正常业务值混淆——**1/2/3 不行**（容易和真实
计数撞），**5000/999/200 这种就行**。终止动作必须有，否则多条分支都命中
会被后面的覆盖，看不出谁先 hit。

```jsonc
{"call": "@if", "args": {"cond": <候选 A>, "then": [
  {"call": "@set", "args": {"var": "vars.diag", "value": 5000}},
  {"call": "@<terminate>"}
]}},
{"call": "@if", "args": {"cond": <候选 B>, "then": [
  {"call": "@set", "args": {"var": "vars.diag", "value": 999}},
  {"call": "@<terminate>"}
]}},
{"call": "@if", "args": {"cond": <候选 C>, "then": [
  {"call": "@set", "args": {"var": "vars.diag", "value": 200}},
  {"call": "@<terminate>"}
]}}
```

终止后用户看到的状态值就是命中分支编号。不用接 console，不用看日志，
JSON-APP 自己就能定位到哪一行 cond 真假。

### 🔧 框架改进备忘

根本治法是把多套表达式系统的边界收敛——例如让原子统一接收"对象引用"
而不是 id 字符串、由框架在 dispatch 阶段一次性把 id/引用都解析好——但那
是大手术。约定 + 文档（这一条）成本最低，写 JSON 时多想一秒"能不能走
短路径"就够了。

---

## 10. 多函数共用 `_i` / `_v` 临时变量，被嵌套调用 clobber

JSON-DSL 没真函数局部作用域，`global._i` 这种全局可写。两个函数都用 `_i` 当循环索引时，A 的循环里调 B，B 跑完 `_i` 已经被改成 B 退出时的值，A 的索引被冲掉。

**踩坑实例**：消消乐 `checkGameOver` 外层 `_i=0..63` 枚举 swap 候选，里面调 `findMatches` 也用 `_i` 跑 64-iter 扫描。findMatches 跑完 `_i=64`，外层 while 立即退出，只测了一次 swap 就误报死局。

**约定**：函数私有的循环临时变量加 `_<funcname>_` 前缀（`_fm_i` / `_cgo_v` 等）。函数的**输出**（`_hasMatch` / `_matchList`）保留无前缀全局名作为返回值约定。

**触发信号**：函数里有 `@while` / `@for_each` 嵌套调其他函数（不止 `@set` 这种 leaf）时，循环变量必须前缀。silent fail 很难调，多打几个字符值得。

---

## 11. flame_game `@for_each_entity` body 里直接用 `{{ loop.id }}` 模板路径

在 flame_game 的 `frame.logic` / `tick.logic` 里写 `@for_each_entity`，body 里很自然会想这样写：

```jsonc
{"call": "@set", "args": {
  "var": "vars._t",
  "value": {"var": "vars.targets.{{ loop.id }}"}  // ⚠️ 不可靠
}}
```

**踩坑实例**：消消乐 pixel 版 v0.2.0~v0.2.7。tap 写 `vars.targets[uid]`、frame for_each 用 `{{ loop.id }}` 读。tap 端写读都 OK、frame 开头 `vars.targets[_uid_a]` 也读得到、entity id 跟 _uid_a 在 jsonlogic `==` 下能匹配 —— 唯独 `{"var": "vars.targets.{{ loop.id }}"}` 永远返 null。同一份 `_loopStack`，jsonlogic var op 看得到 `loop.id`、`{{ vars.X }}` 模板能解析，唯独 `{{ loop.X }}` 在嵌套 jsonlogic var path 里失效。

**workaround**（不依赖 framework 哪个版本都通）：每个迭代开头先用 jsonlogic var 把 `loop.id` 抓到 vars，所有路径/id 用到 entity id 的地方都改用 `{{ vars._cap }}`：

```jsonc
{"call": "@for_each_entity", "args": {
  "where_prefix": "g",
  "do": [
    {"call": "@set", "args": {"var": "vars._cap", "value": {"var": "loop.id"}}},  // 先抓
    {"call": "@set", "args": {"var": "vars._t", "value": {"var": "vars.targets.{{ vars._cap }}"}}},
    {"call": "@pixel.set_position", "args": {"id": "{{ vars._cap }}", "position": [...]}}
  ]
}}
```

**约定**：在 flame_game 的 `@for_each_entity` body 里，**永远**第一步抓 `loop.id` 到 `vars._cap`（或加函数级前缀），后续路径/id 全用 `{{ vars._cap }}`。`{{ loop.id }}` 直接用是埋雷。

**回归保护**：`test/flame_loop_template_test.dart` 覆盖几条关键路径，framework 改坏会 catch。

---

## 12. 误用未注册的 jsonlogic op 名 → 静默退化为数据 Map → 字面量显示

### 🚨 表现

UI 上某个本该显示数字 / 字符串的位置，直接显示 **Dart Map 的 toString 形态**：

```text
共 {list_length: []} 次记录
共 {count: []} 条
得分 {sum: []} 分
```

注意是 **`{op_name: ...}` 的字面量形式**（带大括号和冒号），不是 `{{ }}` 模板。
没有任何运行时异常，UI 看上去就是渲染错了。

### 💔 反面教材分析

`@list_length` 是 builtin **函数**（走 `{call: "@list_length", args: {...}}` 路径，
用在 steps / actions 里）。jsonlogic **运算符**叫 `length`（不带 `list_` 前缀）。
AI 经常把两个混了，在 text 模板里写：

```jsonc
{
  "type": "text",
  "value": "共 {{ {list_length: [{var: 'global.history'}]} }} 次记录"  // ❌
}
```

**根因**：jsonlogic 的求值入口（interpreter `_evaluateExpression`）现在用白名单
判断（见 §6）：

```dart
if (value is Map<String, dynamic>) {
  if (_looksLikeJsonLogic(value)) {  // 单 key + key 在 _knownJsonLogicOps 白名单
    return _jl.apply(...);
  }
  // 数据 Map 分支：递归 evaluate 内部值，整体当数据 Map 返回
  return { for (var e in value.entries) e.key: _evaluateExpression(e.value) };
}
```

`list_length` 不在白名单里 → 命中**数据 Map 分支** → 整块 Map 原样保留。
text 模板 `{{ ... }}` 拿到这个 Map → `.toString()` 拼字符串 → 显示成
`{list_length: []}`（`[]` 是内层 args 求值后的空数组）。

**没异常**意味着排查全靠肉眼 —— 看到 `{xxx: ...}` 字面量时第一反应应该是
"我用错 op 名了"。

### ✅ 正确姿势 / 避坑指南

**当前框架已注册的 jsonlogic op 名（不带 `@` 前缀）**：

| 想做的事 | jsonlogic op | builtin function（带 @） |
|---------|--------------|--------------------------|
| 取列表长度 | `length` | `@list_length` |
| 字符串长度 | `str_len` | `@str_len`（如有） |
| 字符串拼接 | `cat`（jsonlogic 内置） | `@str_concat`（如有） |
| 取下标 | `at` | `@list_get`（如有） |
| 数组切片 | `slice` | `@list_slice`（如有） |
| 字符串大写 | `str_upper` | （同名） |
| 排序 / 反转 | `sort` / `reverse` | （同名） |
| 类型转换 | `to_string` / `to_int` / `to_double` | （同名） |

**铁律**：
1. 在 text 模板 / `value` / `bind` 等表达式位置，用 **jsonlogic op 名**（无 `@`）
2. 在 `{call: "@xxx"}` 函数调用位置，用 **builtin function 名**（带 `@`）
3. 不要假设两套命名一致 —— `length` ≠ `@list_length`，虽然功能等价

**典型修法**：

```jsonc
// ❌ 错：list_length 不是 jsonlogic op
"value": "共 {{ {list_length: [{var: 'global.history'}]} }} 次"

// ✓ 对：用 jsonlogic 的 length
"value": "共 {{ {length: [{var: 'global.history'}]} }} 次"

// ✓ 对：或在 steps 里预先用 @list_length 算到 var，再 {{ var }}
{ "call": "@list_length", "args": { "value": "{{ global.history }}" },
  "assign": "global.historyCount" },
// text: "共 {{ global.historyCount }} 次"
```

### 🔍 自检 / 排查

- UI 上出现 `{xxx: ...}` 字面量 → 立刻去 `interpreter.dart` 搜 `jl.add('` 看注册了哪些 op
- 看不到对应 op 名 → 要么改 JSON 用正确的 op 名、要么把这个 op 注册成 alias
  （只在确认 AI / 用户高频写错某个名时考虑加 alias，不要无脑膨胀白名单）

### 🔧 框架改进备忘

可选改进：让 `_evaluateExpression` 在 unknown op 名命中数据 Map 分支时，
开发模式下打 warning（`debugPrint('[JSON DSL] 警告：{xxx: ...} 看起来像 jsonlogic
表达式但 xxx 不是已注册的 op，按数据 Map 处理'）`）。**不建议**抛异常 —— 数据
Map 是合法场景（§6），抛了会破坏 `@list_add args.item` 等正常用法。

---

## 13. 平台跳跃类游戏：关卡高差必须匹配跳跃数值

### 🚨 表现

平台跳跃类游戏里，玩家“差一点”跳不上箱子、高台或砖块：

- 低台能上，高台怎么试都差一点
- 为了某个高台继续加跳跃力，结果全局手感变飘
- 同一关里平台高度不统一，玩家很难判断哪里能上

### 💔 反面教材分析

这类问题通常不是框架问题，而是**关卡高差没有和跳跃参数一起设计**。
平台跳跃类游戏至少要先估算理论最大跳高：

```text
maxJumpHeight ≈ jumpVelocity² / (2 * gravity)
```

但这个值只是理论上限。实际可玩关卡还要给这些因素留余量：

- 玩家碰撞盒高度和脚底判定误差
- 输入时机误差
- 水平速度和平台距离
- 碰撞分步、掉帧、边缘判定误差
- 平台边缘容错

### ✅ 正确姿势 / 避坑指南

- **先定手感，再设计关卡**：先确定 `jumpVelocity / gravity / moveSpeed`，再摆平台。
- **关键路径不要压理论极限**：推荐单次高差控制在理论跳高的 `55% ~ 75%`。
- **超过安全高差就做阶梯**：不要为了一个高台硬调全局跳跃；用中间台阶、斜坡、移动平台或替代路线解决。
- **同类平台保持视觉一致**：玩家应该能从视觉高度判断“这个能不能跳上去”。

### 🔍 自检 / 排查

- 列出关键路径上所有可落脚平台的 top y
- 计算相邻平台高差和水平距离
- 找出超过安全跳高的段落
- 如果只是一处上不去，优先改地图，不要改全局跳跃数值

---

## 14. 关卡设计类问题：地图要做可玩性校验

### 🚨 表现

游戏能加载、能跑，但实测很别扭：

- 路线不顺，关键跳跃经常失败
- 金币、道具、宝箱等收集物放在不可达位置
- 敌人巡逻区没有完整地面，导致悬空、掉落或突然消失
- 复活点在危险区旁边，复活后立刻再次死亡
- 视觉层和碰撞层不一致：看起来能站但站不上，或看不到东西却被挡住

### 💔 反面教材分析

这类问题不是 DSL 语法错误，而是**关卡只按画面摆，没有按游戏规则验算**。
任何关卡都至少有几层数据需要同时对齐：

- 视觉层：玩家看到什么
- 碰撞层：哪里能站、哪里会挡
- 危险层：哪里会死或扣血
- 实体层：敌人、收集物、出生点、终点在哪里
- 数值层：速度、跳跃、攻击距离、碰撞盒大小

只看其中一层，很容易做出“截图很好看，实际不好玩”的关卡。

### ✅ 正确姿势 / 避坑指南

- **先画主路径**：出生点 → 教学点 → 风险点 → 奖励点 → 终点。
- **每段路线都要可达**：高度差、水平距离、落脚宽度都要和当前数值匹配。
- **收集物不要和障碍/危险区重叠**：要留出碰撞盒余量，确保玩家能实际拿到。
- **敌人活动范围必须安全**：巡逻范围脚下要有连续地面，不要跨坑、跨水、跨尖刺。
- **复活点必须安全**：复活点附近不要有敌人、陷阱、立即必死跳跃。
- **视觉和碰撞同步**：能站的东西要有碰撞，装饰物不要误放进 solid layer。

### 🔍 发布前 checklist

- 主路径可完整走通
- 所有关键跳跃不是极限操作
- 所有奖励物可达
- 所有敌人不会自然掉出地图
- 所有复活点安全
- 视觉层、碰撞层、危险层一致

---
