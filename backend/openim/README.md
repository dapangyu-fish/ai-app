# OpenIM Server 自托管部署指南

## 前置要求

- Docker & Docker Compose v2
- 至少 4GB RAM (推荐 8GB)
- 磁盘空间: 至少 20GB

## 快速部署

```bash
# 1. 进入部署目录
cd backend/openim

# 2. 复制并修改配置
cp .env.example .env
# 编辑 .env，修改所有默认密码

# 3. 启动所有服务
docker compose up -d

# 4. 查看日志
docker compose logs -f openim-server
```

## 服务端口

| 服务 | 端口 | 说明 |
|------|------|------|
| OpenIM WS Gateway | 10001 | WebSocket 长连接（客户端消息通道） |
| OpenIM API | 10002 | HTTP API（客户端调用） |
| OpenIM Chat API | 10008 | 用户注册/登录业务 API |
| OpenIM Admin API | 10009 | 管理后台 API |
| MySQL | 13306 | 映射到宿主机 13306 |
| MongoDB | 37017 | 映射到宿主机 37017 |
| Redis | 16379 | 映射到宿主机 16379 |
| MinIO Console | 10006 | 对象存储管理界面 |
| MinIO API | 10005 | 对象存储 S3 API |

## 架构组件

```
┌─────────────────────────────────────────┐
│               Flutter App              │
│  ┌─────────────┐  ┌─────────────────┐  │
│  │ OpenIM SDK  │  │ Auth (Supabase) │  │
│  └──────┬──────┘  └────────┬────────┘  │
└─────────┼──────────────────┼───────────┘
          │ WS :10001        │
          │ HTTP :10002      │ HTTP :5566
┌─────────┴──────────┐  ┌───┴──────────────┐
│   OpenIM Server    │  │  Flask Backend   │
│  ┌──────┐ ┌─────┐  │  │  /api/im/token   │
│  │ API  │ │ WS  │  │  │  (用户桥接)       │
│  └──┬───┘ └──┬──┘  │  └──────────────────┘
│     │        │     │
│  ┌──┴────────┴──┐  │
│  │   消息引擎    │  │
│  └──────┬───────┘  │
└─────────┼──────────┘
          │
    ┌─────┴──────┐
    │ 基础设施    │
    │ MySQL      │
    │ MongoDB    │
    │ Redis      │
    │ Kafka      │
    │ Etcd       │
    │ MinIO      │
    └────────────┘
```

## 与现有系统集成

OpenIM 有独立的用户体系，通过 Flask 后端 `/api/im/token` 接口桥接：

1. 用户在 App 中通过 Supabase 登录
2. 客户端调用 `/api/im/token` (携带 Supabase JWT)
3. 后端用 Supabase user_id (去掉连字符) 作为 OpenIM userID
4. 后端自动在 OpenIM 注册用户（首次）并获取 userToken
5. 客户端用返回的 userToken 连接 OpenIM SDK

## 数据持久化

所有数据通过 Docker volumes 持久化：
- `mysql_data` — 用户/群组/关系数据
- `mongo_data` — 消息内容
- `redis_data` — 在线状态/缓存
- `kafka_data` — 消息队列
- `minio_data` — 文件/图片/语音

## 生产部署注意

1. **修改所有默认密码** — 编辑 `.env` 文件
2. **配置 MINIO_EXTERNAL_URL** — 设置为公网可访问的域名
3. **配置反向代理** — Nginx/Caddy 代理 10001 (WSS) 和 10002 (HTTPS)
4. **FCM 推送** — 在 OpenIM Server 配置中设置 FCM 服务账号 JSON
5. **备份策略** — 定期备份 MySQL + MongoDB volumes
