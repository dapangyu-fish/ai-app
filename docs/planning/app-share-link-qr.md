# RFC：App 分享链接 + 二维码（深链打开 AI 生成的 JSON-APP）

> 状态：**提案（待实现）** · 作者：平台团队 · 创建：2026-06-29
> 关联：`docs/planning/push-jsonapp-isolation.md`（推送深链，共用 `{app_id, route, params}` 信封与点击落地路由）、`JSON-DSL.md`（`@launch_app` / `@share` / `@launch_url` / `qr_code`）、`backend/REGISTRY_README.md`（`resolve_appid` 解析接口）

---

## 1. 背景与问题

平台已经能让用户「在浏览器里打开一个 AI 生成的 JSON-APP」：把 appid 拼进 URL query，Flutter Web 客户端在启动时识别并直接渲染。Web 端在启动时识别外部 query 直开 JSON-APP 这套机制是生产在跑的——可视复检（visual-review）就是靠**同一套 Web 启动器的另一条 query 分支**把 JSON-APP 截图（`deploy/production/docker-compose.core.yml:103/190/377` 的 `AI_APP_VISUAL_REVIEW_WEB_BASE=https://myapp-web.dapangyu.work`，env 由 `backend/ai_session.py:1812` 的 `_visual_review_env()` 透传，URL 由 `scripts/myapp_visual_review.py:345-350` 的 `_render_url` 拼成 `?remote_file=<json_url>`——注意走的是 `_remoteJsonSource` 直传 JSON 分支，**不是** `?appid=` 经 `resolve_appid` 那条；二者是 `lib/main.dart` 里并列的两个 query 启动入口）。`?appid=` 直达分支本身已在 `MaterialApp.home` 接入并可用，但其生产验证不来自 visual-review。

但「把一个 App 变成一条可发出去、扫一下就打开」的完整能力，存在三个结构性缺口：

1. **没有「生成分享链接 / 二维码」的内置能力**。`qr_code` 控件（`lib/json_ui/widgets/qr_code_widget.dart`）只负责把 `data` 字符串编码成二维码，**不含「按 appid 拼分享 URL」的逻辑**；`@share`（`lib/json_ui/interpreter.dart:1517-1534`）只发文本；`@my_apps_share`（`lib/json_ui/builtins/launcher_bridges.dart:123-153`）**发的是 JSON 文件本体，不是深链 URL**。要分享一条链接，JSON-APP 现在只能在配置里**手工**把 appid 拼进 `qr_code.data` 或 `@share.text`，且 web host 还得硬编码——框架里没有权威的 web host 配置项（`AppConfig` 有 `backendUrl/registryUrl/minioUrl/imApiUrl`，但**没有 `webUrl`**，见 `lib/config/app_config.dart:85-127`）。

2. **移动端 inbound 深链完全不存在**。仓库里有的全是 **outbound** 能力（`url_launcher` `pubspec.yaml:96`、`share_plus` `:97`、`qr_flutter` `:84`），**没有任何 inbound link 接收能力**：无 `app_links`/`uni_links` 依赖（`pubspec.yaml` 零命中）；iOS 无 `com.apple.developer.associated-domains`（`ios/Runner/Release.entitlements` 只有 `aps-environment=production`）、无 `CFBundleURLTypes`（`ios/Runner/Info.plist` 零命中）；Android 的 `intent-filter` 只有 `MAIN`+`LAUNCHER`（`android/app/src/main/AndroidManifest.xml:44-47`），没有 `VIEW`+`BROWSABLE`+`android:host`/`scheme`，也没有 `autoVerify`。结论：`https://<host>/app/<appid>` 或 `myapp://app/<appid>` **点了不会唤起原生 App**。

