# 一条龙全栈 JSON-APP 生成方法（前端 + FaaS 后端 + Postgres 数据库）

> 范本：**贴吧**（`docs/examples/tieba/`）。本文是"带后端、带数据库、多用户"这类应用的**标准生成路径**，
> 照着走就能稳定产出一套能跑、能过校验、能部署的全栈应用。
>
> 只讲后端单文件细节的更底层文档见 [`faas-jsonapp-generation-playbook.md`](faas-jsonapp.md)（受限 Flask、bundle、点了没反应的根因等）。
> 本文聚焦**端到端**：需求 → 数据模型 → 后端 → 前端 → 身份/昵称 → 部署 → 自测。
>
> 关键原则（来自 CLAUDE.md「框架稳定性原则」）：**一条龙应用是"生成物"，不是框架。**
> 生成 `app.py` / `schema.sql` / `xxx.json` 永远不应该改 `lib/`、`backend/faas*.py` 这些框架代码。
> 现有原子控件 + 内置函数 + FaaS 运行时三件套（`myapp_db` / `myapp_auth` / `myapp_data`）满足不了时，
> 先想"换个设计"，而不是"加个框架能力"。

---

## 0. 七步全景

```
1) 收敛需求      把一句话需求拆成"实体 + 动作 + 谁能做 + 看到谁"
2) 设计数据模型   表 / 字段 / 主键(UUID) / 谁是 owner / 哪些是公开读
3) 写后端        schema.sql + app.py（受限 Flask，myapp_db/myapp_auth），本地过 validate_bundle
4) 写前端        xxx.json（@faas.* 调后端，list/loop 渲染，@navigate 串页面），本地过 validate_json_app.py
5) 接身份        写操作带 Authorization: Bearer，后端用 myapp_auth.current_user() 拿到不可伪造的假名
6) 部署          上传 bundle → 部署 → 跑 schema → 起容器（本轮自己完成，不甩给"服务端")
7) 自测          真用户链路打一遍：建、读、写、隔离、越权都验证
```

每一步都要"当场验证"：后端写完立刻 `validate_bundle`，前端写完立刻 `validate_json_app.py`，部署完立刻 invoke 打一发。
**不要攒到最后一起验证**——错误会叠加，难定位。

---

## 1. 收敛需求：从一句话到可实现的清单

把模糊需求拆成四个问题，逐条写死。以贴吧为例：

