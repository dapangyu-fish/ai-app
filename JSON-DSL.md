# Flutter JSON Low-Code DSL 完整开发文档 v3.3

**文档版本**：v3.3
**制定日期**：2026年4月
**状态**：正式发布
**适用范围**：Flutter 跨平台 GUI 客户端（iOS / Android / Web / Desktop）
**目标**：一套**纯 JSON 配置驱动**的低代码 Flutter 应用，支持动态下发 UI 与业务逻辑。

---

## 1. 设计原则

- **Server-Driven UI**：云端下发 JSON，App 内置解释器实时渲染界面并执行逻辑。
- **图灵完备**：支持 `@while`、递归、`@set` 可变状态、`@if` 条件分支、`@parallel` 并发。
- **安全合规**：解释器纯 Dart 静态编译进 APK/IPA，JSON 仅为数据配置。
- **零性能限制**：不对页面层级、Widget 数量、循环次数设上限。
- **位置描述**：每个控件可通过 `position` 精确描述自己在页面中的位置。

- **模块化**：支持 JSON 模块引用，通过 `dependencies` + 版本约束实现复用。

---

## 2. 系统架构

```text
[云端 / 本地文件] ── JSON 配置 ──→ [Flutter App]
│
[JsonInterpreter (Dart)]
│
├── Jsonlogic            (标准 JsonLogic 引擎 + 自定义扩展操作符)
├── DslHttpClient        (HTTP 网络层, 基于 dio)
├── DependencyLoader     (依赖加载 + 版本校验 + 循环依赖检测)
├── JsonWidgetBuilder    (控件注册表 + 分发)
│   └── widgets/         (各类控件实现，含 ref 控件)
└── 状态管理             (Riverpod ChangeNotifierProvider)
```

---

## 3. JSON DSL 规范

### 3.1 顶级结构

```json
{
  "dsl": "3.3",
  "appid": "a1b2c3d4e5f67890",
  "meta": {
    "name": "my-app",
    "version": "1.0.0",
    "type": "app",
    "description": "应用描述",
    "author": "作者",
    "exports": []
  },
  "dependencies": {
    "common-ui": {
      "url": "https://cdn.example.com/common-ui.json",
      "version": "^1.2.0"
    }
  },
  "global": { ... },
  "steps": [ ... ],
  "ui": { ... }
}
```

| 字段 | 必须 | 说明 |
|------|------|------|
| `dsl` | 是 | DSL 规范版本（如 `"3.3"`），兼容旧 `version` 字段 |
| `appid` | 否 | 应用唯一标识（UUID，发布时必须，新创建可留空） |
| `meta.name` | 是 | 模块唯一标识（包名） |
| `meta.version` | 是 | 模块版本号（semver: `MAJOR.MINOR.PATCH`） |
| `meta.type` | 是 | `app`（完整应用）/ `library`（函数/页面集合）/ `widget`（可复用控件模板） |
| `meta.exports` | 否 | library/widget 暴露给外部的函数名和页面 ID 列表 |
| `dependencies` | 否 | 依赖声明，key 为依赖别名，value 含 `url` 和 `version` 约束 |

#### 模块类型

| type | 说明 | 必须字段 | 使用方式 |
|------|------|---------|---------|
| `app` | 完整应用 | `ui.screens`, `steps` | 直接加载运行 |
| `library` | 函数/页面库 | `global.functions` | 被其他模块 `dependencies` 引用 |
| `widget` | 控件模板库 | `ui.templates` | 通过 `ref` 控件引用 |

#### 版本约束语法

| 写法 | 含义 |
|------|------|
| `"1.2.3"` | 精确版本 |
| `"^1.2.0"` | 兼容更新: >=1.2.0 <2.0.0 |
| `"~1.2.0"` | 小版本更新: >=1.2.0 <1.3.0 |
| `">=1.0.0"` | 最低版本 |
| `">=1.0.0 <2.0.0"` | 范围约束 |
| `"*"` | 任意版本 |

#### 跨模块引用规则

```jsonc
// 调用依赖的函数: @depName.funcName
{ "call": "@common-ui.showToast", "args": { "message": "操作成功" } }

// 导航到依赖的页面: depName:screenId
{ "type": "navigate", "screen": "auth:loginPage" }

// 引用依赖的控件模板: ref
{ "type": "ref", "from": "common-ui", "widget": "userCard", "props": { "name": "张三" } }

// 读取依赖的变量（只读）: depName.varPath
"{{ common-ui.theme.primaryColor }}"
```

### 3.2 global（全局定义区）

```json
"global": {
  "variables": {
    "username": "",
    "items": [],
    "user": { "name": "张三", "age": 18 }
  },
  "functions": {
    "myFunc": {
      "params": ["arg1", "arg2"],
      "return": "None",
      "logic": [ ... ]
    }
  }
}
```

**变量路径支持嵌套**：`global.user.name` 可读写深层属性。

### 3.3 值类型规则（核心约定）

在 `args` 中，值的写法决定了解释器如何处理它：

| 写法 | 类型 | 解释器行为 | 示例 |
|------|------|-----------|------|
| `"hello"` | 原始字符串 | 直接使用 | `"value": "hello"` |
| `123` / `true` / `[]` | 原始值 | 直接使用 | `"value": []` |
| `"{{ path }}"` | 模板引用 | 解析为变量的**原始类型**（List/Map/String 等） | `"value": "{{ global.list }}"` → 实际 List |
| `"前缀 {{ path }} 后缀"` | 模板插值 | 解析为**字符串**（变量 toString 后拼接） | `"value": "共 {{ global.count }} 条"` → `"共 5 条"` |
| `{ "op": [...] }` | JsonLogic 表达式 | 通过 jsonlogic 引擎**求值** | `"value": { "merge": [...] }` |

**关键区分**：
- `"{{ global.items }}"` → 返回 items 变量本身（可能是 List、Map、数字等，保留原始类型）
- `{ "var": "global.items" }` → 通过 jsonlogic 引擎求值，效果相同但更明确
- `"总数: {{ global.count }}"` → 返回字符串 `"总数: 5"`（混合文本，强制 String）

**HTTP 响应数据处理示例**：
```json
// 1. 发起请求，结果存入变量（返回 { status, data, headers, error }）
{ "call": "@http_get", "args": { "url": "..." }, "assign": "global.result" }

// 2. 提取 data 字段（模板引用保留原始类型）
{ "call": "@set", "args": { "var": "global.list", "value": "{{ global.result.data }}" } }

// 3. 或用 jsonlogic 表达式提取
{ "call": "@set", "args": { "var": "global.list", "value": { "var": "global.result.data" } } }
```