3. **route/params 维度的深链能力是空白**。现有 `?appid=` 直达只能进 App 的默认首屏：
   - `_WebAppIdStartupLoader` 只读 `appid`/`app_id` 两个 query 键（`lib/main.dart:80`、`:101-109`），不读 `route`/`params`。
   - 初始屏锁死 `screens.first`（`lib/json_ui/interpreter.dart:603-606`），无法从外部指定进哪个屏。
   - `@launch_app` 没有 `initialRoute`/`launchParams` 参数（`lib/json_ui/builtins/launcher_bridges.dart:215-343`），只能进目标 App 首屏——这与 push RFC 列出的同一缺口（`docs/planning/push-jsonapp-isolation.md:163-166`）。
   - `params.*` 只有**函数级**注入入口（`_paramsStack`，`lib/json_ui/interpreter.dart:49` + push/pop 在 `:3700/:3710`），**没有「屏幕级 / 从外部注入」的入口**，深链 `params` 落不进目标屏。

### 目标场景（产品描述）

> 用户在某个 JSON-APP 里点「分享」：
> - 生成一条 `https://<web-host>/?appid=<uuid>&route=<screen>&params=<...>` 链接 / 二维码；
> - 对方**用浏览器打开** → Flutter Web 直接渲染该 App 并落到指定界面（短期已可达）；
> - 对方**手机装了客户端** → 点链接 / 扫码**直接唤起 App** 并深链到对应界面带参数；
> - 对方**没装** → 落地页判活，引导「网页预览 / 下载 App」，安装后再进入对应界面。

## 2. 目标与非目标

**目标**
- 把「按 `appid`（+`route`+`params`）生成可分享 URL / 二维码」做成**框架内置能力**，JSON-APP 不再手拼。
- 寻址格式**沿用既有约定**（`?appid=<uuid>`）叠加 `route`/`params`，与 push RFC 的 `{app_id, route, params}` 信封同构，一套寻址覆盖「链接 / 二维码 / 推送」三入口。
- **一次性补齐 route/params 三处断点**（`@launch_app` 参数、Web 启动器读 query、屏幕级 params 注入），并与 push RFC 的深链补强**合并实现**。
- 引入移动端 **inbound 深链最小集**（Android App Links + iOS Universal Links，自定义 scheme 降级），统一一个落地路由器，与 push 的点击落地**共用**。
- 提供 Web **落地页判活**（已装唤起 / 未装引导）的设计，未装兜底**复用** push RFC 的「邀请下载」流程。

**非目标（本期不做）**
- 不做扫码端原子控件（扫别人二维码）。`mobile_scanner` 依赖虽已在 `pubspec.yaml:86`，但当前无桥接控件，本 RFC 只覆盖 outbound（生成 + 被点开），扫码控件留作独立特性。
- 不改 registry 的索引模型（仍按 appid 遍历公开 index），私有/未发布 App 的可解析性见 §10。
- 不做分享链接的 HMAC 签名 / 防篡改（默认靠「框架注入 appid + route 白名单」防伪，签名留作 §10 开放项）。
- 不重写 marketing 站（`website/`），只在其上叠加一个 deep-link 落地页。

## 3. 术语

| 术语 | 含义 |
|------|------|
| **appid** | JSON-APP 的稳定标识，全平台约定为**标准 UUID v4**（Web 启动校验 `lib/main.dart:886-890`、appid 编辑页校验+生成 `lib/main.dart:3578/3795`、后端 `resolve_appid` 校验 `backend/registry_server.py:263-267` 三处一致）。深链与分享的主键。|
| **分享链接 / share URL** | `https://<web-host>/?appid=<uuid>[&route=...][&params=...]`，可直接发文本、嵌二维码、被点击唤起。|
| **route** | App 内目标界面定位：屏幕 `id`（`screens[].id`），可带 `depName:screenId` 跨依赖前缀（`navigateTo` 已支持，`interpreter.dart:1191`）。|
| **params** | 深链参数，注入为目标屏的 `params.*`（如 `orderId`）。**纯数据**，绝不当表达式求值（见 §7）。|
| **inbound 深链** | 系统层把 `https://<host>/...` 或 `myapp://...` 链接导向本 App（Universal Links / App Links / 自定义 scheme）。当前**完全不存在**。|
| **落地路由器 / DeepLinkRouter** | 客户端统一入口：解析 `{appid, route, params}` → 解析/下载 config → 加载 → 深链到 route。链接点击与推送点击共用。|
| **落地页 / landing** | Web 侧判活页：已装唤起原生、未装引导网页预览或下载。|
| **安装** | JSON-APP 被存进本地 `AppStorage`（`@launch_app kind=local` 可加载、`@my_apps` 可列出）。|

