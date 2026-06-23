# demo-im · 生成全过程记录（模拟 AI 生成链路）

> 这是一份**模拟的生成思考记录**：假设用户在 MyApp 的"让 AI 生成一个 App"入口提了下面的需求，
> AI（生成 agent）从零把一个"微信式即时通讯 App"做出来的完整思考与动作轨迹。
>
> 和[贴吧范本](../tieba/GENERATION-TRANSCRIPT.md)成对照：贴吧选择**自建 FaaS 社交**，本例选择
> **平台 IM 能力、不写后端**。两份记录放一起看，最值钱的是"**第 1 节的选型判断**"。
> 配套方法论见 [`docs/im-app-generation-playbook.md`](../../playbooks/platform-im.md)。
> 最终产物：`templates/demo_im.json`（App）+ `templates/lib_im.json`（IM 组件库）。

---

## 0. 用户输入

> 做一个类似微信的 App：能看最近聊天、有通讯录、能搜人加好友、对方通过后能单聊发消息，
> 要有未读红点、消息要实时；还要有"我"的页面能看头像昵称、改名、换头像、切主题和语言。

---

## 1. 思考（最关键）：这该用平台 IM，还是自己写后端？

需求里全是**重词**：搜到平台上任何人、加好友、实时、未读红点、跨设备同一个账号。我逐个掂量：

- "搜人加好友"——要能搜到**平台上的真人**，不是只在我这个 App 内部。→ 需要**平台级好友图**。
- "实时""未读红点"——消息要推过来、未读要计数。→ 需要**实时收件箱 + 推送**，自己用 FaaS 轮询做体验很差。
- "对方通过后单聊"——标准 IM 好友请求 + 单聊。
- "我的页面：头像/昵称/改名/换头像"——平台**权威身份资料**。

**结论：这是"平台级实时社交"，应该用平台内置 IM 能力（`@im_*` / `lib_im`），不写 FaaS。**

我特意对照了一下贴吧那次：贴吧把好友/私信**建进了 FaaS**，因为那是"论坛内部、用假名、要自定义表"的轻社交，
而且 FaaS 后端只有组内假名、反推不出平台 uid，platform IM 根本接不上。**本例正好相反**——要的就是
真平台身份、跨 App 一致、要推送，那就**别碰 FaaS**：没有 `backend/`、没有 schema、没有部署。
（这一节就是两份范本最该被后人参考的地方：**先选根基，再动手。选错会绕一大圈。**）

---

## 2. 思考：能力盘点 + 用组件库而不是裸内置函数

平台给了一组 `@im_*` 内置函数，已经有现成库 `lib_im` 一对一包好了。**优先用 `lib_im`**（可读、稳定），
裸 `@im_*` 只在库没覆盖时才用。我列了张"需求 → 方法"映射，确认无缺口：

| 需求 | 用什么 |
|------|------|
| 我是谁 | `@lib_im.currentUserId` / `@lib_user.getUserName` / `getUserAvatar` |
| 最近会话 | `@lib_im.listConversations`（带 `latest_text`/`display_time`/`unread_count`） |
| 通讯录 | `@lib_im.listFriends` |
| 搜人加好友 | `@lib_im.searchUsers`（带 `is_friend`/`is_self`）→ `sendFriendRequest` |
| 新的朋友 | `@lib_im.listFriendApplications` → `acceptFriend` / `rejectFriend` |
| 单聊 | `@lib_im.getMessages`（带 `is_me`/`bubble_color`）→ `sendText` |
| 实时 / 未读 | `@lib_im.subscribeInbox`（订阅一次）+ `totalUnread` + `markRead` |
| 资料/换头像/主题/语言 | `@lib_user.*` + `@common-ui.pickImage` + `@set_theme` + `t()` |

零缺口，且**一行后端都不用写**。`dependencies` 定为 `lib_im` + `lib_user` + `common-ui`。

---

## 3. 思考：身份与"昵称/已读"谁来算

