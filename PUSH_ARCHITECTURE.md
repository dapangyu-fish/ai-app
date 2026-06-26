# 离线推送架构（多通道：APNs / FCM / geTui / ...）

> 当聊天消息送达时收件人不在线，由 **我们的后端** 主动推送到对应推送通道。

## 整体流程

```
┌────────────────────────┐
│  发消息的 Flutter 端    │
└──────────┬─────────────┘
           │ ① 用户 A 发消息给 用户 B
           ▼
┌────────────────────────┐
│  OpenIM 服务器          │  myapp-backend.dapangyu.work（与后端同机）
│  保存消息后立即触发      │
│  afterSendSingleMsg     │  ──────┐
│  webhook                │        │ ② HTTP POST
└─────────────────────────┘        │   { sendID, recvID, content,
                                   │     senderNickname, ... }
                                   ▼
                       ┌──────────────────────────┐
                       │  我们的 Flask 后端         │
                       │  /api/im/after_send_msg   │
                       │                           │
                       │  ③ 查 OpenIM API:         │
                       │     B 是否在线？           │
                       │     在线 → return 不推     │
                       │     离线 → 继续           │
                       │                           │
                       │  ④ 查 device_tokens 表：  │
                       │     B 的所有 (channel,    │
                       │     token, channel_meta)  │
                       │                           │
                       │  ⑤ push.dispatch(channel, │
                       │     token, meta, payload) │
                       │     按 channel 路由 provider│
                       └────────┬──────────────────┘
                                │
                  ┌─────────────┼─────────────┐
                  ▼             ▼             ▼
           ┌──────────┐  ┌──────────┐  ┌──────────┐
           │   APNs   │  │   FCM    │  │  geTui   │
           │  (Apple) │  │ (Google) │  │  (国内)  │
           └────┬─────┘  └────┬─────┘  └────┬─────┘
                │             │             │
                ▼             ▼             ▼
             iPhone     国际 Android   国内 Android
```

## 设计要点

### 1. 通道无关的 schema

```sql
CREATE TABLE device_tokens (
  user_id      TEXT        NOT NULL,
  channel      VARCHAR(32) NOT NULL,    -- 'apns' | 'fcm' | 'getui' | 'huawei' | ...
  token        TEXT        NOT NULL,
  channel_meta JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, channel, token)
);
```

`channel_meta` 装通道私有字段，加新通道时 schema 不动：

| channel | channel_meta 例子 | 说明 |
|---------|-------------------|------|
| `apns` | `{"env": "sandbox"}` | dev / Xcode 自动签名 / 模拟器 |
| `apns` | `{"env": "production"}` | TestFlight / App Store |
| `fcm` | `{"app_id": "...debug"}` 或 `{}` | 不同 applicationId 用不同 service account |
| `getui` | `{"app_id": "...", "vendor": "huawei"}` | 厂商通道（华为/小米/OPPO/vivo）|

复合 PK `(user_id, channel, token)` 允许同 user 多设备。客户端侧会避免同一设备同时注册 FCM/APNs 与 GeTui，防止重复通知。

### 2. 后端 dispatcher 模式

`backend/push/__init__.py` 提供：

```python
@dataclass
class PushPayload:                          # 通用 payload，各 provider 自己映射
    title: str
    body: str
    badge: int | None = None
    custom: dict | None = None              # 业务字段：conversation_id / sender_id ...
    collapse_id: str | None = None          # 同会话合并

@dataclass
class PushResult:
    ok: bool
    expired_token: bool = False             # token 失效 → 调用方 DELETE 这条 row
    retryable: bool = False
    status_code: int | None = None
    reason: str | None = None

def register(channel: str, push_fn): ...
def dispatch(*, channel, token, meta, payload) -> PushResult: ...
def is_supported(channel: str) -> bool: ...
```

每个 provider 自注册：

```python
# backend/push/apns_provider.py 末尾
register("apns", push)
```

`backend/push/__init__.py` 末尾把内置 provider 都 import 一下触发注册：

```python
from . import apns_provider  # noqa
# from . import fcm_provider  # 加 FCM 时打开
```

### 3. 加新通道的成本

加 FCM 三步走，**核心代码（im.py / device_tokens schema）一行不改**：