## 4. 总体设计

寻址主键直接沿用 `?appid=<uuid>`（query 优先，零改动复用现有 Web 启动器与后端解析），叠加 `route`/`params`。自下而上分四层：

```
① 寻址 / 生成层   share URL = https://<web-host>/?appid=<uuid>[&route][&params]
        │            框架内置 @build_app_url / @share_app（appid 由框架注入，防伪）
        │            → 喂给 qr_code.data / @share.text（已有控件/动作，零新建）
        │
② 解析 / 装载层   后端 resolve_appid（已实现，按 appid 查公开 index → download_url）
        │            客户端复用 _WebAppIdStartupLoader._load() 的
        │            「resolve_appid → download → loadConfig → executeSteps」核心
        │
③ 深链 / 导航层   route → navigateTo(screen)（已实现），params → 屏幕级注入（待新增）
        │            @launch_app 补 initialRoute / launchParams（待新增，与 push RFC 合并）
        │
④ 入口 / 落地层   Web：? appid 直达（已实现） + deep-link landing 判活（待新增）
                  移动端：inbound 深链（待新增）→ DeepLinkRouter（与推送点击共用）
                  未装兜底：复用 push RFC「邀请下载」（market 安装 → 打开 → 跳 route）
```

三类入口（**链接点击 / 二维码扫码 / 推送点击**）最终都汇聚到同一个 `DeepLinkRouter`，它内部复用 `_WebAppIdStartupLoader._load()` 的装载核心，并与 push RFC 的 `_handleNotificationTap` 共用同一段「已装深链 / 未装兜底」逻辑（`lib/im/im_push_service.dart:77` 目前是注释占位）。

## 5. 详细设计

### 5.1 寻址格式（沿用既有约定，叠加 route/params）

**已实现可复用**：Web 启动器 `_WebAppIdStartupLoader` 已识别 `?appid=`/`?app_id=`（`lib/main.dart:80` 的 `_webAppIdParamNames`、`:101-109` 的 `_webAppIdSource()`），并在 `MaterialApp.home` 第二优先级接入（`lib/main.dart:680-683`，排在 `_LocalJsonDebugLoader` 之后）。后端 `GET /resolve_appid`（`backend/registry_server.py:529-537` → `_resolve_appid_payload` `:260-295`）按 appid 查公开 index 返回 `download_url`，注释明写「用于 Web 分享链接直达 JSON-APP」。**「Web 端按外部 query 启动直开 JSON-APP」这套机制经可视复检在生产验证可用**（不过 visual-review 实际跑的是同机制下的 `?remote_file=` 直传分支，见 §1；`?appid=`→`resolve_appid` 这条分支代码已就绪、与之共享 `MaterialApp.home` 入口，但未被 visual-review 单独覆盖）。

**决策**：分享 URL 形如
```
https://<web-host>/?appid=<uuid>&route=<screenId>&params=<base64url(json)>
```
- 用 **query** 而非 path（`/app/<appid>`）：可零改动复用现有 Web 启动器与 `resolve_appid`，无需新建 Flutter Web 路由或新后端路由。
- path 形式（`/app/<uuid>`）作为**可选美化别名**，在 marketing 站 `website/public/_redirects`（现为 `/* /index.html 200`）层面重写到 query，不进客户端核心。

**待新增**：`_WebAppIdStartupLoader` 扩展为读 `route`/`params` query（见 §5.4）。

### 5.2 内置「生成分享链接 / 二维码」能力（待新增）

**现状**：`qr_code` 控件（`lib/json_ui/widgets/qr_code_widget.dart:18-19`）的 `data` 走 `resolveTemplate`，所以**理论上**能填 `"https://...?appid={{ global.appid }}"`，但 host 与 appid 都得 JSON 手拼；`@share`（`interpreter.dart:1517-1534`）只发文本；`@my_apps_share`（`launcher_bridges.dart:123-153`）发的是 JSON 文件不是链接。**没有任何「按 appid+route+params 生成 URL」的内置函数**。

