# Flutter JSON Low-Code DSL 完整开发文档 v3.4

**文档版本**：v3.4
**制定日期**：2026年5月
**状态**：正式发布
**适用范围**：Flutter 跨平台 GUI 客户端（iOS / Android / Web / Desktop）
**目标**：一套**纯 JSON 配置驱动**的低代码 Flutter 应用，支持动态下发 UI 与业务逻辑。

> 说明：文档版本是 v3.4；当前 JSON 包里的 `"dsl"` 字段仍使用 `"3.3"`，表示运行时兼容线，不需要改成文档版本号。

---

## 1. 设计原则

- **Server-Driven UI**：云端下发 JSON，App 内置解释器实时渲染界面并执行逻辑。
- **图灵完备**：支持 `@while`、递归、`@set` 可变状态、`@if` 条件分支、`@parallel` 并发。
- **安全合规**：解释器纯 Dart 静态编译进 APK/IPA，JSON 仅为数据配置。
- **性能边界清晰**：框架不对页面层级 / Widget 数量做人为配额限制，但运行时仍受设备性能约束；`@while` 有 `max_iterations` 保护，游戏逐帧 logic 应控制实体规模。
- **位置描述**：每个控件可加 `position`；`absolute` 只在 `Stack` 父级下生效，`flex` 只应放在 `Row` / `Column` 等 Flex 父级下。

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
    "displayName": "我的应用",
    "version": "1.0.0",
    "type": "app",
    "description": "应用描述",
    "author": "作者",
    "exports": []
  },
  "dependencies": {
    "common-ui": "^1.3.0"
  },
  "assets": { ... },
  "global": { ... },
  "steps": [ ... ],
  "ui": { ... }
}
```

| 字段 | 必须 | 说明 |
|------|------|------|
| `dsl` | 是 | DSL 规范版本（如 `"3.3"`），兼容旧 `version` 字段 |
| `appid` | 否 | 应用唯一标识（UUID，发布时必须，新创建可留空） |
| `meta.name` | 是 | 模块唯一标识（包名），用于路由 / 依赖引用 / 安装路径；正常展示应使用 `meta.displayName`，仅在 displayName 缺省时作为兜底 |
| `meta.displayName` | 否 | 用户可见的应用名称。支持纯字符串或多语言 Map（见下）。缺省时框架回退到 `meta.name` |
| `meta.version` | 是 | 模块版本号（semver: `MAJOR.MINOR.PATCH`） |
| `meta.type` | 是 | `app`（完整应用）/ `library`（函数/页面集合）/ `widget`（可复用控件模板） |
| `meta.exports` | 否 | library/widget 暴露给外部的函数名和页面 ID 列表 |
| `dependencies` | 否 | 依赖声明，key 必须是 Registry 包名，同时也是调用命名空间（如 `@common-ui.showInfo` 的 `common-ui`）；value 推荐写版本约束字符串（如 `"^1.3.0"`）。也兼容旧对象格式 `{ "url": "...", "version": "^1.2.0" }`，但当前加载器实际按 Registry/CacheManager 解析，`url` 仅保留旧格式兼容 |
| `assets` | 否 | 资源声明区。游戏/媒体类 APP 推荐声明 `assets.bundles`，让客户端启动时缓存远程资源 |

#### `meta.displayName` 两种写法

**纯字符串**（不分语言，所有 locale 显示同一个）：
```json
"meta": { "name": "todo-app", "displayName": "Todo Master" }
```

**多语言 Map**（按当前 locale 取，找不到回退）：
```json
"meta": {
  "name": "todo-app",
  "displayName": {
    "zh": "待办清单",
    "en": "Todo List",
    "default": "Todo"
  }
}
```

查找顺序：精确 BCP 47 tag（如 `zh-CN`） → 语言（`zh`） → `default` → 第一个非空 → `meta.name` → `"JSON App"`

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
{ "call": "@common-ui.showInfo", "args": { "message": "操作成功" } }

// 导航到依赖的页面: depName:screenId
{ "type": "navigate", "screen": "auth:loginPage" }

// 引用依赖的控件模板: ref
{ "type": "ref", "from": "common-ui", "widget": "userCard", "props": { "name": "张三" } }

// 读取依赖的变量（只读）: depName.varPath
"{{ common-ui.theme.primaryColor }}"
```

#### assets.bundles 与素材 manifest

游戏、动画和媒体类 APP 推荐声明所使用的托管素材包：

```json
"assets": {
  "bundles": {
    "kenney_new_platformer": {
      "baseUrl": "https://myapp-oss-endpoint.dapangyu.work/json-app-assets/asset-packs/kenney-new-platformer-pack/1.1/",
      "manifest": "manifest.json",
      "license": "LICENSE",
      "startupDownload": true
    }
  }
}
```

素材包 manifest 是选材和裁剪的事实依据。Agent / 人工编写游戏时应优先读取：

| 字段 | 说明 |
|------|------|
| `files[].image.width/height` | 图片真实像素尺寸 |
| `files[].sprite.kind` | `single` / `grid` / `strip` / `atlas` / `unknown_sheet` |
| `files[].sprite.frameWidth/frameHeight` | 一帧的真实尺寸 |
| `files[].sprite.columns/rows/frames` | 网格/横条 sprite sheet 的行列和帧数 |
| `files[].atlas.entries[]` | XML atlas 解析出的 `SubTexture` 裁剪框 |

如果 manifest 没有 `sprite` / `atlas` 字段，不能凭文件名猜 3x3、8x8 或 64x64。应选择单帧素材，或先读取 PNG 尺寸并明确推断依据，最终必须通过 `backend/validate_json_app.py` 的 sprite 边界校验。单帧 PNG 的 `frame_size` 默认应等于 `files[].image.width/height`；只有确认透明边界时，才用 `src` 显式裁剪。

#### Agent 生成辅助库

后端 Agent 生成复杂 APP 时可以使用 `backend/json_app_builder.py` 作为临时 Python 生成器的辅助库。它不是客户端运行时能力，只用于降低生成 JSON 的出错率。

推荐使用场景：`flame_game`、Tiled 地图、长关卡、大量实体、重复 UI、素材 manifest 选材和 sprite sheet 切帧。生成器应输出最终 JSON 后继续运行 `python3 backend/validate_json_app.py <TMPFILE>`。

常用 helper：

| helper | 用途 |
|--------|------|
| `new_app/screen/text/container/expanded/flame_game` | 生成标准 DSL 结构和基础控件 |
| `pixel_entity/sprite_entity/animated_sprite_entity/parallax_entity/tiled_map_entity` | 生成 `flame_game.entities` 的标准实体结构 |
| `AssetPack.from_url/url/frame_size/animation` | 从 manifest 取资源 URL、单帧尺寸、动画配置 |
| `asset_bundle` | 生成 `assets.bundles` |
| `tile_layer/fill_rect/set_tile/object_layer/tiled_object/tileset/tiled_map` | 生成内联 `tiled-json-v1` 地图 |
| `run_and_gun_stage_plan/tiled_objects_from_run_and_gun_plan` | 生成中立 run-and-gun 关卡骨架和 object layer，避免复制第三方地图 |
| `save_json(app, out, packs=[pack])` | 写出 JSON，并校验资源 URL 来自所选 manifest |

`run_and_gun_stage_plan()` 不是客户端 atom，也不是某个游戏的地图数据。它只给后端
Agent 一个中立关卡节奏骨架：安全开场、首次接敌、掩体交火、坑洞/平台、纵向压力和终点冲刺。
生成器仍必须用所选 asset manifest 填充 tileset、角色、敌人、背景和装饰；不能把 demo 的坐标、
素材路径或第三方地图文件直接复制进新 APP。

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
**支持 List 下标**：路径里的数字段当 List 索引，例如 `global.board.5` 读 `board[5]`，`@set var="global.board.{{ idx }}"` 写 `board[idx]`。读越界 / 不能解析为 int 返回 `null`；写越界静默 no-op（List 不像 Map 会自动扩展）。Map 优先匹配——如果某层是 Map 且有名为 `"5"` 的 key，仍走 Map 分支，不会误判成 List。

### 3.3 值类型规则（核心约定）

在 `args` 中，值的写法决定了解释器如何处理它：

| 写法 | 类型 | 解释器行为 | 示例 |
|------|------|-----------|------|
| `"hello"` | 原始字符串 | 直接使用 | `"value": "hello"` |
| `123` / `true` / `[]` | 原始值 | 直接使用 | `"value": []` |
| `"{{ path }}"` | 模板引用 | 解析为变量的**原始类型**（List/Map/String 等） | `"value": "{{ global.list }}"` → 实际 List |
| `"前缀 {{ path }} 后缀"` | 模板插值 | 解析为**字符串**（变量 toString 后拼接） | `"value": "共 {{ global.count }} 条"` → `"共 5 条"` |
| `{ "op": [...] }` 单 key + key 在 op 集合 | JsonLogic 表达式 | 通过 jsonlogic 引擎**求值** | `"value": { "merge": [...] }` |
| `{ "key": ..., "key2": ... }` 数据 Map | 普通数据对象 | **原样传递**，递归展开内部 `{{ }}` 模板，不走 jsonlogic | `"item": { "id": "{{ loop.index }}", "name": "..." }` |

**关键区分**：
- `"{{ global.items }}"` → 返回 items 变量本身（可能是 List、Map、数字等，保留原始类型）
- `{ "var": "global.items" }` → 通过 jsonlogic 引擎求值，效果相同但更明确
- `"总数: {{ global.count }}"` → 返回字符串 `"总数: 5"`（混合文本，强制 String）