### 3.3 steps（业务逻辑）

```json
"steps": [
  { "call": "@print", "args": { "value": "启动" } },
  { "call": "@http_get", "args": { "url": "https://api.example.com/data" }, "assign": "global.apiResult" },
  { "expression": { "+": [1, 2, 3] }, "assign": "global.sum" }
]
```

每个 step 支持：
- **函数调用**：`{ "call": "...", "args": {...}, "assign": "global.xxx" }`
- **表达式**：`{ "expression": {JsonLogic}, "assign": "global.xxx" }`

`assign` 将函数返回值 / 表达式结果存入指定变量。

---

## 4. 内置函数完整列表

### 4.1 基础

| 函数 | 参数 | 说明 |
|------|------|------|
| `@print` | `{ "value": "..." }` | 调试打印 |
| `@set` | `{ "var": "$.global.xxx", "value": ... }` | 设置变量（value 支持 JsonLogic 表达式） |
| `@navigate` | `{ "screen": "screenId" }` | 页面跳转 |
| `@delay` | `{ "ms": 1000 }` | 延迟指定毫秒 |

### 4.2 控制流

| 函数 | 参数 | 说明 |
|------|------|------|
| `@if` | `{ "condition": {expr}, "then": [...], "else": [...] }` | 条件分支 |
| `@while` | `{ "condition": {expr}, "body": [...], "max_iterations": 10000 }` | 循环 |
| `@for_each` | `{ "source": {expr}, "body": [...] }` | 遍历数组（$.loop.item / $.loop.index） |
| `@loop_by_num` | `{ "count": 10, "body": [...] }` | 按次数循环 |
| `@try_catch` | `{ "try": [...], "catch": [...], "error_var": "$.global.err" }` | 异常捕获 |
| `@parallel` | `{ "steps": [...] }` | **并发执行**多个 step，全部完成后继续 |

**@if 示例**：
```json
{
  "call": "@if",
  "args": {
    "condition": { ">": [{ "var": "$.global.count" }, 0] },
    "then": [
      { "call": "@print", "args": { "value": "有数据" } }
    ],
    "else": [
      { "call": "@print", "args": { "value": "空" } }
    ]
  }
}
```

**@parallel 示例**：
```json
{
  "call": "@parallel",
  "args": {
    "steps": [
      { "call": "@http_get", "args": { "url": "https://api1.com" }, "assign": "$.global.r1" },
      { "call": "@http_get", "args": { "url": "https://api2.com" }, "assign": "$.global.r2" }
    ]
  }
}
```

### 4.3 HTTP 请求

所有 HTTP 函数返回 `{ "status": int, "data": dynamic, "headers": {}, "error": String? }`

| 函数 | 参数 | 说明 |
|------|------|------|
| `@http_get` | `{ "url": "...", "query": {...}, "headers": {...} }` | GET 请求 |
| `@http_post` | `{ "url": "...", "body": {...}, "headers": {...}, "content_type": "application/json" }` | POST 请求 |
| `@http_put` | `{ "url": "...", "body": {...}, "headers": {...} }` | PUT 请求 |
| `@http_delete` | `{ "url": "...", "headers": {...} }` | DELETE 请求 |

**示例**：
```json
{
  "call": "@http_post",
  "args": {
    "url": "https://api.example.com/users",
    "body": {
      "name": "{{ $.global.username }}",
      "email": "{{ $.global.email }}"
    },
    "headers": { "Authorization": "Bearer {{ $.global.token }}" }
  },
  "assign": "$.global.postResult"
}
```

### 4.4 JSON 处理

| 函数 | 参数 | 返回值 |
|------|------|--------|
| `@json_decode` | `{ "value": "{\"key\":1}" }` | 解析后的 Map / List |
| `@json_encode` | `{ "value": {expr} }` | JSON 字符串 |

### 4.5 字符串处理

| 函数 | 参数 | 返回值 |
|------|------|--------|
| `@str_contains` | `{ "value": "hello world", "search": "world" }` | `true` |
| `@str_split` | `{ "value": "a,b,c", "separator": "," }` | `["a","b","c"]` |
| `@str_replace` | `{ "value": "hello", "from": "l", "to": "r" }` | `"herro"` |
| `@str_length` | `{ "value": "hello" }` | `5` |
| `@str_upper` | `{ "value": "hello" }` | `"HELLO"` |
| `@str_lower` | `{ "value": "HELLO" }` | `"hello"` |
| `@str_trim` | `{ "value": " hello " }` | `"hello"` |
| `@str_substring` | `{ "value": "hello", "start": 1, "end": 3 }` | `"el"` |
| `@str_starts_with` | `{ "value": "hello", "prefix": "he" }` | `true` |
| `@str_ends_with` | `{ "value": "hello", "suffix": "lo" }` | `true` |

### 4.6 数组操作

| 函数 | 参数 | 说明 |
|------|------|------|
| `@list_length` | `{ "value": {expr} }` | 返回数组长度 |
| `@list_add` | `{ "var": "$.global.list", "item": "xxx" }` | 向数组末尾添加元素 |
| `@list_remove_at` | `{ "var": "$.global.list", "index": 0 }` | 按索引删除 |
| `@list_remove` | `{ "var": "$.global.list", "value": "xxx" }` | 按值删除（删除所有等于 value 的元素） |
| `@list_insert` | `{ "var": "$.global.list", "index": 0, "item": "xxx" }` | 在指定位置插入 |
| `@list_clear` | `{ "var": "$.global.list" }` | 清空数组 |

### 4.7 类型转换

| 函数 | 参数 | 返回值 |
|------|------|--------|
| `@to_string` | `{ "value": 123 }` | `"123"` |
| `@to_int` | `{ "value": "42" }` | `42` |
| `@to_double` | `{ "value": "3.14" }` | `3.14` |

### 4.8 UI 反馈

