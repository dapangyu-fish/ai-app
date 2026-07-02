# MyApp Launch Notes

> 历史发布/策略备忘，包含当时的代码体量、计划和判断。当前架构事实请以
> `README.md`、`backend/ARCHITECTURE.md`、`backend/REGISTRY_README.md` 和代码为准。

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
| Other services | | `config_center/` / `backend/video_server.py` |
| Templates | 31,578 JSON | 30+ 个示例 JSON-APP |
| - `regression-test.json` | 10,367 | 单文件 10k 行回归测试 app（很多功能验证） |
| - `match3-pixel.json` | 3,008 | 像素消除游戏，纯 DSL 写的 |
| - `calculator.json` | 1,426 | 完整计算器 |
| - `demo_im.json` | 700 | 用 DSL 写的 IM 客户端 |
| Docs | | 11 个 md 文件（JSON-DSL.md 1,778 行规范） |
| Deploy | | `myapp-ctl` 管理生产/测试栈；支持全量部署、组件级更新、密钥配置和健康检查 |

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
5. **`myapp-ctl` 把部署坑收敛成一个控制面** —— 全量部署、组件级更新、密钥配置、健康检查、日志和 agent 状态都能从同一个 CLI 管理
6. **Push 通道无关 dispatcher** —— APNs/FCM 互不感知，加 geTui / 华为推送只要新写一个 provider 注册一行。比 Twilio 早期都干净
7. **审计 / Config Center / User Center / Registry / Backend 五个独立 web 服务**全自研，并已收敛到容器化控制面部署

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
- 你产品的核心 wow 点是"我说了一句话，10-20 分钟后我手机里多了一个能用的 app"
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
- ❌ 旧 bootstrap/test-env 文档（生产入口已经统一到 `myapp-ctl`）
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

[10-30s] 镜头：等待生成 + JSON 流式输出（快进加速展示）
[字幕] "AI 正在生成... 通常需要 10-20 分钟... （已加速）"

[30-50s] 镜头：app 打开 → 输入血压 → 看图表
[字幕] "生成完成，立即可用，无需编译"

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
what app you want to an LLM (Claude/DeepSeek/MiniMax), it emits a JSON config, and
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

---

## Part 8 — Registry 扩展架构待办（规模点触发，现在别做）

> 2026-05-20 讨论记录。触发条件：registry 包数到 **几百个**。今天 35 个，下面全部不用动。

### 现状

- 现役 `registry_server.py` 用 **MinIO 上单个 `_index.json`** 存全部包目录
- 每次 publish / mirror sync 都 **load 整个文件 → 改 → 写回整个文件**（在 `index_lock` 里）
- Postgres `app_registry` 表是**老 store.py legacy 路由**用的，新 Registry 主链路不碰
- 历史：当初主动从 Postgres 迁到了 MinIO json（`registry_init.py` 是迁移脚本）

### 三个会同时爆发的问题（同一个根因 + 同一个解）

1. **单文件读写低效**：几百个包后，每个 `/packages` `/resolve` 请求反序列化几 MB；每次 publish 写几 MB 串行化
2. **富元数据没地方放**：exports / dependencies / widgets_used 想存进索引做检索，但塞进单 JSON 会让上面更糟
3. **检索**：包多了要按相关度召回（关键词→pgvector）

→ **三个都指向同一个解：目录搬进 Postgres。** 同一个规模点（几百包）同时触发。

### 正确目标架构（实证：照抄 PyPI / Warehouse，别自己发明）

PyPI 是分两层的（查证过 warehouse.pypa.io/architecture.html）：

| 层 | PyPI 用什么 | 我们对应 |
|---|---|---|
| 权威服务端（写/查/搜索） | **PostgreSQL** + OpenSearch + Redis | Postgres `registry_packages` 表（已有 jsonapp-postgres 容器）|
| 分发/镜像层（给安装器+镜像读） | **静态可缓存文件**，**per-project 粒度**，走 CDN | per-package 静态文件，可从 DB 生成+缓存 |
| 包文件 | 对象存储 B2/S3 | MinIO（不变）|
| 搜索 | OpenSearch | 先 Postgres 全文 → 后 pgvector（Supabase 自带）|

**关键纠正**：问题不是"用 JSON 文件"（PyPI 也用 JSON，PEP 691），而是"用了一个 **monolithic** 文件"。PyPI 是**一个包一个索引文件**，根目录只列包名。bandersnatch 镜像就是拉这些 per-package 静态文件，镜像端不需要 DB。

我们的 mirror（`/mirror/file` per-package 代理+缓存）**已经踩在正确的 PEP 503 / bandersnatch 路线上**，只差把"目录"（`/mirror/manifest` 那个大 JSON）也拆成 per-package 粒度。

### 迁移时要做的（到规模点再做，约 1 天）

