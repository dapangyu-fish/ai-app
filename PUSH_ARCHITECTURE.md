# 离线推送架构（APNs / FCM / geTui）

> 当聊天消息送达时收件人不在线，由 **我们的后端** 主动推送到对应平台的推送通道。

## 整体流程

```
┌────────────────────────┐
│  发消息的 Flutter 端    │
└──────────┬─────────────┘
           │ ① 用户A 发消息给 用户B
           ▼
┌────────────────────────┐
│  OpenIM 服务器          │  38.76.199.232
│  保存消息后立即触发      │
│  afterSendSingleMsg     │  ──────┐
│  webhook                │        │ ② HTTP POST
└─────────────────────────┘        │   { sendID, recvID, content,
                                   │     senderNickname, ... }
                                   ▼
                       ┌──────────────────────────┐
                       │  我们的 Flask 后端        │  myapp-backend.dapangyu.work
                       │  /api/im/after_send_msg   │
                       │                           │
                       │  ③ 查 OpenIM API:         │
                       │     B 是否在线？           │
                       │     在线 → return 不推     │
                       │     离线 → 继续           │
                       │                           │
                       │  ④ 查 device_tokens 表：  │
                       │     B 的 (platform, token) │
                       │                           │
                       │  ⑤ 按 platform 分发：      │
                       │     ios → apns.py         │
                       │     android-cn → getui.py │
                       │     android-intl → fcm.py │
                       └────────┬──────────────────┘
                                │
                  ┌─────────────┼─────────────┐
                  ▼             ▼             ▼
            ┌──────────┐ ┌──────────┐ ┌──────────┐
            │  Apple   │ │  geTui   │ │   FCM    │
            │  APNs    │ │  (国内)  │ │  (Google)│
            └────┬─────┘ └────┬─────┘ └────┬─────┘
                 │            │             │
                 ▼            ▼             ▼
              iPhone     国内 Android   国际 Android
```

## 为什么用 `afterSendSingleMsg`，不用 `beforeOfflinePush`

OpenIM v3.8 有 6+ 个 webhook 钩子。我们曾试过 `beforeOfflinePush`，**实测在 v3.8 不会被触发**：

- 这个钩子的代码位置埋在 geTui / fcm / jpush 三个 push provider 内部
- openim-push.yml 里 `enable: geTui` 但我们没配 geTui 的 appKey/secret，provider 初始化就报 `code 20001 appid invalid` 直接 return
- 永远走不到 webhook 调用那一步，后端日志全空

`afterSendSingleMsg` 钩子的位置在 message handler 主流程，**只要消息成功保存就触发**，跟 push provider 配置无关。这是 OpenIM 社区里跑通成千上万项目的稳定钩子。

代价：每条消息（不论收件人在线/离线）都会调我们后端，所以后端**必须先查在线状态**再决定是否推。在线就直接 return 不推，避免重复打扰用户。

## 各组件职责

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

> 文件不在 host 上，只在 `openim-server` 容器内 `/openim-server/config/webhooks.yml`。改完用 `docker cp` 拷回去 + restart container。

### 2. 后端 webhook 入口（`backend/im.py`）

`/api/im/after_send_msg` 路由：

1. 校验 query string 里的 `secret`（防止外部伪造）
2. 解析 OpenIM 推过来的 callback body：
   - `sendID` 发送方 OpenIM userID
   - `recvID` 接收方 OpenIM userID（去掉了 hyphen 的 32 位 hex）
   - `content` 消息正文（JSON 字符串）
   - `senderNickname` 显示用
   - `contentType` 消息类型（101=text, 102=image, ...）
3. 查 OpenIM 在线状态 API（`/user/get_users_online_status`，需要 admin token）
   - 在线 → return errCode 0，不做任何事
   - 离线 → 进入分发
4. 查 `device_tokens WHERE user_id = <supabase uuid>`
5. 按 platform 分发：
   - `platform = 'ios'` → `apns.push_to_device(...)`
   - `platform = 'android'` + 国内（暂未实现）→ `getui.push_to_device(...)`
   - `platform = 'android-intl'` + 国际（暂未实现）→ `fcm.push_to_device(...)`
6. 永远 return `{"errCode": 0, "errMsg": ""}`，避免推送失败阻塞 OpenIM 主流程

### 3. APNs 实现（`backend/apns.py`） ✅ 已完成

- `.p8` 私钥存 `/etc/apns/AuthKey_<KEY_ID>.p8`，权限 600，root 持有
- ES256 签 provider JWT（缓存 50 分钟）
- HTTPS POST 到 `api.sandbox.push.apple.com` (dev) / `api.push.apple.com` (prod)
- 410 / `BadDeviceToken` / `Unregistered` 自动清理 device_tokens 表

