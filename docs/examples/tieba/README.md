# 贴吧（Tieba）· 全栈 JSON-APP 范本

一个"前端 JSON-APP + FaaS 后端 + Postgres 数据库"一条龙的参考应用：
任意用户可**开吧**（建者即吧主）、**发主题**、**楼中楼无限嵌套回帖**、**搜索吧**，
列表展示发帖人的**真实昵称**。只做文本，不做图片。

> 这是"一条龙全栈生成"的标准范本。配套方法论：
> [`docs/faas-fullstack-app-generation-playbook.md`](../../faas-fullstack-app-generation-playbook.md)。
> 完整生成思考记录：[`GENERATION-TRANSCRIPT.md`](GENERATION-TRANSCRIPT.md)。

## 文件结构

```
docs/examples/tieba/
├── tieba.json                  前端 JSON-APP（5 屏）
├── backend/
│   ├── app.py                  受限 Flask 后端（7 路由）
│   ├── schema.sql              Postgres 表结构
│   └── service.json            路由清单（与 @app 装饰器对齐）
├── GENERATION-TRANSCRIPT.md    模拟生成全过程（需求→设计→实现→自测）
└── README.md
```

## 功能与屏幕

| 屏幕 | 内容 |
|------|------|
| `home` | 搜索框 + 吧列表（吧名/简介/吧主/主题数）+ 创建新吧入口 |
| `board` | 吧信息 + 主题帖列表 + 发主题入口 |
| `thread` | 主题正文 + 楼中楼回帖（按缩进渲染）+ 底部回复框（可回主楼/楼中楼） |
| `create_board` | 输入吧名、简介 → 创建（建者即吧主） |
| `create_thread` | 输入标题、正文 → 发布 |

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
| GET | `/thread?thread_id=` | 主题 + 全部回帖（后端已 DFS 排好序并标 `depth`/`indent`） | 可选 |
| POST | `/posts` | 回帖；`parent_id` 为空=回主题，非空=楼中楼 | 必须 |
| DELETE | `/posts?post_id=` | 删回帖（只能删自己的，否则 403） | 必须 |

## 楼中楼无限嵌套是怎么做的

`posts.parent_id` 自引用一列承载任意层级。`GET /thread` 在后端做**迭代式先序 DFS**
（显式栈，不递归，避免深嵌套爆栈），输出一个扁平、按楼层顺序排好的数组，每条带 `depth` 和
`indent`(=depth×14，第 12 层封顶)。前端一个 `list` 用 `paddingLeft: "{{ loop.item.indent }}"`
缩进渲染即可——服务端驱动 UI 不需要在前端递归建树。

## 身份与"真实昵称、防止有人改"

- 后端 `myapp_auth.current_user()` 返回**组内假名**（不可伪造、按 (服务组,用户) 稳定、不是平台 uid）。
  写操作把 `author_id`/`owner_id` 强制成它 → **没人能改/冒充别人的帖子归属**。
- 显示名放 `profiles`，`_sync_name` 把 `owner_id` 强制成 `current_user()` → **只能改自己的名字**。
- 前端登录后/发帖前把用户**真实平台昵称**（`@get_user_info().username`）同步进 `profiles`，
  展示时后端 `LEFT JOIN profiles` 带出 `author_name`/`owner_name`。

**已知边界（诚实说明）：** 该设计挡住了"改/冒充他人"，但挡不住用户给**自己**起误导性的显示名（自报虚名）。
要严格到连自己都不能乱设，需要让该字段不走假名化、或给框架加能力——本范本**刻意不改框架**，把这条作为残留风险记录。
原因见 [`GENERATION-TRANSCRIPT.md` §3](GENERATION-TRANSCRIPT.md) 与 playbook §6。

## 本地校验

```bash
# 前端：静态校验（应 exit 0、0 warning）
python3 backend/validate_json_app.py docs/examples/tieba/tieba.json

# 后端：bundle 走 FaaS 校验器（AST 沙箱 / SERIAL / 路由匹配）
# stub config+database 后 import faas_store，对 {service_id,slug,routes,files} 调 validate_bundle
# 期望：VALIDATE OK / routes=7 / db_enabled=True
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
建吧/重名409 · 搜吧 · 发主题 · 回帖 · 楼中楼(indent 递增) · 同步后显示真实昵称 · 删别人403 · 未登录写401
```
