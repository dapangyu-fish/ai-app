# 分享链接 — 方案调研

## 目标 / Acceptance

1. 用户在 launcher 里的一个 JSON-APP（市场上的 / 本地的 / AI 生成的）能"分享"出去
2. 朋友收到链接，**装了 MyApp** → 直接拉起对应 JSON-APP
3. 朋友收到链接，**没装 MyApp** → 落地 Web 页 → 引导到 App Store / TestFlight / APK 下载
4. 病毒传播 KPI：用户做完 app 后愿意分享给至少 1 个朋友

## 关键术语

| 术语 | 意思 |
|------|------|
| **Universal Links (iOS)** | iOS 9+ 机制：HTTPS URL 既能在 Safari 打开（fallback web），也能直接被本地 app 拦截（如果装了）|
| **App Links (Android)** | Android 6+ 同等机制 |
| **Deep link** | 应用内路由地址，比如 `myapp://a/calculator?v=1.0.0` |
| **Deferred deep linking** | 用户**没装**时点链接，**装了之后**仍能感知到原始 URL 并跳转到对应内容 |

---

## 方案对比

### 方案 A：自托管 Universal Links / App Links（推荐 v1）

**做法**：
- 起一个域名（比如 `share.dapangyu.work`）
- 放两个静态文件 `apple-app-site-association` + `assetlinks.json`
- 写个简单的 web fallback 页（识别没装时跳 App Store）
- Flutter 端加 deep link 处理插件（`uni_links` / `app_links`）

**优点**：
- ✅ 零外部依赖、零运营成本
- ✅ 域名 / TLS / 静态 hosting 都用现成 dapangyu.work 基础设施
- ✅ 数据完全自己掌控
- ✅ 链接结构干净（`https://share.dapangyu.work/a/calculator@1.0.0`）

**缺点**：
- ❌ **不支持 deferred deep link**——朋友没装 → 跳 App Store → 装完打开是首页，不会自动加载分享的 app
- ❌ 微信内置浏览器不支持 Universal Link 唤起原生 app（**这是中国市场的硬伤**，下面会单独讲）

### 方案 B：Branch.io（一站式 SaaS）

**做法**：
- Branch SDK 接 iOS / Android
- 在 Branch 后台配置链接行为
- 链接形如 `https://myapp.app.link/abc123`

**优点**：
- ✅ Deferred deep link 开箱即用（这是核心卖点）
- ✅ 内置 attribution / 漏斗分析
- ✅ Branch 帮处理微信 / 抖音内置浏览器的边界 case

**缺点**：
- ❌ **vendor lock-in**（链接长得不像自己的）
- ❌ 免费层 10k 次/月之后开始收费（$59-300+/月）
- ❌ 多一个 SDK 体积（iOS ~3MB / Android ~1MB）
- ❌ 数据要发到 Branch 后台

### 方案 C：Firebase Dynamic Links

