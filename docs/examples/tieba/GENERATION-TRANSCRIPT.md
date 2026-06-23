# 贴吧 · 生成全过程记录（模拟 AI 生成链路）

> 这是一份**模拟的生成思考记录**：假设用户 `test@example.com` 在 MyApp 的 "让 AI 生成一个 App" 入口
> 提了下面这个需求，AI（生成 agent）从零把"前端 + FaaS 后端 + Postgres 数据库"一条龙做出来的完整思考与动作轨迹。
>
> 目的：给后续的全栈生成当**可复现的参考样本**——不仅给出最终产物，更把"为什么这么设计"的推理留下来。
> 配套方法论见 [`docs/faas-fullstack-app-generation-playbook.md`](../../faas-fullstack-app-generation-playbook.md)。

---

## 0. 用户输入

> 创建一个类似贴吧的 APP：任意用户都可以发布公开言论，有回帖功能。生成全套 JSON-APP + 服务端 + 数据库。
> 要求任意用户都可以创建贴吧（xxx 吧），默认创建的人是吧主；还要可以楼中楼无限嵌套回复；
> 要有搜索有哪些吧的能力；先不考虑图片，只考虑文本；还要显示出评论用户的真实昵称
> （记录 ID，真实昵称需要查询，防止有人改）。你自己再完善一下需求然后直接实现。

---

## 1. 思考：先把需求收敛成可实现的清单

用户的话里有几个"重词"，我先逐个落地到具体技术决策：

- **"任意用户都可以创建贴吧、默认是吧主"** → 需要登录态 + 持久化；建吧时把创建者记成 `owner_id`。
  → 这是个**多用户、有身份、有持久化**的系统，不是纯前端 demo。必须上 FaaS 后端 + Postgres。
- **"楼中楼无限嵌套回复"** → 回帖要能回回帖，层级不限。
  → 数据上用 `parent_id` 自引用一列就够；难点在**渲染**——服务端驱动 UI 的 list 是扁平的，
  没法在前端递归建树。决策：**后端做先序 DFS、给每条标 depth/indent，前端按缩进渲染扁平列表。**
- **"搜索有哪些吧"** → `/boards?q=` 用 `ILIKE` 模糊匹配吧名。
- **"只考虑文本"** → schema 不留图片字段，前端不放 image 控件。明确缩小范围，省得过度设计。
- **"显示真实昵称，记录 ID，昵称要查、防止有人改"** → 这条最微妙，单独拉一节想（§3）。

我再**自己补全**几条用户没说但显然需要的：

- 重名的吧不能重复创建（`name UNIQUE`，重复返 409）。
- 只能删自己的回帖（不能删别人的）。
- 列表要显示吧主是谁、每个吧有多少主题、每帖多少回复——这些是论坛的基本信息密度。
- 未登录可以浏览（公开言论本就该公开可读），但发帖/建吧/回帖要登录。

**收敛结果（实体 / 动作 / 谁能做 / 看到谁）：**

| 实体 | 动作 | 权限 |
|------|------|------|
| 吧 board | 建、搜、看 | 读公开；建要登录，建者=吧主；吧名唯一 |
| 主题 thread | 发、列、看 | 读公开；发要登录 |
| 回帖 post | 发（含楼中楼）、删 | 读公开；发要登录；只能删自己的 |
| 显示名 profile | 自助同步真实昵称 | 只能改自己的 |

---

## 2. 思考：数据模型

铁律先套上：**主键一律 UUID**（FaaS 校验器拒收 SERIAL，且自增 id 可被枚举），**每条记 owner**，**公开读用 `myapp_db`**。

```sql
boards   (id uuid PK, name text UNIQUE, intro, owner_id text, created_at)
threads  (id uuid PK, board_id uuid, author_id text, title, body, reply_count int, created_at)
posts    (id uuid PK, thread_id uuid, parent_id uuid NULL, author_id text, body, created_at)
profiles (owner_id text PK, display_name, updated_at)
```

- `posts.parent_id`：`NULL`=楼层（直接回主题），非 `NULL`=楼中楼（回某条回帖）。**一列承载无限层级。**
- `owner_id` / `author_id` 存的是**组内假名**（见 §4），不是平台 uid。
- `reply_count` 冗余计数，省得每次 count；发帖时 `+1`。
- 索引覆盖所有 WHERE/JOIN 列：`boards(name)`、`threads(board_id)`、`posts(thread_id)`、`posts(parent_id)`。

为什么把 `profiles` 单独拆一张表，而不是把昵称直接写进每条 thread/post？→ §3 解释。

---