1. 新建 `backend/push/fcm_provider.py`，实现 `def push(*, token, meta, payload) -> PushResult`，文件末尾 `register("fcm", push)`
2. `backend/push/__init__.py` 末尾加一行 `from . import fcm_provider`
3. Android 客户端注册时 POST `/api/im/push_token` `{channel: "fcm", token, meta: {}}`

geTui / 华为 / 小米 / VoIP / Live Activity 同理。

## 各组件细节

### 1. OpenIM webhook 配置（`webhooks.yml`）

```yaml
url: https://myapp-backend.dapangyu.work/api/im/after_send_msg?secret=<OPENIM_WEBHOOK_SECRET>
afterSendSingleMsg:
  enable: true
  timeout: 5
  attentionIds: []   # 空 = 所有用户都触发
  allowedTypes: []   # 空 = 所有 contentType 都触发
  deniedTypes: []
```

> 文件不在 host，只在 `openim-server` 容器内 `/openim-server/config/webhooks.yml`。改完用 `docker compose up -d --force-recreate --no-deps openim-server`。

### 2. 后端 webhook 入口（`backend/im.py`）

`/api/im/after_send_msg` 路由：

1. 校验 `secret`（防伪造）
2. 解析 OpenIM callback body（`sendID` / `recvID` / `content` / `senderNickname` / `contentType` ...）
3. 查 OpenIM 在线状态：在线 → return 不推，离线 → 继续
4. 调 `_dispatch_to_user(sup_id, payload, ...)` 通道无关派发
5. 永远 return `{"errCode": 0, "errMsg": ""}`，避免推送失败阻塞 IM 主流程

`_dispatch_to_user` 是核心循环：

```python
rows = db_query("SELECT channel, token, channel_meta FROM device_tokens WHERE user_id = %s", (sup_id,))
for row in rows:
    result = push.dispatch(channel=row.channel, token=row.token, meta=row.channel_meta, payload=payload)
    if result.expired_token:
        # 自愈：失效 token 直接 DELETE，下次推送不再尝试
        db_execute("DELETE FROM device_tokens WHERE user_id=%s AND channel=%s AND token=%s", ...)
```

### 3. 为什么用 `afterSendSingleMsg`，不用 `beforeOfflinePush`

OpenIM v3.8 有 6+ 个 webhook。我们曾试过 `beforeOfflinePush`，**实测在 v3.8 不会被触发**：

- 这个钩子的代码位置埋在 geTui / fcm / jpush 三个 push provider 内部
- `openim-push.yml` 里 `enable: geTui` 但我们没配 geTui 的 appKey/secret，provider 初始化报 `code 20001 appid invalid` 直接 return
- 永远走不到 webhook 调用那一步

`afterSendSingleMsg` 钩子在 message handler 主流程，**只要消息成功保存就触发**，跟 push provider 配置无关。

代价：每条消息（不论收件人在线/离线）都会调我们后端，所以后端**必须先查在线状态**再决定是否推。

### 4. APNs provider（`backend/push/apns_provider.py`）✅ 已实现

- `.p8` 私钥存 `/etc/apns/AuthKey_<KEY_ID>.p8`，权限 600，root 持有
- ES256 签 provider JWT（缓存 50 分钟）
- **按每条 token 的 `meta.env` 选 host**（核心修复 — 之前用全局 flag 导致 dev/TF 不能互推）：
  - `{"env": "sandbox"}` → `api.sandbox.push.apple.com`
  - `{"env": "production"}` → `api.push.apple.com`
- 410 / `BadDeviceToken` / `Unregistered` 返 `expired_token=True`，dispatcher 调用方 DELETE row

### 5. FCM provider（`backend/push/fcm_provider.py`）✅ 已实现

- 服务账号 JSON 存 `/etc/fcm/service-account.json`
- `google-auth` + `httpx` POST 到 `https://fcm.googleapis.com/v1/projects/<project>/messages:send`
- payload: `{message: {token, notification: {title, body}, data: {...}}}`
- `FCM_PROJECT_ID` 为空时 provider 返回配置错误，不阻塞 IM 主流程

### 6. GeTui provider（`backend/push/getui_provider.py`）✅ 已实现

