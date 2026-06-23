# 分层提示词索引

目标：先分类，再只读相关资料。不要为了一个普通表单 APP 阅读整套游戏、素材、IM、地图、视频规则。

## 分类流程

1. 先判断用户是在“新建 APP”还是“分析/修改当前 APP”。
2. 如果是当前 APP，主类型是 `debug_existing`。
3. 如果是新建，按主要交互选择一个主类型：
   - `native_app`：日记、笔记、待办、预算、习惯、联系人、CRM、库存、课程表、资料库、表单、列表管理工具、智能家居/设备控制面板、运营仪表盘。**（注意：这些默认是“纯前端/本地状态”，不带后端；一旦要“多用户互相可见 / 服务端持久化 / 登录身份”，改走 `faas_fullstack`，见第 4 步。）**
   - `game`：平台跳跃、射击、跑酷、解谜、2048、白块、Flappy、拖拽棋盘、连续动画、60fps、物理、关卡。
   - `im_social`：聊天、通讯录、朋友圈、个人页、好友申请、OpenIM、消息列表。
   - `media_device`：相机、图片上传/裁剪、二维码、地图、视频、音频、传感器、文件选择。
   - `mixed`：同时包含多个能力时，选用户最关心的主类型，再补读一个能力文档。
4. **再判一个正交维度：要不要后端？**（决定读哪份深度 playbook，和上面的 UI 主类型叠加）
   - **不要后端**（纯 UI / 本地状态 / 不登录不存数据不调外部接口）→ 无需后端 playbook，按 UI 主类型直接生成。
   - **平台级实时社交**（搜得到平台上任何人 / 加好友 / 单聊私信 / 未读红点 / 推送 / 跨 App 同一个人）→ `im_social` 走**平台 IM** 路径（不写后端）。
   - **多用户 + 服务端持久化**（论坛 / 社区 / 贴吧 / 打卡 / 任意用户互相可见、要存数据、要身份；或“应用内假名的关注/私信”）→ `faas_fullstack`（写 FaaS + Postgres）。
   - **要后端但无数据库**（代理网站 / 纯计算 / 调第三方 HTTP / 定时任务）→ `faas_simple`。
   - 判不准就读 `docs/playbooks/README.md` 的决策树（平台 IM 轨 vs FaaS 全栈轨）。**这比盲读 demo 源码更可靠。**

## 按类型读取

`debug_existing`：
- 读 `backend/prompts/generation/debug_existing.md`
- 读 `backend/prompts/generation/validation.md`
- 下载当前 JSON 后，只按具体问题查源码/模板。

`native_app`：
- 读 `backend/prompts/generation/native_app.md`
- 读 `backend/prompts/generation/validation.md`
- 从这些模板中选 1-2 个：`templates/native_quality_notes.json`、`templates/native_quality_crm.json`、`templates/native_quality_budget.json`、`templates/native_quality_habits.json`、`templates/native_quality_workout.json`
- 非 CRUD 工具可选：`templates/framework_quality_smart_home.json`、`templates/framework_quality_ops_dashboard.json`、`templates/framework_quality_travel_pass.json`、`templates/framework_quality_course_player.json`、`templates/framework_quality_camera_inspection.json`

`game`：
- 读 `backend/prompts/generation/game.md`
- 如需图片/角色/地图/背景，读 `backend/prompts/generation/assets.md`
- 读 `backend/prompts/generation/validation.md`
- 从 `templates/demo_2048.json`、`templates/demo_tap_white_tile.json`、`templates/demo_jump.json`、`templates/demo_flappy_bird.json` 或相近 game 模板中选 1 个学习 API 形状。不要复制关卡设计。

`im_social`（先分叉：平台 IM vs 应用内 FaaS 社交）：
- 读 `backend/prompts/generation/im_social.md`（含分叉判断）
- 读 `backend/prompts/generation/validation.md`
- **平台级真人实时社交**（搜平台任意人 / 推送 / 跨 App 同一人）→ 走**平台 IM 轨**：
  - 先读深度方法论 `docs/playbooks/platform-im.md`（Tier-2，比盲读 demo 更牛），再翻范本 `docs/examples/demo-im/`。
  - 只把 `templates/demo_im.json` / `lib_im.json` 当作 `lib_im` / `lib_user` API 接线参考；**不要复用它的 tab 结构、页面 id、函数名集合、通讯录静态行或视觉样式**。
  - 不写后端 / schema / 部署；昵称头像已读未读全用后端字段；不需要 `@get_auth_token`。
- **应用内（假名）的关注/私信**（只在这个 App 内部、要自定义表）→ 改走 `faas_fullstack`（platform IM 接不上 FaaS 假名，原因见 playbook）。

`faas_fullstack`（多用户 + 服务端持久化：论坛/社区/打卡/应用内社交）：
- 先读 `docs/playbooks/faas-jsonapp.md`（Tier-1a：受限 Flask / bundle / `@faas.*` 接线 / 本轮内部署自测 / “点了没反应”根因）
- 再读 `docs/playbooks/faas-fullstack.md`（Tier-1b：UUID 数据模型 / `myapp_db`+`myapp_auth` 三套路 / 不可伪造组内假名+真实昵称 / 楼中楼 DFS+折叠 / 用户主页+好友+私信 / 部署自测）
- 实现时翻范本 `docs/examples/tieba/`（前端 7 屏 + 后端 14 路由 + 思考记录）
- 读 `backend/prompts/generation/validation.md`
- 红线：主键一律 UUID；身份只信 `current_user()`（组内假名 ≠ 平台 uid）；**`@get_auth_token` 必须在写动作里取、不能放启动 `steps`**。

`faas_simple`（要后端但无数据库：代理/计算/第三方 HTTP/定时）：
- 只读 `docs/playbooks/faas-jsonapp.md` + `backend/prompts/generation/validation.md`（不需要全栈/数据库那套）。

`media_device`：
- 读 `backend/prompts/generation/media_device.md`
- 如需外部视觉资源，读 `backend/prompts/generation/assets.md`
- 读 `backend/prompts/generation/validation.md`
- 查 `lib/json_ui/widget_builder.dart` 和对应 widget 源码确认字段。

视觉/动画控件：
- 需要验证码、滑动验证、文字缩放、气泡提示、弧形滑块、复合渐变进度、星形爆炸、云词/径向布局等效果时，先查 `lib/json_ui/widget_builder.dart`，再按类型读 `lib/json_ui/widgets/form_primitives_widget.dart`、`progress_widget.dart`、`visual_primitives_widget.dart`、`layout_primitives_widget.dart`、`overlay_primitives_widget.dart` 的字段。
- 这些是通用原子能力，只能按功能使用，不能假设它们是某个模板或项目的专用桥。

`mixed`：
- 先选主类型文档，再补读最相关的一个能力文档。
- 如果是“游戏 + 资料管理”，以 `game` 为主，补读 `native_app` 的表单/列表部分。
- 如果是“聊天 + 个人资料/设置”，以 `im_social` 为主，补读 `native_app` 的设置页结构。

## 探索边界

- 普通工具类 APP：读完索引、native 文档、validation、一个模板后就开始写生成器。只有 validator 报具体路径或 widget 字段不确定时，再查源码。
- 游戏：读完 game、assets、validation、一个模板和素材 manifest 后开始生成。不要深读 CRUD/native 模板。
- 每轮最多先读 1-2 个模板；除非 validator 或用户需求明确要求，避免无边界 grep 全仓库。