**待新增**：
- `@build_app_url({ appid?, route?, params? })` → 返回标准分享 URL 字符串。
  - **`appid` 缺省取当前运行 App 的 appid**（`interpreter` 在 `loadConfig` 时已提取 `_appId`，`interpreter.dart:567-574`）；**由框架注入，JSON 不能改成别的 App 的 appid**——与 push RFC §7.1 防伪同理（`push-jsonapp-isolation.md:187`），杜绝生成钓鱼链接冒充他人 App。
  - `route` 校验为目标 App 的合法 `screens[].id`（白名单见 §7）；`params` 走 §10 决定的编码。
  - 返回值喂给 `qr_code.data`（生成二维码）或 `@share.text`（弹分享面板）。
- `@share_app({ route?, params? })` → 一步：内部调 `@build_app_url` 再调 `@share`，直接弹系统分享面板分享当前 App 的深链。
- web host 由新增的**权威配置项** `AppConfig.webUrl` 提供（见 §6；现 `AppConfig` 无此项，`lib/config/app_config.dart:85-127`）。

### 5.3 装载核心（已实现可复用）

`_WebAppIdStartupLoader._load()`（`lib/main.dart:939-976`）已经把「校验 appid（`_isValidUuid` `:886-890`）→ `resolve_appid`（`:892-907`）→ `download_url` 下载 config（`:909-937`，无 download_url 时回退 `CacheManager.getResource`）→ `loadConfig` + `executeSteps`（`:947-949`）→ 渲染 `JsonScreenView(isStartupRoot: true)`（`:1018-1021`）」串成一条可用链路。

**决策**：把这段核心抽成可复用方法（如 `DeepLinkRouter.openApp(appid, route, params)`），供三类入口共用，避免在 Web 启动器、移动端 inbound、推送点击里各写一遍。`@launch_app` 的 `pushState`/`loadConfig`/`executeSteps`/`popState` 状态栈嵌套（`launcher_bridges.dart:311-340`）也是同一套装载语义，热场景（App 已在运行时收到深链）走 `@launch_app` 分支。

### 5.4 route/params 深链补强（待新增，与 push RFC 合并）

整条「深链到某屏并带参数」当前断三处，对应三处改动：

1. **`@launch_app` 加 `initialRoute` + `launchParams`**（`launcher_bridges.dart:215-343`）：加载 App 配置后，不再永远进 `screens.first`，而是切到 `initialRoute` 并把 `launchParams` 注入屏幕级 params。push RFC `:163-166` 已把这列为待补强项，**本特性与之合并实现，一处改动两边受益**。
2. **`_WebAppIdStartupLoader` 读 `route`/`params`**（扩展 `lib/main.dart:101-109`/`:939-976`）：`loadConfig` 后，若 `route` 非空则调 `interpreter.navigateTo(route)`（`interpreter.dart:1190-1228`，已支持 `dep:screen` 与历史栈），并注入 `params`。
3. **新增「屏幕级 params 注入」机制**（`interpreter.dart`）：当前 `_paramsStack`（`:49`，push/pop 在 `:3700/:3710`）只服务**函数级** `params.*`，深链落不进屏。新增一条「初始屏 / 当前屏 params」注入入口，使 `{{ params.orderId }}` 在目标屏可解析。注入路径必须走**原始数据**分支（见 §7），不经 `@set` 的 Map→求值分支。

> `navigateTo`（`interpreter.dart:1190-1228`）本身**已实现可复用**：支持 `depName:screenId` 跨依赖跳转、维护 `_navigationHistory` 回退栈。route 深链不需要新导航引擎，只需把外部 route「喂进去」。

### 5.5 Web 落地页判活（分两层）

**现状**：`?appid=` 直达的是 **Flutter Web 客户端**（`build/web`，独立于 marketing 站），它直接在浏览器里**渲染** JSON-APP，**不是**「先判断装没装再唤起原生」。marketing 站 `website/`（Vite + React）只有 `/` 与 `/docs` 两个 page（`website/src/App.tsx:1915`），`website/public/_redirects` 是 `/* /index.html 200`，**没有 `/app/<appid>` 路由、没有 smart-banner、没有「打开 App / 下载」分流**。

