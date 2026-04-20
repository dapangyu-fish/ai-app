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
    "icon_url": "https://example.com/icon.png",
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
| `meta.icon_url` | 否 | 应用/组件的图标图片 URL，可为空 |
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
| `@take_photo` | `{ "bind": "global.photo" }` | 调用摄像头拍照，返回图片路径并绑定到变量 |
| `@pick_image` | `{ "bind": "global.photo" }` | 打开相册选择图片，返回图片路径并绑定到变量 |

**@take_photo / @pick_image 参数**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `bind` | `string` | — | 将图片路径绑定到指定变量 |
| `max_width` | `number` | `1920` | 最大宽度（像素） |
| `max_height` | `number` | `1920` | 最大高度（像素） |
| `quality` | `number` | `85` | 图片质量（1-100） |

> `@take_photo` 在摄像头不可用时自动 fallback 到相册选择。

### 4.9 随机数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `@random` | `{ "min": 1, "max": 100 }` | `int` | 随机整数 [min, max] |
| `@random_float` | `{ "min": 0.0, "max": 1.0 }` | `double` | 随机浮点数 [min, max) |
| `@random_bool` | — | `bool` | 随机布尔值 |
| `@random_chars` | `{ "length": 8, "charset": "alphanumeric" }` | `String` | 随机字符序列 |
| `@uuid` | — | `String` | 生成 UUID v4 |
| `@random_pick` | `{ "list": {expr} }` | `dynamic` | 从数组中随机取一个元素 |

**@random_chars 的 charset 选项**：

| charset | 字符集 |
|---------|--------|
| `numeric` | `0-9` |
| `alpha` | `a-z A-Z` |
| `upper` | `A-Z` |
| `lower` | `a-z` |
| `hex` | `0-9 a-f` |
| `alphanumeric`（默认） | `0-9 a-z A-Z` |

**示例**：
```json
{ "call": "@random", "args": { "min": 1, "max": 6 }, "assign": "global.dice" }
{ "call": "@random_chars", "args": { "length": 6, "charset": "numeric" }, "assign": "global.code" }
{ "call": "@uuid", "args": {}, "assign": "global.id" }
```

### 4.10 时间日期

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `@timestamp` | — | `int` | 当前毫秒时间戳 |
| `@date_format` | `{ "timestamp": 1713523200000, "format": "YYYY-MM-DD HH:mm:ss" }` | `String` | 格式化时间戳 |

**format 占位符**：`YYYY` 年、`MM` 月、`DD` 日、`HH` 时、`mm` 分、`ss` 秒

**示例**：
```json
{ "call": "@timestamp", "args": {}, "assign": "global.now" }
{ "call": "@date_format", "args": { "format": "YYYY-MM-DD" }, "assign": "global.today" }
```

### 4.11 字符串扩展

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `@str_repeat` | `{ "value": "ab", "count": 3 }` | `"ababab"` | 重复字符串 |
| `@str_reverse` | `{ "value": "hello" }` | `"olleh"` | 反转字符串 |
| `@str_pad` | `{ "value": "5", "length": 4, "pad": "0", "direction": "left" }` | `"0005"` | 字符串补位 |
| `@str_join` | `{ "list": ["a","b"], "separator": "," }` | `"a,b"` | 数组连接为字符串 |
| `@str_capitalize` | `{ "value": "hello" }` | `"Hello"` | 首字母大写 |
| `@str_count` | `{ "value": "hello", "search": "l" }` | `2` | 统计子串出现次数 |
| `@str_index_of` | `{ "value": "hello", "search": "l" }` | `2` | 首次出现位置 |
| `@str_last_index_of` | `{ "value": "hello", "search": "l" }` | `3` | 最后出现位置 |
| `@str_between` | `{ "value": "<b>hi</b>", "start": "<b>", "end": "</b>" }` | `"hi"` | 提取两标记间文本 |
| `@str_mask` | `{ "value": "13812345678", "start": 3, "end": 7, "mask": "*" }` | `"138****5678"` | 字符串脱敏 |

