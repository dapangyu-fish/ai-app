# demo-im（微信式 IM）· 平台 IM 类 App 范本

一个"**纯前端 JSON-APP + 平台 IM 能力**、**不写后端**"的参考应用：最近会话、通讯录、搜人加好友、
好友请求通过/拒绝、单聊发消息、未读红点、实时收件箱；外加"我"的页面（头像/昵称/二维码/改名/换头像/主题/语言）。

> 这是和[贴吧全栈范本](../tieba/)**成对照**的另一条路：贴吧**自建 FaaS 社交**（假名、自有 Postgres），
> demo-im **用平台 IM**（真人 uid、平台托管、要推送）。两者的选型判断见下方表 / playbook §0。
> 配套方法论：[`docs/im-app-generation-playbook.md`](../../im-app-generation-playbook.md)。
> 完整生成思考记录：[`GENERATION-TRANSCRIPT.md`](GENERATION-TRANSCRIPT.md)。

## 文件在哪

本范本的 App 与组件库是仓库里**已发布的模板**，不在本目录重复存放：
- App：[`templates/demo_im.json`](../../../templates/demo_im.json)（`meta.name = demo-im`，底部 3 tab + 7 屏）
- IM 组件库：[`templates/lib_im.json`](../../../templates/lib_im.json)（把 `@im_*` 内置函数封成 `@lib_im.*`）
- 依赖：`lib_im` + `lib_user`（资料/头像）+ `common-ui`（选图/Toast）

本目录只放方法论用的**生成思考记录**（`GENERATION-TRANSCRIPT.md`）与本说明。

## 平台 IM vs FaaS 自建社交（选哪条）

| 维度 | **平台 IM**（demo-im 本篇） | **FaaS 自建**（[tieba](../tieba/)） |
|------|------|------|
| 身份 | 平台 uid + 权威昵称/头像，跨 App 一致 | 组内假名，反推不出 uid，按服务组隔离 |
| 好友图 | 全平台，能搜任意用户 | 仅本服务组内 |
| 实时 | 有（inbox 订阅 + 推送 + 未读） | 无（要轮询/手动刷新） |
| 数据归属 | 平台托管，不拥有 schema | 自己的 Postgres，表结构自定 |
| 写后端 | **不用** | 要写 + 部署 |
| 选它当 | 通讯录式真人社交、要推送/已读未读 | 应用内自建数据/假名社交 |

判据一句话：**"搜得到平台任何人 + 要推送" → 平台 IM；"我要自己的表 + 应用内假名" → FaaS。**

## 屏幕

| 屏 / tab | 内容 |
|------|------|
| `home` · 微信 | 最近会话（头像/`show_name`/`latest_text`/`display_time`/未读红点）→ `chat` |
| `home` · 通讯录 | 「新的朋友」(角标=待处理) +「搜好友」+ 好友列表 → `chat` |
| `home` · 我 | 资料卡 + 二维码/设置/刷新 |
| `add_friend` | 搜索 + 结果三态（加 / 发消息 / 这是你） |
| `applications` | 好友请求（通过 / 拒 / 已通过 / 已拒绝） |
| `chat` | 单聊气泡列表（全高 list + `scrollToEnd`）+ 钉底输入行 |
| `profile_qr` / `avatar_preview` / `settings` | 二维码 / 看大图 / 设置（改名/主题/语言） |

## `lib_im` 方法速查

`currentUserId` · `searchUsers` · `sendFriendRequest` · `listFriendApplications` · `acceptFriend` ·
`rejectFriend` · `listFriends` · `listConversations` · `getMessages` · `sendText` · `markRead` ·
`subscribeInbox` · `totalUnread`（字段说明见 playbook §1）。

## 几个关键技巧（详见 playbook）

- **实时**：`subscribeInbox` 在 `loadHome` **只调一次**，不要 timer 轮询；红点绑 `totalUnread`/`display_unread`，进会话 `markRead`。
- **聊天页滚动**：消息 `list` **不 shrinkWrap** + `scrollToEnd: true`，输入行钉底（和图文流页的"整页 scrollable + 列表 shrinkWrap"相反）。
- **身份**：`is_me`/`nickname`/`face_url`/`bubble_color`/`unread` 全由 IM 后端给，前端只渲染，不自己算。
- **不需要 `@get_auth_token`**：IM 能力在已登录会话直接可用，没有 FaaS 的取 token 时序坑。

## 本地校验

```bash
python3 backend/validate_json_app.py templates/demo_im.json   # 期望 exit 0、0 warning
```
没有后端要校验——纯前端 + 平台能力，无 `backend/`、无 schema、无部署。
