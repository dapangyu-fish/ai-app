# 分层提示词索引

目标：先分类，再只读相关资料。不要为了一个普通表单 APP 阅读整套游戏、素材、IM、地图、视频规则。

## 分类流程

1. 先判断用户是在“新建 APP”还是“分析/修改当前 APP”。
2. 如果是当前 APP，主类型是 `debug_existing`。
3. 如果是新建，按主要交互选择一个主类型：
   - `native_app`：日记、笔记、待办、预算、习惯、联系人、CRM、库存、课程表、资料库、表单、列表管理工具、智能家居/设备控制面板、运营仪表盘。
   - `game`：平台跳跃、射击、跑酷、解谜、2048、白块、Flappy、拖拽棋盘、连续动画、60fps、物理、关卡。
   - `im_social`：聊天、通讯录、朋友圈、个人页、好友申请、OpenIM、消息列表。
   - `media_device`：相机、图片上传/裁剪、二维码、地图、视频、音频、传感器、文件选择。
   - `mixed`：同时包含多个能力时，选用户最关心的主类型，再补读一个能力文档。

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

`im_social`：
- 读 `backend/prompts/generation/im_social.md`
- 读 `backend/prompts/generation/validation.md`
- 只把 `templates/demo_im.json` 当作 `lib_im` / `lib_user` API 接线参考；不要复用它的 tab 结构、页面 id、函数名集合、通讯录静态行或视觉样式。

`media_device`：
- 读 `backend/prompts/generation/media_device.md`
- 如需外部视觉资源，读 `backend/prompts/generation/assets.md`
- 读 `backend/prompts/generation/validation.md`
- 查 `lib/json_ui/widget_builder.dart` 和对应 widget 源码确认字段。

`mixed`：
- 先选主类型文档，再补读最相关的一个能力文档。
- 如果是“游戏 + 资料管理”，以 `game` 为主，补读 `native_app` 的表单/列表部分。
- 如果是“聊天 + 个人资料/设置”，以 `im_social` 为主，补读 `native_app` 的设置页结构。

## 探索边界

- 普通工具类 APP：读完索引、native 文档、validation、一个模板后就开始写生成器。只有 validator 报具体路径或 widget 字段不确定时，再查源码。
- 游戏：读完 game、assets、validation、一个模板和素材 manifest 后开始生成。不要深读 CRUD/native 模板。
- 每轮最多先读 1-2 个模板；除非 validator 或用户需求明确要求，避免无边界 grep 全仓库。
