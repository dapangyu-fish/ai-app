# RFC：JSON-APP 维度的推送隔离 + 点击深链 + 主动授权

> 状态：**提案（待实现）** · 作者：平台团队 · 创建：2026-06-29
> 关联：`PUSH_ARCHITECTURE.md`（现有离线推送管线）、FaaS 服务组权限模型（`CLAUDE.md` §FaaS）、`JSON-DSL.md`（`@launch_app` / `@im_send_text`）

---

## 1. 背景与问题

平台现有的离线推送管线（见 `PUSH_ARCHITECTURE.md`）已经能稳定地把 IM 消息推到 APNs / FCM / GeTui：

```
OpenIM afterSendSingleMsg webhook → backend /api/im/after_send_msg
  → 查在线状态（离线才推）→ 查 device_tokens → push.dispatch(channel,…)
```

但它是**纯框架 IM 维度**的，存在三个结构性缺口：

1. **推送触达不到 JSON-APP**。消息体只有 `sendID / recvID / content / contentType`（纯文本），不携带「这条消息属于哪个 JSON-APP、该跳到该 App 的哪个界面」。点击通知只能回到框架 IM 会话页——`lib/im/im_push_service.dart` 的 `_handleNotificationTap` 目前还是注释占位（未实现）。
2. **框架层推送没有按 App 隔离**。任意来源的消息都走同一条框架推送，收件人无法按「来自哪个 App / 哪个服务」区分、开关或静音。
3. **没有授权门槛，易被滥用**。只要拿到收件人 uid 就能借 IM 发消息触发推送，缺少「收件人主动同意某个 App / 服务才收推送」的开关。

### 目标场景（产品描述）

> 用户 1 在 **JSON-APP A** 里给用户 2 发了一条消息：
> - 用户 2 **装了 A** → 点推送**直接进 A 的对应界面**；
> - 用户 2 **没装 A** → 落到**框架层兜底**，展示一张 **「邀请下载 A」** 卡片，点了之后下载并进入 A；
> - 且用户 2 必须**事先主动对某个 App / 服务开启推送**，才会收到该来源的推送（主动授权、防滥用）。

## 2. 目标与非目标

**目标**
- 给消息加上**应用维度的结构化载荷**（app 身份 + 目标路由 + 参数），使推送可精确深链到某个 JSON-APP 的某个界面。
- **按 App（可细到发送者 / 服务）隔离推送**，收件人对每个来源**默认关闭、显式授权后才收**。
- 点击通知的**完整跳转链**：已安装→深链进 App；未安装→框架兜底「邀请下载」→ 安装→进 App。
- 复用并扩展现有多通道推送管线与 FaaS 服务组权限模型，**不改 provider 层**。

**非目标（本期不做）**
- 不改 OpenIM 服务端实现，只用其自定义消息能力与现有 webhook。
- 不做富文本编辑器 / 群聊扩展（仅做「App 来源消息」的结构化卡片渲染）。
- 不做跨设备推送偏好同步以外的复杂通知中心（如分组、免打扰时段）——留作后续。

## 3. 术语

| 术语 | 含义 |
|------|------|
| **app_id** | JSON-APP 的稳定标识（`meta.appid`，registry 命名空间唯一）。深链与授权的主键。|
| **route** | App 内目标界面定位：屏幕 `name`（可带嵌套路径），点击后跳转到该屏。|
| **params** | 深链参数，注入为目标屏的 `params.*`（如 `conversationId` / `orderId`）。|
| **App 来源消息** | 由某个 JSON-APP 发出、携带 `{app_id, route, params}` 信封的 IM 消息（区别于框架原生聊天消息）。|
| **推送授权（grant）** | 收件人对某个来源（App / App+发送者 / App+服务）显式开启推送的记录。|
| **安装** | JSON-APP 被保存进本地 `AppStorage`（`@launch_app` 可加载、`@my_apps` 可列出）。|

## 4. 总体设计

分四层，自下而上：

```
① 消息信封层   App 发的 IM 消息携带 {app_id, route, params}（框架注入 app_id，防伪）
      │
② 授权 + 隔离层  收件人 push_app_grants：按 (App[/发送者][/服务]) 默认关、显式开
      │           backend 派发前用「消息的 app_id」查 grant，未授权→不推（站内消息仍达）
      │
③ 推送载荷层   PushPayload.custom += {app_id, route, params, source, sender_id}（provider 层无改动）
      │
④ 客户端路由层  点击通知 → 按 app_id 路由：
                  已安装 → @launch_app 深链进 App + 跳 route(params)
                  未安装 → 框架兜底「邀请下载 A」卡片 → 安装 → 进 App
```

两类推送来源都走同一套授权 + 载荷 + 路由：
- **P2P（用户→用户，在 App A 内）**：经 IM 自定义消息 → webhook 带出 app_id → 按收件人对 A 的 grant 门控。
- **服务→用户（A 的 FaaS 后端主动推）**：新增后端入口，用服务组身份鉴权 → 按收件人对「A+该服务」的 grant 门控。

## 5. 详细设计

### 5.1 应用维度消息信封（"消息变富文本"的真正含义）

