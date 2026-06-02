# test-env

一键起一套**和生产同形态**的全栈测试环境（docker-compose only，纯 IP，无 nginx，无 push）。

## 使用

依赖：`docker`、Docker Compose v2、`openssl`、`python3`、`envsubst`、`curl`、`wget`、`qrencode`。
`bootstrap.sh` 会尽量自动补齐缺失依赖，支持 `apt-get`、`dnf`、`yum`、`brew`、`apk`、`pacman`、
`zypper`。Debian/Ubuntu/Fedora/CentOS/RHEL 缺 Docker 时会通过 `https://get.docker.com/`
安装 Docker Engine；Alpine/Arch/openSUSE 会使用系统包管理器安装 Docker 包；macOS 有 Homebrew
时会尝试安装 Docker Desktop cask，但仍需要手动启动 Docker Desktop / OrbStack / Colima。
其中 `qrencode` 用于部署完成后生成客户端环境导入二维码。

```bash
cd deploy/test-env
./bootstrap.sh
```

交互式先选择语言（支持 English / 中文 / Deutsch / Español），再询问配置；按 Enter 接受默认：

1. 客户端访问 IP（自动探测）
2. AI provider：可添加 DeepSeek / MiniMax / 自定义 Anthropic-compatible provider，也可先跳过凭据后续再改 `.env`
3. 测试账号邮箱 + 密码（默认 `test@example.com` / `qwe123`）
4. Registry mirror（默认镜像生产应用市场；输入 `none` 才独立运行）
5. 端口偏移（默认 0；改成 100 可在同机起第二套）

## 部署完后客户端怎么用

启动手机/模拟器上的 app，进设置 → 标题连点 7 下 → 服务环境 → 右上扫码按钮，扫描
`test-env-environment.png` 或终端里渲染出的二维码即可导入整套环境。

bootstrap 同时会保存：

| 文件 | 用途 |
|------|------|
| `test-env-environment.png` | 客户端扫码导入环境 |
| `test-env-environment.json` | 二维码内的 JSON 内容，便于检查/复制 |
| `test-env-info.txt` | 完整部署信息，包含测试账号和运维入口 |

也可以手动进服务环境 → 右上 + 新建：

| 字段 | 填什么 |
|------|--------|
| Backend | `http://<HOST_IP>:5566` |
| Supabase | `http://<HOST_IP>:18000` |
| MinIO | `http://<HOST_IP>:19000` |
| Registry | `http://<HOST_IP>:3254` |
| OpenIM HTTP | `http://<HOST_IP>:10002` |
| OpenIM WS | `ws://<HOST_IP>:10001` |
| Config Center | `http://<HOST_IP>:5567` |

`HOST_IP` 见 `test-env-info.txt`。所有具体端口（如果用了 PORT_OFFSET）也都在该文件里。

⚠️ **iOS / Android 默认禁明文 HTTP**：客户端的 `Info.plist` 已配 `NSAllowsArbitraryLoads=true`，Android 需 `usesCleartextTraffic=true`（仓库默认应该已开）。

## 镜像版本（与生产对齐）

| 服务 | 镜像 |
|------|------|
| Supabase Studio | `supabase/studio:2026.04.08-sha-205cbe7` |
| Supabase Postgres | `supabase/postgres:15.8.1.085` |
| Supabase GoTrue | `supabase/gotrue:v2.186.0` |
| Kong | `kong/kong:3.9.1` |
| PostgREST | `postgrest/postgrest:v14.8` |
| Storage API | `supabase/storage-api:v1.48.26` |
| Realtime | `supabase/realtime:v2.76.5` |
| Logflare | `supabase/logflare:1.36.1` |
| pg-meta | `supabase/postgres-meta:v0.96.3` |
| Edge Runtime | `supabase/edge-runtime:v1.71.2` |
| Supavisor | `supabase/supavisor:2.7.4` |
| Vector | `timberio/vector:0.53.0-alpine` |
| imgproxy | `darthsim/imgproxy:v3.30.1` |
| jsonapp Postgres | `postgres:15.8` |
| App MinIO | `minio/minio:RELEASE.2025-04-22T22-12-26Z` |
| Backend Redis (AI session) | `redis:7.4-alpine` |
| OpenIM Server | `openim/openim-server:v3.8.3-patch.12` |
| OpenIM MySQL | `mysql:8.0` |
| OpenIM Mongo | `mongo:7.0` |
| OpenIM Redis | `redis:7.0.0` |
| OpenIM Kafka | `bitnamilegacy/kafka:3.5.1` |
| OpenIM Etcd | `bitnamilegacy/etcd:3.5.13` |