- 服务端环境变量：`GETUI_APP_ID` / `GETUI_APP_KEY` / `GETUI_MASTER_SECRET`，真实值只放 `myapp-ctl` 管理的 `/etc/myapp/secrets.d/push.env`
- 先调 `POST /v2/{appId}/auth` 换接口 token，provider 内存缓存并在失效时刷新
- `POST /v2/{appId}/push/single/cid` 推单个 CID；`device_tokens.token` 在该通道下就是 GeTui ClientID
- `GETUI_APP_SECRET` 作为控制台凭证保留在服务端环境变量；当前 Android 原生桥只需要构建时注入 AppID，MasterSecret 严禁进入客户端

### 7. 客户端上报 token（`lib/im/apns_service.dart` / `lib/im/fcm_service.dart` / `lib/im/getui_service.dart`）

注册流程：
1. 登录成功后 `IMService` 启动推送服务：
   - 默认：iOS 走 APNs，Android 走 FCM
   - Android 构建时配置 `GETUI_ENABLED=true` 且注入 `GETUI_APP_ID` 后：优先走 GeTui，并注销同设备旧 FCM token，避免重复推送
2. APNs：弹通知权限 → `registerForRemoteNotifications`
3. iOS native `AppDelegate.swift` 在 `didRegisterForRemoteNotificationsWithDeviceToken` 回调里：
   - hex 化 deviceToken
   - **调 `detectApsEnvironment()` 真实读 entitlement**（见下文坑）
   - 用 MethodChannel 把 `{token, env}` 发给 Dart
4. FCM/GeTui：SDK 获取 token/CID 后直接 POST `/api/im/push_token`
5. Dart 把 APNs `'development'` 规约成 `'sandbox'`，POST `/api/im/push_token`：
   ```json
   { "channel": "apns", "token": "<hex>", "meta": {"env": "sandbox"|"production"} }
   ```
   GeTui 对应：
   ```json
   { "channel": "getui", "token": "<cid>", "meta": {"app_id": "<appid>", "platform": "android"} }
   ```

注销流程（logout / 切账号）：
1. `ApnsService.instance.unregister()`：DELETE `/api/im/push_token` 删后端 row + 清 `_started`/`_lastUploadedToken`
2. 必须在 `AuthService._clearLocal()` / `SharedPreferences.clear()` **之前**做，否则 access_token 没了后端鉴权拒掉

### 8. iOS 端 env 探测的坑（`AppDelegate.swift`）

**不能用 `kReleaseMode` / `#if DEBUG`** —— TF 也是 release mode，但 APNs env 是 production。
**不能用 sandbox/production receipt URL** —— TF 是 sandbox receipt 但 APNs 要 production。

正确做法分两路：

```swift
private static func detectApsEnvironment() -> String {
  #if targetEnvironment(simulator)
  // iOS 16+ 模拟器能拿真 APNs token 走 sandbox，但 bundle 里没 mobileprovision，
  // 不能让兜底落到 production（曾踩此坑：sim 注册成 production → BadDeviceToken → 自愈删 row）
  return "development"
  #else
  // 真机：从 embedded.mobileprovision 解 Entitlements.aps-environment
  // dev/ad-hoc/enterprise/AppStore 都有这文件，里头的 aps-environment 就是 APNs 实际环境
  // 文件读不到时兜底 "production"（合理：上架包不可能是 sandbox）
  guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
        let data = try? Data(contentsOf: url) else { return "production" }
  // 解 PKCS#7 容器里嵌入的 plist，读 Entitlements["aps-environment"]
  ...
  #endif
}
```

### 9. 后端注销接口（`DELETE /api/im/push_token`）

```
DELETE /api/im/push_token
Authorization: Bearer <access_token>
Body: { "channel": "apns", "token": "<token>" }
```

精确删 `(user_id, channel, token)` 一行。幂等。`user_id` 来自鉴权，所以**只能删自己 user 的 row**，不会误炸别人。

为啥需要：之前没接这个，同一台 sim 先后登过两个账号会留下两条 row（同 token + 不同 user_id）。结果 user A 离线时被发消息，本来推到这台设备的 user A 推送，会同时也推到这台设备显示成 user B 的消息（即使 B 早就登出）。