> 用户的猜测成立：要把推送精确送进 App 的某个界面，**消息必须从纯文本升级为携带结构化信封的消息**。

**做法**：用 OpenIM **自定义消息类型**（custom message，`contentType` 自定义号）承载信封，而**不是**把 JSON 塞进文本 body（避免污染文本、避免被旧客户端误显示）。

信封 schema（自定义消息 `customData`）：
```jsonc
{
  "v": 1,
  "app_id": "mycompany/forum",     // 框架注入，JSON 不可伪造（见安全）
  "route": "thread_detail",         // 目标屏 name
  "params": { "threadId": "t_123" },// 深链参数 → 目标屏 params.*
  "title": "新回复",                // 推送/卡片标题
  "body": "张三 回复了你的帖子",     // 推送/卡片正文
  "preview": { ... }                // 可选：站内卡片渲染用的轻量预览
}
```

**框架侧渲染**：IM 会话里收到此类自定义消息时，框架以一张**富卡片**（标题 + 正文 + App 角标 + 「打开」按钮）展示，点击走 §5.4 同一路由逻辑。这就是产品所说的「消息变富文本 / 富卡片」。

**DSL 接口**（JSON-APP 侧，`lib/json_ui/interpreter.dart` 扩展）：
- 新增 `@im_send_app_message({ user_id, route, params, title, body, preview? })`：在**当前运行的 JSON-APP**上下文里发一条 App 来源消息。
- **关键：`app_id` 由框架从「当前运行 App 的 `meta.appid`」自动注入**，JSON 代码**无法指定别的 app_id**（防止冒充其它 App，见 §7）。
- 现有 `@im_send_text` 保持不变（发框架原生文本，无信封、不触发 App 深链）。

> 现状参照：`@im_send_text`（`interpreter.dart:2745`）走 `IMService.sendTextMessageAsMap`；新函数走对应的 `sendCustomMessage`，customData 由框架拼装。

### 5.2 推送授权与隔离（主动授权，默认关闭）

**新表 `push_app_grants`**（JSON-APP Postgres / 平台库）：

```sql
CREATE TABLE push_app_grants (
  user_id    TEXT        NOT NULL,           -- 收件人（平台 uid）
  app_id     TEXT        NOT NULL,           -- JSON-APP appid
  scope      TEXT        NOT NULL DEFAULT 'app', -- 'app' | 'sender:<uid>' | 'service:<service_id>'
  enabled    BOOLEAN     NOT NULL DEFAULT TRUE,  -- 行存在=授权；可置 false 表示显式屏蔽
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, app_id, scope)
);
```

**授权语义**
- **默认无行 = 未授权 = 不推**（站内 IM 消息照常送达，只是不发 OS 级推送）。
- 收件人显式开启 → 写一行 `scope='app'`（收 A 的所有推送）；或更细 `scope='sender:<uid>'` / `scope='service:<sid>'`。
- 任一 scope 命中且 `enabled=true` → 允许推；命中且 `enabled=false`（黑名单）→ 拒绝（优先级高于宽 scope）。

**授权入口（UI）**
- 框架设置页「App 通知管理」：列出收件人收到过 App 来源消息的 App，逐个开关。
- 首次收到来自 A 的 App 来源消息时，站内弹一次轻量征询：「是否允许 **A** 给你发送通知？」——一次性、可在设置页改。

**后端门控**（`backend/im.py` `_dispatch_to_user` 之前插入）
1. webhook 解析自定义消息的 `customData.app_id`（框架原生消息无此字段 → 走旧框架逻辑，不受影响）。
2. 查 `push_app_grants`：`(recvID, app_id, 'app' | 'sender:<sendID>')` 是否有 `enabled=true` 且无 `enabled=false` 黑名单命中。
3. 未授权 → **跳过 push.dispatch**（仍 `return errCode:0`，不阻塞 IM）。

### 5.3 推送载荷扩展（provider 层零改动）

`PushPayload.custom`（`backend/push/__init__.py`）补字段，APNs/FCM/GeTui 的 `data`/`custom` 透传即可：
```python
custom = {
  "source": "im",            # "im" | "service"
  "app_id": "mycompany/forum",
  "route": "thread_detail",
  "params": {"threadId": "t_123"},
  "sender_id": "u_1",
  # 既有：conversation_id 等
}
```
`title` / `body` 取信封里的 `title`/`body`（无则回退框架默认文案）。`collapse_id` 用 `app_id+conversation` 合并同会话。

### 5.4 客户端点击路由（落地 `_handleNotificationTap`）

实现 `lib/im/im_push_service.dart` 现注释掉的点击处理，覆盖**冷启动**（`getInitialMessage`，从被杀状态点推送拉起）与**热点击**（`onMessageOpenedApp`）：

```
读 custom.app_id：
  ├─ 空 / source=framework → 现有框架行为（打开对应 IM 会话）
  └─ 有 app_id：
       查 AppStorage 是否已安装该 app_id（@my_apps 同源）
        ├─ 已安装 → @launch_app(kind: local, …) 打开 A
        │            → 进入后导航到 route，注入 params（深链）
        └─ 未安装 → 框架兜底页：「邀请下载 A」卡片（见 §5.5）
```