| 函数 | 参数 | 说明 |
|------|------|------|
| `@show_toast` | `{ "message": "保存成功" }` | 底部 SnackBar 提示 |
| `@show_snackbar` | `{ "message": "邮件已发送", "actionLabel": "撤销", "action": {...}, "durationMs": 4000, "backgroundColor": "#333333" }` | 增强 SnackBar，支持操作按钮回调 |
| `@show_dialog` | `{ "title": "确认", "message": "确定删除？" }` | 弹窗，返回 `true`/`false` |
| `@show_input_dialog` | `{ "title": "重命名", "hint": "请输入", "defaultValue": "", "bind": "global.name" }` | 文本输入弹窗，返回输入值（取消返回 `null`） |
| `@show_choice_dialog` | `{ "title": "保存修改？", "message": "...", "buttons": [{"label":"保存","value":"save","style":"primary"},{"label":"丢弃","value":"discard","style":"danger"},{"label":"取消","value":"cancel"}], "dismissible": true }` | 自定义按钮弹窗，返回被点按钮的 `value`（关闭返回 `null`）。`style`：`primary` / `danger` / `text`（默认） |
| `@show_date_picker` | `{ "initial": "2026-04-28", "firstDate": "2020-01-01", "lastDate": "2030-12-31", "bind": "global.date" }` | 命令式日期选择器，返回 yyyy-MM-dd 字符串（取消返回 `null`） |
| `@show_time_picker` | `{ "initial": "14:30", "bind": "global.time" }` | 命令式时间选择器，返回 HH:mm 字符串（取消返回 `null`） |
| `@show_bottom_sheet` | `{ "content": { ...widget... }, "isDismissible": true, "enableDrag": true, "backgroundColor": "#FFFFFF" }` | 底部弹窗，content 是任意 widget 配置，弹窗内可通过自定义函数关闭并返回值 |

---

## 5. JsonLogic 表达式引擎

所有 `{ "operator": [...args] }` 形式的 JSON 节点都通过表达式引擎求值。

### 5.1 数据访问

| 操作 | 示例 | 说明 |
|------|------|------|
| `var` | `{ "var": "$.global.name" }` | 读取变量 |
| `var` (空) | `{ "var": "" }` | 读取当前迭代元素 (filter/map 中) |

### 5.2 算术运算

| 操作 | 示例 | 结果 |
|------|------|------|
| `+` | `{ "+": [1, 2, 3] }` | `6` |
| `-` | `{ "-": [10, 3] }` | `7` |
| `*` | `{ "*": [2, 3] }` | `6` |
| `/` | `{ "/": [10, 3] }` | `3.33` |
| `%` | `{ "%": [10, 3] }` | `1` |

### 5.3 比较运算

`==`, `!=`, `>`, `<`, `>=`, `<=`

```json
{ ">": [{ "var": "$.global.age" }, 18] }
```

### 5.4 逻辑运算

| 操作 | 示例 |
|------|------|
| `and` | `{ "and": [true, { ">": [1, 0] }] }` |
| `or` | `{ "or": [false, true] }` |
| `!` / `not` | `{ "!": [false] }` → `true` |
| `if` / `?:` | `{ "if": [condition, thenVal, elseVal] }` |
| `!!` | `{ "!!": ["non-empty"] }` → `true` |

### 5.5 字符串运算

| 操作 | 示例 | 结果 |
|------|------|------|
| `cat` | `{ "cat": ["hello", " ", "world"] }` | `"hello world"` |
| `substr` | `{ "substr": ["hello", 1, 3] }` | `"ell"` |
| `str_len` | `{ "str_len": ["hello"] }` | `5` |
| `str_upper` | `{ "str_upper": ["hello"] }` | `"HELLO"` |
| `str_lower` | `{ "str_lower": ["HELLO"] }` | `"hello"` |
| `str_trim` | `{ "str_trim": [" hi "] }` | `"hi"` |
| `str_contains` | `{ "str_contains": ["hello", "ell"] }` | `true` |
| `str_replace` | `{ "str_replace": ["hello", "l", "r"] }` | `"herro"` |
| `str_split` | `{ "str_split": ["a,b,c", ","] }` | `["a","b","c"]` |
| `str_join` | `{ "str_join": [["a","b"], ","] }` | `"a,b"` |

### 5.6 数组运算

| 操作 | 示例 | 说明 |
|------|------|------|
| `merge` | `{ "merge": [[1,2], [3,4]] }` | `[1,2,3,4]` |
| `in` | `{ "in": [2, [1,2,3]] }` | `true` |
| `filter` | `{ "filter": [[1,2,3], { ">": [{"var":""}, 1] }] }` | `[2,3]` |
| `map` | `{ "map": [[1,2,3], { "*": [{"var":""}, 2] }] }` | `[2,4,6]` |
| `reduce` | `{ "reduce": [[1,2,3], { "+": [{"var":"accumulator"}, {"var":"current"}] }, 0] }` | `6` |
| `all` | `{ "all": [[2,4,6], { ">": [{"var":""}, 0] }] }` | `true` |
| `some` | `{ "some": [[1,-2,3], { "<": [{"var":""}, 0] }] }` | `true` |
| `none` | `{ "none": [[1,2,3], { "<": [{"var":""}, 0] }] }` | `true` |
| `length` | `{ "length": [[1,2,3]] }` | `3` |
| `at` | `{ "at": [[10,20,30], 1] }` | `20` |
| `slice` | `{ "slice": [[1,2,3,4], 1, 3] }` | `[2,3]` |
| `sort` | `{ "sort": [[3,1,2]] }` | `[1,2,3]` |
| `reverse` | `{ "reverse": [[1,2,3]] }` | `[3,2,1]` |

### 5.7 类型转换

`to_string`, `to_int`, `to_double`

### 5.8 数学

`min`, `max`, `abs`

---

## 6. UI 定义

### 6.1 Screen 配置

```json
"ui": {
  "screens": [
    {
      "id": "home",
      "title": "首页",
      "layout": "column",
      "padding": 16,
      "backgroundColor": "#F8F9FE",
      "children": [ ... ]
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | string | 页面唯一标识 |
| `title` | string | AppBar 标题 |
| `layout` | string | `column`(默认) / `row` / `stack` |
| `padding` | number | 内边距 (dp) |
| `backgroundColor` | string | 页面背景色 (`#RRGGBB` / `#AARRGGBB`) |
| `children` | array | 子控件列表 |

### 6.2 position 字段

每个控件都支持 `position` 字段：

| type | 说明 | 附加字段 |
|------|------|----------|
| `relative` | 顺序排列（默认） | — |
| `absolute` | 绝对定位（需 `layout=stack`） | `top`, `left`, `bottom`, `right` |
| `flex` | 弹性布局 | `flex` (数字) |