## 测试矩阵

每个组合都应该通：

| 发送端 | 接收端 | 预期 |
|--------|--------|------|
| Xcode dev sim → | Xcode dev sim | sandbox→sandbox ✅ |
| Xcode dev sim → | TF 真机 | sandbox→production ✅ |
| TF 真机 → | Xcode dev sim | production→sandbox ✅ |
| TF 真机 → | TF 真机 | production→production ✅ |
| AppStore 真机 → | TF 真机 | production→production ✅ |

发送端的版本/通道**不影响**接收端的推送 —— 后端只看接收端那条 row 的 `meta.env`。

## 配置参考

服务端推送 secret 由 `myapp-ctl setup` 写入 `/etc/myapp/secrets.d/push.env`
和 `/etc/myapp/secrets.d/files/**`，权限建议 `600 root:root`：

```bash
APNS_KEY_PATH=/etc/myapp/secrets.d/files/apns/AuthKey_XXXXXXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=dapangyu.fish.myapp
APNS_USE_SANDBOX=true

FCM_SERVICE_ACCOUNT_PATH=/etc/myapp/secrets.d/files/fcm/service-account.json
FCM_PROJECT_ID=

GETUI_BASE_URL=https://restapi.getui.com/v2
GETUI_APP_ID=
GETUI_APP_KEY=
GETUI_APP_SECRET=
GETUI_MASTER_SECRET=
GETUI_TTL_MS=7200000
```

Android 客户端启用 GeTui 时，构建环境注入 AppID，但不提交到仓库；iOS 继续走 APNs，不引入 GeTui iOS SDK：

```bash
export GETUI_APP_ID=...
flutter build apk \
  --dart-define=GETUI_ENABLED=true \
  --dart-define=GETUI_APP_ID="$GETUI_APP_ID"
```

## 排查清单

收件人没收到推送时：

1. **后端有没有 `/api/im/after_send_msg` 请求进来**
   - 没有 → OpenIM 那边问题：检查 `webhooks.yml` `afterSendSingleMsg.enable: true`；`docker logs openim-server | grep webhook`
2. **请求进来了，但走了"在线"分支**
   - 接收方真的离线吗？前台 / 刚划掉几秒内 OpenIM 还判定 online；划掉 app + 等 30 秒
3. **走了离线分支，但 `device_tokens` 表里没记录**
   - 客户端 token 上报失败：看 `[APNs] device token 已上传 (env=...)` 日志，没有就检查 `/api/im/push_token` 请求
4. **有 token，但推送失败**
   - 后端日志 `[APNs] ❌ 推送失败 env=... status=... reason=...`
   - `400 BadDeviceToken` → token 跟 env 对不上（最常见：sim 错注册成 production）；自愈逻辑会删 row，让客户端下次启动重新注册
   - `403` → `.p8` / Team ID / Bundle ID 配置不对
   - `410 Unregistered` → token 失效（用户卸载 app 等），自愈删
5. **DB 里同一 token 出现在多个 user 下**
   - 历史污染（早期版本登出没清 token）。新版 `unregister()` 已修；存量数据可以用 SQL 按 `updated_at` 取最新者保留：
   ```sql
   DELETE FROM device_tokens dt
   WHERE EXISTS (
     SELECT 1 FROM device_tokens dt2
     WHERE dt2.channel = dt.channel AND dt2.token = dt.token
       AND dt2.user_id <> dt.user_id AND dt2.updated_at > dt.updated_at
   );
   ```

## 后续扩展点

- [x] `backend/push/fcm_provider.py` + Flutter Firebase 集成（Android 海外）
- [x] `backend/push/getui_provider.py` + 客户端 GeTui SDK 集成（Android 国内）
- [ ] APNs VoIP / Live Activity（独立 channel，独立 .p8 也独立 push-type）
- [ ] iOS Notification Service Extension：从 `custom.conversation_id` 跳到具体会话
- [ ] 用户级开关：app 内可关闭某些类型推送（@消息 / 群消息 / 静音对话）
- [ ] `push_log` 表记录每条推送的 status，方便查 token 失效率 / 通道送达率