**作用域不在时模板原文保留**：
当模板引用的是 `loop.*` / `event.*`，而当前没有对应作用域（`_loopContextStack` / `_eventContextStack` 为空），引擎会**保留模板原文**而不是返回 null。典型场景：把 widget JSON 通过函数参数传给 helper（如 `@common-ui.showSheet({content: {type: "list", item_template: {... {{ loop.item.x }} ...}}})`），`item_template` 里的 `{{ loop.item.x }}` 在 `_resolveArgs` 阶段还没 loop 上下文，原文留到 `list` 控件给每项建好上下文时再求值，结果正确。`global.*` / `params.*` 仍然在 args 解析时立刻求值（按调用方当时的作用域）。

#### Map 何时被当 jsonlogic 表达式？

引擎只对**单 key + key 在已知 op 集合**的 Map 跑 jsonlogic：
- ✅ jsonlogic：`{"if": [...]}`、`{"var": "..."}`、`{"merge": [...]}`、`{"sort": [...]}`、`{"==": [...]}` …
- ✅ 数据 Map：`{"id": 1, "name": "x"}`（多 key）、`{"display": "🐹"}`（单 key 但 `display` 不是 op）
- ⚠️ 数据 Map 但单 key 撞上 op 名：`{"in": "users"}` 会被当 `in` 表达式跑去崩。要么换键名，要么塞进多 key（`{"_kind": "data", "in": "users"}`）。

**op 集合**（写新 key 名前请确认不撞）：
`var / missing / missing_some / if / ?: / and / or / ! / !! / == / != / === / !== / < / <= / > / >= / + / - / * / / / % / min / max / cat / substr / in / map / filter / reduce / all / some / none / merge / log` ＋ 框架自定义：
`str_len / str_upper / str_lower / str_trim / str_contains / str_replace / str_split / str_join / length / at / slice / sort / reverse / to_string / to_int / to_double / abs`

> 历史背景：3.3 之前所有 Map 都被无脑送进 jsonlogic，导致 `@list_add args.item={"id":..., "display":...}` 这种正常数据对象也会抛 `JsonlogicException: operator id not defined`。修复后数据 Map 安全可用，详见 `templates/bacsase/anti_patterns_and_pitfalls.md` §6。

**HTTP 响应数据处理示例**：
```json
// 1. 发起请求，结果存入变量（返回 { status, data, headers, error }）
{ "call": "@http_get", "args": { "url": "..." }, "assign": "global.result" }

// 2. 提取 data 字段（模板引用保留原始类型）
{ "call": "@set", "args": { "var": "global.list", "value": "{{ global.result.data }}" } }

// 3. 或用 jsonlogic 表达式提取
{ "call": "@set", "args": { "var": "global.list", "value": { "var": "global.result.data" } } }
```

### 3.4 steps（业务逻辑）

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

`assign` 将表达式结果存入指定变量；函数调用的 `assign` 只在返回值非 `null` 时写入，避免取消弹窗、空网络结果等把已有状态误清空。

### 3.5 i18n（JSON 层国际化）

**核心原则：JSON-APP 的所有 UI 字符串归 JSON 自己管，加语言只改 JSON、不改框架。**

框架自身（登录页 / 设置页 / 市场页等原生 UI）的 i18n 走 `lib/i18n/framework_strings.dart`，与 JSON-APP 完全独立。

#### 字典结构

```json
"global": {
  "variables": { "locale": "zh" },      // 可选，缺省时框架按 loadConfig 注入当前 appLocale
  "i18n": {
    "zh": {
      "home": { "title": "首页", "greet": "你好, {{ global.user.name }}" },
      "logout": "退出登录"
    },
    "en": { "home": { "title": "Home", "greet": "Hi, {{ global.user.name }}" }, "logout": "Logout" },
    "de": { "home": { "title": "Startseite", "greet": "Hallo, {{ global.user.name }}" }, "logout": "Abmelden" },
    "es": { "home": { "title": "Inicio", "greet": "Hola, {{ global.user.name }}" }, "logout": "Cerrar sesión" }
  }
}
```

任意 widget 字段用 `{{ t('home.title') }}` 查表；查不到回退键名本身（**不会崩**，方便调试）。

#### 插值与嵌套

翻译值里允许嵌 `{{ ... }}` —— 命中字符串后框架会再过一次 `resolveTemplate`，把里头的变量 / 嵌套 `t()` 都解开。这是 i18n 标准做法 —— 翻译者控制变量在句子里的位置（不同语言语序不同），调用方不能强切字符串再拼接。

支持递归（`t('A')` → 含 `{{ t('B') }}`），最深 6 层防循环引用。

#### locale 来源

`global.locale` 决定查哪一档：

1. JSON-APP `global.variables.locale` 显式给了 → 用 JSON 的优先（保护 app 内的语言选择）
2. 没给 → loadConfig 时框架把当前 `appLocale` 简化（`zh-CN` → `zh`）一次性写入
3. 运行时 `@set_locale({ value: "en" })` 只改 JSON 的 `global.locale`，**不影响框架**
4. 运行时 `@set_framework_locale({ value: "en" })` **同步**框架 + JSON 的 locale（launcher 等"全局切语言"场景用这个）

#### Fallback 链

`{{ t('key.path') }}` 查找顺序：
1. 精确匹配 `global.i18n[当前 locale][key.path]`
2. 找不到 → 返回 `'key.path'` 字符串本身（**不会崩**）
3. JSON-APP 完全没写 `global.i18n` 块 → 所有 `{{ t('xxx') }}` 都返回 `'xxx'`

#### 组件库（ref）的 i18n 约定

`ref` 加载依赖模块的 widget 模板时，模板里的 `{{ t('xxx') }}` 查的是**消费方**（当前运行的 JSON-APP）的 `global.i18n`——因为框架的 `_i18nLookup` 读的是当前 interpreter 的 `_config.global.i18n`，而 ref 渲染的是同一个 interpreter。

后果：
- ✅ **lib 内不要硬编码 UI 字符串**，统一写 `{{ t('xxx') }}`
- ✅ **消费方负责提供翻译**，键名约定由 lib 文档化（例如 `launcher-settings` 用 `settings.theme` / `settings.locale` 等）
- ⚠️ **lib 自己 `global.i18n` 块** *目前不会被 ref 模板查到*——这是框架现状（lib 的 i18n 表是其模块私有；ref 渲染时 `_config` 仍是消费方）。lib 可以在 README 列清楚自己需要哪些键，消费方按需补齐。

参考实现：
- `templates/lib_launcher_settings.json`（lib：模板全用 `t()`，无硬编码字符串）
- `templates/demo_launcher.json`（消费方：`global.i18n.{zh,en,de,es}` 给 launcher-* 三个 lib 用到的所有键提供翻译）

加一种新语言（例如日语）到 launcher：
1. `demo_launcher.json` 的 `global.i18n` 加一个 `ja` 块（复制现有 zh 块翻译即可）
2. `launcher-settings` 语言 dropdown 的 options 加 `{ label: "日本語", value: "ja" }`
3. **零框架代码改动**

---

## 4. 内置函数完整列表

### 4.1 基础

| 函数 | 参数 | 说明 |
|------|------|------|
| `@print` | `{ "value": "..." }` | 调试打印 |
| `@set` | `{ "var": "global.xxx", "value": ... }` | 设置变量（value 支持 JsonLogic 表达式）。`$.global.xxx` 旧路径仍兼容，但新 JSON 统一写 `global.xxx` |
| `@var_get` | `{ "var": "global.xxx", "default": null }` | 命令式读取变量；变量不存在时返回 `default` |
| `@navigate` | `{ "screen": "screenId" }` | 页面跳转 |
| `@delay` | `{ "ms": 1000 }` | 延迟指定毫秒 |

### 4.2 控制流

| 函数 | 参数 | 说明 |
|------|------|------|
| `@if` | `{ "condition": {expr}, "then": [...], "else": [...] }` | 条件分支 |
| `@while` | `{ "condition": {expr}, "body": [...], "max_iterations": 10000 }` | 循环 |
| `@for_each` | `{ "source": {expr}, "body": [...] }` | 遍历数组（`loop.item` / `loop.index`） |
| `@loop_by_num` | `{ "count": 10, "body": [...] }` | 按次数循环 |
| `@try_catch` | `{ "try": [...], "catch": [...], "error_var": "global.err" }` | 异常捕获 |
| `@parallel` | `{ "steps": [...] }` | **并发执行**多个 step，全部完成后继续 |
| `@throw` | `{ "message": "..." }` | 主动抛出异常（用于测试 @try_catch / 业务侧失败时进入 catch 分支） |

**@if 示例**：
```json
{
  "call": "@if",
  "args": {
    "condition": { ">": [{ "var": "global.count" }, 0] },
    "then": [
      { "call": "@print", "args": { "value": "有数据" } }
    ],
    "else": [
      { "call": "@print", "args": { "value": "空" } }
    ]
  }
}
```

> 注意：上表是普通 JSON-APP 主解释器的写法。`flame_game.input` /
> `flame_game.frame` / `flame_game.tick` 内部使用轻量 GameLogicEngine，
> 其 `@if` 条件字段是 `cond`（见 flame_game 章节），不要混用。

**@parallel 示例**：
```json
{
  "call": "@parallel",
  "args": {
    "steps": [
      { "call": "@http_get", "args": { "url": "https://api1.com" }, "assign": "global.r1" },
      { "call": "@http_get", "args": { "url": "https://api2.com" }, "assign": "global.r2" }
    ]
  }
}
```

### 4.3 HTTP 请求

`@http_get` / `@http_post` / `@http_put` / `@http_delete` 返回 `{ "status": int, "data": dynamic, "headers": {}, "error": String? }`。`@http_sse` 返回 `{ "status": int, "events": [], "done": bool, "error": String? }`，并可在流式过程中触发回调。

