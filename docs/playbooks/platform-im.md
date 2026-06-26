# 即时通讯（IM）类 App 生成方法（基于平台 IM 能力，**不写后端**）

这是和 [`faas-fullstack-app-generation-playbook.md`](faas-fullstack.md)
**互补**的另一条路：当需求是"微信式"的实时社交（通讯录、加好友、单聊、未读红点、推送）时，
**别去写 FaaS + Postgres**，直接用**平台内置 IM 能力**（`@im_*` 一组内置函数，已由 `lib_im` 封装好，
后端是平台托管的 OpenIM）。范本：`templates/demo_im.json`（微信风 IM，`meta.name = demo-im`）。

> ⚠️ **本文里出现的 `loadHome` / `openChat` / `sendMessage` 等函数名、`home/add_friend/chat` 等屏幕 id、
> 以及微信三 tab 结构，都只是 `demo_im` 的【示例形状】，用来讲清 `lib_im` 接线，不是要你照抄。**
> **必须按本轮产品重新设计信息架构、tab 划分、屏幕 id、函数名（用产品语义的动词，如 `loadInbox`/`openTicket`/
> `openGroup`/`postMoment`）、空状态与文案。** 判据：把品牌词换成"微信"后如果还像 `demo_im`（同一套
> `loadHome/openChat/addFriend` + 同样的页面），就是失败，要重做 IA。只把 demo 当 API 接线参考，不当骨架。

---

## 0. 最重要的一步：先判断用 IM 还是用 FaaS 自建社交

两条路都能做"好友 + 私信"，但**根基完全不同**，选错会绕一大圈：

| 维度 | **平台 IM**（`@im_*` / `lib_im`，本篇） | **FaaS 自建社交**（[贴吧范本](../examples/tieba/)） |
|------|------|------|
| 身份 | **平台 uid + 权威昵称/头像**（真人、跨 App 一致） | **组内假名**（不可反推 uid，按服务组隔离） |
| 好友图 | **全平台通用**，能搜任意平台用户 | **仅本服务组内**，靠在 App 里点到的人加 |
| 实时性 | **有**：inbox 订阅 + 推送 + 未读计数 | **无**：要自己轮询/手动刷新 |
| 数据归属 | 平台托管，**你不拥有 schema/数据** | **你自己的 Postgres**，表结构随便定 |
| 写后端 | **不用**（零 SQL、零部署） | 要写 `app.py` + `schema.sql` + 部署 |
| 适合 | 通讯录式社交、跨 App 私信、要推送/已读/未读 | 应用内轻社交、要自定义数据模型、要假名隐私隔离 |

**判据：**
- 需求里出现"加好友能搜到平台上任何人""消息要推送""未读红点""跨 App 都是同一个人" → **平台 IM**。
- 需求里出现"这个论坛/社区内部的关注与私信""我要自己存消息、自己定字段""用户在我这是匿名/假名" → **FaaS 自建**。
- 贴吧范本特意把社交建进 FaaS，正是因为 FaaS 后端只有假名、反推不出平台 uid，platform IM 接不上
  （见 fullstack playbook §4.6）。**反过来：要的就是真平台社交，就走本篇，别碰 FaaS。**

> 本篇 App **完全不写后端**：没有 `backend/`、没有 schema、没有部署。所有能力来自内置函数 + 现成组件库。

---

## 1. 平台 IM 能力栈：`@im_*` 与 `lib_im`

底层是一组内置函数 `@im_*`；`lib_im`（`templates/lib_im.json`，`type: library`）把它们一对一包成
可读的方法，App 通过 `dependencies` 引入后用 `@lib_im.xxx` 调。**优先用 `lib_im`，不要直接写 `@im_*`**
（除非 lib_im 没覆盖到）。

| `lib_im` 方法 | 内置 | 作用 / 返回关键字段 |
|------|------|------|
| `currentUserId(bind)` | `@im_current_user_id` | 我的平台 uid |
| `searchUsers(q, bind)` | `@im_search_users` | 搜用户 → `[{im_user_id, nickname, email, face_url, is_friend, is_self}]` |
| `sendFriendRequest(userId, message)` | `@im_send_friend_request` | 发好友请求 |
| `listFriendApplications(bind)` | `@im_friend_applications` | 收到的请求 → `[{from_user_id, from_nickname, from_face_url, req_msg, handle_result}]`（0待处理/1已通过/-1已拒） |
| `acceptFriend(userId)` / `rejectFriend(userId)` | `@im_accept_friend` / `@im_reject_friend` | 通过 / 拒绝 |
| `listFriends(bind)` | `@im_friend_list` | 好友 → `[{user_id, nickname, face_url}]` |
| `listConversations(bind)` | `@im_conversations` | 最近会话 → `[{user_id, show_name, face_url, latest_text, display_time, unread_count, display_unread}]` |
| `getMessages(userId, count, bind)` | `@im_history` | 单聊历史（count≤50）→ `[{is_me, is_other, sender_face_url, content_type(101文/102图/104视频), text, image_url, video_url, bubble_color}]` |
| `sendText(userId, text)` | `@im_send_text` | 发文本 |
| `markRead(userId)` | `@im_mark_read` | 标记会话已读 |
| `subscribeInbox()` | `@im_subscribe_inbox` | **订阅实时收件箱**（启动调一次） |
| `totalUnread(bind)` | `@im_total_unread` | 全局未读数（badge 用） |

