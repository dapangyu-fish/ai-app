# 贴吧（Tieba）· 全栈 JSON-APP 范本

一个"前端 JSON-APP + FaaS 后端 + Postgres 数据库"一条龙的参考应用：
任意用户可**开吧**（建者即吧主）、**发主题**、**楼中楼无限嵌套回帖**（一组超过 2 条默认收起、可展开）、
**搜索吧**；点头像/名字进**用户主页**，可**加好友**，好友之间可**私信**。底部 3 个 tab（吧 / 好友 / 我的）。
列表展示发帖人的**真实昵称**。只做文本，不做图片。

> 这是"一条龙全栈生成"的标准范本。配套方法论：
> [`docs/faas-fullstack-app-generation-playbook.md`](../../faas-fullstack-app-generation-playbook.md)。
> 完整生成思考记录：[`GENERATION-TRANSCRIPT.md`](GENERATION-TRANSCRIPT.md)。

## 文件结构

```
docs/examples/tieba/
├── tieba.json                  前端 JSON-APP（底部 3 tab + 7 屏）
├── backend/
│   ├── app.py                  受限 Flask 后端（14 路由）
│   ├── schema.sql              Postgres 表结构（论坛 + 身份 + 社交）
│   └── service.json            路由清单（与 @app 装饰器对齐）
├── GENERATION-TRANSCRIPT.md    模拟生成全过程（需求→设计→实现→自测）
└── README.md
```

## 功能与屏幕

底部导航 3 个 tab（screen 级 `tabs`）：**吧** / **好友** / **我的**，外加若干可跳转的子屏。

| 屏幕 | 内容 |
|------|------|
| `home` → tab「吧」 | 搜索框 + 吧列表（吧名/简介/吧主/主题数）+ 创建新吧入口 |
| `home` → tab「好友」 | 待处理好友请求（通过/拒绝）+ 好友列表（点进私信）+ 刷新 |
| `home` → tab「我的」 | 我的资料卡（显示名 + 开吧/主题/回帖数）+ 我发的主题 + 刷新 |
| `board` | 吧信息 + 主题帖列表 + 发主题入口 |
| `thread` | 主题正文 + 楼中楼回帖（缩进 + 超 2 条折叠/展开/收起）+ 点名字看主页 + 回复框 |
| `user_profile` | 某用户公开主页 + 统计 + 最近主题 + 加好友/发私信（按与我的关系切换） |
| `chat` | 与某好友的私信会话（左右气泡 + 输入框 + 刷新） |
| `create_board` / `create_thread` | 表单 → 创建/发布 |

## 后端路由

| 方法 | 路径 | 说明 | 登录 |
|------|------|------|------|
| GET | `/whoami` | 当前调用者假名 + 我的显示名 | 可选 |
| POST | `/me` | 同步我的真实昵称到 `profiles`（只能改自己） | 必须 |
| GET | `/boards?q=` | 列/搜吧（`ILIKE`，空词=全部）；带吧主名 + 主题数 | 可选 |
| POST | `/boards` | 建吧，建者=吧主；吧名唯一（重名 409） | 必须 |
| GET | `/board?board_id=` | 单个吧详情（含 `is_owner`） | 可选 |
| GET | `/threads?board_id=` | 某吧的主题列表 | 可选 |
| POST | `/threads` | 在某吧发主题 | 必须 |
| GET | `/thread?thread_id=&expanded=` | 主题 + 回帖（DFS 拍平、带 `depth`/`indent`/`kind`，按 `expanded` 折叠楼中楼） | 可选 |
| POST | `/posts` | 回帖；`parent_id` 为空=回主题，非空=楼中楼 | 必须 |
| DELETE | `/posts?post_id=` | 删回帖（只能删自己的，否则 403） | 必须 |
| GET | `/user?owner_id=` | 用户公开主页：显示名 + 统计 + 最近主题 + 与我的关系 `rel` | 可选 |
| GET | `/friends` | 我的好友列表 | 必须 |
| GET | `/friends/requests` | 收到的待处理好友请求 + 计数 | 必须 |
| POST | `/friends/request` | 发好友请求（对方已请求过我则直接互为好友） | 必须 |
| POST | `/friends/accept` | 同意好友请求 | 必须 |
| POST | `/friends/reject` | 拒绝好友请求 | 必须 |
| GET/POST | `/dm` | 私信历史 / 发私信（**仅好友之间**，否则 403） | 必须 |

## 楼中楼无限嵌套 + 默认折叠是怎么做的