### 6.3 Widget 类型完整映射表

| type | Flutter Widget | 必填字段 | 可选字段 |
|------|----------------|----------|----------|
| `text` | `Text` | `value` | `style` |
| `button` | `FilledButton` / `OutlinedButton` / `TextButton` | `label` | `action`, `variant`, `icon`, `style`, `disabled` |
| `input` | `TextField` | `placeholder` / `bind` | `maxLines`, `keyboardType`, `obscureText`, `prefix`, `suffix`, `prefixIcon`, `suffixIcon`, `label`, `style` |
| `list` | `ListView.builder` | `source`, `item_template` | — |
| `container` | `Container` | `children` | `layout`, `color`, `padding`, `margin`, `borderRadius`, `border`, `elevation`, `width`, `height` |
| `divider` | `Divider` | — | `height`, `thickness`, `color`, `indent` |
| `image` | `Image.network` | `url` | `fit`, `width`, `height`, `borderRadius` |
| `spacer` | `SizedBox` | — | `height`, `width` |
| `switch` | `Switch` | `bind` | `label`, `action` |
| `image_picker` | `ImagePicker` | `bind` | `source`(gallery/camera), `placeholder`, `width`, `height`, `borderRadius` |
| `video` | `Chewie` + `VideoPlayer` | `url` | `autoplay`, `looping`, `aspectRatio`, `borderRadius` |
| `icon` | `Icon` | `name` | `size`, `color` |
| `card` | `Card` | `children` | `layout`, `padding`, `margin`, `elevation`, `borderRadius`, `color`, `onTap`, `crossAxisAlignment`, `mainAxisAlignment` |
| `checkbox` | `Checkbox` | `bind` | `label`, `action`, `disabled`, `color` |
| `expanded` | `Expanded` | `child` | `flex` |
| `loading` | `CircularProgressIndicator` / `LinearProgressIndicator` | — | `kind`(circular/linear), `size`, `color`, `value`, `strokeWidth`, `label` |
| `dropdown` | `DropdownButtonFormField` | `bind`, `options` | `placeholder`, `label`, `disabled`, `prefixIcon`, `color`, `action` |
| `radio` | `Radio` 组 | `bind`, `options` | `layout`(column/row), `disabled`, `color`, `action` |
| `wrap` | `Wrap` | `children` | `spacing`, `runSpacing`, `direction`, `alignment`, `runAlignment`, `crossAlignment` |
| `grid` | `GridView.builder` | `source`, `item_template` | `crossAxisCount`, `spacing`, `crossAxisSpacing`, `mainAxisSpacing`, `childAspectRatio`, `padding`, `shrinkWrap`, `emptyText` |
| `padding` | `Padding` | `child` | `padding`, `paddingH`, `paddingV`, `paddingTop/Bottom/Left/Right` |
| `center` | `Center` | `child` | `widthFactor`, `heightFactor` |
| `align` | `Align` | `child` | `alignment`(topLeft/center/bottomRight 等), `widthFactor`, `heightFactor` |
| `flexible` | `Flexible` | `child` | `flex`, `fit`(loose/tight) |
| `stack` | `Stack` | `children` | `alignment`, `fit`(loose/expand), `clipBehavior` |
| `slider` | `Slider` | `bind` | `min`, `max`, `divisions`, `showLabel`, `color`, `disabled`, `action` |
| `date_picker` | 触发 `showDatePicker` 的输入框 | `bind` | `placeholder`, `label`, `prefixIcon`, `firstDate`, `lastDate`, `disabled`, `action` |
| `time_picker` | 触发 `showTimePicker` 的输入框 | `bind` | `placeholder`, `label`, `prefixIcon`, `disabled`, `action` |
| `tooltip` | `Tooltip` | `message`, `child` | `preferBelow`, `waitDuration`, `showDuration` |
| `chip` | `Chip` / `ChoiceChip` / `FilterChip` | `label` | `variant`(chip/choice/filter), `bind`, `value`, `icon`, `action`, `color`, `deletable` |
| `badge` | `Badge` | `child` | `count`, `label`, `color`, `textColor`, `isLabelVisible` |
| `avatar` | `CircleAvatar` | — | `url`, `text`(无图时取首字母), `size`, `color`, `textColor` |
| `rich_text` | `Text.rich` | `spans` | `style`(默认), `textAlign` |
| `progress` | `LinearProgressIndicator` | — | `value`, `color`, `backgroundColor`, `height`, `width`, `borderRadius` |
| `inkwell` | `InkWell` (含 Material 包裹) | `child` | `onTap`, `onLongPress`, `onDoubleTap`, `borderRadius`, `splashColor` |
| `gesture_detector` | `GestureDetector` | `child` | `onTap`, `onDoubleTap`, `onLongPress`, `onSwipeLeft/Right/Up/Down` |
| `dismissible` | `Dismissible` | `key`, `child` | `direction`, `onDismissed`, `confirmAction`, `background`, `secondaryBackground` |
| `draggable` | `Draggable` | `child` | `feedback`, `data`, `axis`, `onDragStarted/Completed/Canceled` |
| `refresh` | `RefreshIndicator` | `child`, `onRefresh` | `color`, `backgroundColor` |
| `tab_view` | `TabBar` + `TabBarView` | `tabs` | `initialIndex`, `isScrollable`, `color`, `backgroundColor`, `height`, `onTabChange` |
| `app_bar` | `AppBar` | — | `title`, `centerTitle`, `backgroundColor`, `color`, `elevation`, `leading`, `actions` |
| `webview` | `WebViewWidget` (webview_flutter) | `url` | `height`, `javascriptEnabled` |
| `qr_code` | `QrImageView` (qr_flutter) | `data` | `size`, `backgroundColor`, `color`, `errorCorrectionLevel`(L/M/Q/H) |
| `chart` | `LineChart` / `BarChart` / `PieChart` (fl_chart) | `data` | `kind`(line/bar/pie), `height`, `width`, `color` |
| `map` | `FlutterMap` (OSM, 无需 API key) | — | `latitude`, `longitude`, `zoom`, `markers`, `height`, `borderRadius` |
| `camera` | `CameraPreview` (camera 包) | — | `lensDirection`(back/front), `resolution`(low/medium/high/veryHigh), `height` |
| `ref` | 引用依赖模板 | `from`, `widget` | `props` |

### 6.4 button 详细属性