## 已禁用的功能

只有 **push** 不可用：

- APNs / FCM / 极光 不配凭据，`/api/im/push_token` 返回 400（客户端吞异常）
- OpenIM `beforeOfflinePush` / `afterSendSingleMsg` webhook 禁用
- 用户杀后台收不到推送，但**消息正常存 OpenIM 服务端**，app 打开会拿到积压

其他全部跟生产同构。Supabase 13 服务全开（含 Studio / Realtime / Storage API / Edge Functions / Logflare 等）。

## 常用命令

```bash
./bootstrap.sh             # 部署
./reset-data.sh            # 只清数据卷不删容器（快速重测）
./teardown.sh              # 彻底销毁
docker compose --env-file .env logs -f backend          # 实时日志
```

并行多个测试环境（同一台机器）：
```bash
PORT_OFFSET=0   ./bootstrap.sh    # 默认端口
PORT_OFFSET=100 ./bootstrap.sh    # 5666 / 18100 / 19100 / ...
```

每个 env 用独立的 compose project name（`testenv-app`, `supabase`, `testenv-openim`）+ 独立 volume namespace，互不打架。

## 文件目录

```
deploy/test-env/
├── bootstrap.sh                 ← 主入口
├── teardown.sh
├── reset-data.sh
├── docker-compose.yml           ← app 自有服务（backend/registry/config-center/jsonapp-postgres/app-minio）
├── Dockerfile.backend           ← backend / registry / config-center 共用镜像
├── .env.template / .env         ← bootstrap 渲染
├── supabase/
│   ├── docker-compose.yml       ← 从生产 vendor 来的 13 服务全栈
│   ├── docker-compose.override.yml
│   ├── volumes/                 ← Kong / DB init 脚本
│   ├── .env.template / .env
├── openim/
│   ├── docker-compose.yml       ← 8 服务 OpenIM 栈
│   ├── .env.template / .env
└── lib/
    ├── mint-jwt.py              ← 用 HS256 签 Supabase ANON / SERVICE_ROLE key
    ├── seed-test-user.py        ← 调 GoTrue admin API 建测试账号
    └── init-buckets.sh          ← 在 app-minio 上建 4 个 bucket
```

## 部署后健康检查

```bash
# Backend
curl http://$HOST_IP:5566/health

# Supabase auth
curl http://$HOST_IP:18000/auth/v1/health

# OpenIM
curl http://$HOST_IP:10002/

# MinIO
curl http://$HOST_IP:19000/minio/health/ready
```

## 网络要求

- 测试机自己能访问外网（拉镜像）
- 客户端（手机/电脑）和测试机**同局域网**，或者测试机有公网 IP
- 端口默认全开 `0.0.0.0`，需要确认防火墙放行 5566 / 3254 / 5567 / 10001 / 10002 / 18000 / 19000

## 故障排查

| 现象 | 检查 |
|------|------|
| `Failed to fetch` (客户端) | 防火墙、`HOST_IP` 写的是不是局域网 IP、客户端能不能 `ping` 通 |
| Supabase auth 起不来 | `docker compose --env-file supabase/.env -f supabase/docker-compose.yml logs auth` |
| OpenIM 等不到 ready | `docker logs testenv-openim-server`，Kafka 内存不够最常见 |
| MinIO presigned URL 404 | `MINIO_SERVER_URL` 设的对不对（应该是 `http://HOST_IP:19000`） |
| 测试账号登不上去 | 检查 `test-env-info.txt` 里的 email/密码大小写；或者 `psql ... -c "SELECT email FROM auth.users;"` |