| 函数 | 参数 | 说明 |
|------|------|------|
| `@http_get` | `{ "url": "...", "query": {...}, "headers": {...} }` | GET 请求 |
| `@http_post` | `{ "url": "...", "body": {...}, "headers": {...}, "content_type": "application/json" }` | POST 请求 |
| `@http_put` | `{ "url": "...", "body": {...}, "headers": {...} }` | PUT 请求 |
| `@http_delete` | `{ "url": "...", "headers": {...} }` | DELETE 请求 |
| `@http_sse` | `{ "url": "...", "method": "POST", "body": {...}, "headers": {...}, "bind": "global.stream", "onEvent": [...] }` | Server-Sent Events。每个事件形如 `{raw,event,id,data,json,done,delta}`；`delta` 自动兼容 OpenAI Chat Completions / Responses 常见文本增量。Web 端走浏览器兼容桥，若目标服务未配 CORS 仍会被浏览器拦截 |

**示例**：
```json
{
  "call": "@http_post",
  "args": {
    "url": "https://api.example.com/users",
    "body": {
      "name": "{{ global.username }}",
      "email": "{{ global.email }}"
    },
    "headers": { "Authorization": "Bearer {{ global.token }}" }
  },
  "assign": "global.postResult"
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
| `@list_add` | `{ "var": "global.list", "item": "xxx" }` | 向数组末尾添加元素 |
| `@list_remove_at` | `{ "var": "global.list", "index": 0 }` | 按索引删除 |
| `@list_remove` | `{ "var": "global.list", "value": "xxx" }` | 按值删除（删除所有等于 value 的元素） |
| `@list_insert` | `{ "var": "global.list", "index": 0, "item": "xxx" }` | 在指定位置插入 |
| `@list_clear` | `{ "var": "global.list" }` | 清空数组 |

### 4.7 类型转换

| 函数 | 参数 | 返回值 |
|------|------|--------|
| `@to_string` | `{ "value": 123 }` | `"123"` |
| `@to_int` | `{ "value": "42" }` | `42` |
| `@to_double` | `{ "value": "3.14" }` | `3.14` |
| `@format_number` | `{ "value": 12, "precision": 2 }` | `"12.00"`（**强制保留小数位**，金额/百分比用） |

> **数字显示约定**：默认 `{{ x }}` 模板把整数值的 double（如 `1.0`、`100.0`）显示成 `"1"` / `"100"` 不带 `.0`，避免 jsonlogic 算数（`+`/`*` 在底层会升级 double）造成 UI 显示难看 + 路径解析断掉。需要"强制 N 位小数"用 `@format_number`。

### 4.8 UI 反馈

| 函数 | 参数 | 说明 |
|------|------|------|
| `@show_toast` | `{ "message": "保存成功" }` | 轻量底部 toast（Overlay 浮层，非 SnackBar） |
| `@show_snackbar` | `{ "message": "邮件已发送", "actionLabel": "撤销", "action": {...}, "durationMs": 4000, "backgroundColor": "#333333" }` | 增强 SnackBar，支持操作按钮回调 |
| `@show_dialog` | `{ "title": "确认", "message": "确定删除？" }` | 弹窗，返回 `true`/`false` |
| `@show_input_dialog` | `{ "title": "重命名", "hint": "请输入", "defaultValue": "", "bind": "global.name" }` | 文本输入弹窗，返回输入值（取消返回 `null`） |
| `@show_choice_dialog` | `{ "title": "保存修改？", "message": "...", "buttons": [{"label":"保存","value":"save","style":"primary"},{"label":"丢弃","value":"discard","style":"danger"},{"label":"取消","value":"cancel"}], "dismissible": true }` | 自定义按钮弹窗，返回被点按钮的 `value`（关闭返回 `null`）。`style`：`primary` / `danger` / `text`（默认） |
| `@show_date_picker` | `{ "initial": "2026-04-28", "firstDate": "2020-01-01", "lastDate": "2030-12-31", "bind": "global.date" }` | 命令式日期选择器，返回 yyyy-MM-dd 字符串（取消返回 `null`） |
| `@show_time_picker` | `{ "initial": "14:30", "bind": "global.time" }` | 命令式时间选择器，返回 HH:mm 字符串（取消返回 `null`） |
| `@show_bottom_sheet` | `{ "content": { ...widget... }, "isDismissible": true, "enableDrag": true, "backgroundColor": "#FFFFFF" }` | 底部弹窗，content 是任意 widget 配置。当前 JSON action 可用 `{ "type": "back" }` 关闭；关闭返回 `null` |

### 4.9 系统 / 平台原生

| 函数 | 参数 | 说明 |
|------|------|------|
| `@clipboard_copy` | `{ "text": "..." }` | 写入系统剪贴板 |
| `@clipboard_paste` | `{}` | 读取系统剪贴板，返回字符串 |
| `@haptic` | `{ "style": "light" }` | 触觉反馈：`light` / `medium` / `heavy` / `selection` / `vibrate`（默认 `light`） |
| `@launch_url` | `{ "url": "https://..." 或 "tel:..." 或 "mailto:..." 或 "sms:...", "mode": "external" }` | 打开外链；`mode`：`external`（默认外部浏览器）/ `inAppBrowserView`（iOS Safari / Android Custom Tabs）/ `inAppWebView`（旧式嵌入）。返回 bool |
| `@share` | `{ "text": "...", "subject": "...", "files": ["/path/to/file.png"] }` | 调起系统分享面板。`text` 必填或 `files` 非空 |
| `@request_permission` | `{ "type": "camera" }` | 请求权限。`type`：`camera` / `microphone` / `photos` / `location` / `locationWhenInUse` / `locationAlways` / `contacts` / `calendar` / `notification` / `storage` / `bluetooth` / `speech`。返回 status: `granted` / `denied` / `restricted` / `permanentlyDenied` / `limited`。<br>⚠️ **选图/选视频不需要申请 `photos`**：`image_picker` 控件 / `@pick_image` 走系统 Photo Picker（Android 13+）/ PHPicker（iOS），系统级代选，零权限。`photos` 仅用于"app 内自绘相册网格读取全部媒体"这种场景，Android 上当前已移除该权限声明（请求会返回 `denied`），iOS 仍有效。 |
| `@permission_status` | `{ "type": "..." }` | 同 `@request_permission`，但只查不请求 |
| `@open_app_settings` | `{}` | 跳系统设置页（用于 permanentlyDenied 后引导用户手动开启） |
| `@biometric_auth` | `{ "reason": "请验证身份解锁" }` | 触发指纹 / Face ID / 设备 PIN 验证。返回 bool |
| `@flame_game_reset` | `{}` | 重置当前屏幕挂着的所有 flame_game。给 JSON-APP 层（结算 dialog 的"再来一局"按钮）从外面重置游戏用，避免依赖 canvas 的 tap-to-reset |
| `@flame_game_input` | `{ "type": "button", "id": "jump", "pressed": true }` 或 `{ "type": "joystick", "x": 0.5, "y": -0.2, "strength": 0.54 }` | 从普通 JSON widget 向当前屏幕的 flame_game 注入外部输入。`virtual_gamepad` 组件库就是基于这个桥接实现 |

### 4.9.1 媒体 / 相机（底层 API，**建议走 lib**）

> ⚠️ 这几个是底层媒体 API，**JSON-APP 不要直接调**。请通过组件库间接使用：
> - 选图 / 拍照 → `@common-ui.pickImage` / `@common-ui.takePhoto`（参数 `bind`，自动 quality=85）
> - 上传/更换头像 → `@lib_user.updateAvatar`（参数 `imagePath`，内部做 base64 + 上传）
>
> 走系统 Photo Picker（Android 13+）/ PHPicker（iOS）/ 相机，**零相册权限**（拍照用 camera 权限）。本节仅作 lib 的实现底层参考。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `@pick_image` | `{ "bind": "...", "max_width": 1920, "max_height": 1920, "quality": 85 }` | string 路径 \| null | 从相册选 1 张图（系统 Photo Picker），返回本地文件路径 |
| `@take_photo` | `{ "bind": "...", "max_width": 1920, "max_height": 1920, "quality": 85 }` | string 路径 \| null | 调相机拍 1 张（失败自动 fallback 到相册），返回本地文件路径 |
| `@file_to_base64` | `{ "path": "...", "bind": "..." }` | string base64 \| null | 把本地文件读成 base64（给上传 / 内嵌 image 用） |

### 4.10 私信 / 好友（IM）

> ⚠️ 这些 action 直接对接 OpenIM SDK，建议**通过 `lib_im` 库间接调用**（包装好的 nicely-named function：`searchUsers` / `sendFriendRequest` / `listFriends` / `getMessages` / `sendText` 等），而不是在 JSON-APP 里直接写 `@im_*`。本节仅用作 lib_im 的实现底层参考。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `@im_current_user_id` | `{ "bind": "..." }` | string \| null | 我的 IM userId。未登录返回 null |
| `@im_get_user_info` | `{ "user_id": "...", "bind": "..." }` | Map \| null | 按 userId 取对方公开资料：`{user_id, nickname, face_url, email}`。底层走后端 user search → Supabase（OpenIM 自己的 faceURL 老不更新，Supabase 是头像真实源）。找不到返 null |
| `@im_search_users` | `{ "q": "...", "bind": "..." }` | List | 关键词模糊搜邮箱/昵称/UUID（≥2 字符），每条 `{im_user_id, nickname, email, face_url}` |
| `@im_send_friend_request` | `{ "user_id": "...", "message": "..." }` | bool | 发好友申请，对方在 friend_applications 里能看到 |
| `@im_friend_applications` | `{ "bind": "..." }` | List | 我收到的好友申请。每条 `{from_user_id, from_nickname, from_face_url, req_msg, handle_result, create_time}`（handle_result：0=待处理 1=已同意 -1=已拒绝） |
| `@im_accept_friend` / `@im_reject_friend` | `{ "user_id": "..." }` | bool | 通过 / 拒绝某用户的好友申请 |
| `@im_friend_list` | `{ "bind": "..." }` | List | 我的好友列表。每条 `{user_id, nickname, face_url, remark}` |
| `@im_conversations` | `{ "bind": "..." }` | List | 会话列表。每条 `{conversation_id, user_id, show_name, face_url, latest_text, latest_time, unread_count, display_unread, display_time}` |
| `@im_history` | `{ "user_id": "...", "count": 30, "bind": "..." }` | List | 单聊历史（**升序：旧→新**，UI 直接 list 渲染呈现"老消息在顶、新消息在底"的微信式聊天）。每条 `{client_msg_id, send_id, recv_id, send_time, content_type, text, sender_nickname, sender_face_url, is_me, is_other, display_sender, display_time, bubble_color, bubble_text_color}` |
| `@im_send_text` | `{ "user_id": "...", "text": "..." }` | Map \| null | 给某 user 发文本，返回已发送 message 对象 |
| `@im_mark_read` | `{ "user_id": "..." }` | bool | 标记与某 user 的会话为已读 |
| `@im_total_unread` | `{ "bind": "..." }` | int | 跨所有会话的未读总数（用于 tab badge / 应用角标）。失败返回 0 |
| `@im_subscribe_inbox` | `{}` | bool | 订阅新消息（幂等）。订阅后 `global._im` 会被维护：`{tick, last_message, current_user_id}`，每来一条新消息 `tick` +1 + `last_message` 更新一次。UI 绑 `tick` 即可被动刷新（参见下方"实时新消息"） |

**display_*** 字段说明（v1.1 起）：
- `display_sender`：消息发送者的展示名。本人发的固定 `"我"`，其他人用 `sender_nickname`
- `display_time`：epoch 毫秒预格式化为 IM 列表常见的 `HH:mm` / `昨天` / `N天前` / `MM-dd`
- `display_unread`：会话未读数；0 时为空串（绑到 text.value 上自动隐藏徽标）
- 这几个字段是为了让 JSON-APP 不用在 DSL 层写条件 / 时间格式（DSL 静态属性不接受 jsonlogic Map），原始 `is_me` / `unread_count` / `send_time` / `latest_time` 同时也保留，开发者可按需自取

**实时新消息约定**：
- JSON-APP 在 `steps` / 启动函数里调一次 `@lib_im.subscribeInbox`（即 `@im_subscribe_inbox`）
- 之后 `global._im.tick` 每收到一条新消息会 +1，`global._im.last_message` 更新到最新一条
- 想做"自动刷新会话列表"，绑 `tick` 触发 rebuild + 在适当时机重新调 `listConversations` 即可
- 想做未读 badge，调一次 `@lib_im.totalUnread { bind: "global.totalUnread" }`，UI 绑 `{{ global.totalUnread }}`，业务路径里发完 / 读完消息再调一次刷新
- 平台限制：iOS / Android 使用原生 OpenIM SDK；Web 使用 `openim/wasm-client-sdk` 兼容层。macOS / Windows / Linux 暂无真实 IM SDK，所有 `@im_*` 安全降级返回空数据，不会崩。

### 4.11 主题 / 多语言 / 生命周期

| 函数 | 参数 | 说明 |
|------|------|------|
| `@set_theme` | `{ "mode": "light" }` | 运行时切主题。`mode`：`light` / `dark` / `system`（跟随系统） |
| `@get_theme` | `{}` | 返回当前 `mode` 字符串 |
| `@set_locale` | `{ "value": "en" }` | 切 **JSON-APP 自己**的 `global.locale`（不动框架 UI）。等价于 `@set var="global.locale" value="en"`，但顺带触发 `t()` 重查 |
| `@get_locale` | `{}` | 返回 JSON-APP 当前 locale |
| `@set_framework_locale` | `{ "value": "en" }` / `"system"` | 同步切框架 + JSON-APP locale（launcher 等"全局切语言"场景）。会调 `LocaleController.setLocale` 触发框架 UI 重建，同时 `setVariable('global.locale', ...)` |
| `@get_framework_locale` | `{}` | 返回框架当前 locale 简码（`zh` / `en` / `de` / `es`）或 `'system'`（跟随系统时） |

i18n 字典结构、`{{ t('xxx') }}` 用法、locale 来源、fallback 链、组件库 ref 的 i18n 约定 —— 见 §3.5。

**生命周期 hook**：
```json
"global": {
  "lifecycle": {
    "onResume":    [{ "call": "@http_get", "args": { "url": "..." }, "assign": "global.feed" }],
    "onPause":     [{ "call": "@storage_set", "args": { "key": "draft", "value": "{{ global.draft }}" } }],
    "onInactive":  [...],
    "onDetached":  [...],
    "onHidden":    [...]
  }
}
```

**计算属性 / 派生值**：
```json
"global": {
  "variables": { "first": "John", "last": "Doe" },
  "computed": {
    "fullName": { "cat": [{ "var": "global.first" }, " ", { "var": "global.last" }] }
  }
}
```
- `{{ global.fullName }}` 自动跟着 `first` / `last` 变化重算，不需要手动 `@set`。
- 真实变量同名时优先（real shadows computed）。
- 支持嵌套引用 computed→computed，但有递归保护（A→B→A 时返回 null，不会死循环）。

### 4.12 启动器 / 组件市场 / 用户

给"用户自己用 JSON 写启动器（launcher）"准备的桥接函数。配合 `templates/lib_launcher_*` 三个组件库使用，但函数本身可以独立调。

| 函数 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `@my_apps_list` | — | `List<{fileName, name, displayName, description, savedAt, version, author, type}>` | 列出本地保存的 JSON-APP（按时间倒序）。配合 `assign: "global.xxx"` 写到变量 |
| `@my_apps_delete` | `{fileName}` | `bool` | 删一个本地 APP |
| `@my_apps_share` | `{fileName}` | `bool` | 通过系统分享发出 JSON 文件 |
| `@market_list` | `{type?: "app"\|"library", search?, page?, perPage?}` | `List<{name, displayName, description, version, author, type}>` | 从 Registry 分页拉市场列表，`search` 由服务端模糊匹配。默认 `page=1`, `perPage=50` |
| `@launch_app` | `{kind: "local"\|"market", fileName?, name?, version?, isStartupRoot?}` | `bool` | 在当前 JSON-APP 内嵌套启动另一个 JSON-APP。kind=local 必须传 fileName；kind=market 必须传 name（version 缺省任意）。`isStartupRoot=true` 时新 APP 没有返回按钮（启动器场景）。框架会自动 push/pop 状态栈，子 APP pop 时父态恢复 |
| `@startup_default_get` | — | `{kind, hasTarget, marketName, marketVersion, marketDisplayName, localFileName, localDisplayName, displayName}` | 读默认启动 APP 配置 |
| `@startup_default_set` | `{kind: "market"\|"local", name?, version?, fileName?, displayName?}` | `bool` | 设默认启动 APP（market 必填 name+version；local 必填 fileName） |
| `@startup_default_clear` | — | `bool` | 清掉默认启动 APP |
| `@cache_clear` | — | `bool` | 清 dsl_cache 目录（市场/库本地缓存） |
| `@auth_logout` | — | `bool` | 登出（IM + token） |
| `@get_framework_locale` | — | `'zh'\|'en'\|'de'\|'es'\|'system'` | 见 §4.11（也归在这里方便 launcher 场景查） |
| `@set_framework_locale` | `{ value: 'zh'\|'en'\|'de'\|'es'\|'system' }` | `bool` | 见 §4.11 |

读取当前用户信息直接用现有的 `@get_user_info`（native）或 lib_user 的
`getUserAvatar` / `getUserName` / `getUserEmail`——launcher 这里不重复
包一份。原始字段名见 `AuthService.currentUser`：`id` / `username` / `email`
/ `avatar_url` / `role`。

### 4.13 其它内置函数索引（补充）

本节记录近期框架层已经存在、但容易漏写到文档里的通用函数。详细参数以源码实现为准，JSON-APP 里应优先通过组件库封装复用。

| 类别 | 函数 |
|------|------|
| 本地 KV | `@storage_set`, `@storage_get`, `@storage_remove`, `@storage_clear` |
| 本地 JSON 文件 | `@file_write_json`, `@file_read_json`, `@file_exists`, `@file_delete`, `@file_list`, `@file_append_json`, `@file_remove_json_item`, `@file_update_json_item` |
| 本地表/数据库 | `@db_create_table`, `@db_insert`, `@db_query`, `@db_update`, `@db_delete`, `@db_count`, `@db_kv_set`, `@db_kv_get`, `@db_kv_delete` |
| 随机/时间 | `@random`, `@random_float`, `@random_bool`, `@random_chars`, `@uuid`, `@random_pick`, `@timestamp`, `@date_format` |
| 扩展字符串 | `@str_repeat`, `@str_reverse`, `@str_pad`, `@str_join`, `@str_capitalize`, `@str_count`, `@str_index_of`, `@str_last_index_of`, `@str_between`, `@str_mask` |
| 扩展数组 | `@list_shuffle`, `@list_sample`, `@list_unique`, `@list_flatten`, `@list_sort`, `@list_reverse`, `@list_slice` |
| 账号/应用配置 | `@get_user_info`, `@get_auth_token`, `@is_logged_in`, `@logout`, `@refresh_user`, `@update_profile`, `@upload_avatar`, `@get_app_config`, `@apply_app_config`, `@save_app_config` |


**使用示例 — 嵌套启动**

```json
{
  "type": "card",
  "onTap": {
    "call": "@launch_app",
    "args": { "kind": "local", "fileName": "{{ loop.item.fileName }}" }
  },
  "children": [...]
}
```

**使用示例 — 启动器组件库**

直接 ref 三个 launcher 组件即可拼一个 tab 式启动器，参考 `templates/demo_launcher.json`：

```json
"dependencies": {
  "launcher-my-apps": "^1.0.0",
  "launcher-market": "^1.0.0",
  "launcher-settings": "^1.0.0"
},
"steps": [
  { "call": "@launcher-my-apps.init", "args": {} },
  { "call": "@launcher-market.init", "args": {} },
  { "call": "@launcher-settings.init", "args": {} }
],
"ui": {
  "screens": [{
    "id": "home",
    "tabs": [
      { "label": "本地", "icon": "apps",     "children": [{"type":"ref","from":"launcher-my-apps","widget":"myAppsGrid","props":{}}] },
      { "label": "市场", "icon": "store",    "children": [{"type":"ref","from":"launcher-market","widget":"marketBrowser","props":{}}] },
      { "label": "设置", "icon": "settings", "children": [{"type":"ref","from":"launcher-settings","widget":"settingsPanel","props":{}}] }
    ]
  }]
}
```

每个 lib 各自把状态挂在固定路径（`global._lma.*` / `global._lm.*` / `global._ls.*`）下，避免冲突。同一页面同一个 lib 不能开两份（路径冲突），launcher 这种典型场景用不到。

---

## 5. JsonLogic 表达式引擎

单 key 且 key 属于已知 operator 的 Map 会通过表达式引擎求值，例如 `{ "operator": [...args] }`；多 key Map 或 key 不是 operator 的单 key Map 会按普通数据对象递归解析。

### 5.1 数据访问

| 操作 | 示例 | 说明 |
|------|------|------|
| `var` | `{ "var": "global.name" }` | 读取变量 |
| `var` (空) | `{ "var": "" }` | 读取当前迭代元素 (filter/map 中) |

> JsonLogic 的 `var` 走 `jsonlogic` 包的点路径查找，必须写 `global.xxx` / `loop.xxx` / `params.xxx` / `event.xxx`。`$.global.xxx` 只在模板 `{{ $.global.xxx }}` 和 action 的路径字符串里做旧格式兼容，不要写进 `{ "var": ... }`。

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
{ ">": [{ "var": "global.age" }, 18] }
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

每个控件都支持 `position` 字段，但它只是外层包装：

| type | 说明 | 附加字段 |
|------|------|----------|
| `relative` | 顺序排列（默认） | — |
| `absolute` | 绝对定位（需 `layout=stack`） | `top`, `left`, `bottom`, `right` |
| `flex` | 弹性布局（需 Row / Column / Flex 父级） | `flex` (数字) |

`position.type=absolute` 会包装成 Flutter `Positioned`，父级必须是 `screen.layout="stack"`、`container.layout="stack"` 或 `stack` 控件；`position.type=flex` 会包装成 `Expanded`，父级必须是 Flex 布局。放错父级会触发布局错误。

#### visible 字段（条件渲染）

任何控件都可以加 `visible` 字段控制是否渲染：

| 写法 | 行为 |
|------|------|
| 不写 | 默认渲染（向后兼容） |
| `"visible": true` / `false` | 直接控制 |
| `"visible": "{{ loop.item.is_me }}"` | 模板，按解析值的真假 |
| `"visible": {">": [{"var": "global.appCount"}, 0]}` | jsonlogic 表达式求值 |

`visible: false` 时框架返回 `SizedBox.shrink()`，**完全不占空间**（Flex 布局里不会留 flex slot），等价于把整个节点从 widget tree 里摘掉。常见场景：

```json
// 微信式聊天气泡 — 自/他用两个 row 子树，靠 visible 二选一
{
  "type": "container", "visible": "{{ loop.item.is_other }}",
  "layout": "row",
  "children": [{"type": "avatar", ...}, {"type": "container", "color": "{{ loop.item.bubble_color }}", ...}]
},
{
  "type": "container", "visible": "{{ loop.item.is_me }}",
  "layout": "row",
  "children": [{"type": "spacer", "position": {"type": "flex", "flex": 1}}, {"type": "container", "color": "{{ loop.item.bubble_color }}", ...}, {"type": "avatar", ...}]
}
```

```json
// 角标徽章 — 数为 0 时整个红圈消失
{"type": "container", "visible": {">": [{"var": "global.unread"}, 0]}, "color": "#FF3B30", "borderRadius": 10, ...}
```

### 6.3 Widget 类型完整映射表

| type | Flutter Widget | 必填字段 | 可选字段 |
|------|----------------|----------|----------|
| `text` | `Text` | `value` | `style` |
| `button` | `FilledButton` / `OutlinedButton` / `TextButton` | `label` | `action`, `variant`, `icon`, `style`, `disabled` |
| `input` | `TextField` | `placeholder` / `bind` | `maxLines`, `keyboardType`, `obscureText`, `prefix`, `suffix`, `prefixIcon`, `suffixIcon`, `label`, `style` |
| `list` | `ListView.builder` | `source`, `item_template` | `emptyText`, `onRefresh`, `onLoadMore`, `key`(滚动位置保留), `separator`(默认 `"divider"` 画 1px 分隔线；`"none"` 关掉，聊天气泡 / 自定义卡片用), `scrollToEnd`(true 时初次渲染 + items 增多时自动滚到底，聊天页用) |
| `reorderable_list` | `ReorderableListView.builder` | `source`, `item_template`, `bind` | `onReorder`, `emptyText`, `padding`, `itemKey`(默认 `id`)。拖完自动写回 `bind` 变量；onReorder 回调可拿到 `params.from` / `params.to` / `params.list` |
| `skeleton` | 自实现 shimmer | — | `width`, `height`, `borderRadius`, `loading`(布尔, 与 `child` 联用), `child`(loading=true 时用 child 撑形状再覆盖 shimmer，false 时透传) |
| `container` | `Container` | `children` | `layout`(column/row/stack), `color`, `padding`, `margin`, `borderRadius`, `border`, `elevation`, `width`, `height` |
| `divider` | `Divider` | — | `height`, `thickness`, `color`, `indent` |
| `image` | `Image.network` / `Image.memory` / 本地文件 | `url` / `src` | `fit`, `width`, `height`, `borderRadius` |
| `spacer` | `SizedBox` / `Spacer` | — | `height`, `width`, `flex`（不写任何字段时默认 `Spacer()`，仅在 Flex 父级生效） |
| `switch` | `Switch` | `bind` | `label`, `action` |
| `image_picker` | `ImagePicker` | `bind` | `source`(gallery/camera), `placeholder`, `width`, `height`, `borderRadius` |
| `video` | `Chewie` + `VideoPlayer` | `url` / `src` | `autoplay`, `looping`, `aspectRatio`, `width`, `height`, `borderRadius` |
| `icon` | `Icon` | `name` | `size`, `color` |
| `card` | `Card` | `children` | `layout`, `padding`, `margin`, `elevation`, `borderRadius`, `color`, `onTap`, `crossAxisAlignment`, `mainAxisAlignment` |
| `checkbox` | `Checkbox` | `bind` | `label`, `action`, `disabled`, `color` |
| `expanded` | `Expanded` | `child` | `flex` |
| `loading` | `CircularProgressIndicator` / `LinearProgressIndicator` | — | `kind`(circular/linear), `size`, `color`, `value`, `strokeWidth`, `label` |
| `dropdown` | `DropdownButtonFormField` | `bind`, `options` | `placeholder`, `label`, `disabled`, `prefixIcon`, `color`, `action` |
| `radio` | `Radio` 组 | `bind`, `options` | `layout`(column/row), `disabled`, `color`, `action` |
| `wrap` | `Wrap` | `children` | `spacing`, `runSpacing`, `direction`, `alignment`, `runAlignment`, `crossAlignment` |
| `grid` | `GridView.builder` | `source`, `item_template` | `crossAxisCount`, `spacing`, `crossAxisSpacing`, `mainAxisSpacing`, `childAspectRatio`, `padding`, `shrinkWrap`, `emptyText`, `key`(滚动位置保留) |
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
| `flame_game` | Flame `GameWidget` 嵌入 ECS 游戏 | `world` | `vars`, `entities`, `input`, `frame`, `tick`, `on_*`, `overlay`, `height`（详见 6.42） |
| `virtual_gamepad` | 通用虚拟手柄 | — | `mode`(`dpad`/`joystick`), `directions`, `actions`, `actionLayout`(`wrap`/`ps`), `joystick`, `height`。适合平台跳跃 / 动作游戏；可通过组件库 `game-controls` 复用 |

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
  "bind": "global.email",
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
  "args": { "name": "{{ global.username }}" },
  "assign": "global.last_result"
}
```