**深链能力补强**（`@launch_app` / 启动流程）：
- `@launch_app` 增加可选 `initialRoute` + `launchParams`：加载 App 配置后，初始屏切到 `initialRoute`、把 `launchParams` 注入 `params.*`，而不是永远进 App 的默认首屏。
- 或提供启动后回调钩子，由路由层在 App 就绪后调一次框架级 `@navigate(route, params)`。
- 需要约定：JSON-APP 的可深链屏在 `ui.screens[].name` 上稳定命名；`route` 即屏 name。

### 5.5 未安装兜底与「邀请下载」

未安装 A 时，框架展示**邀请页**（不是直接报错）：
- 用 `app_id` 去 registry 拉 A 的展示信息（icon / displayName / description / 最新版本）。
- 卡片：「**A** 给你发来一条消息，安装后查看」+「下载并打开」按钮。
- 点击 → `@launch_app(kind: market, name: app_id, version: latest)` 拉取 → 存入 `AppStorage`（即"安装"）→ 打开 → 跳 `route(params)`。
- 取不到 registry 信息（私有/下架）→ 退化为「该应用不可用」纯文案，不崩。

## 6. 数据模型汇总

| 对象 | 位置 | 作用 |
|------|------|------|
| App 来源消息信封 | OpenIM 自定义消息 `customData` | 携带 `{app_id, route, params, title, body}` |
| `push_app_grants` | 平台 Postgres | 收件人对 (App[/发送者][/服务]) 的推送授权 |
| `PushPayload.custom` 扩展 | `backend/push` | 深链字段透传给 provider data |
| （可选）`app_push_log` | 平台 Postgres | 审计：谁/哪个 App/哪个服务/对谁/是否被授权门控拦下 |

## 7. 安全与防滥用

1. **app_id 防伪**：信封的 `app_id` **只能由框架从当前运行 App 的 `meta.appid` 注入**，`@im_send_app_message` 不接受调用方传入的 app_id。杜绝 A 冒充 B 发深链。
2. **默认关闭 + 显式授权**：`push_app_grants` 无行即不推；防止「拿到 uid 就能轰炸」。
3. **可撤销 + 黑名单**：收件人随时关；`enabled=false` 行作为强屏蔽，优先于宽 scope。
4. **服务→用户推送鉴权**：A 的 FaaS 主动推走新入口，用**服务组身份**（复用 FaaS run-token / owner 模型）签名鉴权，且按 `scope='service:<sid>'` 门控；函数代码不持任何推送密钥。
5. **限流**：按 `(app_id, sender)` 与 `(app_id, service)` 限频，防单 App 刷推送。
6. **内容净化**：`title`/`body` 限长、纯文本、剥 HTML；`params` 仅作深链参数，不可注入可执行逻辑。
7. **在线不推**（沿用现状）：收件人在线时只走站内，不发 OS 推送。

## 8. 兼容性与迁移

- **向后兼容**：框架原生文本消息无信封字段 → webhook 门控直接放行走旧逻辑，老客户端不受影响。
- 旧客户端收到 App 自定义消息：OpenIM 自定义类型在不识别时降级为「[应用消息]」占位文案，不崩；升级后才渲染富卡片 + 深链。
- `device_tokens` schema 不变；新增表与新增 custom 字段都是叠加式。

## 9. 分期实施计划

**P1 · 深链直达（已安装路径打通）**
1. 消息信封：`@im_send_app_message` + 框架注入 app_id + 自定义消息收发。
2. webhook 解析 app_id；新表 `push_app_grants`；`_dispatch_to_user` 前置门控。
3. `PushPayload.custom` 扩展；客户端 `_handleNotificationTap`（热 + 冷启动）→ 已安装则 `@launch_app` 深链。
4. `@launch_app` 加 `initialRoute`/`launchParams`；IM 会话富卡片渲染。
5. 授权 UI：设置页「App 通知管理」+ 首条消息征询弹窗。

**P2 · 未安装兜底**
6. 框架「邀请下载 A」兜底页（registry 取展示信息）→ 安装→打开→深链。

**P3 · 服务推送 + 加固**
7. 服务→用户推送入口（FaaS 主动推，服务组身份鉴权，`scope='service'`）。
8. 限流、`app_push_log` 审计、黑名单/撤销完善。

## 10. 待定 / 开放问题

- 深链 `route` 是否需要支持多级路径（如 `tab/thread/detail`）与回退栈，还是只定位单屏即可？
- `push_app_grants` 放平台库还是各 App 的 FaaS 库？建议放**平台库**（跨 App 统一管理、框架 UI 直读）。
- 「服务推送」的配额与计费口径（是否计入 App 的 FaaS 配额）。
- 是否需要免打扰时段 / 通知分组（留 P3+）。

---

**实现完成后**：把 `@im_send_app_message`、`@launch_app` 的 `initialRoute`/`launchParams`、自定义消息富卡片等回流到 `JSON-DSL.md`；把 `push_app_grants` 与门控回流到 `PUSH_ARCHITECTURE.md`。