```json
{
  "type": "button",
  "label": "提交",
  "variant": "filled",
  "icon": "send",
  "disabled": false,
  "style": {
    "backgroundColor": "#4CAF50",
    "textColor": "#FFFFFF",
    "fontSize": 16,
    "borderRadius": 12,
    "paddingH": 24,
    "paddingV": 14
  },
  "action": { ... }
}
```

**variant**：`filled`（默认实心）/ `outlined`（描边）/ `text`（纯文字）

**icon**：Material 图标名称，支持 100+ 常用图标（home, search, add, delete, edit, save, send, settings, person, star, favorite, check, close, email, phone, lock, camera, image 等）

### 6.5 text 详细样式

```json
{
  "type": "text",
  "value": "标题文本",
  "style": {
    "fontSize": 24,
    "fontWeight": "bold",
    "color": "#333333",
    "fontStyle": "italic",
    "decoration": "underline",
    "textAlign": "center",
    "maxLines": 2,
    "overflow": "ellipsis",
    "letterSpacing": 1.5,
    "lineHeight": 1.5,
    "paddingV": 4,
    "paddingH": 8
  }
}
```

**fontWeight**：`bold` / `normal` / `w100`~`w900`
**decoration**：`underline` / `lineThrough` / `overline`
**textAlign**：`left` / `center` / `right` / `justify`
**overflow**：`ellipsis` / `clip` / `fade`

### 6.6 input 详细属性

```json
{
  "type": "input",
  "placeholder": "请输入邮箱",
  "label": "邮箱地址",
  "bind": "$.global.email",
  "keyboardType": "email",
  "maxLines": 1,
  "obscureText": false,
  "prefixIcon": "email",
  "style": {
    "borderRadius": 12,
    "fontSize": 15,
    "fillColor": "#F5F5F5"
  }
}
```

**keyboardType**：`text`(默认) / `number` / `email` / `phone` / `url` / `multiline`

### 6.7 container 详细属性

```json
{
  "type": "container",
  "layout": "column",
  "color": "#F0F4FF",
  "padding": 16,
  "margin": 8,
  "borderRadius": 12,
  "elevation": 2,
  "border": { "color": "#CCCCCC", "width": 1 },
  "width": 300,
  "height": 200,
  "children": [ ... ]
}
```

### 6.8 action 与双向绑定

**action 格式**：

```json
"action": {
  "type": "call",
  "call": "@global.submitForm",
  "args": { "name": "{{ global.username }}" }
}
```

或导航（支持依赖页面 `depName:screenId`）：
```json
"action": { "type": "navigate", "screen": "detail" }
"action": { "type": "navigate", "screen": "auth:loginPage" }
```

**双向绑定**：`"bind": "global.xxx"` 使 input / switch 的值与变量实时同步。

### 6.9 icon 控件 — 图标

```json
{
  "type": "icon",
  "name": "favorite",
  "size": 32,
  "color": "#E91E63"
}
```

**name** 必须是 `IconRegistry` 中定义的名称（home / search / add / delete / edit / save / send / settings / person / star / favorite / check / close / email 等 100+ 个）。未识别的名称会显示 `help_outline` 占位。

### 6.10 card 控件 — 卡片容器

```json
{
  "type": "card",
  "layout": "column",
  "elevation": 4,
  "borderRadius": 16,
  "padding": 20,
  "margin": 12,
  "color": "#FFFFFF",
  "onTap": { "type": "navigate", "screen": "detail" },
  "children": [
    { "type": "text", "value": "标题" },
    { "type": "text", "value": "副标题" }
  ]
}
```

`Card` 与 `container` 的区别：默认带阴影 + 圆角 + 自动剪裁，更适合内容卡片场景。`onTap` 自带波纹效果。

### 6.11 checkbox 控件 — 复选框

```json
{
  "type": "checkbox",
  "bind": "global.agreed",
  "label": "我已阅读并同意用户协议",
  "action": { "type": "call", "call": "@global.onAgreeChange" },
  "disabled": false,
  "color": "#6C5CE7"
}
```

与 `switch` 用法相同，区别在表现形式（方框 vs 滑动开关）。

### 6.12 expanded 控件 — 弹性占位

```json
{
  "type": "container",
  "layout": "row",
  "children": [
    { "type": "icon", "name": "search" },
    {
      "type": "expanded",
      "flex": 1,
      "child": { "type": "input", "placeholder": "搜索…", "bind": "global.q" }
    },
    { "type": "button", "label": "搜索" }
  ]
}
```

只能用在 `Row` / `Column` 内部。等价于在子控件上设 `position.type=flex`，但写法更直观。

### 6.13 loading 控件 — 加载指示器

```json
{
  "type": "loading",
  "kind": "circular",
  "size": 48,
  "color": "#6C5CE7",
  "strokeWidth": 4,
  "label": "正在加载…"
}
```

```json
{
  "type": "loading",
  "kind": "linear",
  "value": 0.65,
  "color": "#00B894",
  "size": 200
}
```

- `kind`：`circular`（默认，圆形）/ `linear`（横条）
- `value`：0~1 之间，**不传 = 不确定进度**（无限旋转），传了 = 确定进度
- `label`：可选文字，仅 `circular` 时显示在下方

### 6.14 dropdown 控件 — 下拉选择

```json
{
  "type": "dropdown",
  "bind": "global.gender",
  "label": "性别",
  "placeholder": "请选择",
  "prefixIcon": "person",
  "options": [
    { "label": "男", "value": "male" },
    { "label": "女", "value": "female" },
    { "label": "其他", "value": "other" }
  ],
  "action": { "type": "call", "call": "@global.onGenderChange" }
}
```

`options` 支持两种格式：
- `[{label, value}]` — 显示文本与绑定值不同
- `["a", "b", "c"]` — 文本即值

被选中时 `bind` 变量被赋值为对应的 `value`（保留原始类型，可以是 string/num/bool 等）。

### 6.15 radio 控件 — 单选组

```json
{
  "type": "radio",
  "bind": "global.size",
  "layout": "row",
  "color": "#6C5CE7",
  "options": [
    { "label": "S", "value": "small" },
    { "label": "M", "value": "medium" },
    { "label": "L", "value": "large" }
  ]
}
```

整组单选按钮，`bind` 绑定当前选中的 value。`layout`：`column`（默认，一项一行）或 `row`（自动换行）。

### 6.16 wrap 控件 — 自动换行