## 限制

- 不支持 push（设计如此）
- HTTPS 没启（纯 HTTP + IP）；客户端 ATS 必须放行明文
- Supabase 邮件验证关了（`ENABLE_EMAIL_AUTOCONFIRM=true`），账号注册即生效
- 老 docker-compose v1 不支持，需要 docker compose v2（`docker compose` 是 plugin，不是 `docker-compose`）

## 已验证过的环境（实战记录）

2026-05-18 在一台全新 Ubuntu 24.04 / 11G RAM / 6c VPS 上完整跑通。
全程蹚出来的坑（已修在 git 历史）：

| # | 现象 | 根因 | 修法 |
|---|------|------|------|
| 1 | docker pull cloudflare 网络重置 | IPv6 出口 + cloudflare CDN 不稳 | `/etc/docker/daemon.json` 配 `docker.m.daocloud.io` 国内镜像 |
| 2 | `ghcr.io/openimsdk/openim-server:v3.8: not found` | tag 不存在 | 改用 `openim/openim-server:v3.8.3-patch.15` (dockerhub) |
| 3 | `docker.1panel.live/v2/bitnami/kafka/manifests/3.7: 403 Forbidden` | bitnami 删了 kafka:3.7 | 换 `bitnamilegacy/kafka:3.7`（bitnami 把老镜像迁过去了）|
| 4 | Supabase 起不来 `Bind for 0.0.0.0:15432 failed: port is already allocated` | override 给 db 加端口和 supavisor 撞 | 删 override 里 db 端口，supavisor 才是外部入口 |
| 5 | Kong `init_by_lua error: ... keyauth_credentials uniqueness violation` | kong.yml 给 anon/service_role 两个 consumer 各注册了 2 个相同 key | 删 kong.yml 里 PUBLISHABLE_KEY/SECRET_KEY 那两条（supabase 2026 新流程，本地用不上）|
| 6 | GoTrue 启动 fatal `converting '' to type int` (SMTP_PORT) | .env 里 SMTP_PORT 留空 | 必须给数字（587），即使不发邮件 |
| 7 | Bootstrap auth healthcheck 一直 401 | Kong 的 `/auth/v1/*` 路由开了 keyauth 插件，必须带 apikey | curl 加 `-H "apikey: $SUPABASE_ANON_KEY"` |
| 8 | pyaudio wheel build 失败 | repo 的 requirements.txt 收了 pyaudio>=0.2.11，但 backend 代码并不用 | Dockerfile 装 portaudio19-dev + build-essential 让它编译过 |
| 9 | backend 启动 `ModuleNotFoundError: No module named 'jwt'` | repo requirements.txt 漏了 pyjwt（prod 单独 venv 装的）；同样漏 httpx | Dockerfile 加 pip install pyjwt httpx flask-caching |
| 10 | `mc: ERROR sh is not a recognized command` | minio/mc 镜像默认 ENTRYPOINT 是 mc | docker run 加 `--entrypoint sh` |
| 11 | bootstrap 最后 `JSONAPP_DB_USER: unbound variable` | set -u 抓住没 export 的变量 | summary 里写硬编码 jsonapp 即可 |
| 12 | openim-chat 无限重启 `too many arguments in call to mageutil.Build` | openim-chat v1.8 跟 server v3.8 的 mageutil 版本不兼容 | 直接删掉 openim-chat（backend 用不上，只用 openim-server）|
| 13 | OpenIM API 不监听 10002，日志狂报 `Fail to connect Mongo localhost:37017` | v3.8 镜像**不读 env**，只读 `/openim-server/config/*.yml`，env 设的 MONGO_ADDRESS 全被忽略 | bootstrap 从镜像 docker cp 出 config → sed 替换 mongodb/redis/kafka/etcd/minio 的 address+凭据 → mount 进容器 |
