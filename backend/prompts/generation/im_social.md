# IM / 社交类 APP 生成指南

适用：聊天、通讯录、好友申请、会话列表、个人页、设置页、朋友圈式信息流、IM 演示应用。

## 参考

- 主要参考 `templates/demo_im.json` 的 API 形状和页面组织。
- 不要直接换壳照抄 demo；用户需求不同就重新设计 tabs、页面、数据结构和文案。
- 如果包含个人设置、表单、主题、语言等功能，可补读 `backend/prompts/generation/native_app.md` 的设置/表单结构。

## 依赖与数据源

常用依赖：

```json
"dependencies": {
  "lib_im": "^1.1.0",
  "lib_user": "^1.3.0",
  "common-ui": "^1.0.0"
}
```

常用能力：

- `@lib_im.currentUserId`
- `@lib_im.listFriends`
- `@lib_im.listConversations`
- `@lib_im.listFriendApplications`
- `@lib_im.getMessages`
- `@lib_im.sendText`
- `@lib_im.markRead`
- `@lib_im.totalUnread`
- `@lib_user.getUserName`
- `@lib_user.getUserAvatar`
- `@lib_user.getOtherUserAvatar`
- `@lib_user.updateUserName`
- `@lib_user.uploadAvatar`

具体字段以 `templates/lib_im.json`、`templates/lib_user.json`、`lib/json_ui/interpreter.dart` 为准。

## 页面结构

聊天 / 通讯录类 APP 通常至少包含：

- 会话列表：头像、昵称、最后消息、时间、未读数。
- 通讯录：好友列表、新朋友入口、搜索入口。
- 聊天页：消息列表、输入框、发送按钮、刷新/已读逻辑。
- 个人页：头像、昵称、二维码/设置入口。
- 设置页：能真实修改的功能才做按钮；未实现功能用“开发中”提示，不要假按钮。

## 头像规则

- 好友、会话、消息头像优先使用 `face_url` / `sender_face_url`。
- 自己头像优先来自 `@lib_user.getUserAvatar`。
- 不要手写固定头像 URL。
- 不要为了头像在 JSON 里做大量逐用户临时 search；框架层会对 IM list/history 做 profile 回填。

## 交互规则

- 列表项必须可点击进入真实页面或显示明确提示。
- 设置页里的功能要真能改状态或资料，例如头像、昵称、主题、语言。
- “朋友圈 / 收藏 / 卡包”等如果没有真实实现，不要做假页面；可替换成开发中提示或删除。
- 发送消息后要刷新消息列表、清空输入、更新未读/会话状态。

## i18n

如果用户要求多语言，JSON 层用 `global.i18n` / `t('key')`。至少保持导航、按钮、设置项、提示文本可切换。

不要把中文文案散落在大量动态字段里，除非是 demo 数据内容。