```json
{
  "type": "wrap",
  "spacing": 8,
  "runSpacing": 8,
  "alignment": "start",
  "children": [
    { "type": "button", "label": "标签 1", "variant": "outlined" },
    { "type": "button", "label": "标签 2", "variant": "outlined" },
    { "type": "button", "label": "标签 3", "variant": "outlined" }
  ]
}
```

子项排到一行放不下时自动换行，常用于标签云、筛选条、按钮组。

- `spacing`：同行子项间距（默认 8）
- `runSpacing`：行间距（默认 8）
- `alignment`：`start` / `center` / `end` / `spaceBetween` / `spaceAround` / `spaceEvenly`
- `direction`：`horizontal`（默认）/ `vertical`

### 6.17 grid 控件 — 网格布局

```json
{
  "type": "grid",
  "source": "{{ global.products }}",
  "crossAxisCount": 3,
  "spacing": 12,
  "childAspectRatio": 0.75,
  "shrinkWrap": true,
  "padding": 12,
  "item_template": {
    "type": "card",
    "padding": 8,
    "margin": 0,
    "children": [
      { "type": "image", "url": "{{ loop.item.image }}" },
      { "type": "text", "value": "{{ loop.item.name }}" }
    ]
  }
}
```

数据驱动的网格，渲染 `source` 数组的每一项 → `item_template`。在循环上下文里通过 `{{ loop.item }}` / `{{ loop.index }}` 访问当前项。

- `crossAxisCount`：列数（默认 2）
- `childAspectRatio`：子项宽高比（默认 1）
- `spacing` 一次设置横纵两个方向；也可分别用 `crossAxisSpacing`、`mainAxisSpacing`
- `shrinkWrap`：放进 ScrollView/Column 内时设 `true`，避免高度无限或冲突；独占整屏时留 `false`（默认走 Expanded）

### 6.18 padding 控件 — 内边距

```json
{ "type": "padding", "padding": 16, "child": { ... } }
{ "type": "padding", "paddingH": 24, "paddingV": 8, "child": { ... } }
{ "type": "padding", "paddingTop": 12, "paddingBottom": 4, "child": { ... } }
```

`padding` 一次设置四个方向；`paddingH`/`paddingV` 横纵分组；`paddingTop`/`Bottom`/`Left`/`Right` 单独设置。优先级：单边 > 横纵 > all。

### 6.19 center 控件 — 居中

```json
{ "type": "center", "child": { "type": "text", "value": "居中文字" } }
```

可选 `widthFactor` / `heightFactor`（子项宽/高的倍数）。

### 6.20 align 控件 — 对齐

```json
{
  "type": "align",
  "alignment": "bottomRight",
  "child": { "type": "icon", "name": "favorite" }
}
```

`alignment`：`topLeft` / `topCenter` / `topRight` / `centerLeft` / `center` / `centerRight` / `bottomLeft` / `bottomCenter` / `bottomRight`。

### 6.21 flexible 控件 — 灵活占位

```json
{
  "type": "flexible",
  "flex": 2,
  "fit": "loose",
  "child": { "type": "text", "value": "可大可小" }
}
```

与 `expanded` 的区别：`fit=loose`（默认）允许子项小于剩余空间；`fit=tight` 强制填满（等价 `Expanded`）。

### 6.22 stack 控件 — 堆叠布局

```json
{
  "type": "stack",
  "children": [
    { "type": "image", "url": "...", "width": 200, "height": 200 },
    {
      "type": "icon",
      "name": "favorite",
      "color": "#FF5252",
      "position": { "type": "absolute", "top": 8, "right": 8 }
    }
  ]
}
```

子项默认按 `alignment`（默认 `topStart`）排列；要精确定位，给子项加 `position.type=absolute` + `top`/`left`/`bottom`/`right`（已有的位置系统直接复用）。

### 6.23 slider 控件 — 滑块

```json
{
  "type": "slider",
  "bind": "global.volume",
  "min": 0,
  "max": 100,
  "divisions": 10,
  "showLabel": true,
  "color": "#6C5CE7"
}
```

`divisions` 设置后值会按整数取整。

### 6.24 date_picker / time_picker — 日期 / 时间选择器

```json
{
  "type": "date_picker",
  "bind": "global.birthday",
  "label": "生日",
  "prefixIcon": "calendar",
  "firstDate": "1900-01-01",
  "lastDate": "2030-12-31"
}
```

```json
{
  "type": "time_picker",
  "bind": "global.alarmTime",
  "label": "闹钟时间",
  "prefixIcon": "clock"
}
```

`bind` 写回字符串：date 是 `yyyy-MM-dd`，time 是 `HH:mm`。也可以用命令式 `@show_date_picker` / `@show_time_picker` 在事件回调里弹出。

### 6.25 tooltip 控件 — 工具提示

```json
{
  "type": "tooltip",
  "message": "点击查看详情",
  "child": { "type": "icon", "name": "info" }
}
```

长按或鼠标悬停 1 秒显示。

### 6.26 chip 控件 — 标签

```json
{ "type": "chip", "label": "Flutter", "icon": "tag", "deletable": true, "action": {...} }
{ "type": "chip", "label": "已读", "variant": "choice", "bind": "global.isRead", "value": true }
{ "type": "chip", "label": "前端", "variant": "filter", "bind": "global.tags", "value": "frontend" }
```

三种 variant：
- `chip`（默认）：单纯展示，可设 `deletable=true` 出现 × 按钮（点击触发 `action`）
- `choice`：单选，`bind` 通常是单一值；点击切换为 `value`
- `filter`：多选，`bind` 是 List；点击切换 `value` 是否在列表中

### 6.27 badge 控件 — 角标

```json
{
  "type": "badge",
  "count": "{{ global.unread }}",
  "color": "#E74C3C",
  "child": { "type": "icon", "name": "notification", "size": 28 }
}
```

`count > 99` 自动显示 `99+`；`count = 0` 自动隐藏。也可以用 `label` 字段显示任意文字。

### 6.28 avatar 控件 — 圆形头像

```json
{ "type": "avatar", "url": "{{ global.user.avatar }}", "size": 48 }
{ "type": "avatar", "text": "张三", "size": 40, "color": "#6C5CE7" }
```

`url` 优先；为空时用 `text` 的首字母（中文取首字、英文大写首字母）。

### 6.29 rich_text 控件 — 多样式文本

