# Step 1: Generate Dart Plan

开始写 JSON 前，先写 `$AI_APP_WORKSPACE/app_dart_plan.dart`。

要求：

- 先做极简信息架构和视觉计划，但不要输出给用户。
- Dart plan 要像高质量原生移动端 APP 的结构：清晰导航、真实数据密度、合理留白、明确操作状态。
- 工具/记录/管理类 APP 要偏 native：顶部栏、列表、筛选、表单、详情页、设置或统计，不要做营销页。
- 内容/社区类 APP 要有信息流、发布入口、详情、收藏/个人状态，不要套用聊天 APP。
- 游戏类 APP 要先定义玩法闭环、实体、输入、胜负、分数、生命、重开、暂停。
- 多页面纵向内容必须使用 scroll/list，避免底部内容不可达。
- 如果需要资产，优先使用 manifest/OSS 可用资产；没有资产时使用 JSON-DSL 可绘制或可替代的视觉 primitive。

原生质感细则（与 v1 native/game 规则保持一致，已经可视化验证）：

- 多分区 APP 主导航优先底部导航（bottom nav），而非顶部文字 tab；更贴近 iOS/Android 原生。
- 快捷场景 / 快捷开关等动作入口用紧凑横向 chip 行或两列网格，不要每个做成占满整行的纵向大列表项，避免把真内容挤出首屏。
- 任何"标签 + 当前值"必须有合理默认值，不要渲染成标签后空白；设备/控件不要把原始类型枚举（light/switch/sensor）当副标题，要么省略要么显示真实状态（如"已开·亮度80%"），优先用真实开关控件。
- 所有用户可见文字必须中文：标题、按钮、弹窗、游戏 HUD/得分/失败弹窗；不要出现 "Tap to restart""Game Over""Pixel Runner" 等英文。
- 不要用 emoji 当标题/HUD/列表状态/空状态/游戏弹窗的图标；用 icon（取自 icon_registry.dart）或纯文字。

自检：

- Dart plan 中每个 widget/action 都能在 JSON-DSL 中表达。
- 每个 screen 都有明确 `id`。
- 每个交互都有对应 JSON action。
- 不存在不可转换 Flutter 能力。

