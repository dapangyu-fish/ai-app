# OpenIM 部署 / 运维手册

## 拓扑

```
┌──────────────────────────────────────────────────────────┐
│  iOS / Android / Web 客户端                              │
│   ├─ POST /api/im/token  →  myapp-backend.dapangyu.work   │
│   └─ WS / API           →  38.76.199.232:10001 / 10002 │
└──────────────────────────────────────────────────────────┘
            │                                │
            │ HTTPS                          │ HTTP / WS（暂无 SSL）
            ▼                                ▼
┌────────────────────────┐    ┌─────────────────────────────┐
│ app-backend (Flask)    │    │ 38.76.199.232 (OpenIM)      │
│ /api/im/token          │───▶│ openim-server :10002 (API)  │
│ /api/im/users/lookup   │    │ openim-server :10001 (WS)   │
│ supervisorctl ai-app   │    │ openim-chat   :10008        │
└────────────────────────┘    │ minio  :10005   web :11001  │
                              │ admin  :11002   metrics …   │
                              └─────────────────────────────┘
```

## 关键参数

| 项 | 值 |
|---|---|
| OpenIM server | `38.76.199.232` |
| OpenIM API | `http://38.76.199.232:10002` |
| OpenIM WS | `ws://38.76.199.232:10001` |
| OpenIM admin secret | `openIM_v3iM_secret_2026_dev`（暂进 git，dev only） |
| OpenIM admin userID | `imAdmin`（OpenIM v3.8 默认） |
| 部署目录 | `/opt/openim-docker` |
| Docker | 29.4.1 + Compose v5.1.3 |
| Mongo / Redis / Kafka / etcd / MinIO | 全部由 docker-compose 拉起，仅监听容器内网，外部不可达 |

**Supabase user.id ↔ OpenIM userID 映射规则**：去掉 hyphen。  
OpenIM 拒绝含 `-` 的 userID（errCode=1001 "userID is legal"），UUID `5f993b2a-815b-4ff9-820a-e6dba721943d` → OpenIM userID `5f993b2a815b4ff9820ae6dba721943d`。所有客户端 / 后端必须保持一致 strip。

## 常用命令（在 38.76.199.232 上）

```bash
# 启动 / 停止 / 重启
cd /opt/openim-docker
docker compose up -d
docker compose down
docker compose restart openim-server

# 查看状态
docker compose ps

# 查 server 日志（最常用）
docker logs -f --tail 100 openim-server
docker logs -f --tail 100 openim-chat

# 端口确认
ss -tlnp | grep -E "10001|10002|10005"
```

## 健康检查 / 自检

```bash
# 1. 拿 admin token
curl -X POST http://38.76.199.232:10002/auth/get_admin_token \
  -H "Content-Type: application/json" -H "operationID: smoke" \
  -d '{"secret":"openIM_v3iM_secret_2026_dev","userID":"imAdmin"}'
# 期望：errCode=0 + token

# 2. 注册一个 OpenIM 用户（注意 userID 不能含 -）
ADMIN_TOKEN="<上一步 token>"
curl -X POST http://38.76.199.232:10002/user/user_register \
  -H "Content-Type: application/json" -H "operationID: smoke" -H "token: $ADMIN_TOKEN" \
  -d '{"secret":"openIM_v3iM_secret_2026_dev","users":[{"userID":"smoketest001","nickname":"Smoke"}]}'

# 3. 给该用户签一个 user token
curl -X POST http://38.76.199.232:10002/auth/get_user_token \
  -H "Content-Type: application/json" -H "operationID: smoke" -H "token: $ADMIN_TOKEN" \
  -d '{"secret":"openIM_v3iM_secret_2026_dev","platformID":1,"userID":"smoketest001"}'
```

## 后端集成（myapp-backend.dapangyu.work）

后端通过 `backend/im.py` 提供两个路由：
- `POST /api/im/token` —— 客户端登录后调，业务 token 换 IM token
- `GET  /api/im/users/lookup?user_id=xxx` —— 加好友前用对方 ID 查昵称头像

**部署**：
```bash
# 在本机 push 代码到 origin/feat/openim-messaging 后
ssh root@myapp-backend.dapangyu.work
cd /root/ai-app && git pull   # 或 scp 单个文件
supervisorctl restart ai-app
tail -f /var/log/ai-app/ai-app.log    # 看启动日志中是否有 "IM: /api/im/{token,users/lookup}"
```

## TODO（暂未做）

1. **HTTPS / 域名** —— 现在 OpenIM 走 IP 明文。iOS 真机能跑（Info.plist 已开 NSAllowsArbitraryLoads），但上线 App Store 必须改 SSL。建议：
   - 给 38.76.199.232 申请域名 `im.dapangyu.work`
   - 用 nginx 反向代理 + Let's Encrypt 证书（OpenIM 的 nginx 模板见 docker-compose.yaml 注释）
   - 客户端把 NSAllowsArbitraryLoads 关掉
2. **APNs 推送** —— iOS app 杀死时收不到消息。要做：
   - Apple Developer 申请 APNs Auth Key（.p8 文件）
   - 配 OpenIM `config/notification.yaml` 的 push.iosPush（写入 .p8 + bundleID）
   - 客户端拿到 deviceToken 后调 OpenIM SDK setAppBadge / 注册
3. **OPENIM_SECRET 进 .env** —— 现在硬编码进 git 是 dev 行为，上线前必须挪到 .env 并轮换
4. **MinIO 公网访问** —— OpenIM 的图片消息 / 头像走 MinIO，上线前要：
   - 给 MinIO 加 SSL（同上 nginx）
   - 或客户端直接走 38.76.199.232:10005（已开），但 iOS 又要 NSAllowsArbitraryLoads
5. **服务器加防火墙** —— `ufw allow 10001 10002`，再 `ufw enable`。现在 ufw inactive，所有端口暴露公网

## 故障排查

### 客户端登录 OpenIM 失败 / 一直 connecting
1. 看后端日志确认 `/api/im/token` 是否给客户端返了正确的 token
2. 用 `wscat -c ws://38.76.199.232:10001/?sendID=...&token=...&platformID=1&operationID=test`
3. 看 OpenIM server 容器日志：`docker logs openim-server --tail 200`

### 加好友后对方收不到
- OpenIM 默认 "申请-同意" 模式，对方需要在客户端 "新的朋友" 页面手动同意
- 如果想跳过审批，调 `/friend/import_friend`（admin token），双向直接加为好友

### 重新初始化数据
```bash
cd /opt/openim-docker
docker compose down -v       # -v 会删除 volumes（mongo / redis / minio 数据全部清空）
docker compose up -d
```