```json
{
  "type": "rich_text",
  "style": { "fontSize": 14 },
  "spans": [
    { "text": "总计 " },
    { "text": "{{ global.count }}", "style": { "fontWeight": "bold", "color": "#E74C3C" } },
    { "text": " 条结果" }
  ]
}
```

每个 span 是字符串或 `{ text, style }`；子 style 与默认 `style` 合并。

### 6.30 progress 控件 — 线性进度条

```json
{
  "type": "progress",
  "value": "{{ global.ratio }}",
  "color": "#00B894",
  "height": 8,
  "borderRadius": 4
}
```

与 `loading kind=linear` 重叠，但接口更简洁直接。

### 6.31 inkwell — 水波纹点击

```json
{
  "type": "inkwell",
  "borderRadius": 12,
  "onTap": { "type": "call", "call": "@global.openDetail" },
  "onLongPress": { "type": "call", "call": "@global.openMenu" },
  "child": { "type": "container", ... }
}
```

`Material` 已在内部包好；onTap / onLongPress / onDoubleTap 在 build 阶段预解析模板，可安全用于 list/grid 循环上下文。

### 6.32 gesture_detector — 手势检测

```json
{
  "type": "gesture_detector",
  "onSwipeLeft": { "type": "call", "call": "@global.next" },
  "onSwipeRight": { "type": "call", "call": "@global.prev" },
  "child": { ... }
}
```

不带水波纹但能识别滑动（基于 200 像素/秒阈值的 primaryVelocity）。

### 6.33 dismissible — 滑动删除

```json
{
  "type": "dismissible",
  "key": "{{ loop.item.id }}",
  "direction": "rightToLeft",
  "confirmAction": { "type": "call", "call": "@common-ui.confirmDelete", "args": { "itemName": "{{ loop.item.name }}" } },
  "onDismissed": { "type": "call", "call": "@global.removeAt", "args": { "i": "{{ loop.index }}" } },
  "child": { ... }
}
```

- `key` **必填**且需唯一，否则 Flutter 会抱怨重复 key
- `confirmAction` 调用的函数返回 `true` 或非空字符串（如 `"delete"`）才会真正执行 onDismissed
- `direction`：`leftToRight` / `rightToLeft` / `up` / `down` / `vertical` / `horizontal`(默认)
- `background` / `secondaryBackground`：滑动时露出的背景，可以是 widget 配置（默认红色 + 删除图标）

### 6.34 draggable — 可拖拽

```json
{
  "type": "draggable",
  "data": "{{ loop.item.id }}",
  "axis": "vertical",
  "feedback": { "type": "icon", "name": "drag_indicator" },
  "onDragCompleted": { "type": "call", "call": "@global.onDrop" },
  "child": { ... }
}
```

通常与上层逻辑里的 DragTarget 配合（当前框架未单独暴露 DragTarget 控件，可在后续批次补）。

### 6.35 refresh — 下拉刷新

```json
{
  "type": "refresh",
  "onRefresh": { "type": "call", "call": "@global.reload" },
  "child": { "type": "list", "source": "...", "item_template": {...} }
}
```

`child` 必须是可滚动 widget（list / grid / 内置 ScrollView）。已有 `list.onRefresh` 是同样语义，refresh 控件适合包非 list 的滚动内容。

### 6.36 tab_view — 内嵌标签页

```json
{
  "type": "tab_view",
  "height": 400,
  "tabs": [
    { "label": "首页", "icon": "home",     "content": { ...widget... } },
    { "label": "消息", "icon": "message",  "content": { ...widget... } },
    { "label": "我的", "icon": "person",   "content": { ...widget... } }
  ]
}
```

单 widget 同时管 TabBar 和 TabBarView，避免上下两层 widget 各自管理 controller 的麻烦。`height` 用于 TabBarView 高度（必须明确）。

> 提示：如果你想要的是底部 tab + 多页面切换，screen 级别的 `tabs` 配置更合适（已支持，见下文）。

### 6.37 app_bar 与 screen.appBar 配置

**作为独立 widget 嵌入 column**：
```json
{
  "type": "app_bar",
  "title": "页面标题",
  "actions": [{ "icon": "search", "action": {...} }]
}
```

**作为 screen 的顶部栏（覆写默认 AppBar）**：
```json
{
  "id": "home",
  "appBar": {
    "title": "{{ global.user.name }} 的主页",
    "backgroundColor": "#6C5CE7",
    "color": "#FFFFFF",
    "actions": [
      { "icon": "search", "action": { "type": "call", "call": "@global.openSearch" } },
      { "icon": "more",   "action": { "type": "call", "call": "@global.openMenu" } }
    ]
  },
  "children": [...]
}
```

字段：`title` / `centerTitle` / `backgroundColor` / `color`(前景) / `elevation` / `leading: {icon, action}` / `actions: [{icon, action}]`。

### 6.38 screen.drawer — 侧边栏（Scaffold 级别）

```json
{
  "id": "home",
  "drawer": {
    "header": { "type": "text", "value": "{{ global.user.name }}", "style": { "fontSize": 20, "color": "#FFFFFF" } },
    "items": [
      { "icon": "home",     "label": "首页", "action": { "type": "navigate", "screen": "home" } },
      { "icon": "settings", "label": "设置", "action": { "type": "navigate", "screen": "settings" } },
      { "icon": "logout",   "label": "退出", "action": { "type": "call", "call": "@global.logout" } }
    ]
  },
  "children": [...]
}
```

drawer 是 Scaffold 的属性，所以是 screen 级别配置。点击侧边栏的 item 会先关闭 drawer 再触发 action。

### 6.39 screen.tabs — 底部导航栏（已支持，等同 bottom_nav）

```json
{
  "id": "home",
  "title": "我的应用",
  "tabs": [
    { "label": "首页", "icon": "home",     "children": [...] },
    { "label": "消息", "icon": "message",  "children": [...] },
    { "label": "我的", "icon": "person",   "children": [...] }
  ]
}
```

每个 tab 有独立的 `children`，切换 tab 时 body 整个换。等价于其他框架的 BottomNavigationBar。

### 6.40 webview / qr_code / chart / map / camera —— 特殊控件

#### webview
```json
{ "type": "webview", "url": "https://flutter.dev", "height": 500 }
```
基于 `webview_flutter`。Android 不需额外配置（自带 INTERNET 权限）；iOS 加载 http URL 需要在 Info.plist 配置 NSAppTransportSecurity。