**待新增，分两层**：
- **短期（零新建）**：分享链接直接指向 Flutter Web 客户端 `?appid=`，对方用浏览器打开即在网页里跑 App。满足「发出去 → 能看」。
- **完整**：新增 deep-link landing（可在 marketing 站加 `/app/<appid>` 别名页，或一张独立轻页），做 smart-banner：尝试唤起 `myapp://` / Universal Link，失败回退「网页预览（跳 Flutter Web `?appid=` 直达）/ 下载 App」。Web 端「未装」的定义：浏览器本身永远算「未装原生」，落地页据此默认提供网页预览入口。

### 5.6 移动端 inbound 深链（待新增）

**现状**：三端原生配置全缺（§1 第 2 点）。

**待新增最小集**：
- 引入 `app_links` 包（统一收 https 链接与自定义 scheme；`pubspec.yaml` 现无）。
- **iOS Universal Links**：`Release.entitlements` 加 `com.apple.developer.associated-domains`（`applinks:<web-host>`）；web host 部署 `apple-app-site-association`。
- **Android App Links**：`AndroidManifest.xml` 主 Activity 加 `VIEW`+`BROWSABLE`+`android:host`/`android:scheme=https` 的 `intent-filter` 并 `android:autoVerify="true"`；web host 部署 `.well-known/assetlinks.json`。
- **自定义 scheme `myapp://app?appid=...`** 作为降级（部分浏览器 / 二维码扫码 App 不支持 Universal Link 直唤起时）。
- 统一一个 `DeepLinkRouter`：监听 `app_links` 冷启动（被杀状态下点链接拉起）与热点击（运行中点链接），解析出 `{appid, route, params}` → 调 §5.3 的装载核心 → §5.4 的 route 深链。**与 push 的 `_handleNotificationTap`（`im_push_service.dart:77`）共用同一段「已装深链 / 未装兜底」逻辑**。

### 5.7 未安装兜底（复用 push RFC）

未装目标 App 时，**复用** push RFC §5.5 的「邀请下载 A」流程（`push-jsonapp-isolation.md:168-174`）：用 appid 去 registry 取展示信息 → 卡片引导 → `@launch_app kind=market` 拉取安装 → 存入 `AppStorage` → 打开 → 跳 `route(params)`。**链接/二维码/推送三入口共用同一段兜底代码**，不另起一套。

## 6. 数据模型 / 接口汇总

| 对象 | 位置 | 状态 | 作用 |
|------|------|------|------|
| `?appid=`/`?app_id=` query | `lib/main.dart:80/101-109` | **已实现** | Web 启动直达识别 |
| `GET /resolve_appid?appid=` | `backend/registry_server.py:529-537` / `:260-295` | **已实现** | appid → download_url（分享链接服务端） |
| `_WebAppIdStartupLoader._load()` | `lib/main.dart:939-976` | **已实现（待扩展 route/params）** | resolve→download→load→render 装载核心 |
| `navigateTo(screenId)` | `lib/json_ui/interpreter.dart:1190-1228` | **已实现** | route→屏导航（支持 `dep:screen`） |
| `qr_code` 控件 | `lib/json_ui/widgets/qr_code_widget.dart` | **已实现** | 把 URL 编码成二维码 |
| `@share` / `@launch_url` | `lib/json_ui/interpreter.dart:1517-1534` / `:1499-1516` | **已实现** | 发文本（含 URL）/ 打开外链 |
| `AppConfig.webUrl` | `lib/config/app_config.dart` | **待新增** | 权威 web host（现仅有 backend/registry/minio/im URL） |
| `@build_app_url({appid?,route?,params?})` | `lib/json_ui/interpreter.dart` | **待新增** | 生成分享 URL（appid 框架注入） |
| `@share_app({route?,params?})` | `lib/json_ui/interpreter.dart` | **待新增** | 一步分享当前 App 深链 |
| `@launch_app` 的 `initialRoute`/`launchParams` | `lib/json_ui/builtins/launcher_bridges.dart:215-343` | **待新增（与 push RFC 合并）** | 装载后深链到 route 带 params |
| 屏幕级 params 注入 | `lib/json_ui/interpreter.dart`（现 `_paramsStack` 仅函数级 `:49/3700/3710`） | **待新增** | 让 `{{ params.x }}` 在深链目标屏可解析 |
| `DeepLinkRouter` | 新模块 | **待新增** | 三入口统一落地（与 `_handleNotificationTap` 共用） |
| iOS associated-domains / `apple-app-site-association` | `ios/Runner/Release.entitlements` + web host | **待新增** | iOS Universal Links |
| Android App Links intent-filter / `assetlinks.json` | `android/app/src/main/AndroidManifest.xml` + web host | **待新增** | Android App Links |
| `app_links` 依赖 | `pubspec.yaml` | **待新增** | inbound 链接接收 |
| deep-link landing | `website/`（现仅 `/` `/docs`，`App.tsx:1915`） | **待新增** | 已装唤起 / 未装引导判活 |