**@str_pad 的 direction**：`left`（左补位）/ `right`（右补位，默认）

### 4.12 数组扩展

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `@list_shuffle` | `{ "var": "global.list" }` | `List` | 随机打乱数组（原地修改） |
| `@list_sample` | `{ "var": "global.list", "count": 3 }` | `List` | 随机取 N 个元素（不修改原数组） |
| `@list_unique` | `{ "var": "global.list" }` | `List` | 数组去重（原地修改） |
| `@list_flatten` | `{ "var": "global.list", "depth": 1 }` | `List` | 数组扁平化（原地修改） |
| `@list_sort` | `{ "var": "global.list", "key": "age", "desc": true }` | `List` | 排序（原地修改） |
| `@list_reverse` | `{ "var": "global.list" }` | `List` | 反转数组（原地修改） |
| `@list_slice` | `{ "var": "global.list", "start": 1, "end": 4 }` | `List` | 切片（原地修改） |

### 4.13 本地存储

| 函数 | 参数 | 说明 |
|------|------|------|
| `@storage_set` | `{ "key": "userName", "value": "张三" }` | 写入本地存储 |
| `@storage_get` | `{ "key": "userName" }` | 读取本地存储 |
| `@storage_remove` | `{ "key": "userName" }` | 删除指定 key |
| `@storage_clear` | — | 清空所有本地存储 |

### 4.14 用户信息

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `@get_user` | — | `Map?` | 获取当前登录用户信息（id, email, username, avatar_url 等），未登录返回 null |
| `@get_user_token` | — | `String?` | 获取当前用户的 access token，未登录返回 null |
| `@is_logged_in` | — | `bool` | 判断用户是否已登录 |
| `@logout` | — | `null` | 登出当前用户 |
| `@refresh_user` | — | `Map?` | 从后端重新获取最新用户信息，失败返回 null |
| `@update_profile` | `{ "username": "新名称", "avatar_url": "https://..." }` | `Map` | 更新用户名或头像 URL，失败返回含 error 字段 |
| `@upload_avatar` | `{ "base64": "..." }` | `String?` | 上传 base64 头像，返回头像 URL，失败返回 null |

**@get_user 返回字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `String` | 用户唯一 ID |
| `email` | `String` | 邮箱 |
| `username` | `String` | 用户名 |
| `avatar_url` | `String?` | 头像 URL |

**示例**：
```json
{ "call": "@get_user", "args": {}, "assign": "global.user" }
{ "call": "@is_logged_in", "args": {}, "assign": "global.logged_in" }
{ "call": "@update_profile", "args": { "username": "{{ global.new_name }}" }, "assign": "global.result" }
```

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

### 6.9 ref 控件 — 引用依赖模板

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
        ├── position_handler.dart  # position 定位处理
        ├── screen_layout.dart     # Screen 布局处理
        └── icon_registry.dart     # Material 图标名称映射

tools/
└── video_server.py                # 本地视频流媒体服务器（支持 Range 请求 + /api/list）

