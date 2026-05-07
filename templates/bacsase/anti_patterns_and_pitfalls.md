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
但**同样性质的字段**漏调的不少（一次复审找出 8 处）：

- `screen.title`（默认 AppBar，不是自定义 appBar）
- `screen.tabs[].title`（tab 内层 AppBar）
- `screen.tabs[].label`（底部 BottomNavigationBar 的 tab 文字）← regression-test 撞上的就是这个
- `input.placeholder`、`dropdown.placeholder`、`date_picker.placeholder`、
  `time_picker.placeholder`、`image_picker.placeholder`
- `list.emptyText`、`grid.emptyText`、`reorderable_list.emptyText`

判断的根因是：写 widget 代码的人脑子里"label / title / heading 是给人看的文本 →
模板"是直觉，但"placeholder / emptyText / tab 标签"在直觉里更像"配置"，
就忘了走 resolveTemplate。

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
