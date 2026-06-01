# IM / 社交类 APP 生成指南

适用：聊天、通讯录、好友申请、会话列表、个人页、设置页、朋友圈式信息流、IM 演示应用。

## 参考

- `templates/demo_im.json` 只能作为 `lib_im` / `lib_user` API 接线、头像字段、消息读写流程的参考。
- 不要参考 `demo_im` 的 tab 数量/顺序、页面 id、函数名集合、通讯录静态行、视觉结构和配色。除非用户明确要求“微信克隆”，否则这些都必须按本轮产品重新设计。
- 不要直接换壳照抄 demo；用户需求不同就重新设计 tabs、页面、数据结构、空状态和文案。如果把品牌词替换成“微信”后仍然像 `demo_im`，说明设计失败，需要重做信息架构。
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

如果用户要求“小红书 / Instagram / 社区 / 内容流”这类社交产品：

- 内容消费是主体验，优先做首页/发现瀑布流或卡片流、笔记详情、发布/互动入口、创作者个人页。
- IM 和通讯录只是辅助能力，不要把产品做成 `demo_im` 的会话 + 通讯录换皮。
- 函数名和页面名要表达当前产品语义，例如 `loadFeed`、`openNote`、`toggleLike`、`openCreatorProfile`、`openConversation`，不要整套复用 `loadHome/openChat/addFriendByRow`。

通讯录/好友页如果有“新朋友、搜索、分组标题”等静态入口：

- 静态入口要紧凑，不能在顶部堆出大空白。
- 后面的好友列表如果只是嵌在页面中的一段内容，必须写 `"shrinkWrap": true`，并提供紧凑 emptyText。
- 默认 full-height `list` 只能作为该 tab 的主滚动区域；不要放在 4 个以上静态兄弟节点后面。

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