❌ **不要用**——Google 已宣布 [2025 年 8 月停止服务](https://firebase.google.com/support/dynamic-links-faq)。

### 方案 D：纯 H5 导出（独立 web app）

**做法**：JSON-APP 直接在浏览器跑（Flutter Web 加 JSON 解释器），分享出去的链接朋友**不用装 app** 就能用。

**优点**：
- ✅ 零下载摩擦，传播率最高
- ✅ 没装 MyApp 的人也能用 → 是真正的"病毒载体"
- ✅ 配 deep link 双轨：装了 app 跳 native，没装跑 web

**缺点**：
- ❌ 工程量大（2-3 周）—— 需要 Flutter Web build + 部分原生功能 fallback（相机 / 推送等不能用）
- ❌ Flutter Web 体积大（首屏 ~2MB），加载慢
- ❌ 一些 native widget 在 Web 上没等价物（video_player / camera / IM 全部不可用）

### 推荐组合

**v1（4 周内）**：方案 A（自托管 Universal Links）—— 跑通基础链路
**v2（2 个月内）**：叠加方案 D（H5 fallback 渲染只读预览）—— 没装也能"看一眼"
**v3（看数据再决定）**：如果 deferred deep link 转化是瓶颈，再考虑接 Branch

---

## v1 自托管方案 — 技术详细设计

### URL Schema

```
https://share.dapangyu.work/a/<source>/<identifier>
```

例：
| 链接 | 含义 |
|------|------|
| `https://share.dapangyu.work/a/m/calculator@1.0.0` | 市场 app, name=calculator, version=1.0.0 |
| `https://share.dapangyu.work/a/u/abc123def` | 用户上传 app（uuid 索引到一个临时存储的 JSON） |

URL 里没有 PII，可以随便分享。

### 后端 / 服务端

**新增 endpoints**（加在 `backend/ai_server.py`）：

| 路径 | 方法 | 作用 |
|------|------|------|
| `GET /a/m/<name>@<version>` | 浏览器 | 渲染 web fallback 页（含市场 app 元信息 + 下载 CTA） |
| `GET /a/u/<uuid>` | 浏览器 | 同上，对应用户上传的 JSON |
| `POST /share/upload` | 客户端 | 用户分享非市场 app 时，上传 JSON 到 MinIO，返回 uuid。带 7-30 天 TTL |
| `GET /share/json/<uuid>` | 客户端 | 拉取分享 JSON 内容（鉴权可选） |

**静态文件**（nginx 直接 serve）：

```
https://share.dapangyu.work/.well-known/apple-app-site-association
https://share.dapangyu.work/.well-known/assetlinks.json
```

`apple-app-site-association`（iOS 必须）：
```json
{
  "applinks": {
    "apps": [],
    "details": [{
      "appID": "TEAMID.com.dapangyu.myapp",
      "paths": ["/a/*"]
    }]
  }
}
```

`assetlinks.json`（Android 必须）：
```json
[{
  "relation": ["delegate_permission/common.handle_all_urls"],
  "target": {
    "namespace": "android_app",
    "package_name": "com.dapangyu.myapp",
    "sha256_cert_fingerprints": ["<release-cert-sha256>"]
  }
}]
```

### 客户端 (Flutter)

**加包**：`app_links: ^6.0.0`（pure Dart，跨平台，比 uni_links 维护更活跃）

**iOS 配置**：
- Xcode → Signing & Capabilities → Associated Domains
- 加 `applinks:share.dapangyu.work`

**Android 配置**：
- `AndroidManifest.xml` 加 intent-filter：
  ```xml
  <intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https"
          android:host="share.dapangyu.work"
          android:pathPrefix="/a/" />
  </intent-filter>
  ```

**Dart 端**：
- App 启动时拿 `appLinks.getInitialAppLink()` 看冷启动 URI
- 运行时监听 `appLinks.uriLinkStream`
- 解析 URI → 调 `@launch_app({kind, name?, version?, uuid?})`
- 复用 `pushState/popState` 状态栈（如果当前在 launcher 里，分享的 app 嵌套启动）

### 用户分享 UI（在 launcher-my-apps lib 里加）

- 卡片长按 / 加分享按钮 → 调 `@share_app(kind, fileName/name@version)`
- 新桥接 `@share_app`：
  - 市场 app：直接生成 `https://share.dapangyu.work/a/m/<name>@<version>` URL，调系统分享面板
  - 本地 app：先 POST 到 `/share/upload` 拿 uuid，再生成 `https://share.dapangyu.work/a/u/<uuid>` URL，调系统分享面板

### Web Fallback 页（landing page）

域名根 + `/a/*` 路径的 GET 返回 HTML（不是 JSON）。

页面内容：
- 顶部：app 名 / 图标 / 描述（从 meta 拉）
- 主 CTA：「在 MyApp 中打开」（Universal Link 自动唤起，如果装了）
- 副 CTA：「下载 MyApp」→ 检测 UA：
  - iOS → App Store 链接（v1 阶段先去 TestFlight 公开链接）
  - Android → Play Store / 自家 APK 下载页
  - 其他 → 显示 QR 码

页面要点：
- **必须很轻**（< 50KB，1 秒内显示），WeChat 等内置浏览器经常 5G 关闭加载慢页面
- 配上 OpenGraph 标签（朋友圈 / 微信预览图）
- **微信特殊处理**：检测到 WeChat UA → 显示「点击右上角 ... → 在浏览器中打开」遮罩

### 微信内置浏览器的硬限制 ⚠️

WeChat / 抖音 / 小红书的 in-app browser **不会触发 Universal Link**，链接只会在它自己的 webview 里打开。

**绕过方案**（行业标准做法）：
1. 检测 UA 是 micromessenger / aweme / xhs → 显示"在浏览器中打开"引导遮罩（指向右上角 `...` 按钮）
2. 遮罩遮住整个屏幕直到用户离开内置浏览器
3. 用户在外部浏览器打开 → Universal Link 正常工作

这一步**必须做**，否则在中国市场分享率会降 80%。

---

## 实施分解（v1）

### Phase 1：基础设施（1-2 天）
- [ ] 申请 / 配置 `share.dapangyu.work` 子域名（nginx + TLS 证书）
- [ ] iOS 工程查 Team ID + Bundle ID
- [ ] Android 工程取 release signing cert SHA256
- [ ] 生成 + 部署 `apple-app-site-association` 和 `assetlinks.json` 到子域名

### Phase 2：客户端集成（2-3 天）
- [ ] 加 `app_links` 包
- [ ] iOS Xcode 加 Associated Domains 配置
- [ ] Android Manifest 加 intent-filter
- [ ] Dart 端写 `DeepLinkHandler`：解析 URL → 调 `@launch_app`
- [ ] 处理两个时机：冷启动初始 URI + 运行时 URI 流

### Phase 3：分享 / 上传后端（2 天）
- [ ] `POST /share/upload` endpoint（认证 + TTL + 大小限制）
- [ ] MinIO 新建 bucket `shared-apps`，配 7 / 30 天生命周期
- [ ] `GET /share/json/<uuid>` endpoint（认证可选，做防爬）
- [ ] `@share_app` launcher 桥接函数

### Phase 4：Web Landing Page（2-3 天）
- [ ] Flask render template `/a/m/<name>@<version>` 和 `/a/u/<uuid>`
- [ ] UA 检测 + 下载 CTA 路由
- [ ] WeChat / 抖音内置浏览器引导遮罩
- [ ] OpenGraph + 微信卡片预览图

### Phase 5：测试 + 联调（1-2 天）
- [ ] iOS：Universal Link 唤起测试（safari / 短信 / WhatsApp / WeChat 外）
- [ ] Android：App Link 自动验证测试（`adb shell pm get-app-links`）
- [ ] 没装时正确跳 App Store / TestFlight
- [ ] 装了时正确拉起对应 JSON-APP
- [ ] 微信 / 抖音内置浏览器引导流畅度

**总工作量估算：8-12 个工作日**。

---

## 风险 / 未解决问题

### 🟡 中等风险

**1. App Store / TestFlight 可用性**
- 现在 MyApp 还没上 App Store。v1 阶段 fallback 跳 TestFlight 公开链接（适合内测用户）+ APK 直链（Android）
- 上 App Store 后改 fallback 链接即可

**2. 用户上传 JSON 的隐私 / 安全**
- 上传的 JSON 可能包含 secrets（hard-coded token / API key）
- Mitigation：分享前扫描 JSON 提示用户、限制只能分享市场 app 或显式标记为可分享的 my_app
- 大小限制 200KB（一般 JSON-APP 都在这个范围内）

**3. Deferred deep linking 缺失**
- 没装 → 装了 → 不会自动加载分享的 app
- 方案：装完首次启动时，弹窗"刚才尝试访问的链接是 X，要打开吗？" —— 但需要服务端记录 IP / 设备指纹，工程复杂度上升
- v1 接受这个缺陷，v2 看数据再决定要不要做

### 🔴 高风险

**4. iOS Universal Link 在某些场景不触发**
- 复制粘贴链接到 Safari 地址栏 → 不会唤起（必须从外部点击）
- WeChat / 抖音内部 → 完全不会唤起
- 必须给清楚的"在浏览器中打开"引导

**5. Android App Links 自动验证失败**
- 如果 `assetlinks.json` 配置错（指纹错 / 包名错），系统不会自动信任
- 用户点链接会被问"用哪个 app 打开"，而不是直接跳 MyApp
- 必须发布前在真机上 `adb shell pm get-app-links com.dapangyu.myapp` 验证

---

## 待你决策

1. **方案选 A（自托管）还是 B（Branch）？** —— 我建议 A
2. **域名用 `share.dapangyu.work` 还是另起？**
3. **本地 app（未发布到市场）能不能分享？**
   - A. 可以，临时上传到 share bucket，7 天 TTL
   - B. 不能，必须先发到市场才能分享
4. **iOS 下载 CTA 现阶段指向哪？**
   - TestFlight 公开链接（最快）/ 内部分发链接 / "App Store 即将上架"占位页
5. **Android 下载 CTA 现阶段指向哪？**
   - 自托管 APK / Google Play / 国内应用市场（华为 / OPPO 等）

回完这 5 个我就开干。