**要点：所有"昵称/头像/已读未读"都是后端权威给的，前端只渲染**——这正是和 FaaS 假名模型的根本差别：
那边昵称要自己同步进 `profiles`，这边 `@im_*` 直接吐 `nickname`/`face_url`。

---

## 2. 身份模型：平台 uid + 权威昵称/头像

- `@lib_im.currentUserId` 给**平台 uid**（真实、可反查、跨 App 一致）；`@im_history` 每条消息带 `is_me`
  （后端按发送者 = 当前用户算好），前端左右气泡直接用，不用自己比对 uid。
- 搜索结果带 `is_friend` / `is_self`，据此渲染"加 / 发消息 / 这是你"三态按钮。
- 这套**不需要 `@get_auth_token`**：IM 能力在已登录会话内可直接用（登录态由框架托管）。
  贴吧那条"@get_auth_token 必须在动作里调"的坑，本篇**不存在**（没有 FaaS 调用）。

---

## 3. 实时与未读

```
启动 steps → @global.loadHome
  loadHome: @lib_im.subscribeInbox（订阅一次）→ currentUserId / 昵称 / 头像
           → listFriends / listFriendApplications / listConversations / totalUnread
```

- `subscribeInbox` **只在 loadHome 调一次**：订阅后收件箱有更新会推过来。**不要写 timer 轮询。**
- 进入会话 `openChat`：拉 `getMessages` → `markRead` → 重算 `totalUnread`（红点立刻清）。
- 发完消息 `refreshChat`：重拉历史 + `markRead` + `totalUnread`。
- 通讯录"新的朋友"角标、会话列表未读小红点：都绑 `totalUnread` / `conversation.display_unread`，
  用 `container` + `visible` 画红点（见 §6）。

---

## 4. 组合积木：`lib_user` + `common-ui` + i18n + 主题

IM App 很少单打独斗，`demo_im` 的 `dependencies` 是个好模板：
```json
"dependencies": { "lib_im": "^1.1.0", "lib_user": "^1.3.0", "common-ui": "^1.0.0" }
```
- **`lib_user`**：`getUserName` / `getUserAvatar`（我的资料）、`getOtherUserAvatar(userId)`（对方头像）、
  `updateAvatar(imagePath)`（换头像，内部 base64+上传）。
- **`common-ui`**：`pickImage(bind)`（选图）、`showSuccess(message)`（成功 Toast）。
- **i18n**：展示文案用 `{{ t('tabs.wechat') }}` 取多语言；切语言后重载。
- **主题**：`@set_theme {mode}`（system/light/dark）。

> 这些都是**现成组件**，新功能优先靠组合它们实现——和框架稳定性原则一致，别为一个 App 改框架。

---

## 5. 前端结构：底部 3 tab + 子屏

`demo_im` 用 screen 级 `tabs` 做微信式底部导航，外加若干跳转子屏：

| 屏 / tab | 内容 |
|------|------|
| `home` · tab「微信」 | 最近会话列表（头像+`show_name`+`latest_text`+`display_time`+未读红点）→ 点进 `chat` |
| `home` · tab「通讯录」 | 「新的朋友」入口（角标=待处理数）+ 「搜好友」入口 + 好友列表 → 点进 `chat` |
| `home` · tab「我」 | 资料卡（头像/昵称/uid）+ 二维码 / 设置 / 刷新 |
| `add_friend` | 搜索框 + 结果列表（按 `is_friend`/`is_self` 切按钮） |
| `applications` | 好友请求列表（按 `handle_result` 切 通过/拒绝/已通过/已拒绝） |
| `chat` | 单聊：消息气泡列表 + 底部输入行 |
| `profile_qr` / `avatar_preview` / `settings` | 二维码 / 看大图 / 设置（改名、主题、语言） |

提醒：screen `tabs` **没有切换钩子**——`loadHome` 一次性把三个 tab 的数据都拉好；点 tab 不重拉。
需要刷新时给个手动按钮 / 进子屏时重拉。

---

## 6. 聊天页关键技巧（和贴吧的滚动契约正好相反）