## 7. 安全与防滥用

1. **appid 强制 UUID 校验**：客户端启动校验（`lib/main.dart:886-890`）、appid 编辑校验（`:3795`）、后端 `resolve_appid`（`backend/registry_server.py:263-267`）三处已一致。`DeepLinkRouter` 入口处**再校验一次**，非 UUID 直接拒。
2. **appid 防伪（生成端）**：`@build_app_url` 的 appid **由框架从当前运行 App 注入**（`interpreter.dart:567-574` 的 `_appId`），JSON 不能改成别的 appid，杜绝生成冒充他人 App 的钓鱼链接——与 push RFC §7.1 同理（`push-jsonapp-isolation.md:187`）。
3. **params 永不当表达式求值**：遵守 CLAUDE.md「框架稳定性原则」第 3 条——运行时数据永不当 jsonlogic/表达式执行。深链 `params` 注入屏幕变量时，**必须走「原始数据」分支**，不经 `@set` 的 Map→求值路径。
4. **防开放重定向 / 越权跳转**：`route` 只允许命中目标 App `ui.screens[].id` 白名单，不命中则回首屏（`screens.first`，`interpreter.dart:603-606`），不接受任意外部屏名。
5. **download_url 只信 registry**：config 下载地址只取 `resolve_appid` 返回的 `download_url`（`backend/registry_server.py:280-285`），**绝不接受链接 query 里携带的任意 URL**，防止用分享链接投递恶意 config。
6. **内容隔离**：分享链接只携带 `{appid, route, params}` 三个寻址字段，不携带 token / 凭证；params 仅作目标屏数据注入。
7.（可选，见 §10）若 params 含敏感定位（如 `orderId`），考虑复用 push RFC「框架注入 + 服务端校验」思路而非自造签名。

## 8. 兼容性与迁移

- **向后兼容**：现有 `?appid=` 直达不变（不带 `route`/`params` 即进首屏，与今天行为一致）；`route`/`params` 是叠加式可选 query。
- **二维码 / `@share` 控件无 schema 变更**：`@build_app_url` 只是给它们提供一个**更安全的 URL 来源**，老 JSON 手拼 URL 的写法继续可用。
- **inbound 深链是纯叠加**：新增依赖 + 原生配置 + 新模块，不触碰现有渲染 / 推送管线；未升级到带深链原生配置的旧客户端，链接退化为「浏览器里用 Flutter Web 打开」，不崩。
- **与 push RFC 协同**：`@launch_app` 的 `initialRoute`/`launchParams`、`DeepLinkRouter`、未装「邀请下载」兜底三者**两边共用**，谁先落地谁建、另一方直接复用，避免两套实现。
- **新 host 配置**：`AppConfig.webUrl` 需随环境切换（与 `backendUrl`/`registryUrl` 同机制，`app_config.dart:85-127`），demo 模式需指向 demo web host。

## 9. 分期实施计划