#### qr_code
```json
{ "type": "qr_code", "data": "https://example.com", "size": 200, "color": "#000000" }
```
仅生成。扫码功能后续可接 `mobile_scanner`。

#### chart
```json
{
  "type": "chart",
  "kind": "line",
  "height": 240,
  "color": "#6C5CE7",
  "data": [
    {"x": 0, "y": 1}, {"x": 1, "y": 3}, {"x": 2, "y": 2},
    {"x": 3, "y": 5}, {"x": 4, "y": 4}
  ]
}
```
- `kind=line`：data 是 `[{x, y}]` 或 `[number]`
- `kind=bar`：data 是 `[{label, value}]`
- `kind=pie`：data 是 `[{label, value, color?}]`

#### map
```json
{
  "type": "map",
  "latitude": 39.9042,
  "longitude": 116.4074,
  "zoom": 12,
  "height": 320,
  "markers": [
    { "latitude": 39.9042, "longitude": 116.4074, "label": "北京" },
    { "latitude": 39.9700, "longitude": 116.3000 }
  ]
}
```
基于 OpenStreetMap，**无需 API key**。

#### camera
```json
{ "type": "camera", "lensDirection": "back", "resolution": "medium", "height": 360 }
```
**需要平台权限**：
- Android：`AndroidManifest.xml` 加 `<uses-permission android:name="android.permission.CAMERA"/>`
- iOS：`Info.plist` 加 `NSCameraUsageDescription`

只需"拍照存路径"用 `image_picker`（source=camera）更简单，本控件做实时预览。

### 6.41 ref 控件 — 引用依赖模板

```json
{
  "type": "ref",
  "from": "common-ui",
  "widget": "userCard",
  "props": {
    "name": "{{ global.userName }}",
    "avatar": "{{ global.avatarUrl }}"
  }
}
```

引用的 widget 模板定义在依赖模块的 `ui.templates` 中：

```json
"ui": {
  "templates": {
    "userCard": {
      "props": ["name", "avatar"],
      "root": {
        "type": "container",
        "layout": "row",
        "children": [
          { "type": "image", "url": "{{ props.avatar }}", "width": 40, "height": 40, "borderRadius": 20 },
          { "type": "text", "value": "{{ props.name }}", "style": { "fontSize": 16 } }
        ]
      }
    }
  }
}
```

`{{ props.xxx }}` 在渲染时被替换为调用方传入的 `props` 值。

---

## 7. 项目结构

```text
lib/
├── main.dart                      # App 入口、Riverpod Provider、文件选择页、渲染页
└── json_ui/
    ├── interpreter.dart           # 解释器核心（async 执行引擎 + 全部内置函数 + 命名空间）
    ├── dependency_loader.dart     # 依赖加载器（下载/版本校验/循环检测/命名空间注册）
    ├── semver.dart                # 语义化版本解析和约束匹配
    ├── http_client.dart           # dio HTTP 客户端封装
    ├── widget_builder.dart        # 控件注册表 + type 分发
    └── widgets/
        ├── base_widget.dart       # 抽象基类
        ├── text_widget.dart       # Text 控件
        ├── button_widget.dart     # Button 控件（3 种 variant）
        ├── input_widget.dart      # Input 控件
        ├── list_widget.dart       # List 控件
        ├── container_widget.dart  # Container 控件
        ├── divider_widget.dart    # Divider 控件
        ├── image_widget.dart      # Image 控件（网络/本地/base64/GIF）
        ├── image_picker_widget.dart # 图片选择器
        ├── video_widget.dart      # 视频播放器（video_player + chewie）
        ├── ref_widget.dart        # Ref 控件（引用依赖模板）
        ├── spacer_widget.dart     # Spacer 控件
        ├── switch_widget.dart     # Switch 控件
        ├── icon_widget.dart       # Icon 控件
        ├── card_widget.dart       # Card 控件
        ├── checkbox_widget.dart   # Checkbox 控件
        ├── expanded_widget.dart   # Expanded 控件
        ├── loading_widget.dart    # Loading 控件
        ├── dropdown_widget.dart   # Dropdown 控件
        ├── radio_widget.dart      # Radio 单选组
        ├── wrap_widget.dart       # Wrap 自动换行
        ├── grid_widget.dart       # Grid 网格
        ├── padding_widget.dart    # Padding 内边距
        ├── center_widget.dart     # Center 居中
        ├── align_widget.dart      # Align 对齐
        ├── flexible_widget.dart   # Flexible 灵活占位
        ├── stack_widget.dart      # Stack 堆叠
        ├── slider_widget.dart     # Slider 滑块
        ├── date_picker_widget.dart # DatePicker 日期
        ├── time_picker_widget.dart # TimePicker 时间
        ├── tooltip_widget.dart    # Tooltip 工具提示
        ├── chip_widget.dart       # Chip 标签
        ├── badge_widget.dart      # Badge 角标
        ├── avatar_widget.dart     # Avatar 头像
        ├── rich_text_widget.dart  # RichText 多样式文本
        ├── progress_widget.dart   # Progress 进度条
        ├── inkwell_widget.dart    # InkWell 水波纹
        ├── gesture_detector_widget.dart # GestureDetector
        ├── dismissible_widget.dart # Dismissible 滑动删除
        ├── draggable_widget.dart  # Draggable 拖拽
        ├── refresh_widget.dart    # RefreshIndicator
        ├── tab_view_widget.dart   # TabBar + TabBarView
        ├── app_bar_widget.dart    # AppBar (含 buildAppBar 共享构建器)
        ├── drawer_helper.dart     # buildDrawer (供 screen.drawer 使用)
        ├── webview_widget.dart    # WebView 网页
        ├── qr_code_widget.dart    # QR 二维码生成
        ├── chart_widget.dart      # Chart line/bar/pie
        ├── map_widget.dart        # Map (OSM)
        ├── camera_widget.dart     # Camera 实时预览
        ├── position_handler.dart  # position 定位处理
        ├── screen_layout.dart     # Screen 布局处理
        └── icon_registry.dart     # Material 图标名称映射

tools/
└── video_server.py                # 本地视频流媒体服务器（支持 Range 请求 + /api/list）

templates/                         # JSON DSL 示例配置
├── test_collector.json            # 文本收藏夹 app
├── demo_5pages.json               # 5 页记事本 app
├── demo_media.json                # 图片+视频 demo
└── demo_video_browser.json        # 视频浏览器 app（HTTP API + 列表 + 播放）
```
