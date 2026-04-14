# Flutter JSON Low-Code DSL 完整开发文档 v3.2

**文档版本**：v3.2
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

---

## 2. 系统架构

```text
[云端 / 本地文件] ── JSON 配置 ──→ [Flutter App]
│
[JsonInterpreter (Dart)]
│
├── ExpressionEngine    (JsonLogic 表达式引擎)
├── DslHttpClient       (HTTP 网络层, 基于 dio)
├── JsonWidgetBuilder   (控件注册表 + 分发)
│   └── widgets/        (各类控件实现)
└── 状态管理            (Riverpod ChangeNotifierProvider)
```

---

## 3. JSON DSL 规范

### 3.1 顶级结构

```json
{
  "version": "3.2",
  "meta": {
    "name": "应用名",
    "description": "应用描述",
    "author": "作者"
  },
  "global": { ... },
  "steps": [ ... ],
  "ui": { ... }
}
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

**变量路径支持嵌套**：`$.global.user.name` 可读写深层属性。

### 3.3 steps（业务逻辑）

```json
"steps": [
  { "call": "@print", "args": { "value": "启动" } },
  { "call": "@http_get", "args": { "url": "https://api.example.com/data" }, "assign": "$.global.apiResult" },
  { "expression": { "+": [1, 2, 3] }, "assign": "$.global.sum" }
]
```

每个 step 支持：
- **函数调用**：`{ "call": "...", "args": {...}, "assign": "$.global.xxx" }`
- **表达式**：`{ "expression": {JsonLogic}, "assign": "$.global.xxx" }`

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
| `@show_dialog` | `{ "title": "确认", "message": "确定删除？" }` | 弹窗，返回 `true`/`false` |

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
  "args": { "name": "{{ $.global.username }}" }
}
```

或导航：
```json
"action": {
  "type": "navigate",
  "screen": "detail"
}
```

**双向绑定**：`"bind": "$.global.xxx"` 使 input / switch 的值与变量实时同步。

---

## 7. 项目结构

```text
lib/
├── main.dart                      # App 入口、Riverpod Provider、文件选择页、渲染页
└── json_ui/
    ├── interpreter.dart           # 解释器核心（async 执行引擎 + 全部内置函数）
    ├── expression_engine.dart     # JsonLogic 表达式引擎
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
        ├── image_widget.dart      # Image 控件
        ├── spacer_widget.dart     # Spacer 控件
        ├── switch_widget.dart     # Switch 控件
        ├── position_handler.dart  # position 定位处理
        ├── screen_layout.dart     # Screen 布局处理
        └── icon_registry.dart     # Material 图标名称映射
```
