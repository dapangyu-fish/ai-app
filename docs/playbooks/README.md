# 生成 Playbook · 总路由（**先读这一份**）

> 这是 AI 生成 JSON-APP 的**分层阅读入口**（深度方法论的目录）。原则：**先分类选准一条「轨道」
> → 只读那条轨道的 Tier-1 方法 → 实现时再翻它的 Tier-2 范本**。不要一上来就通读所有 playbook 或
> 盲读 demo 源码——那样又慢又容易抄错。**先选根基，再动手；选错轨道会绕一大圈。**
>
> ⚠️ **别把两个概念搞混**：
> - **生成 pipeline（v1 `json_dsl_v1` / v2 `dart_to_json_v2`）= 怎么生成**（直接写 JSON-DSL，还是先写 Dart 设计稿再转）。由系统/环境选定，和应用类型无关。
> - **轨道（track）= 做什么应用 + 读哪份 playbook**（下表）。**两个 pipeline 都要先分类轨道、再分层读对应 playbook。**
> 系统的分类入口是 [`backend/prompts/generation/index.md`](../../backend/prompts/generation/index.md)；本文件是其中"带后端 / 社交"类的深度方法论目录。

## 第一步：判断这次属于哪条「轨道」（决策树，从上往下命中即停）

| 命中特征（用户需求里出现） | 轨道 | 后端 |
|------|------|------|
| 只有 UI / 计算器 / 展示 / 本地状态，**不登录、不存数据、不调外部接口** | **纯前端** | 无 |
| 微信式**实时社交**：搜得到**平台上任何人** / 加好友 / 单聊私信 / 未读红点 / 推送 / 跨 App 同一个人 | **平台 IM 轨** | **不写后端**（用平台 IM 能力） |
| **多用户 + 持久化**：论坛 / 社区 / 贴吧 / 打卡 / 任意用户互相可见、要存数据、要身份；或"应用内（假名）的关注/私信" | **FaaS 全栈轨** | 写 FaaS + Postgres |
| 要后端但**不要数据库**：代理某网站 / 纯计算 / 调第三方 HTTP / 定时任务 | **简单 FaaS 轨** | 写 FaaS（无 DB） |

判不准时的关键追问：
- **"加好友能搜到谁？"** 平台上任何真人 → v2 平台 IM；只在这个 App 内部点到的人 → v1 FaaS 自建。
- **"数据归谁、要不要自定义表？"** 要自己的表/字段 → FaaS；只要现成 IM 收发 → 平台 IM。
- **"要推送/已读未读吗？"** 要 → 平台 IM（自建轮询体验差）。

## 第二步：按命中的链路分层读（只读你这条）

### 纯前端
- Tier-1：`../../JSON-DSL.md`（控件 / 表达式 / 模板 / 内置函数契约）。直接生成，不碰任何后端 playbook。

### 平台 IM 轨（实时社交）— 范本 `demo-im`
- **Tier-1（方法，先读）**：[`platform-im.md`](platform-im.md) — 何时用 IM 而非 FaaS、`@im_*`/`lib_im` 能力栈、
  平台 uid 权威身份、`subscribeInbox` 实时+未读、聊天页"全高 list+scrollToEnd"、加好友闭环。
- **Tier-2（范本，实现时翻）**：[`../examples/demo-im/`](../examples/demo-im/)（思考记录 + 索引）；
  App 本体 `templates/demo_im.json` + 组件库 `templates/lib_im.json`。
- 关键红线：**不写 backend / schema / 部署**；昵称头像已读未读全用后端字段；不需要 `@get_auth_token`。

### FaaS 全栈轨（数据库社区类）— 范本 `tieba`
- **Tier-1a（后端基础，先读）**：[`faas-jsonapp.md`](faas-jsonapp.md) — 何时建后端、`faas` 调用库 + `app` 命名空间、
  受限 Flask 写法、本轮内部署自测拿真实 service_id、`@faas.*` 接线、"点了没反应"的根因。
- **Tier-1b（全栈方法，再读）**：[`faas-fullstack.md`](faas-fullstack.md) — 需求收敛 → UUID 数据模型 →
  `myapp_db`/`myapp_auth` 三套路 → 不可伪造组内假名 + 真实昵称 → 楼中楼 DFS/折叠 → 用户主页/好友/私信 → 部署自测。
- **Tier-2（范本，实现时翻）**：[`../examples/tieba/`](../examples/tieba/)（前端 7 屏 + 后端 14 路由 + 思考记录）。
- 关键红线：主键一律 UUID；身份只信 `current_user()`（组内假名，≠平台 uid，反推不出）；
  **`@get_auth_token` 必须在写动作里取、不能放启动 `steps`**；社交建进 FaaS 自己的库（platform IM 接不上假名）。

### 简单 FaaS 轨（无数据库）
- **Tier-1**：[`faas-jsonapp.md`](faas-jsonapp.md)（只读这一份；不需要数据库/全栈那套）。

## FaaS 全栈轨 vs 平台 IM 轨 一句话对照

| | FaaS 全栈轨 | 平台 IM 轨 |
|--|--|--|
| 身份 | 组内假名（反推不出 uid，按服务组隔离） | 平台 uid + 权威昵称/头像，跨 App 一致 |
| 社交范围 | 仅本服务组内 | 全平台可搜任意人 |
| 实时/推送 | 无（轮询/手动刷新） | 有（inbox 订阅 + 推送 + 未读） |
| 数据 | 自己的 Postgres，表结构自定 | 平台托管，不拥有 schema |
| 写后端 | 要写 + 部署 | **不写** |
| 范本 | `../examples/tieba/` | `../examples/demo-im/` |

> 共同底座：两条链路的前端都遵循 [`../../JSON-DSL.md`](../../JSON-DSL.md)（控件/表达式/滚动契约/内置函数）。
> 框架稳定性原则：新功能优先用现有控件 + 内置函数 + 组件库组合实现，**不为单个生成 App 改框架代码**。