| 维度 | 问题 | 贴吧的答案 |
|------|------|-----------|
| **实体** | 系统里有哪些"东西"？ | 吧(board)、主题帖(thread)、回帖(post)、用户显示名(profile) |
| **动作** | 每个实体能被怎么操作？ | 吧：建/搜/看；主题：发/列/看；回帖：发/删/**楼中楼嵌套** |
| **谁能做** | 每个动作要不要登录？谁有权？ | 读全公开；写要登录；只能删自己的；建吧者=吧主 |
| **看到谁** | 列表里展示谁的什么？ | 展示发帖人**真实昵称**（要能查、要防篡改） |

再补三个"工程约束"，避免后面返工：

- **规模感**：贴吧是"任意用户都能开吧"的公开多用户系统 → 必须有持久化 DB、必须有身份。
- **数据形状**：楼中楼"无限嵌套" → 用 `parent_id` 自引用，**后端做先序 DFS + 标 depth**，前端按缩进渲染扁平列表（见 §4.3）。
- **明确不做**：本期只做文本，不做图片 → schema 不留 image 字段，前端不放 image 控件。

> 经验：需求里凡是出现"无限 / 树 / 嵌套 / 谁发的 / 防止改 / 搜索"这种词，
> 都要在这一步就决定它落在**数据库结构**还是**后端逻辑**还是**前端渲染**，别拖到写代码时拍脑袋。

---

## 2. 设计数据模型（最值钱的一步）

### 2.1 铁律

1. **主键一律 UUID**，禁自增：`id uuid PRIMARY KEY DEFAULT gen_random_uuid()`。
   自增 id 会被人顺序枚举（IDOR）。FaaS 的静态校验器会直接**拒收** `SERIAL`。
2. **每条数据记一个 owner**：用 `author_id` / `owner_id` 存**调用者的组内假名**（见 §5），不是平台 uid。
3. **想清楚"公开读 vs 私有读"**：
   - 公开内容（论坛帖、评论）→ 用 `myapp_db` 裸 SQL，人人可读。
   - 私有数据（每人只能看自己的）→ 用 `myapp_data`（后端按调用者强制 owner 作用域）。
4. **外键关系用 UUID 列 + 索引**，不依赖数据库级外键约束也行，但**查询路径上的列必须建索引**。

### 2.2 贴吧的表

```sql
-- 论坛
boards      (id uuid PK, name text UNIQUE, intro, owner_id text[吧主假名], created_at)
threads     (id uuid PK, board_id uuid, author_id text, title, body, reply_count int, created_at)
posts       (id uuid PK, thread_id uuid, parent_id uuid NULL, author_id text, body, created_at)
-- 身份
profiles    (owner_id text PK, display_name, updated_at)
-- 社交（§4.6）
friendships (id uuid PK, requester_id text, addressee_id text, status pending|accepted, UNIQUE(requester,addressee))
messages    (id uuid PK, sender_id text, recipient_id text, body, created_at)
```

要点：
- 表多没关系——按领域拆开（论坛 / 身份 / 社交）比硬塞一张表清楚；用户说"一个 schema 不够可以用多个"，
  本范本仍放一个 `schema.sql` 但分段写。
- `posts.parent_id` 自引用：`NULL` = 直接回主题（楼层），非 `NULL` = 回某条回帖（楼中楼）。一列搞定无限层级。
- `boards.name UNIQUE`：吧名全局唯一，重复建吧时后端返 409。
- `profiles` 单独存显示名（§6 详解为什么要拆出来）。
- `friendships` 主体是**组内假名**，一条边一行、状态机 `pending→accepted`；无序对去重在函数里查双向。
- 索引覆盖所有 WHERE/JOIN 列：`threads(board_id)`、`posts(thread_id)`、`posts(parent_id)`、`boards(name)`、
  `friendships(addressee_id,status)`、`messages(sender_id,recipient_id,created_at)`。

完整文件见 `docs/examples/tieba/backend/schema.sql`。

---

## 3. 写 FaaS 后端

底层规则（受限 Flask、AST 白名单、`%s` 参数、UUID 主键、bundle 格式）见
[`faas-jsonapp-generation-playbook.md` §3–§4](faas-jsonapp.md)。这里只补"多用户 DB 应用"特有的几条。

### 3.1 三件套怎么选

| 运行时模块 | 干什么 | 什么时候用 |
|-----------|--------|-----------|
| `myapp_db` | 裸 SQL：`query / queryone / execute / tx` | **公开读**、跨用户聚合（列吧、列帖、JOIN profiles 取昵称）、计数 |
| `myapp_auth` | `current_user()` = 调用者**组内假名**；`is_authenticated()` | 任何"谁在操作"的判断；写操作记 owner |
| `myapp_data` | 后端中介的按调用者 CRUD：`find/insert/update/delete`，**强制 owner=调用者** | **私有数据**（每人只看/改自己的那种），自己不想写 owner 过滤时 |

贴吧是公开论坛 → 主体用 `myapp_db`（公开读）+ `myapp_auth`（记作者、判越权）。

### 3.2 写操作的三个套路（直接抄）

**套路 A：写之前先确认登录**
```python
def _me():
    return myapp_auth.current_user()

@app.post("/threads")
def create_thread():
    me = _me()
    if not me:
        return jsonify({"error": "login required"}), 401
    ...
```

**套路 B：作者永远是当前用户（不信前端传的 author）**
```python
# 前端就算偷偷塞 author_id=别人，也没用——这里只用 me
row = myapp_db.queryone(
    "INSERT INTO threads (board_id, author_id, title, body) VALUES (%s,%s,%s,%s) RETURNING id",
    [bid, me, title, body],   # author_id = me，强制
)
```

**套路 C：只能改/删自己的（把 owner 写进 WHERE）**
```python
@app.delete("/posts")
def delete_post():
    me = _me()
    n = myapp_db.execute("DELETE FROM posts WHERE id=%s AND author_id=%s", [pid, me])
    if not n:
        return jsonify({"error": "无权删除或不存在"}), 403  # 删别人的 → 命中 0 行 → 403
    return jsonify({"ok": True})
```

> 这三个套路就是"防止有人改别人东西"的全部。核心是：**身份来自 `myapp_auth.current_user()`（后端注入、不可伪造），
> 不是来自请求体。** 前端传的任何 id 都只是数据，不是身份。

### 3.3 路由清单要和装饰器对齐

`service.json` 的 `routes[]`（path + methods）必须和 `app.py` 里的 `@app.get/post/...` 一一对应，
否则 invoke 代理找不到路由。贴吧的 7 条：
```
GET /whoami · POST /me · GET,POST /boards · GET /board · GET,POST /threads · GET /thread · POST,DELETE /posts
```

### 3.4 当场自测（本地，不连服务器）

用项目内的校验器把 bundle 走一遍（覆盖 AST 沙箱、SERIAL 检查、路由匹配）：

```python
# 见本仓库历史命令：stub config+database 后 import faas_store，调 F.validate_bundle({service_id, slug, routes, files})
# 通过标志：VALIDATE OK / routes=N / db_enabled=True
```

---

## 4. 写前端 JSON-APP

### 4.1 依赖 `faas` 调用库

```json
"dependencies": { "faas": "^1.0.2" }
```
之后用 `@faas.get/post/put/del/sse`，库会用 `{{ app.backendUrl }}/api/faas/invoke/<svc><route>` 拼完整 URL。
`serviceId` 用一个 `global.svc` 变量存（值 = 部署后的服务 id），方便一处改。

### 4.2 一个动作 = 一个全局函数

页面上的按钮/卡片只触发**一个** action。凡是"取数 + 改状态 + 跳页"的复合动作，
都写成 `global.functions` 里的一个函数，再 `{"call":"@global.fn"}` 调它。函数里可以串多步、可以再调别的 `@global.fn`、可以 `@navigate`。

贴吧的 `openBoard` 就是范例：set 当前吧 id → `@faas.get /board` → set 当前吧 → 调 `@global.loadThreads` → `@navigate board`。

### 4.3 列表 + 楼中楼无限嵌套（关键技巧）

服务端驱动 UI 的 `list` 控件渲染的是**扁平数组**，没法在前端用 jsonlogic 递归建树。
所以**让后端把树拍平**：先序 DFS 排好序、给每条标 `depth`/`indent`，前端一个 `list` 按缩进渲染即可。

后端（`/thread`）迭代式 DFS（不递归，避免深栈）：
```python
children = {}
for r in rows:
    children.setdefault(r.get("parent_id"), []).append(r)
ordered, stack = [], [(r, 0) for r in reversed(children.get(None, []))]
while stack:
    node, depth = stack.pop()
    capped = min(depth, 12)
    node["depth"], node["indent"] = capped, capped * 14
    ordered.append(node)
    for k in reversed(children.get(node["id"], [])):
        stack.append((k, depth + 1))
```

前端一个扁平 `list`，用后端给的 `indent` 当左缩进：
```json
{
  "type": "list", "source": "{{ global.posts }}", "shrinkWrap": true, "separator": "none",
  "item_template": {
    "type": "container", "layout": "column", "paddingLeft": "{{ loop.item.indent }}",
    "children": [
      { "type": "text", "value": "{{ loop.item.author_name }}" },
      { "type": "text", "value": "{{ loop.item.body }}" },
      { "type": "button", "label": "回复", "variant": "text",
        "action": { "call": "@global.replyTo", "args": { "postId": "{{ loop.item.id }}", "name": "{{ loop.item.author_name }}" } } }
    ]
  }
}
```
数据是无限层级的；视觉缩进在第 12 层封顶，防止深嵌套把内容挤出屏幕。

**楼中楼默认收起（超过 2 条折叠 + 展开/收起按钮）——状态留在前端、计算放后端。**
真实贴吧里一组楼中楼太多会很长，要默认只显示前 2 条 + 「展开 N 条」。别想在前端 jsonlogic 里
按祖先链算可见性（很难写对）。正确分工：**前端只维护一个「已展开的父帖 id 集合」，把它传给后端；
后端在 DFS 时按集合决定每组展开还是折叠，并吐出带 `kind` 标记的扁平行。**

后端 `/thread?expanded=id1,id2`：楼层（root）永远全显示；任何一组楼中楼 `>2` 且其父不在 `expanded`
里 → 只发前 2 条 + 一个 `kind:"more"` 行（带 `remaining`）；父在 `expanded` 里 → 全发 + 一个
`kind:"collapse"` 行。普通帖子行 `kind:"post"`。（完整实现见范本 `app.py:_flatten_thread`。）

前端用 DSL 的数组算子维护展开集合，再用 `str_join` 拼成查询串重拉——**不改框架**：
```json
"expandReplies": { "params": ["parentId"], "logic": [
  { "call": "@list_add", "args": { "var": "global.expanded", "item": "{{ params.parentId }}" } },
  { "call": "@set", "args": { "var": "global.expandedCsv", "value": { "str_join": [ { "var": "global.expanded" }, "," ] } } },
  { "call": "@global.reloadThread", "args": {} } ] }
```
（`collapseReplies` 把 `@list_add` 换成 `@list_remove`；`reloadThread` 的 route 带 `&expanded={{ global.expandedCsv }}`；
进帖时 `@list_clear global.expanded` 复位。）item_template 里用 `visible` 按 `kind` 分支渲染 post / more / collapse 三种行：
```json
{ "type": "button", "label": "▾ 展开 {{ loop.item.remaining }} 条回复", "variant": "text",
  "visible": { "==": [{ "var": "loop.item.kind" }, "more"] },
  "action": { "call": "@global.expandReplies", "args": { "parentId": "{{ loop.item.parent_id }}" } } }
```

### 4.4 滚动契约（别踩的坑）

`validate_json_app.py` 会对"整屏长列表混一堆静态兄弟"告警。最省心的做法：
**页面 `scrollable: true` + 列表 `shrinkWrap: true`**，整页一起滚。数据量大的纯列表页才用"列表作为屏幕直接子节点、不 shrinkWrap"。

### 4.5 其他高频约定

- `@if` 主程序用 `condition`（不是 `cond`，那是 flame_game 的）。
- `list.source` 必须是字符串插值 `"{{ global.xxx }}"`，不能是 jsonlogic。
- 展示文本槽（`value`/`label`/`title`…）用字符串或 `{{ }}` 插值，别塞 jsonlogic。
- `container` 没有 `style` 字段；样式属性直接平铺（`paddingLeft`/`color`…）。`text` 可以有 `style`。
- 按钮 action 用 `{ "call": "@global.fn", "args": {} }`，不用写 `"type":"call"`（冗余会告警）。

### 4.6 多 tab + 社交（用户主页 / 加好友 / 私信）

**底部 tab 用 screen 级 `tabs`**（不是 `tab_view`，那是页内的）：每个 tab 一份 `children`。
注意 **`tabs` 没有"切换时触发动作"的钩子**——需要数据的 tab（好友、我的）放一个「🔄 刷新」按钮，
点了走 loader（loader 第一步 `@global.syncMyName` 拿 token + 记 `myId`），并在关键动作后（同意请求、发完私信）顺手重拉。
tab 里有列表照样 `shrinkWrap: true`，整屏一起滚。

**🔴 先分叉：要的是"平台级真人实时社交"还是"应用内假名社交"？**
如果需求是"搜得到平台上任何人 + 要推送 + 通讯录 + 跨 App 同一个人"（微信式），**那根本不该走 FaaS**，
改读 [`docs/im-app-generation-playbook.md`](platform-im.md)（范本 `demo-im`，用 `lib_im` 平台 IM 能力、
**不写后端**）。本节讲的是另一种：**论坛/社区内部的、用假名的轻社交**，这种才建进 FaaS。

**别用平台 IM（`@im_*`）做 FaaS 应用内的好友/私信。** `demo_im` 的 `@im_send_friend_request` /
`@im_history` / `@im_send_text` 都按**平台 uid** 工作；而 FaaS 后端只有**组内假名**、反推不出 uid（同 §5.2）。
所以从一条帖子（假名）发起加好友 / 私信，platform IM 接不上。`demo_im` 只能当**UI 参照**（头像 `avatar`、
左右气泡用 `visible` + 前导 flex `spacer`、输入行）。**社交关系要建进 FaaS 自己的库、用假名做主体**：

- 表：`friendships(requester_id, addressee_id, status pending|accepted, UNIQUE(requester,addressee))`、
  `messages(sender_id, recipient_id, body)`——主体全是组内假名。
- 后端三套路照旧：所有写强制 `current_user()`；私信收发前先查双向 `accepted` 边（**只有好友能私信**）；
  对方已请求过我时再请求 → 直接互为好友（mutual auto-accept）。
- 用户主页 `/user?owner_id=<假名>`：吐显示名 + 统计 + 最近主题 + **与我的关系** `rel{is_self,is_friend,outgoing_pending,incoming_pending}`，
  前端按 `rel` 用 `visible` 切「加好友 / 已发送 / 同意 / 发私信 / 这是你」。
- 私信会话：`is_me`（`sender_id==current_user()`）由后端标，前端左右气泡分别 `visible: {"!":[is_me]}` / `is_me`。
- **隐私自洽**：好友/私信只在**本服务组内**用假名互通，跨 App 关联不了同一个人——和假名隔离一致，不是缺陷。

完整范本见 `docs/examples/tieba/`（前端 7 屏 + 后端 14 路由）。

---

## 5. 接身份：不可伪造的"组内假名"

这是全栈应用最容易做错、也最关键的一环。

### 5.1 链路

```
前端 @get_auth_token 拿到用户 token
  → 调 @faas.post/get 时带 headers: { "Authorization": "Bearer {{ global.userToken }}" }
  → invoke 代理验证 JWT，派生 假名 = HMAC(server_secret, app_id || uid)（app_id = 本服务组 id，新服务组即 service_id），剥掉 Authorization，注入 X-MyApp-Caller-Pseudonym
  → 后端 myapp_auth.current_user() 读到这个假名（拿不到平台 uid，更没有原始 token）
```

要点：
- 🔴 **`@get_auth_token` 必须放在「写操作」里调（在动作里、首屏构建之后），绝不能放启动 `steps`。**
  原因：`@get_auth_token` 的授权弹窗需要 UI 上下文（`globalContext`），而启动 `steps` 在首屏构建**之前**执行，
  此时 `globalContext==null` → 授权 fail-closed 返回空 → `global.userToken` 整个会话都是空 → **每个写操作都 401
  "login required"**（公开读不受影响，所以症状是"能看不能写"）。正确做法：在每个写动作都先走的 `syncMyName`
  里把 `@get_auth_token {bind global.userToken}` 作为**第一步**；启动 `steps` 只做 `@is_logged_in` + 公开读。
  这样首次点写操作时（已有上下文）弹一次授权框，用户授权后 token 落到 `global.userToken`，后续写入即带上有效 Bearer。
- **写操作（建吧/发帖/回帖/同步昵称）必须带 `Authorization: Bearer`**，否则后端 `current_user()` 为空 → 401。
- 公开读也可以带（无害），带了 `/board` 才能正确返回 `is_owner`。
- 假名**按 (服务组, 用户) 稳定**：同一用户在本服务组里每次都是同一个 `author_id`；跨服务组不可关联（secret 只在服务端）。
- 后端**拿不到平台 uid**，这是隐私设计（权限模型 B1-G2），不是 bug。

### 5.2 推论：为什么 `@im_get_user_info` 在 FaaS 里直接查不了别人昵称

`@im_get_user_info {user_id}` 需要**平台 uid**，但 FaaS 后端只有假名、反推不出 uid。
所以"存 uid、按 uid 查权威昵称"的经典 IM 写法，在 FaaS 假名模型下用不了。昵称怎么办 → §6。

---

## 6. 真实昵称 + 防篡改（在不改框架的前提下）

需求："显示发帖人真实昵称，记录 ID、昵称要能查、防止有人改。"

### 6.1 设计

- **身份（author_id）= 服务端注入的假名**，前端伪造不了，也改不了——这satisfies "记录 ID、防止改"里最硬的一半：**没人能改别人帖子的归属**。
- **显示名（display_name）放 `profiles` 表，每人只能写自己那行**：后端 `_sync_name` 把 `owner_id` 强制成
  `current_user()`，所以你只能改自己的名字，改不了别人的。
- **前端把"用户的真实平台昵称"同步进 `profiles`**：登录后 `@get_user_info` 拿到自己的真实昵称 → `@faas.post /me {display_name}`。
  发帖/回帖前也顺手同步一次，保证任何发过言的人都有真实昵称。
- 列表展示时后端 `LEFT JOIN profiles` 把 `display_name` 一起带出来（`owner_name` / `author_name`）。

### 6.2 这个设计挡住了什么、没挡住什么（要诚实写清楚）

- ✅ **挡住**：改别人帖子的署名 / 改别人的显示名 / 伪造他人身份发帖（author_id 是服务端假名）。
- ⚠️ **没挡住**：用户给**自己**设一个误导性的显示名（比如把自己显示成"官方")。这是 vanity 级别的自报名风险。
- 想要"严格权威、连自己都不能乱设"的昵称，需要后端能拿到一个可信的服务端解析身份——
  那要么**这个字段不走 FaaS 假名化**，要么**给框架加一个能力**。后者属于改框架，本期**刻意不做**（守框架稳定性原则）。

> 取舍结论：在"不改框架"约束下，本设计是正解。它把"防冒充他人"做满了，把"自报虚名"作为已知残留风险**显式记录**，
> 而不是假装解决了。

---

## 7. 部署 + 自测（本轮自己跑完）

部署动作（上传 bundle → 部署 → 跑 schema → 起容器）必须**在本轮内自己完成**，不能只写步骤让"服务端代劳"。
具体命令见 [`faas-jsonapp-generation-playbook.md` §5](faas-jsonapp.md) 和
[`faas-docker-runtime`](faas-docker-runtime.md)。要点：

- 运行时是 **local-docker**（OpenFaaS/faasd 已移除）；改了运行时镜像要 rebuild + push + ctr 重新拉。
- DB 应用首跑要执行 `schema.sql`；表属主是部署期的 owner 角色，运行时角色只有 DML。
- 部署后**真用户链路自测**，逐条打：

```
建吧      POST /boards {name}            → 200, is_owner:true, 再建同名 → 409
搜吧      GET  /boards?q=...             → 命中过滤
发主题    POST /threads {board_id,title} → 200
楼中楼    POST /posts {thread_id,parent_id} → 200；GET /thread 看 depth/indent 递增
真实昵称  POST /me 同步后，列表里的 owner_name/author_name = 真实昵称
越权      删别人的 post                  → 403（命中 0 行）
未登录写  不带 Authorization 发帖        → 401
```

前端再用 `validate_json_app.py` 过一遍（exit 0、0 warning 最佳）。

### 7.1 排错：所有写操作都报 `login required`（401），但用户明明已登录

这是**部署级**问题，不是某个 app 的问题——会让**所有** FaaS app 的鉴权写入全挂：

- 根因：后端 `FAAS_CALLER_PSEUDONYM_SECRET` 为空。invoke 代理验证完调用者 JWT 后，要用这个
  密钥派生**组内假名**注入给函数；密钥为空时 `_caller_pseudonym()` 返回 `""` →
  不注入 `X-MyApp-Caller-Pseudonym` → 函数里 `myapp_auth.current_user()` 永远是 None →
  每个鉴权写入都 401。公开读不受影响（所以"能看不能写"是典型症状）。
- 排查：拿一个**真实用户**的 token 打 `GET .../whoami`，若返回 `logged_in:false` 且
  `me:""`，就是没注入假名。
- 修复（运维侧，一次性，**密钥要稳定**——轮换会让所有人的假名变化、丢失数据归属）：
  ```bash
  myapp-ctl secret generate faas FAAS_CALLER_PSEUDONYM_SECRET --bytes 32
  # 可选：本地 HS256 校验 token（省掉每次 invoke 一次 GoTrue 往返），值＝GoTrue 的 JWT_SECRET
  myapp-ctl secret set backend SUPABASE_JWT_SECRET="<supabase 组的 JWT_SECRET>"
  myapp-ctl deploy --group core
  ```
- 预防：`myapp-ctl secret init-stack` 现已自动生成 `FAAS_CALLER_PSEUDONYM_SECRET` /
  `FAAS_RUN_TOKEN_SECRET` 并把 `SUPABASE_JWT_SECRET` 写入 backend 组，新部署不会再踩。

---

## 8. 范本索引

`docs/examples/tieba/`：

| 文件 | 作用 |
|------|------|
| `tieba.json` | 前端 JSON-APP（5 屏：首页/搜索、吧、主题+楼中楼、建吧、发主题） |
| `backend/schema.sql` | Postgres 表结构（UUID 主键、parent_id 自引用、profiles） |
| `backend/app.py` | 受限 Flask 后端（7 路由、myapp_db+myapp_auth、DFS 楼中楼排序） |
| `backend/service.json` | 路由清单（与 `@app` 装饰器对齐） |
| `GENERATION-TRANSCRIPT.md` | **模拟生成全过程**（test@example.com 从需求到交付的思考记录），下次照着复现 |
| `README.md` | 怎么部署、怎么试、设计取舍速查 |

---

## 9. 交付前 Checklist（逐条对照）

- [ ] 需求拆成了"实体/动作/谁能做/看到谁" + 工程约束（规模/数据形状/明确不做）。
- [ ] 数据模型：UUID 主键、每条记 owner、公开读 vs 私有读分清、查询列建索引。
- [ ] 后端：写操作先判登录；author/owner 强制 = `current_user()`；改/删带 owner 进 WHERE。
- [ ] 后端：`service.json` routes 与 `@app` 装饰器逐条对齐；本地 `validate_bundle` 通过。
- [ ] 前端：复合动作收进 `@global.fn`；列表 `shrinkWrap`+页面 `scrollable`；`@if` 用 `condition`。
- [ ] 楼中楼/树形：后端 DFS 拍平 + `indent`，前端缩进渲染。
- [ ] 身份：写操作带 `Authorization: Bearer {{ global.userToken }}`。
- [ ] 真实昵称：`profiles` 自助同步、JOIN 带出、防冒充他人成立，自报虚名残留风险**已写明**。
- [ ] 部署：本轮自己跑完 bundle 上传/部署/schema/起容器。
- [ ] 自测：建/搜/发/楼中楼/昵称/越权/未登录 七条链路全打过。
- [ ] 没动任何框架代码（`lib/`、`backend/faas*.py`）。
