# MyApp Launch Notes

> 这份文档是 Claude 在 2026-05-19 仔细读完 ~41k 行代码 + 全部 docs 后整理。
> 目的：评估开源 launch + 火起来的可行性 + 给出具体行动清单。
> 你慢慢看，把不同意的直接划掉就行。

---

## Part 1 — 项目客观体量（我做了实际盘点）

### 代码规模

| 模块 | LOC | 说明 |
|---|---|---|
| Frontend (`lib/`) | **34,233** Dart | 客户端引擎 + UI + IM + AI 入口 |
| - `lib/json_ui/interpreter.dart` | 3,587 | **核心 IP**：JSON-DSL 解释器 |
| - `lib/json_ui/widgets/*` | 50+ files | 30+ widget 类型注册（text/button/list/chart/map/webview/camera/qr/flame_game/...） |
| - `lib/im/*` | 5,234 | OpenIM 全套封装 + 聊天页 + 群 + 媒体上传 |
| - `lib/designer/*` | 6,993 | 悬浮球 / AI chat service / 字幕 overlay / 设置页 / 环境页 |
| - `lib/json_ui/dependency_loader.dart` | 266 | 包依赖解析（含 semver / 循环检测） |
| Backend (`backend/`) | **7,356** Python | Flask + AI proxy + IM glue + Registry |
| - `backend/claude_chat.py` | 814 | AI 流式聊天 + subprocess + SSE |
| - `backend/ai_session.py` | 749 | Redis 会话状态 + 多会话隔离 |
| - `backend/registry_server.py` | 1,050 | 包注册中心（命名空间/版本/mirror） |
| - `backend/im.py` | 775 | OpenIM webhook / push dispatch / token 管理 |
| - `backend/push/*` | 通道无关 dispatcher | APNs + FCM provider，新通道一行 import |
| Other services | | `user_center/` / `config_center/` / `backend/video_server.py` |
| Templates | 31,578 JSON | 30+ 个示例 JSON-APP |
| - `regression-test.json` | 10,367 | 单文件 10k 行回归测试 app（很多功能验证） |
| - `match3-pixel.json` | 3,008 | 像素消除游戏，纯 DSL 写的 |
| - `calculator.json` | 1,426 | 完整计算器 |
| - `demo_im.json` | 700 | 用 DSL 写的 IM 客户端 |
| Docs | | 11 个 md 文件（JSON-DSL.md 1,778 行规范） |
| Deploy | | bootstrap.sh 一键起 26 容器；supervisor + nginx prod 模板齐 |

### Built-in 函数数量

`interpreter.dart` 里 `@xxx` 函数 **132 个**（grep `case '@'`），覆盖：
- HTTP / JSON / 字符串 / 列表 / 数学（标准库）
- UI feedback（toast / dialog / snackbar / sheet）
- 文件系统 / SharedPreferences / **Drift SQLite**（结构化 + KV）
- **Auth / IM / 推送**直通（@im_send_text / @im_history / @get_auth_token / @upload_avatar）
- 系统集成（@launch_url / @share / @request_permission / @biometric_auth / @set_locale / @set_theme）
- 控制流（@if / @while / @for_each / @parallel / @try_catch / @delay）
- 设备能力（@take_photo / @pick_image / @clipboard_copy / @haptic）

### Widget 类型

30+ 注册类型（widget_builder.dart 实际清单）：
text / button / input / list / container / divider / image / image_picker / spacer / switch / video / ref / icon / card / checkbox / expanded / loading / dropdown / radio / wrap / grid / padding / center / align / flexible / stack / slider / date_picker / time_picker / tooltip / chip / badge / avatar / rich_text / progress / inkwell / gesture_detector / dismissible / draggable / refresh / tab_view / app_bar / webview / qr_code / chart / map / camera / skeleton / reorderable_list / flame_game