templates/                         # JSON DSL 示例配置
├── test_collector.json            # 文本收藏夹 app
├── demo_5pages.json               # 5 页记事本 app
├── demo_media.json                # 图片+视频 demo
├── demo_video_browser.json        # 视频浏览器 app（HTTP API + 列表 + 播放）
├── demo_super_app.json            # Super App（Tab 导航 + 本地存储）
├── demo_with_deps.json            # 依赖引用 demo（引用 common-ui）
├── xiaohongshu-demo.json          # 小红书风格 demo
├── lib_common_ui.json             # 通用 UI 函数库（toast/confirm/格式化）
└── lib_data_utils.json            # 数据处理工具库（随机/UUID/时间/字符串/数组）
```

---

## 8. 官方组件库

### 8.1 data-utils — 数据处理工具库

**模块名**：`data-utils`
**版本**：`1.0.0`
**类型**：`library`
**依赖声明**：
```json
"dependencies": {
  "data-utils": {
    "url": "https://app-backend.dapangyu.work/download/lib_data_utils.json",
    "version": "^1.0.0"
  }
}
```

#### 随机数函数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `randomInt` | `min`, `max` | `int` | 随机整数 [min, max] |
| `randomFloat` | `min`, `max` | `double` | 随机浮点数 [min, max) |
| `randomBool` | — | `bool` | 随机布尔值 |
| `randomChars` | `length`, `charset` | `String` | 随机字符序列 |
| `randomCode` | `length` | `String` | 随机数字验证码 |
| `randomHex` | `length` | `String` | 随机十六进制字符串 |
| `uuid` | — | `String` | 生成 UUID v4 |
| `randomPick` | `list` | `dynamic` | 从数组中随机取一个元素 |

#### 时间日期函数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `timestamp` | — | `int` | 当前毫秒时间戳 |
| `dateFormat` | `timestamp`, `format` | `String` | 格式化时间戳 |
| `nowFormatted` | `format` | `String` | 当前时间格式化 |

#### 字符串处理函数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `strRepeat` | `value`, `count` | `String` | 重复字符串 |
| `strReverse` | `value` | `String` | 反转字符串 |
| `strPadLeft` | `value`, `length`, `pad` | `String` | 左补位 |
| `strPadRight` | `value`, `length`, `pad` | `String` | 右补位 |
| `strJoin` | `list`, `separator` | `String` | 数组连接为字符串 |
| `strCapitalize` | `value` | `String` | 首字母大写 |
| `strCount` | `value`, `search` | `int` | 统计子串出现次数 |
| `strIndexOf` | `value`, `search` | `int` | 首次出现位置 |
| `strLastIndexOf` | `value`, `search` | `int` | 最后出现位置 |
| `strBetween` | `value`, `start`, `end` | `String` | 提取两标记间文本 |
| `strMask` | `value`, `start`, `end`, `mask` | `String` | 自定义脱敏 |
| `strMaskPhone` | `phone` | `String` | 手机号脱敏 `138****5678` |
| `strMaskEmail` | `email` | `String` | 邮箱脱敏 `z***@example.com` |
| `strMaskCard` | `cardNo` | `String` | 银行卡号脱敏 |

#### 数组处理函数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `listShuffle` | `var` | `List` | 随机打乱数组 |
| `listSample` | `var`, `count` | `List` | 随机取 N 个元素 |
| `listUnique` | `var` | `List` | 数组去重 |
| `listFlatten` | `var`, `depth` | `List` | 数组扁平化 |
| `listSort` | `var`, `key`, `desc` | `List` | 排序（key 为对象属性名，desc 为是否降序） |
| `listReverse` | `var` | `List` | 反转数组 |
| `listSlice` | `var`, `start`, `end` | `List` | 切片 |

#### 组合工具函数

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `generateId` | `prefix` | `String` | 生成带前缀的唯一 ID（时间戳+随机数） |
| `generateOrderNo` | — | `String` | 生成订单号 `ORD20260419123456789012` |

#### 使用示例

```json
{
  "dependencies": {
    "data-utils": {
      "url": "https://app-backend.dapangyu.work/download/lib_data_utils.json",
      "version": "^1.0.0"
    }
  },
  "steps": [
    { "call": "@data-utils.randomInt", "args": { "min": 1, "max": 100 }, "assign": "global.luckyNumber" },
    { "call": "@data-utils.uuid", "args": {}, "assign": "global.sessionId" },
    { "call": "@data-utils.randomCode", "args": { "length": 6 }, "assign": "global.verifyCode" },
    { "call": "@data-utils.nowFormatted", "args": { "format": "YYYY-MM-DD HH:mm:ss" }, "assign": "global.currentTime" },
    { "call": "@data-utils.strMaskPhone", "args": { "phone": "13812345678" }, "assign": "global.maskedPhone" },
    { "call": "@data-utils.generateOrderNo", "args": {}, "assign": "global.orderNo" }
  ]
}
```