和贴吧最大的不同：**这里所有权威信息都由 IM 后端给，前端只渲染。**
- `@im_history` 每条消息已经带 `is_me`（后端按发送者==当前用户算好），左右气泡直接用，**前端不比对 uid**。
- 搜索结果带 `is_friend`/`is_self`，三态按钮直接据此切。
- 昵称 `nickname` / 头像 `face_url` 是平台权威值——不像贴吧要自己同步进 `profiles` 再 JOIN。
- 还有个隐含好处：**不需要 `@get_auth_token`**。IM 能力在已登录会话里直接可用，
  贴吧那条"token 必须在动作里取、不能放启动 steps"的坑，本例天然不存在（没有 FaaS 调用）。

---

## 4. 动作：搭骨架（变量 + loadHome + 启动）

启动只做一件事：`steps → @global.loadHome`。`loadHome` 是全局入口，一次拉齐首屏要的所有数据：
```
loadHome:
  @lib_im.subscribeInbox            ← 订阅实时收件箱，只此一次（绝不写 timer 轮询）
  @lib_im.currentUserId  → myId
  @lib_user.getUserName  → myName
  @lib_user.getUserAvatar→ myAvatar
  @lib_im.listFriends            → friends
  @lib_im.listFriendApplications → applications
  @lib_im.listConversations      → conversations
  @lib_im.totalUnread            → totalUnread
```
变量按"会话/通讯录/聊天/我/草稿"分组（`conversations`/`friends`/`applications`/`messages`/`draft`/
`currentChatUserId`…）。底部 `tabs` 没有切换钩子，所以一次性拉好、点 tab 不重拉。

---

## 5. 动作：聊天页（这里的滚动契约和贴吧相反）

贴吧是"整页 `scrollable` + 列表 `shrinkWrap`"的图文流；聊天页要的是"消息区自己滚、输入框钉底"。
所以消息 `list` **不写 shrinkWrap**（吃满剩余高度）、`scrollToEnd: true`（来新消息自动滚到底），
输入行作为兄弟节点固定在下方。左右气泡用 `visible: is_me/is_other` + flex `spacer` 分边，`bubble_color`
由后端给。`openChat` 进来先 `getMessages` → `markRead` → 重算 `totalUnread`（红点立刻清）；
`sendMessage` 先判空 → `sendText` → 清 `draft` → `refreshChat`。

---

## 6. 动作：加好友闭环 + 我的页面

- `add_friend`：`searchUsers(q)` → 结果按行三态：`is_self`→「这是你」；`is_friend`→「发消息」(openChat)；
  否则「加」→ `sendFriendRequest`。
- `applications`：`listFriendApplications` → `handle_result==0` 显示「通过/拒」，处理后 `loadHome` 重拉 + `showSuccess`。
- 「我」tab + `settings`：`getUserName`/`getUserAvatar` 展示；`changeAvatar` = `pickImage` →（非空）`updateAvatar`；
  `saveName`；`applyTheme`=`@set_theme`；`applyLanguage` 切 `t()` 语言后重载。

---

## 7. 动作：校验

```bash
python3 backend/validate_json_app.py templates/demo_im.json   # exit 0、0 warning
```
**没有后端要校验**——这正是本范本和贴吧的形态差异：纯前端 + 平台能力，无 `backend/`、无 schema、无部署。

---

## 8. 复盘：这次生成沉淀下来的可复用经验

1. **先选根基**：平台级真人实时社交 → 平台 IM、不写后端；应用内自建数据/假名社交 → FaaS。选错绕一大圈。
2. **优先用组件库**（`lib_im`/`lib_user`/`common-ui`）而不是裸内置函数；新功能靠组合积木，别改框架。
3. **权威信息全由后端给**（`is_me`/`nickname`/`face_url`/`bubble_color`/`unread`），前端只渲染、不自己算身份。
4. **实时靠 `subscribeInbox` 订阅一次**，不要 timer 轮询；红点靠 `totalUnread`/`display_unread` + `markRead`。
5. **聊天页滚动契约**：消息 `list` 不 shrinkWrap + `scrollToEnd`，输入行钉底——和图文流页正好相反。
6. **IM App 不需要 `@get_auth_token`**：登录态托管、IM 能力直接可用，没有 FaaS 的取 token 时序坑。