**P1 · 链接 + 二维码生成 + Web 深链（不依赖原生改动，纯框架 + 后端已就绪）**
1. 新增 `AppConfig.webUrl`（权威 web host，随环境切换）。
2. 新增 `@build_app_url({appid?,route?,params?})` + `@share_app({route?,params?})`，appid 框架注入、route 白名单校验。
3. 扩展 `_WebAppIdStartupLoader` 读 `route`/`params` query，`loadConfig` 后 `navigateTo(route)` + 注入屏幕级 params。
4. 新增「屏幕级 params 注入」机制（原始数据分支）。
5. 抽出 `DeepLinkRouter.openApp(appid, route, params)` 复用 `_load()` 装载核心。

**P2 · `@launch_app` 深链 + 移动端 inbound（与 push RFC 合并）**
6. `@launch_app` 加 `initialRoute`/`launchParams`（与 push RFC `:163-166` 合并实现）。
7. 引入 `app_links`；iOS associated-domains + `apple-app-site-association`；Android App Links intent-filter + `assetlinks.json`；自定义 scheme 降级。
8. `DeepLinkRouter` 接 inbound 冷/热启动，与 push `_handleNotificationTap`（`im_push_service.dart:77`）共用落地逻辑。

**P3 · 落地页判活 + 未装兜底 + 加固**
9. deep-link landing（marketing 站 `/app/<appid>` 别名 + smart-banner：唤起 / 网页预览 / 下载分流）。
10. 未装兜底接 push RFC「邀请下载」流程（registry 取展示信息 → `@launch_app kind=market` 安装 → 打开 → 跳 route）。
11. 加固：route 白名单 / params 编码收敛 / （可选）敏感 params 签名。

## 10. 开放问题

1. **寻址主键用 appid（UUID）还是包名 `namespace/app`？** 现状 `resolve_appid` 按 appid（`registry_server.py:270-271`），`@launch_app kind=market` 按 name（`launcher_bridges.dart:226-251`）。建议统一用 appid（稳定、已全平台 UUID 校验），但需确认**私有/未发布 App 的 appid 能否解析**——`_resolve_appid_payload` 现只遍历公开 index（`registry_server.py:269-295`）。
2. **route 是否支持多级路径与回退栈？** 现状 `navigateTo` 只定位单屏（支持 `dep:screen`，`interpreter.dart:1191`），push RFC 也把这列为开放问题（`push-jsonapp-isolation.md:221`，§10 首条）。建议先单屏，多级留后。
3. **params 编码**：`base64url(JSON)`（防注入稳、不可读）vs 扁平 query（可读、需逐键白名单）。建议 base64url 为主。
4. **签名 / 防篡改**：公开 App 多数不必；若 params 含敏感定位（如 `orderId`），是否引入 HMAC 签名 vs 复用 push RFC「框架注入 + 校验」思路？
5. **未装兜底统一**：Web 端「未装」如何界定（浏览器永远是「未装原生」）需单独定义；移动端兜底必须与 push RFC「邀请下载」**复用同一段代码**，避免两套。
6. **Web host 配置的唯一来源**：当前 `myapp-web.dapangyu.work` 字面量只散落在 deploy compose（`docker-compose.core.yml:103/190/377` 的 `AI_APP_VISUAL_REVIEW_WEB_BASE` 默认值）与 visual-review 脚本（`scripts/myapp_visual_review.py:37` 的 `DEFAULT_WEB_BASE`，env 由 `ai_session.py:1812` 透传 key），`AppConfig` 无 `webUrl`。需把它收敛为权威配置项并随环境切换。

---

**实现完成后**：把 `@build_app_url` / `@share_app` / `@launch_app` 的 `initialRoute`·`launchParams` / 屏幕级 params 注入回流到 `JSON-DSL.md`；把 `?appid=&route=&params=` 寻址格式与 `resolve_appid` 用法回流到 `backend/REGISTRY_README.md`；把 inbound 深链原生配置（associated-domains / App Links / scheme）与 `DeepLinkRouter` 的「已装深链 / 未装兜底」契约回流到 `docs/planning/push-jsonapp-isolation.md`（与推送点击落地共用一节）。