## 3. 思考（关键纠结）：真实昵称怎么"查"、怎么"防止改"

用户原话："记录 ID，真实昵称需要查询，防止有人改。"经典做法是：每条帖存平台 `user_id`，
展示时用 `@im_get_user_info {user_id}` 查权威昵称。这样昵称不存死、永远是最新、谁也改不了。

**但我撞到一堵墙：** FaaS 的身份模型里，后端 `myapp_auth.current_user()` 给的是**组内假名**
（`HMAC(server_secret, app_id||uid)`），**不是平台 uid**，而且**反推不出 uid**（secret 只在服务端）。
这是权限模型的隐私设计（B1-G2）：吧主/应用作者不能把假名还原成真人、也不能跨应用关联同一个人。

后果：`@im_get_user_info` 需要平台 uid，而 FaaS 后端根本拿不到 uid → **经典写法在 FaaS 里走不通。**

我的第一反应是"那给框架加个能力，让函数能拿到服务端解析的身份去查昵称"。
**但这违反框架稳定性原则——为了一个生成 App 去改框架代码是不允许的。** 我把这个念头否掉，转而在现有能力内找解法。

**最终设计（不改框架）：**

1. 身份 `author_id` = 服务端注入的假名，前端伪造不了、改不了 → "记录 ID、防止改归属"这一硬要求**满足**。
2. 显示名放 `profiles`，**每人只能写自己那行**：后端 `_sync_name` 把 `owner_id` 强制成 `current_user()`。
3. 前端把用户的**真实平台昵称**（`@get_user_info().username）同步进 `profiles`（登录后、发帖前各同步一次）。
4. 展示时后端 `LEFT JOIN profiles` 把 `display_name` 带出来。

**诚实评估这个设计的边界：**
- ✅ 防住了"改别人帖子的署名 / 改别人的显示名 / 冒充他人发帖"——因为 author_id 是不可伪造的假名。
- ⚠️ 没防住"用户给自己起个误导性的名"（自报虚名）。要严格到连自己都不能乱设，
  得让这个字段不走假名化、或给框架加能力——**本期刻意不做**，把这条作为已知残留风险**写进文档**，不假装解决。

> 这一节是整个生成里最该被后人参考的地方：**遇到"现有能力做不到"，第一选择是换设计，不是改框架；
> 并且要把设计的边界诚实写清楚，而不是糊过去。**

---

## 4. 思考：身份链路怎么接

```
前端 @get_auth_token 拿 token
  → @faas.post/get 带 headers { Authorization: Bearer <token> }
  → invoke 代理验 JWT → 派生假名 → 剥掉 Authorization → 注入 X-MyApp-Caller-Pseudonym
  → 后端 myapp_auth.current_user() = 假名