`posts.parent_id` 自引用一列承载任意层级。`GET /thread` 在后端做**迭代式先序 DFS**
（显式栈，不递归，避免深嵌套爆栈），输出一个扁平、按楼层顺序排好的数组：

- 普通帖子行 `kind:"post"`，带 `depth` 和 `indent`(=depth×16，第 12 层封顶) + `floor_label`（楼层/楼中楼）。
- 楼层（root）永远全显示；**任何一组楼中楼超过 2 条**且其父 id 不在 `expanded` 里 → 只发前 2 条 + 一个
  `kind:"more"` 行（带 `remaining` 剩余条数）；父在 `expanded` 里 → 全发 + 一个 `kind:"collapse"` 行。
- 前端用 `@list_add`/`@list_remove` 维护 `global.expanded` 集合、`str_join` 拼成 `?expanded=` 重拉（**不改框架**），
  item_template 按 `kind` 用 `visible` 渲染 post / 展开按钮 / 收起按钮。

## 用户主页 / 好友 / 私信是怎么做的

- **不能用平台 IM（`@im_*`）**：那套按平台 uid 工作，而 FaaS 只有**组内假名**、反推不出 uid。
  所以社交关系全建进 FaaS 自己的库、用假名做主体（`demo_im` 仅作 UI 参照：头像、左右气泡、输入行）。
- `friendships` 一条边一行、状态机 `pending→accepted`；`request` 时若对方已 `pending` 请求我 → 直接互为好友。
- `messages` 收发前后端查双向 `accepted` 边，**只有好友能私信**；`is_me` 由后端按 `sender_id==current_user()` 标，
  前端左右气泡用 `visible` 切。
- `/user` 返回 `rel{is_self,is_friend,outgoing_pending,incoming_pending}`，主页据此切「加好友/已发送/同意/发私信/这是你」。
- **隐私自洽**：好友/私信只在**本服务组内**用假名互通，跨 App 关联不了同一个人——和假名隔离一致。

## 身份与"真实昵称、防止有人改"

- 后端 `myapp_auth.current_user()` 返回**组内假名**（不可伪造、按 (服务组,用户) 稳定、不是平台 uid）。
  写操作把 `author_id`/`owner_id`/好友与私信的主体强制成它 → **没人能改/冒充别人的归属**。
- 显示名放 `profiles`，`_sync_name` 把 `owner_id` 强制成 `current_user()` → **只能改自己的名字**。
- 前端登录后/发帖前把用户**真实平台昵称**（`@get_user_info().username`）同步进 `profiles`，
  展示时后端 `LEFT JOIN profiles` 带出 `author_name`/`owner_name`/`display_name`。

**已知边界（诚实说明）：** 该设计挡住了"改/冒充他人"，但挡不住用户给**自己**起误导性的显示名（自报虚名）。
要严格到连自己都不能乱设，需要让该字段不走假名化、或给框架加能力——本范本**刻意不改框架**，把这条作为残留风险记录。
原因见 [`GENERATION-TRANSCRIPT.md` §3](GENERATION-TRANSCRIPT.md) 与 playbook §6。

## 本地校验

```bash
# 前端：静态校验（应 exit 0、0 warning）
python3 backend/validate_json_app.py docs/examples/tieba/tieba.json

# 后端：bundle 走 FaaS 校验器（AST 沙箱 / SERIAL / 路由匹配）
# stub config+database 后 import faas_store，对 {service_id,slug,routes,files} 调 validate_bundle
# 期望：VALIDATE OK / routes=14 / db_enabled=True
```

## 部署（概要）

详见 [`docs/faas-jsonapp-generation-playbook.md`](../../faas-jsonapp-generation-playbook.md) §5 与
[`docs/faas-docker-runtime.md`](../../faas-docker-runtime.md)。流程：

1. 把 `backend/`（`app.py` + `schema.sql` + `service.json`）打成 bundle 上传、创建/部署服务（service_id=`tieba`）。
2. 首跑执行 `schema.sql`（表属主=部署期 owner 角色；运行时角色只有 DML）。
3. 起运行容器（local-docker 运行时）。
4. 把 `tieba.json` 里的 `global.svc` 改成实际部署的 service id（默认 `tieba`），发布/加载前端。

## 上线后自测清单

```
建吧/重名409 · 搜吧 · 发主题 · 回帖 · 楼中楼(indent 递增 + >2 折叠/展开/收起) · 同步后显示真实昵称
· 点名字进主页 · 加好友(mutual auto-accept) · 同意/拒绝请求 · 好友间私信 · 非好友私信403 · 删别人403 · 未登录写401
```