- `assign`（可选）：把 call 的返回值写进指定变量。和 steps 里的 `assign` 语义一致，方便点按钮直接抓结果。

或导航（支持依赖页面 `depName:screenId`）：
```json
"action": { "type": "navigate", "screen": "detail" }
"action": { "type": "navigate", "screen": "auth:loginPage" }
```

或返回上一屏（弹出导航历史栈）：
```json
"action": { "type": "back" }
```

**导航历史与系统返回手势**：

框架在 `JsonInterpreter` 内部维护一个导航历史栈：
- 每次 `{type: "navigate", screen: X}` 把当前页推入栈，再切到 X；如果 X 已在栈中，则弹到那一帧（防止死循环增长）
- `{type: "back"}` 从栈顶弹一帧，回到上一屏
- iOS 边缘滑动 / Android 物理返回键 / AppBar 默认返回按钮 都会**优先**调 `navigateBack`；只有栈空（已在入口屏）才会真正弹出外层 Route 退出 JSON-APP

这样任何 JSON-APP 都自动具备"返回上一屏"行为，无需特殊配置。

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
- `key`：跨屏导航时保留滚动位置。给 list / grid 设一个**全局唯一**的字符串键
  （如 `"home_list"`），框架会用 `PageStorageKey` + Flutter 内置 `PageStorage`
  自动存/取该列表的滚动 offset。从子页 `back` 回来后停在原来位置而不是回到顶部。
  同一 JSON-APP 里不同的 list/grid 必须用不同的 key 否则会串。

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