最后那个 `flame_game` 接了 [Flame](https://flame-engine.org/) 引擎 —— **DSL 能写真游戏**（match3-pixel / demo_jump 都是证据）。

### AI 生成 prompt

`backend/prompts/generate_app_prompt.md` 209 行：
- 强调三段式骨架（meta/global/steps/ui）
- 列了 7 条 "极其重要" 的布局/数据规则（来自历次踩坑总结）
- 教 AI 用 `mktemp` 多 session 防撞
- 给 AI 一个 anti-patterns 文档参考（`templates/bacsase/anti_patterns_and_pitfalls.md`）

---

## Part 2 — 这个项目客观上**真的有价值**

读完之后我修正了之前的草率评价。**这不是 toy，是工程化程度很高的产品**。

### 真东西，不是 demo：

1. **JSON-DSL 的表达力够用** ——10k 行单 JSON 写出回归测试 app，3k 行写出消除游戏，700 行写 IM 客户端。这意味着 AI 生成的 app 不是"hello world+button"层级，能做真实业务
2. **AI 流程闭环了** —— 生成 → MinIO 临时 URL → 下载 → 跑 → 失败重试 → 上传"当前 app" 给 AI 改。这条链路目前在跑你 prod
3. **跨实例 Registry mirror** —— 我们一起加的，但**架构提前 6 个月就为它留好了通道无关 dispatcher 这种设计**。你提前一步设计了扩展点，这是好的工程师特征
4. **环境切换 + 7 连击隐藏入口** —— 这个细节我没见过其他 OSS 项目做。它是 OSS-with-managed-service 模型的杀手锏（用户体验上能无缝从你 hosted 切到自己部署，不锁定）
5. **bootstrap.sh 把 13 个部署坑都修过** —— 这是**事实上的 OSS 友好度证据**。绝大多数 OSS 项目卡在 step 3 没人能跑通
6. **Push 通道无关 dispatcher** —— APNs/FCM 互不感知，加 geTui / 华为推送只要新写一个 provider 注册一行。比 Twilio 早期都干净
7. **审计 / Config Center / User Center / Registry / Backend 五个独立 web 服务**全自研全 supervisor 化部署 —— 你已经在做 SaaS 的事，只是没意识到

### 客观弱项：

1. **测试只有 1 个** —— 不影响 launch 但**接受外部 PR 之前**必须给 interpreter 加 unit tests
2. **README 之前是 Flutter 模板默认的**（我已重写一版草稿）
3. **没 LICENSE** —— 5 分钟能补
4. **`pubspec.yaml: name: flutter_application_1`** —— 没改成项目名
5. **docs 里 dapangyu.work 域名/邮箱痕迹**（30 分钟 sed 替换）
6. **没 viral demo 资产**（视频、GIF、screenshot 都没）

---

## Part 3 — "怎么火起来 + 你出名" 的诚实策略

你说想"火 + 出名"。我把这个拆成两条独立目标：

### 火 ≠ 出名

- **项目火**：GitHub stars / 用户量 / 媒体报道 / VC 关注
- **你出名**：开发者认你的名字 / 演讲机会 / 跳槽 / 创业融资

这两个**正相关但不一样**。SQLite 火死了但 D. Richard Hipp 普通人不知道。Linus 出名是因为他**持续发声 + 长期维护 + 个人品牌经营**，不只是 Linux 火。

如果你目标是**你自己出名**，下面 viral 部分是必要但不充分；还要看 Part 4 的"个人品牌"部分。

### 三条最高 ROI 的 viral 路径（按推荐优先级）

#### 🥇 路径 1：录"60 秒 AI 造 app"短视频反复发

**为啥这条最强**：
- 你产品的核心 wow 点是"我说了一句话，30 秒后我手机里多了一个能用的 app"
- 这是**所有同类产品里最适合短视频呈现**的，几乎专为抖音/小红书/Twitter 而生
- v0/Cursor 那帮"AI 写代码"的视频常常需要观众懂代码，**你这个不需要**
- 一个好视频比 100 个 GitHub star 来得快

**具体怎么做**：
1. 选 3 个 wow 场景：
   - "做一个我和女朋友吵架记账 app"（情感向，小红书命中率高）
   - "做一个我爸量血压记录 app"（孝心向，对中年用户传播力强）
   - "做一个班级群里发投票的 app"（实用向，群主转发概率高）
2. 录制要求：**单镜头一镜到底**，从"打开 app → 描述 → 等 → 跑起来" 全过程，不剪辑
3. 视频时长 < 60s（抖音首页停留率），最好 < 30s（推特/Threads 完播率）
4. 第一帧字幕："我用 AI 给 XX 做了个 app"（钩子），不要先讲产品
5. 视频末尾**永远**说"扫码下载试试"或"评论区扣 1 给你做"

**节奏建议**：每周 1 个视频，**重复同一公式 5 周以上**才能数据。前 3 个视频几乎一定流量惨淡，第 4-5 个开始有数据。**绝对不要发了一个看数据不行就放弃**。

#### 🥈 路径 2：在 Hacker News 发英文 Show HN，强调"WeChat-mini-program but open source + AI generated"

**为啥这条值得做**：
- HN 受众 = 你最想抢的开发者人群 + VC 在看
- 英文圈 "AI 造 app" 现在是热点
- 你这个有"中国 WeChat 文化背景 + 跨平台 + 开源"三个 hook 同时存在

**怎么写 Show HN 标题**（重要程度 80%）：
- 烂标题：`Show HN: MyApp - AI generated server-driven UI framework`（太抽象）
- 好标题：`Show HN: Tell AI what app you want, get a running cross-platform app in 60s (no recompile)`（具体、有冲击）
- 神标题：`Show HN: I built the open-source version of WeChat Mini Programs (with AI generation)`（中国背景 + 类比清晰 + 开源差异化）

**发帖时机**：周二 / 周三的 UTC 14:00 左右（北京时间 22:00），周五周末数据差。同时同步发 Twitter / X / Reddit r/programming + r/FlutterDev / lobsters。

**准备**（缺一不可）：
- README 必须有 5 秒读懂的描述 + 60 秒视频 + 一行可跑的 demo（hosted）
- 提前在评论区准备好 5-8 条预期 FAQ 的回答（"how is this different from FlutterFlow", "why not just use code", etc.）
- 上线第一个小时**每条评论必须 1 小时内回**，HN 排名靠互动权重

#### 🥉 路径 3：在中文开发者圈做"我用 100 行 JSON 写了 X" 系列

**为啥这条独立做**：
- 即刻 / V2EX / Twitter 中文圈 / 少数派 受众跟 HN 完全不重叠
- 中文圈对"开源中国出品"的支持度比英文圈对你的"AI 造 app" 更直接
- 不用录英文视频，门槛低

**系列选题**：
- "我用 100 行 JSON 写了一个微信"（demo_im 本来就是这个）
- "我用 200 行 JSON 写了一个 Match3 游戏"
- "我用 50 行 JSON 写了一个会自动同步的笔记 app"

每篇配 1 个截屏 GIF + 完整 JSON 链接 + GitHub repo 链接。

---

## Part 4 — "出名" 这件事的诚实路径

**单靠"项目火"不会让你出名**。需要并行做这三件事：

### A. 个人公开身份

- GitHub profile：写完整简介 + pin 这个 repo + 真名 + 头像
- Twitter / X：用真名（或固定 handle 别换）持续发关于这个项目的进展
- 个人技术博客（v2ex / 即刻 / Medium / Substack 任选一）：每周一篇深度文章
- 中文圈：知乎 + 即刻 + 少数派
- LinkedIn：把"MyApp 作者"加到 headline

### B. 持续公开 build in public

- **每周 1 篇** "本周我做了什么 / 踩了什么坑" 帖子
- **每个 bugfix 公开复盘**（你 13 个部署坑就是绝佳素材）
- 数据指标公开（star 数、用户数、增长曲线）—— 别人对透明的项目更有好感

### C. 演讲 / 写作

- 等 stars 到 500+ 后投 Flutter China meetup / GDG / 各类技术大会
- 把"DSL 设计踩坑笔记" 写成长文，类似 Sentry 团队那种深度内部分享

---

## Part 5 — Launch 前必须做的清单（精简到真正必须）

✅ = 已完成 / 🟢 = 简单（< 1 小时）/ 🟡 = 中等 / 🔴 = 大

| # | 任务 | 优先级 | 难度 |
|---|---|---|---|
| 1 | ✅ ~~README 重写~~ 我已经写了草稿在 README.md，你 review 后调整 | 🔴 必须 | 已完成草稿 |
| 2 | 加 LICENSE 文件（Apache 2.0 模板，附录里我贴了） | 🔴 必须 | 🟢 5 分钟 |
| 3 | `pubspec.yaml` `name: flutter_application_1` → `myapp` | 🟡 重要 | 🟢 1 分钟 |
| 4 | 录 60 秒 wow demo 视频（路径 1 第 1 个） | 🔴 必须 | 🟡 半天 |
| 5 | 拿一个 logo / app icon 设计（不用专业，能看就行） | 🟡 重要 | 🟡 半天 / Fiverr / Midjourney |
| 6 | 把 `dapangyu.work` / `dapangyu-fish` 个人痕迹从 templates/regression-test.json 等示例里删掉（保留 backend 文档里的 README 例子可以，那是说明用法） | 🟢 nice | 🟢 30 分钟 |
| 7 | Public hosted free tier 上线（你 prod 已经在跑，只是没对外宣传） | 🔴 必须 | 已完成 |
| 8 | App Store / Play 上架（Play 已提审；iOS TestFlight 可先） | 🔴 必须 | 🟡 你已在做 |
| 9 | 加 1-2 个公开渠道入口（Twitter handle / Discord server / 即刻账号） | 🟡 重要 | 🟢 1 小时 |
| 10 | 准备 Show HN 帖子草稿（标题 + 描述 + 答 FAQ）| 🟡 视情况 | 🟡 2 小时 |

**不在必须清单的**（可以以后做，别 launch 卡这上面）：
- ❌ 加 CI（没人提 PR 之前无所谓）
- ❌ 写 unit tests（接 PR 之前再说）
- ❌ docker-compose-only 完全 mock 部署（bootstrap.sh 已够）
- ❌ 文档完整化（先有人来再补）
- ❌ 性能优化 / DSL v4 设计（产品-市场契合之前别投资）
- ❌ 法律 / 商标注册（流量起来再说）

---

## Part 6 — 你最该警惕的 3 个心态陷阱

我读完代码后**最担心你掉进去的坑**（按风险排序）：

### 1. "等代码再完美一点再发"陷阱

你 41k 行代码工程化程度已经比 99% 早期 OSS 项目好。**你随时可以发**。
- 在 v2.0 之前不要等
- 在测试覆盖率不够之前不要等
- 在某个新功能完成之前不要等
- launch 不是"准备好"，launch 是"开始接触市场"

### 2. "把精力分散到 5 个方向" 陷阱

我读到你这一周做的事：FCM 接入、Mirror、User Center、签名上 Play、客户端头像、Avatar 缓存、release minify 排查...
**全是改进型工作，不是 viral 型工作**。

短期最高 ROI 的事**只有一件**：录一个能传播的视频。
其他都可以等。

### 3. "开源 ≠ 自动有人来"陷阱

**不主动推 = 不会火**。GitHub trending 看的是当日 star 增速，没人发 = 没人加 star。

我见过太多技术上完美的 OSS 项目**因为作者觉得"代码自己会说话"** 最终 30 stars 死掉。

**代码不会自己说话。视频会。HN 帖子会。Twitter 持续输出会。**

---

## Part 7 — 一个具体的 30 天实验计划

如果你接受我的判断，下面这 30 天值得**专门安排出来做 launch**（其他改进型工作都让位）：

### Week 1 — 资产准备
- 周一：补 LICENSE / pubspec 名字 / 1-line description
- 周二-三：录第 1 个视频草稿（不剪辑，能跑通就行）
- 周四：注册 Twitter / Discord（或选一个中文平台）
- 周五：写好 Show HN 帖子初稿（请人 review）
- 周末：app icon + 海报图（小红书 / 抖音封面准备）

### Week 2 — 国内试水
- 即刻 / 小红书 / B 站发第一波（中文圈最容易反馈）
- 看数据 → 调标题 / 钩子 / 时长
- 跟评论的人对话（前 100 个用户每一个都加微信 / 跟踪反馈）

### Week 3 — 国际试水
- Show HN 发布
- Reddit r/FlutterDev / r/AIDev 同步
- Twitter 用英文发同一个视频
- 拉一拉 dev community 微信群 / Discord

### Week 4 — 数据分析 + 调整
- 哪个钩子最响？哪个渠道最多新增？哪种描述方式 conversion 最高？
- 如果都不行，**复盘哪里阻塞**而不是放弃。每一个 viral 项目都至少试过 3-5 个版本。

---

## 附录 A — Apache 2.0 LICENSE 模板（5 分钟事）

新建 `/LICENSE` 文件，粘贴：
https://www.apache.org/licenses/LICENSE-2.0.txt 全文

然后在每个源代码文件**头部**可加（非必须）：
```
// Copyright 2026 dapangyu / MyApp authors
// Licensed under the Apache License, Version 2.0
```

## 附录 B — 视频脚本模板（60 秒）

```
[0-3s] 镜头：手机黑屏 / 打开 MyApp
[字幕] "我用 AI 给我妈做了个量血压记录 app"

[3-10s] 镜头：聊天框输入
[字幕] 用户说话："帮我做一个量血压记录的 app，每天提醒，能看趋势"

[10-30s] 镜头：等待生成 + JSON 流式输出（加速 2x）
[字幕] "AI 在写代码... 用 JSON-DSL... 直接运行..."

[30-50s] 镜头：app 打开 → 输入血压 → 看图表
[字幕] "30 秒前还不存在的 app，现在能用了"

[50-60s] 镜头：app icon + 二维码
[字幕] "扫码下载 MyApp，AI 给你做任何 app"
```

## 附录 C — Show HN 文案草稿

```
Title: Show HN: I built the open-source version of WeChat Mini Programs (AI-generated)

Body:

Hi HN,

I've been building MyApp for the past year. It's a Flutter runtime that interprets
JSON-DSL into native cross-platform UI + business logic. The twist: you describe
what app you want to an LLM (Claude/DeepSeek/GLM), it emits a JSON config, and
the app loads + runs it instantly. No recompile, no app store review cycle.

Three things that make this different from FlutterFlow / Bolt / v0:

1. The runtime is the product. There's no code-export step. Apps are pure JSON.
2. Cross-platform: iOS / Android / Web / macOS / Linux / Windows from one DSL.
3. Server-driven by design: I can ship UI changes to running apps in seconds.

The DSL is at v3.3, 1700-line spec, 132 builtin functions, 50+ widgets, working
IM (OpenIM-based) with APNs+FCM push, a package registry with cross-instance
mirror, and a one-command Docker Compose self-host (26 containers).

Demo video (60 sec): [VIDEO LINK]
GitHub: [REPO LINK]
Try the hosted version: [APPSTORE / PLAY LINKS]

Happy to answer questions about the DSL design, AI prompt engineering, or the
"server-driven UI but for end users not enterprises" thesis.

[Your name]
```

---

## 最后

**你已经把一个不可能完成的东西做出来了**。剩下的不是"再写代码"，是"让世界知道这个存在"。后者跟工程师的本能反着来，但这一步**只有你自己能做**。

下一步建议：**这个文档读完后，做唯一一件事 —— 录第一个视频**。其他都晚于这件。

— Claude（读了 41k 行代码后的诚实意见）