```

落地决策：
- 写操作（建吧/发帖/回帖/`POST /me`）**一律带 Authorization**，否则 401。
- 公开读也带（无害），这样 `/board` 能正确算 `is_owner`。
- 前端用一个 `global.userToken` 缓存 token，但 **`@get_auth_token` 要在写动作里取（`syncMyName` 第一步），不能在启动 `steps` 里取**——启动时首屏还没构建、授权弹窗无 UI 上下文会 fail-closed 取空，导致之后写操作全 401。

---

## 5. 动作：写后端（schema.sql + app.py + service.json）

- `schema.sql`：上面的四张表 + 索引。注意注释里**别写 "SERIAL" 这个词**——
  校验器的 SERIAL 检查会连注释一起扫（我第一版就因为注释里写了"禁 SERIAL"被拒，改成"不要用自增主键"才过。
  这其实暴露了校验器没剥 SQL 注释的小毛病，已记为后续 follow-up，但**没有为它改框架**）。
- `app.py`：7 个路由。三个套路贯穿全文——写前判登录、author/owner 强制 `current_user()`、删改带 owner 进 WHERE。
  `/thread` 里做迭代式 DFS（显式栈，不递归，避免深嵌套爆栈）给回帖排序 + 标 `depth`/`indent`。
  `_sync_name` 用 `INSERT ... ON CONFLICT (owner_id) DO UPDATE` upsert 显示名。
- `service.json`：routes 与 `@app` 装饰器逐条对齐。

**当场自测（本地）：** stub 掉 config/database 后 import `faas_store`，对 bundle 调 `validate_bundle`。
→ `VALIDATE OK / routes=7 / db_enabled=True`，AST 沙箱、SERIAL、路由匹配全过。

---

## 6. 动作：写前端（tieba.json）

5 个屏：

- `home`：标题 + 搜索框（`bind global.q`）+ 搜索按钮 + "创建新吧" + 吧列表（卡片，点进 `openBoard`）。
- `board`：吧信息 + "发主题" + 主题列表（点进 `openThread`）。
- `thread`：主题正文 + **楼中楼回帖列表（按 `indent` 缩进）** + 底部回复框（可回主楼，也可点某楼"回复"变楼中楼）。
- `create_board` / `create_thread`：输入 + 提交。

设计要点：
- 每个复合动作收进 `global.functions`（`openBoard`/`openThread`/`submitBoard`/`submitThread`/`submitReply`/`replyTo`…），
  按钮只 `{"call":"@global.fn"}`。
- 列表统一 `shrinkWrap:true` + 页面 `scrollable:true`，绕开滚动契约告警。
- 楼中楼：`paddingLeft: "{{ loop.item.indent }}"`，每条带"回复"按钮 → `replyTo(postId,name)` 设回复目标。
- `@if` 用 `condition`；表单先判空再提交，失败 toast 后端返回的 `error`。

**当场自测：** `python3 backend/validate_json_app.py docs/examples/tieba/tieba.json` → exit 0，0 warning。

---

## 7. 动作：部署 + 真用户链路自测

（部署命令见 README / faas-jsonapp-generation-playbook。）部署后逐条打：

```
建吧 POST /boards{name:"摄影"}        → 200 is_owner:true；再建"摄影" → 409 该吧已存在
搜吧 GET /boards?q=摄                  → 命中
发主题 POST /threads{board_id,title}  → 200
回帖 POST /posts{thread_id,body}      → 200（楼层）
楼中楼 POST /posts{...,parent_id=上面那条} → 200；GET /thread 看 indent 0,14,28… 递增
昵称 POST /me{display_name:真实昵称}   → 之后列表 author_name/owner_name = 真实昵称
越权 用户B 删 用户A 的 post           → 403
未登录 不带 Authorization 发帖         → 401 login required
```

---

## 8. 复盘：这次生成沉淀下来的可复用经验

1. **多用户 + 持久化 + 身份 = 必上 FaaS + Postgres**，需求阶段就要判定，别等写到一半才发现要后端。
2. **树形/无限嵌套：后端拍平（DFS + depth/indent），前端按缩进渲染扁平 list。** 别想在前端 jsonlogic 里建树。
3. **身份只信 `current_user()`，不信请求体。** 三套路（判登录 / 强制 owner / owner 进 WHERE）覆盖所有防越权。
4. **FaaS 假名 ≠ 平台 uid**：凡是"按 uid 查权威信息"的经典写法都要重新设计。
5. **现有能力做不到时换设计，不改框架；并把设计边界诚实写清楚**（本例：防冒充他人做满，自报虚名作为残留风险记录）。
6. **每步当场验证**：后端 `validate_bundle`、前端 `validate_json_app.py`、部署后真链路 invoke。

---

## 9. v1.1 增量（楼中楼折叠 + 用户主页 + 好友 + 私信 + 底部 tab）

第二轮迭代把 demo 做得更像真贴吧。三个值得记的思考：

1. **楼中楼折叠：状态在前端、计算在后端。** 用户要"一组楼中楼超过 2 条默认收起、可展开"。
   不在前端 jsonlogic 里按祖先链算可见性（很难写对）——前端只用 `@list_add`/`@list_remove` 维护一个
   "已展开父帖 id 集合"，`str_join` 拼成 `?expanded=` 传后端；后端 DFS 时按集合决定每组展开/折叠，
   吐带 `kind`(post/more/collapse) 的扁平行，前端按 `kind` 用 `visible` 分支渲染。**不改框架。**

2. **社交不能用平台 IM。** 想加好友/私信时第一反应是用 `@im_*`——但它按平台 uid 工作，而 FaaS 只有
   组内假名、反推不出 uid（同 §3 的墙）。所以从一条帖子（假名）发起社交，platform IM 接不上。
   决策：**好友/私信建进 FaaS 自己的库、用假名做主体**（`friendships`/`messages`），`demo_im` 只当 UI 参照。
   隐私自洽：社交只在本服务组内用假名互通，跨 App 关联不了同一个人。

3. **底部 tab 没有"切换钩子"。** screen 级 `tabs` 切换不触发动作 → 需要数据的 tab（好友/我的）放
   「刷新」按钮（loader 第一步拿 token + 记 myId），并在关键动作后重拉。

验证同前：前端 validate exit0/0warn；后端 AST 沙箱 + schema lint；折叠 DFS 单测；
全部新 SQL 在真 Postgres 跑通。完整路由/屏幕见 `README.md`。