**聊天页用"全高 `list` + `scrollToEnd: true`"，输入行固定在底部——不要 shrinkWrap。**
贴吧那种"整页 `scrollable` + 列表 `shrinkWrap`"适合图文流；聊天页要的是"消息区自己滚、输入框钉底"，
所以消息 `list` **不写 shrinkWrap**（让它吃满剩余高度），`scrollToEnd: true`（新消息自动滚到底）：
```json
{ "type": "list", "source": "{{ global.messages }}", "scrollToEnd": true, "separator": "none",
  "item_template": { ...气泡... } }
```

左右气泡用 `visible` + 前导/后随的 flex `spacer` 分边（后端已给 `is_me` / `is_other` / `bubble_color`）：
```json
{ "type": "container", "layout": "column", "children": [
  { "type": "container", "layout": "row", "visible": "{{ loop.item.is_other }}", "crossAxisAlignment": "start",
    "children": [
      { "type": "avatar", "url": "{{ loop.item.sender_face_url }}", "size": 40 },
      { "type": "spacer", "width": 8 },
      { "type": "container", "color": "{{ loop.item.bubble_color }}", "borderRadius": 8, "padding": 10,
        "child": { "type": "text", "value": "{{ loop.item.text }}", "style": { "fontSize": 15 } } } ] },
  { "type": "container", "layout": "row", "visible": "{{ loop.item.is_me }}", "crossAxisAlignment": "start",
    "children": [
      { "type": "spacer", "position": { "type": "flex", "flex": 1 } },
      { "type": "container", "color": "{{ loop.item.bubble_color }}", "borderRadius": 8, "padding": 10,
        "child": { "type": "text", "value": "{{ loop.item.text }}", "style": { "fontSize": 15 } } },
      { "type": "spacer", "width": 8 },
      { "type": "avatar", "url": "{{ global.myAvatar }}", "size": 40 } ] } ] }
```
图片/视频消息按 `content_type`（102/104）切 image/video 控件（`visible` 判 `content_type`）。

**发消息闭环**（先判空 → 发 → 清草稿 → 重拉）：
```json
"sendMessage": { "logic": [ { "call": "@if", "args": {
  "condition": { "and": [ { "!!": [{ "var": "global.draft" }] }, { "!=": [{ "var": "global.draft" }, ""] } ] },
  "then": [
    { "call": "@lib_im.sendText", "args": { "userId": "{{ global.currentChatUserId }}", "text": "{{ global.draft }}" } },
    { "call": "@set", "args": { "var": "global.draft", "value": "" } },
    { "call": "@global.refreshChat", "args": {} } ] } } ] }
```

未读红点（绑 `display_unread` / `totalUnread`，`visible` 控制）：
```json
{ "type": "container", "visible": "{{ loop.item.display_unread }}", "color": "#FA5151", "borderRadius": 10, "padding": 4,
  "child": { "type": "text", "value": "{{ loop.item.unread_count }}", "style": { "fontSize": 11, "color": "#FFFFFF" } } }
```

---

## 7. 加好友闭环

```
通讯录「搜好友」→ add_friend：searchUsers(q) → 结果列表
  按行三态：is_self → 文案「这是你」；is_friend → 按钮「发消息」(openChat)；
            否则 → 按钮「加」→ sendFriendRequest(userId, "你好，加个好友")
通讯录「新的朋友」→ applications：listFriendApplications
  handle_result==0 → 「通过」(acceptFriend→loadHome) /「拒」(rejectFriend→loadHome)
  ==1 已通过(绿字) / ==-1 已拒绝(灰字)
```
通过/拒绝后都 `@global.loadHome` 重拉（好友表 + 请求表 + 会话一起刷新），再 `showSuccess` 提示。

---

## 8. 交付前 Checklist

- [ ] 需求确属"平台级实时社交" → 用本篇；若是应用内自建数据/假名社交 → 改走 FaaS 范本。
- [ ] `dependencies` 引入 `lib_im`（必）+ 视需要 `lib_user` / `common-ui`；展示文案走 `t()`。
- [ ] 启动 `steps` → `loadHome`：`subscribeInbox` **只调一次** + 拉 me/好友/请求/会话/未读。
- [ ] 昵称/头像/已读未读**全用后端字段**（`nickname`/`face_url`/`is_me`/`bubble_color`/`display_unread`），不自己造。
- [ ] 聊天页：消息 `list` **不 shrinkWrap** + `scrollToEnd: true`，输入行钉底；发完 `refreshChat`。
- [ ] 加好友三态（加/发消息/这是你）+ 请求三态（通过/拒/已处理）齐全；处理后 `loadHome`。
- [ ] 进会话 `markRead` + 重算 `totalUnread`，红点能清。
- [ ] `validate_json_app.py` exit 0、0 warning。
- [ ] **没有 backend/、没有 schema、没有部署**——本篇 App 的正确形态就是"纯前端 + 平台能力"。

范本与生成思考记录见 [`docs/examples/demo-im/`](../examples/demo-im/)。