### 4. FCM 实现（`backend/fcm.py`） ⏳ 待实现

- 服务账号 JSON 存 `/etc/fcm/service-account.json`，不进 git
- 用 `google-auth` + `httpx` POST 到 `https://fcm.googleapis.com/v1/projects/<project>/messages:send`
- payload: `{message: {token, notification: {title, body}, data: {...}}}`

### 5. geTui 实现（`backend/getui.py`） ⏳ 待实现

- AppID/AppKey/MasterSecret 存 `.env`（geTui 没有像 .p8 那样的高权限私钥，secret 进 .env 即可）
- 先调 `/auth_sign` 拿短期 token（24h）
- 再调 `/push/single/cid` 推单设备
- 设备绑定时上报 `clientID`（geTui 自己生成的设备标识，不是 APNs deviceToken）

### 6. 设备 token 表（`device_tokens`） ✅ 已完成

```sql
CREATE TABLE device_tokens (
  user_id    TEXT NOT NULL,        -- Supabase user UUID（带 hyphen）
  platform   TEXT NOT NULL,        -- 'ios' | 'android' | 'android-intl'
  token      TEXT NOT NULL,        -- APNs hex / FCM token / geTui clientID
  bundle_id  TEXT,                 -- iOS bundle ID 或 Android package
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, platform, token)
);
CREATE INDEX idx_device_tokens_user_id ON device_tokens (user_id);
```

复合主键 `(user_id, platform, token)` 允许同一用户多设备（一台 iPhone + 一台 Android），UPSERT 幂等。

### 7. 客户端上报 token（`lib/im/apns_service.dart` 等）

- 登录成功后调 `ApnsService.start()`（iOS）/ `FcmService.start()`（Android，待实现）
- 拿到 token → POST `/api/im/push_token` `{platform, token}` 入库
- 已有 `_lastUploadedToken` dedup，同一 token 不重复上传

## 后续扩展点

- [ ] 添加 `backend/fcm.py` + Flutter Firebase 集成
- [ ] 添加 `backend/getui.py` + 客户端 geTui SDK 集成
- [ ] 推送内容增加业务字段：`{conversation_id, message_id}`，让 iOS Notification Service Extension / Android NotificationListener 能跳转到具体会话
- [ ] 推送限流：同一对话短时间多条消息合并（用 APNs `apns-collapse-id`，FCM `collapse_key`，geTui `transmissionContent`）—— 已在 `apns.py` 实现 collapse_id，其他两家照做
- [ ] 推送统计：写一张 `push_log` 表记录每条推送的 status，方便排查 token 失效率
- [ ] 用户级开关：用户可以在 app 里关闭某些类型的推送（@消息 / 群消息 / 静音对话），后端在 ④ 之后加一层过滤

## 配置参考

`backend/config.py` 里的相关常量：

```python
# OpenIM webhook 共享密钥
OPENIM_WEBHOOK_SECRET = os.environ.get("OPENIM_WEBHOOK_SECRET", "openIM_webhook_secret_2026_dev")

# APNs（仅 iOS）
APNS_KEY_PATH = "/etc/apns/AuthKey_8NM9U7CJCJ.p8"
APNS_KEY_ID   = "8NM9U7CJCJ"
APNS_TEAM_ID  = "5CD2U23TPH"
APNS_BUNDLE_ID = "dapangyu.fish.myapp"
APNS_USE_SANDBOX = True   # dev/TestFlight 用 sandbox，App Store 上线版改 false

# FCM（待加）
FCM_SERVICE_ACCOUNT_PATH = "/etc/fcm/service-account.json"
FCM_PROJECT_ID = "..."

# geTui（待加）
GETUI_APP_ID = "..."
GETUI_APP_KEY = "..."
GETUI_MASTER_SECRET = "..."
```

## 排查清单

收件人没收到推送时：

1. 后端日志看有没有 `/api/im/after_send_msg` 请求进来
   - 没有 → OpenIM 那边问题：
     - 检查 `webhooks.yml` 里 `afterSendSingleMsg.enable: true`
     - `docker logs openim-server | grep webhook`
2. 有请求进来，但分支走了"在线"
   - 接收方真的离线吗？前台 / 刚划掉几秒内 OpenIM 还判定 online
   - 划掉 app + 等 30 秒后再发
3. 走了离线分支，但 device_tokens 表里没记录
   - 客户端 token 上报流程出问题，看 `[APNs] device token 已上传后端` 日志
4. 有 token，但 APNs 推送失败
   - 后端日志会有 `[APNs] ❌ 推送失败 status=...`
   - 410/BadDeviceToken：token 过期，已自动清理
   - 403：`.p8` / Team ID / Bundle ID 配置不对
   - 网络问题：服务器到 `api.sandbox.push.apple.com` 不通
