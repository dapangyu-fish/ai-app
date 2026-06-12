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

自检：

- Dart plan 中每个 widget/action 都能在 JSON-DSL 中表达。
- 每个 screen 都有明确 `id`。
- 每个交互都有对应 JSON action。
- 不存在不可转换 Flutter 能力。