单 widget 同时管 TabBar 和 TabBarView，避免上下两层 widget 各自管理 controller 的麻烦。`height` 用于 TabBarView 高度，建议显式写；不写时默认 400。

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

全屏体验（游戏标题页、沉浸式工具页等）可以显式关闭默认顶部栏：

```json
{
  "id": "title",
  "appBar": false,
  "backgroundColor": "#000000",
  "children": [...]
}
```

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
{ "type": "camera", "lensDirection": "back", "resolution": "medium" }
```
- 不写 `width` / `height` 时按摄像头原生比例自然撑开（推荐）。
- 想固定尺寸用 `fit` 指定缩放方式，**永远不会压扁**：
  - `fit: "contain"`（默认）—— 保比例 + 黑边
  - `fit: "cover"` —— 保比例 + 裁切
  - `fit: "fill"` —— 拉伸到目标尺寸（**会变形**，慎用）

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

模板可以声明 props 默认值，调用方未传或传 `null` 时生效。默认值支持只引用
`props.*` 的 JsonLogic，适合表达“某个 prop 默认等于另一个 prop”：

```json
"userCard": {
  "props": ["name", "avatar", "fallbackAvatar"],
  "defaults": {
    "fallbackAvatar": { "var": ["props.avatar", "https://example.com/avatar.png"] }
  },
  "root": {
    "type": "image",
    "url": { "or": [{ "var": "props.avatar" }, { "var": "props.fallbackAvatar" }] }
  }
}
```

出于生命周期安全，`ref` 的构建阶段只会提前计算完全由 `props.*` 组成的
JsonLogic；`event.*` / `loop.*` / `global.*` 仍在实际事件或运行时逻辑里计算。

### 6.42 flame_game 控件 — 嵌入小游戏（atom + 编排）

`flame_game` 是一个**通用游戏宿主**：JSON 描述游戏的世界、实体、输入、循环规则，框架（Flame 引擎 + 游戏 atom）负责执行。**新加一个游戏不需要改客户端代码**——只要 JSON 用现有 atom 拼出即可。

#### 设计原则：游戏 = JSON-APP 的一种用法，不是独立 DSL

`flame_game` 在 DSL 里和 `text` / `list` / `button` 是**同一级公民** —— 它就是 widget builder 注册的一个 widget 类型。意味着：

- **没有"游戏 APP"和"普通 APP"之分**：snake / 2048 这些 demo 都是 `meta.type: "app"` 的普通 JSON-APP，它们恰好顶层放了一个 `flame_game` 占满屏幕而已
- **任何 JSON-APP 都能嵌 `flame_game`**：例如教学 APP 第 5 章末尾放一个 `value_grid` 当随堂练习；电商 APP 在等待支付时放一个 `cell_path` 让用户消磨时间；签到 APP 用 `flame_game` 做转盘抽奖
- **能和其他 widget 自由组合**：见 `templates/demo_2048.json` —— 顶部 `container` 显示得分（普通 widget），中间 `expanded > flame_game`（游戏宿主），底部 `container` 显示历史结果（普通 widget），三段全是同一份 JSON
- **数据双向打通**：游戏内 `vars` / `score` 通过 `on_score_changed` / `on_game_over` 回调，外层用 `@set` 写到 `global.*`，再用 `{{ global.x }}` 在普通 widget 里展示。反过来外层 `{{ global.x }}` 在 build 时也会烤进 `flame_game` spec 作为初始值

简而言之：**flame_game 不是"游戏引擎"——它是"画布上跑 JSON 编排的循环逻辑"的一个原子**。把它当成一个会自己刷新的复杂可交互区域来用即可。

#### 顶层结构

```json
{
  "type": "flame_game",
  "world": { ... },
  "vars": { ... },
  "entities": { "<id>": { ... } },
  "audio": {
    "base_url": "https://example.com/game-audio/",
    "tracks": { "bgm": { "src": "main.ogg", "loop": true, "volume": 0.3 } },
    "sounds": { "jump": { "src": "jump.ogg", "volume": 0.8 } }
  },
  "input": { "tap": [...], "swipe": [...], "pan": [...], "swipe_threshold": 16 },
  "frame": { "logic": [...] },
  "tick": { "interval": 0.16, "logic": [...] },
  "on_score_changed": { ... },
  "on_game_over": { ... },
  "on_reset": { ... },
  "overlay": { "score": true, "game_over": true, "game_over_title": "游戏结束", "game_over_hint": "点击重新开始" },
  "height": 600
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `world` | ✅ | 坐标系 |
| `vars` | ❌ | 游戏内变量初始值（每次 reset 重置） |
| `entities` | ❌ | 实体声明（id → spec） |
| `audio` | ❌ | 游戏音频目录。`tracks` 适合 BGM/循环音，`sounds` 适合跳跃、拾取、命中等短音效；资源由 JSON 以 URL/相对路径声明 |
| `input.tap` | ❌ | 点击事件 logic（event 含 `x`, `y`） |
| `input.swipe` | ❌ | **离散** swipe：一次手势结束才触发一次（按累积位移决定方向）。event 含 `direction`（up/down/left/right）+ 累积 `dx`/`dy`。适合 2048、贪吃蛇、卡牌这类"一次手势 = 一次事件"的游戏 |
| `input.pan` | ❌ | **连续** pan：onPanUpdate 每帧（~16ms）触发一次，event 只含本帧增量 `dx`/`dy`（不含 direction）。适合划线、轨迹、拖动、连续蓄力这类需要逐帧位移的游戏 |
| `input.swipe_threshold` | ❌ | swipe 触发的最小累积位移（像素），默认 16。设大一点可以防抖，设小一点更灵敏 |
| `input.press_end` | ❌ | **按住-释放**语义：onTapDown 时框架记开始时刻，onTapUp 时触发，event 含 `x`/`y` + `held_ms`（按住时长，毫秒）。蓄力跳跃 / 弹弓 / 充能技能等用。注意 `input.tap` 仍然在按下时立刻触发（适合做"按下"动画），press_end 是松手时触发，两个可以共用 |
| `frame.logic` | ❌ | 每帧执行 |
| `tick` | ❌ | 间隔执行：`{ interval, logic }` 或 `[{...}, {...}]`，`interval` 支持 `"{{ vars.x }}"` 模板（每次 tick 重新求值，所以可以让 snake 加速） |
| `init.logic` | ❌ | entities 建好之后跑一次的初始化（典型用途：开局先 spawn 几个 tile）；reset 后会再跑 |
| `on_<event>` | ❌ | 游戏事件回调，由外层 JSON-APP 处理 |
| `overlay` | ❌ | 内置 overlay 配置 |
| `height` | ❌ | 不写时占满父级 |

#### 内置作用域（在 vars/entities/input/tick/frame 里 `{{ ... }}` 可用）

| 路径 | 含义 |
|---|---|
| `{{ vars.x }}` | 当前游戏实例的 vars |
| `{{ entities.<id>.<field> }}` | 实体快照（如 `entities.snake.head` → `[10, 14]`） |
| `{{ event.x }}` | 当前事件 payload（仅在 input/tick/frame 等回调里有值）。`frame.logic` 里 `{{ event.dt }}` 是当前帧时长（秒），用 `gravity * event.dt` 这种乘法做 FPS-independent 物理 |
| `{{ loop.x }}` | `@for_each_entity` 等迭代原子内可用：`loop.id` / `loop.entity` / `loop.index` |
| `{{ world.cols }}` / `{{ world.rows }}` / `{{ world.width }}` / `{{ world.height }}` / `{{ world.cell_w }}` / `{{ world.cell_h }}` | 世界尺寸 |
| `{{ score }}` / `{{ best }}` / `{{ game_over }}` | 内置标量 |

外层模板（`{{ global.x }}`, `{{ params.x }}`）会在 widget build 时一次性烤进 spec，仅作为初始值用。`vars.*` / `event.*` / `entities.*` / `world.*` / `loop.*` 属于游戏内部命名空间，必须保留到 game logic 执行时再解析。

#### `world` —— 坐标系

```json
{ "kind": "grid", "cols": 20, "rows": 30, "bg": "#1A1A2E", "grid_lines": "#222244" }
{ "kind": "pixel", "bg": "#2B2B2B" }
```

`grid` 模式：cellW/cellH 自动按画布尺寸算；entity_cell / entity_cell_path 在格子坐标系里操作。
`pixel` 模式：自由像素。

#### `entities` —— 实体类型

| kind | 必填字段 | 说明 |
|---|---|---|
| `cell` | `init: [x, y]` | 单个网格格子（snake 食物） |
| `cell_path` | `init: [[x,y], ...]` | 网格上的格子序列（snake 身体）；`render.gradient: true` 启头亮尾暗 |
| `scroll_list` | `direction: "down"` | 垂直滚动行序列（tap_white_tile）；`speed`, `row_height`(默认 width/cells), `safe_zone_bottom`(默认 2), `row_spec` |
| `value_grid` | `cols`, `rows` | 网格里每格存 int 值（2048 类游戏）；`init: [[0,0,2,...]]` 初始矩阵；`render.by_value: { "2": {...}, "4": {...} }` 按值渲染，`render.default` 兜底；render 支持 `text` + `text_color` + `font_size` 在色块上叠数字，`{{ value }}` 占位会被当前值替换 |
| `pixel` | `position: [x, y]`, `size: [w, h]`, `velocity: [vx, vy]` | **自由 2D sprite**：默认每帧自动 `position += velocity * dt`，如需静态像素块用 `velocity: [0,0]` 或 `auto_update: false`；render 支持 rect / circle / text（emoji 走 `shape: "text"`） |
| `sprite` | `asset`, `position`, `size` | 单张图片 / spritesheet 子区域渲染；可配 `src` 裁切 |
| `animated_sprite` | `asset`, `position`, `size`, `frame_size` | spritesheet 动画；支持 `animations`、`currentAnimation`、`loop`、`step_time`；非零起点/非紧密排布的图集可用 `src_origin: [x,y]` / `src_x` / `src_y` 和 `frame_step: [dx,dy]` / `frame_step_x` / `frame_step_y` |
| `parallax` | `asset` | 横向循环背景层；支持 `speed_x`, `y`, `height` |
| `tiled_map` | `source` 或 `map_data` | Tiled 地图渲染 + 碰撞 + object layer 读取；支持外链 TMX/JSON，也支持内联 `tiled-json-v1`（见下）。`solid_layers` / `hazard_layers` 可指向 tile layer，也可指向 objectgroup 的矩形碰撞层 |

每个 entity 的 `render` 字段：

```json
{ "shape": "rect", "color": "#00C800", "padding": 2, "radius": 4 }
{ "shape": "circle", "color": "#FF4444", "padding": 4 }
```

#### `tiled_map` 地图输入：外链资源 / 内联 JSON

`tiled_map` 是通用地图 atom，不绑定任何具体游戏。它把 Tiled 地图读成框架内部统一结构，供渲染、碰撞、object spawn 使用。

**Agent 选型规则**：做 JSON 游戏时，如果需要 TMX / Tiled 地图，默认优先生成
`map_data` 并保存在同一份 JSON APP 里。这样用户拿到的就是一个完整 APP，
不需要额外准备 bucket、CDN、上传 TMX，也不容易因为资源路径漏传导致地图空白。
只有在地图很大、已有稳定资源托管、需要用 Tiled 工具链反复维护、或多款 APP
共享同一套地图资源时，才优先使用外链 `source`。

**模式 A：外链 TMX / JSON**

```json
{
  "kind": "tiled_map",
  "source": "map/level_1.tmx",
  "base_url": "https://cdn.example.com/my-game/",
  "solid_layers": ["Ground"],
  "hazard_layers": ["Hazard"]
}
```

`source` 可以是绝对 URL，也可以配 `base_url` 使用相对路径。`.tmx` 会按 Tiled XML 解析；`.json` 或内容以 `{` 开头时按 `tiled-json-v1` 解析。外链模式适合已经有资源托管和地图制作流程的项目，便于 Tiled 工具链、图片资源和缓存协同；不应作为 AI 生成小游戏的默认选择。

**模式 B：内联地图数据**

```json
{
  "kind": "tiled_map",
  "base_url": "https://cdn.example.com/my-game/",
  "map_data": {
    "format": "tiled-json-v1",
    "source": "map/level_1.tmx",
    "width": 96,
    "height": 15,
    "tilewidth": 64,
    "tileheight": 64,
    "tilesets": [
      {
        "firstgid": 1,
        "source": "tiles/ground.tsx",
        "name": "ground",
        "tilewidth": 64,
        "tileheight": 64,
        "tilecount": 8,
        "columns": 4,
        "image": "ground.png",
        "tiles": [
          {
            "id": 0,
            "type": "Platform",
            "collision": [{ "x": 0, "y": 0, "width": 64, "height": 64 }]
          }
        ]
      }
    ],
    "layers": [
      {
        "type": "tilelayer",
        "name": "Ground",
        "width": 96,
        "height": 15,
        "data": [0, 0, 1, 1, 0]
      },
      {
        "type": "objectgroup",
        "name": "spawn",
        "objects": [
          { "id": 1, "name": "start", "x": 128, "y": 704, "width": 48, "height": 48 }
        ]
      }
    ]
  }
}
```

内联模式是 AI 生成游戏的推荐默认方案，也适合小/中地图、用户没有 bucket/CDN 的场景。地图结构可以直接放在 `global.variables._tiledMaps`，实体和 `@tiled.load` 用 `{{ global._tiledMaps.level1 }}` 引用，避免重复塞多份。`map_data.source` 可选，但建议保留原 TMX 相对路径（如 `map/level_1.tmx`），框架会用它作为 tileset 图片相对路径的解析基准。

注意：`map_data` 解决的是地图结构内联；tileset 图片仍建议用 URL / `base_url` 资源。小图未来可以用 data URL，但大型 spritesheet 不建议塞进主 JSON。

碰撞层规则：`solid_layers` 和 `hazard_layers` 中的 layer name 如果是 tile layer，会按 tileset 的 tile collision / type 生成碰撞；如果是 objectgroup，会把该层每个矩形 object 当作 AABB 碰撞区域。object 自己有 `type` 时优先使用 object type，否则 solid 默认 `Platform`、hazard 默认 `Hazard`。

#### atom @action 集合（仅 flame_game 内可用）

**通用流程控制**（少量复制 JSON-DSL 主 action）：

| @action | 说明 |
|---|---|
| `@set` | `{var, value}` 写变量；value 支持模板 / jsonlogic / 内联 `{call: ...}` 调用 |
| `@if` | `{cond, then, else}` 分支；cond 支持表达式 / 内联 action |
| `@noop` | 占位 |

**游戏专属**：

| @action | 说明 |
|---|---|
| `@score.add({n})` | 分数 +n，emit `scoreChanged` |
| `@score.set({value})` | 分数设为 v |
| `@game_over` | 触发结束，emit `gameOver` |
| `@game_reset` | 重置（仅清状态，不重新构建结构）。**只能在 flame_game 内部 logic 里用**，外层 JSON-APP 用下面的 `@flame_game_reset` |
| `@emit({event, data})` | 从游戏内部发自定义事件给外层 JSON-APP；外层用 `on_<event>` 接收 |
| `@cell_path.advance({path, direction})` | 头按方向走一格（带 wrap）|
| `@cell_path.grow({path})` | 长一节 |
| `@cell_path.contains({path, cell, skip_head})` | 是否包含某格（碰撞检测） |
| `@cell_path.head({path})` | 返回 `[x, y]` |
| `@cell_path.head_collides_self({path})` | head 撞到自己身体 |
| `@cells_equal({a, b})` | 两格深比较（jsonlogic 不一定深比 list） |
| `@cell.set({id, cell})` | 设置 cell entity 的位置 |
| `@grid.random_empty({exclude, assign})` | 随机空格；可 `assign: "<entity_id>"` 直接写到该 cell entity |
| `@scroll_list.set_speed({id, value})` | 设置速度 |
| `@scroll_list.add_speed({id, by, max})` | 速度 +by，不超过 max |
| `@scroll_list.tap({id, x, y})` | 像素 tap 命中检测，返回 `'hit'` / `'miss'` / `'outside'` |
| `@scroll_list.first_unhit_below({id, y})` | 是否有未点 active 行越过 y（死亡线） |
| `@value_grid.slide_merge({grid, direction})` | 按方向 slide+merge，返回 `{moved: bool, score: int}`，2048 类用 |
| `@value_grid.spawn({grid, four_chance: 0.1})` | 随机空格 spawn 一个 2 / 4，返回是否成功 |
| `@value_grid.can_move({grid})` | 是否还能动（有空格或邻接同值） |
| `@matrix.clear({grid, value?})` | 清空 `value_grid` 为指定整数，默认 0；适合棋盘/消除/下落方块类游戏 |
| `@matrix.can_place({grid, cells, x, y, empty_values?, allow_above?})` | 判断多格形状能否放入网格；`cells` 支持 `[[x,y], ...]` 或 `{x,y}` 列表，默认空值为 0，默认允许形状部分在顶部以上 |
| `@matrix.place({grid, cells, x, y, value, only_in_bounds?})` | 把多格形状写入网格，返回写入格数；默认越界格跳过 |
| `@matrix.clear_full_rows({grid, empty_values?, fill?})` | 清除所有满行并顶部补空行，返回 `{cleared, rows}` |
| `@matrix.random_item({items})` | 从列表中随机深拷贝一项，适合抽取下一块/下一张牌/下一个图案 |
| `@polyomino.rotate({cells, direction?, normalize?})` | 旋转多格形状；`direction` 支持 `cw`/`ccw`/`flip`，默认旋转后归一到最小 x/y 为 0 |
| `@not({value})` | 通用否定。jsonlogic `!` 不递归 inline action 调用，需要 `@not` 把 inline call 结果取反 |
| `@pixel.set_position({id, p: [x, y]})` | 写 pixel entity 的位置 |
| `@pixel.set_velocity({id, v: [vx, vy]})` | 写 pixel entity 的速度（写完每帧自动按 v*dt 更新位置） |
| `@pixel.add_velocity({id, dv: [dvx, dvy]})` | 累加速度。每帧加 `[0, gravity*dt]` = 重力；加 `[wind, 0]` = 风力；通用语义 |
| `@spawn({kind, id, position?, size?, velocity?, render?, ...})` | 运行时创建一个新 entity（任何 kind）。typical 用于子弹 / 敌人 / 障碍物等"无限生成"的场景 |
| `@despawn({id})` | 运行时销毁一个 entity |
| `@animated_sprite.set_animation({id, animation})` | 切换 animated_sprite 当前动画 |
| `@animated_sprite.effect({...})` | 生成一次性动画特效，播完自动移除 |
| `@entity.exists({id})` | 判断 entity 是否存在 |
| `@entity.get({id, field})` | 读取 entity 字段；常用字段：`x/y/w/h/vx/vy/position/size/velocity/auto_update/state.xxx` |
| `@entity.set({id, field, value})` | 写 entity 字段；推荐写标量字段 `x/y/w/h/vx/vy/auto_update/state.xxx`。框架兼容 `position:[x,y]` / `size:[w,h]` / `velocity:[vx,vy]`，但新 JSON 生成时优先分别写 `x/y`、`w/h`、`vx/vy`，错误更容易定位 |
| `@entity.add({id, field, by, min?, max?})` | 对 entity 数值字段做累加；常用字段：`x/y/w/h/vx/vy/state.xxx`。兼容旧别名 `path/value`，但新 JSON 必须写 `field/by` |
| `@entity.flip_by_velocity({id})` | 按 vx 自动翻转 sprite 朝向 |
| `@audio.play({id, source?, loop?, volume?, restart?})` | 播放 `audio.tracks/sounds` 中的 id，或直接播放 `source` URL/asset。BGM 通常 `loop:true`；短音效用默认一次性播放 |
| `@audio.stop({id?})` | 停止指定循环音；不传 id 时停止当前游戏内所有音频 |
| `@audio.pause({id?})` / `@audio.resume({id?})` | 暂停/恢复指定或全部循环音 |
| `@audio.set_volume({id, volume})` | 调整循环音音量，`volume` 范围 0..1 |
| `@collide.rect({a, b})` | 两个 entity 的 AABB 矩形重叠检测，返回 bool。两边都得是 pixel 类（暴露 x/y/w/h） |
| `@collision.first({a, where_prefix})` | 查询实体 `a` 与指定 id 前缀实体的第一条 AABB 碰撞，返回命中的 entity id 或 `null` |
| `@tiled.loaded({map})` | 地图是否已加载完成 |
| `@tiled.first_object({map, layer})` | 读取 object layer 第一项 |
| `@tiled.load({map, source})` | 切换 tiled_map 到另一张外链 TMX/JSON |
| `@tiled.load({map, map_data})` | 切换 tiled_map 到另一份内联 `tiled-json-v1` 数据 |
| `@tiled.clear_spawned({prefix})` | 删除指定前缀的动态生成实体 |
| `@tiled.spawn_objects({map, layer, templates})` | 按 object layer 批量生成实体 |
| `@tiled.spawn_objects_near({map, layer, reference, proximity, templates})` | 只生成 reference 附近的 object，适合长地图懒加载 |
| `@tiled.collisions({map, rect})` / `@tiled.collisions({map, entity})` | 返回指定矩形或 entity AABB 范围内的瓦片碰撞列表 |
| `@tiled.has_collision_type({map, rect, type})` / `@tiled.has_collision_type({map, entity, type})` | 判断范围内是否命中特定碰撞类型；`type: "hazard"` 时掉出地图底部也视为命中 |
| `@tiled.nearest_object({map, layer, before_x})` | 查某层中 `x < before_x` 且离 `before_x` 最近的 object，常用于找最近重生点 |
| `@tiled.remove_object({map, layer, object_id})` | 从指定 object layer 移除一个 object，并标记为已消费；适合破坏砖块、拾取后不再参与碰撞的地图对象 |
| `@platformer.step({...})` | 通用平台跳跃物理步进：重力、地面、墙、危险区域等 |
| `@platformer.backend({...})` | 平台物理后端辅助，供复杂 platformer 使用 |
| `@platformer.respawn({...})` | 按 respawn 点重生 |
| `@platformer.stuck_check({...})` | 卡住检测 |
| `@platformer.section_exit({...})` | 横版跑图段落出口检测 |
| `@for_each_entity({where_prefix, do})` | 遍历 id 前缀匹配的所有 entity。子 logic 里 `{{ loop.id }}` / `{{ loop.entity }}` / `{{ loop.index }}` 可用。子 logic 内 spawn/despawn 不影响本轮迭代（用快照） |

`@tiled.spawn_objects*` 的 object layer 只提供点位和属性，不等于可见实体。生成敌人、
道具、掩体时必须传 `templates`，模板里写清 `kind`、真实 `asset`、`position`、`size`、
动画的 `frame_size/frames/frames_per_row` 和必要 `state`。否则 object 能被读取，但生成出来的
实体可能没有素材、没有行为，表现为“地图里有点位但游戏里没有敌人”。

横版射击类游戏如果使用 `bullet_count` / `projectile_count` 这类上限变量，必须在命中敌人、
飞出屏幕或超时销毁时都释放计数；只在命中时释放会导致玩家打空几发后永远不能开火。
`@platformer.step` 会写入 `entities.<id>.hazard` / `outOfBounds` 语义，关卡游戏需要在
`frame.logic` 里读取并触发扣命、重生或 `@game_over`，避免角色掉出地图后继续隐形运行。
它也会写入通用碰撞边信息：`blockedLeft` / `blockedRight` / `blockedUp` /
`blockedDown`、`xCollision` / `yCollision` / `onGroundCollision`。平台游戏可以据此
实现撞墙反向、顶砖块、踩地触发等状态机，不要靠猜坐标。

平台游戏发布前至少过这组验收：地面能站住；墙/管道/箱子从侧面会阻挡；砖块从下方能顶到；
单向平台只在显式 `one_way_types` / `one_way_tilesets` 指定时生效；掉坑、碰危险物、冲出地图会扣命、
重生或结束；敌人、道具、子弹不会因为离屏/命中路径遗漏而永久卡住状态。
| `@random_int({min, max})` | 返回 [min, max) 的随机整数 |
| `@random_double({min, max})` | 返回 [min, max) 的随机 double |

#### 双向桥

- 游戏 emit 的事件（`score_changed` / `game_over` / `reset`）会在 spec 的 `on_<event>` 字段里被外层 JSON-APP 接住，能调外层 JSON-APP 的全局 @action（例如 @set 写 global、@http_*、@navigate 等）
- 游戏内部 logic 用上面 atom @action 集，不能调 @http、@navigate 这种（避免污染游戏循环）

#### 已知限制 / 设计边界

- 音频能力只负责播放 JSON 引入的 BGM / 短音效；复杂混音、音频精确同步和动态合成暂不支持。
- 没有动画曲线 / 缓动系统；简单 spritesheet 动画用 `animated_sprite`。
- 没有游戏专用持久化；高分/进度让 JSON-APP 自己在 `on_game_over` / `on_score_changed` 中用 storage/file/db 保存。
- `frame.logic` 是逐帧解释执行，适合轻量规则；大批量实体建议用 `@tiled.spawn_objects_near`、前缀遍历和距离 despawn 控制规模。
- `tiled_map.map_data` 可以承载小/中地图；大型正式地图仍建议外链 asset，避免主 JSON 难以 review。

#### 完整示例

| 示例 | 涉及原子 | 演示了什么 |
|---|---|---|
| `templates/demo_snake.json` | `grid_world` + `cell_path` + `tick.logic` + `swipe` | 网格定时推进、方向键队列、自我碰撞 |
| `templates/demo_tap_white_tile.json` | `pixel_world` + `scroll_list` + `frame.logic` + `tap` | 像素坐标命中检测、死亡线、滚动加速 |
| `templates/demo_2048.json` | `pixel_world` + `value_grid` + `init.logic` + `swipe` | **flame_game 与普通 widget 混排**：顶部分数 bar、中间游戏区、底部结果 bar 在同一份 JSON 里 |
| `templates/demo_flappy_bird.json` | `pixel` entity + `@pixel.add_velocity` + `@spawn`/`@despawn` + `@collide.rect` + `@for_each_entity` | **物理 + 动态生成 + 碰撞**：重力 / 跳跃冲量 / 管道无限生成 / 出屏销毁 / 计分 全在 JSON 里编排，框架零业务逻辑。bird 用 🐦 emoji 渲染 |
| `templates/demo_jump.json` | `input.press_end` + `pixel` entity + 抛物线物理 + 状态机 | **蓄力跳跃 + 平台滚动**：按住-松手按 `held_ms` 决定 vx，抛物线由重力自然形成；落到目标平台→镜头滚动（platform / player 同时 `set_velocity`)，到位后 despawn / spawn 切换。整套状态机（ready/jumping/rolling）由 JSON `vars.state` 驱动 |
| `templates/demo_superdash_runner.ALL_IN_ONE.json` | `demo-superdash-runner-all-in-one` | 官方 SuperDash 风格跑酷，地图结构内联在 JSON 中；图片仍走 asset URL |
| `templates/demo_platformer_adventure.ALL_IN_ONE.json` | `demo-platformer-adventure-all-in-one` | 多关卡平台跳跃，地图结构内联在 JSON 中，演示无 bucket 的 all-in-one 游戏发布方式 |
| `templates/demo_tetris.json` | `value_grid` + `@matrix.*` + `@polyomino.rotate` | 竖屏下落方块游戏；棋盘清行、旋转和放置都通过通用矩阵 atom 编排 |
| `templates/demo_mario_platformer.json` | `tiled_map` objectgroup 碰撞 + `animated_sprite.src_origin` + `@platformer.step` | 横屏平台跳跃游戏；外链 TMX/素材，玩法逻辑留在 JSON 层 |

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