1. 建 Postgres `registry_packages` 表：name / type / latest / versions(JSONB) / appid / description / meta_type / **exports(JSONB)** / **dependencies(JSONB)** / **widgets_used(JSONB)** / created_at / author_id / source / （未来）embedding(vector)
2. publish 时：解析包 JSON 提取 exports/dependencies/widgets_used，写 1 行（不再 load 整个 index）
3. `_load_index`/`_save_index` → 改成查/写 Postgres；`_index.json` 退役或降级成生成的快照缓存
4. `/packages` `/resolve` `/mirror/manifest` → 查 Postgres 吐 JSON（对外格式不变，下游/客户端无感）
5. `/mirror/manifest` 拆成"根列表（只名字+版本）+ per-package 详情"
6. backfill 脚本：把现有包重新解析一遍灌进表
7. 检索（可选，更晚）：Postgres 全文 → pgvector hybrid + LLM 重排，详见 Part（之前对话）

### 现在的纪律

- **别往 `_index.json` 塞 exports/dependencies** —— 会让单文件问题更早爆发，是反方向
- 35 个包，monolithic JSON 完全够用，**啥都不动**
- 真要 catalog 带 library API 签名喂 AI，那是触发 Postgres 迁移的理由，不是 fatten JSON 的理由

---

### 元数据 / summary / 检索策略（2026-05-20 最终结论，覆盖本节前面的"富化推迟"说法）

**背景痛点**：现在挑参考模板就费劲 —— 标题太薄、全文太重（10k 行 JSON）。所以"密集摘要 summary"**不是向量检索的增强，是让目录可被挑选的本体**，现在就需要。

**三层分离（capture / enrich / search 互相独立，别捆一起）**：

| 层 | 干啥 | 成本 | 何时做 | 存哪 |
|---|---|---|---|---|
| ① 捕获 capture | 解析 JSON 提 exports/deps/widgets/builtins | 几乎零（纯解析） | 迁 Postgres 时 | DB |
| ② 富化 enrich | LLM 写 summary + tags + 拼 search_text | 贵（LLM） | **现在就该有**（解决挑选痛点） | **DB，不进 JSON** |
| ③ 检索 search | query → top-K | 看方案 | 推迟（先全量 catalog → 全文 → 向量） | — |

**关键决策 1：summary 放 DB，不放 `meta` / 不进 package JSON。**
- 跟 PyPI 一致：包文件保持纯净（= wheel），检索元数据在 catalog DB（= Warehouse Postgres），从包派生但分离
- 好处：包 immutable 不被污染；summary 可随时重算不产生新版本；内容走文件同步、目录元数据走目录同步
- 连带后果：「生成 AI 顺手写进 meta」这条免费路径**不用了**

**关键决策 2：summary 由异步 enrich worker LLM 生成（方案 A）。**
- publish 只写结构化字段 + 标 `needs_reindex=true`，**不卡 LLM**，立刻返回
- 独立 worker 扫 `needs_reindex` 行 → 读包全文 → LLM 写 summary + tags → 写回 DB、清 flag
- 覆盖所有包（含老包/手工包），逻辑统一，无"AI 漏写"边界
- backfill = 全表 `needs_reindex=true`；改富化逻辑 = 同样翻 flag 重跑
- 以后加 embedding 也在同一个 worker 里顺手做
- （优化备选，现在不做：publish 请求带 summary 字段复用 AI 的活 / 复用 AI 给用户的"我做了啥"那段话 —— 等 worker LLM 成本肉疼再加）

**关键决策 3：embedding（向量）仍然推迟。**
- summary 现在做；embedding 等几百个包再 backfill，embed 现成的 search_text
- summary 不依赖 embedding：向量阶段直接 embed `search_text`（= summary + exports + deps 拼接），不用重写 summary
- 这就是"summary 现在做、向量推迟"不矛盾的原因：summary 是地基，被每一级挑选方式（全量 catalog → 全文 → 向量）复用

**关键决策 4：mirror 通过 manifest 传 summary，不通过文件。**
- `/mirror/manifest` 多带 summary/tags 字段 → 下游 sync 写进自己 DB
- 包文件照旧走 `/mirror/file`
- 干净分离：内容走文件同步，目录元数据走目录同步（同 bandersnatch：simple index 元数据 + release files 内容分开拉）

**挑选体验（有了 summary，现在就能用，不等任何检索基建）**：catalog 注入变成「每包 2-4 行：name + meta_type + summary + tags + exports/deps」，AI 扫一眼挑相关的 → 只对选中的 curl 全文。包多到 catalog 塞不下 prompt 时，再加"关键词/全文过滤 summary → 注入 top-K"，最后才向量。summary 让每一级都成立。

**schema 补充**（在前面 schema 草图基础上明确）：`summary` / `tags` / `search_text` 是 enrich worker 填，**数据来源是包全文，存储位置是 DB，绝不回写进 package JSON**。`needs_reindex BOOLEAN` + `indexed_at` 是重建队列的核心。
