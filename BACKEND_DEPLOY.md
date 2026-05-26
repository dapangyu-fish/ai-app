# 后端部署文档

## 登录服务器

通过 SSH 登录到后端服务器：

```bash
ssh root@myapp-backend.dapangyu.work
```

（本机已配置免密登录，无需输入密码）

## 代码位置

代码位于服务器的 `/root/ai-app` 目录。

## 密钥配置位置 ⚠️

**所有后端 secret 集中在 `/etc/ai-app/backend.env`**（mode 600，root only），**不在 git 工作树内**，不受 `git pull` / `git checkout` 影响。

```
加载顺序（首个存在的文件生效）：
  1. $BACKEND_ENV_PATH        — supervisor 通过环境变量注入
  2. /etc/ai-app/backend.env  — 生产环境标准位置 ← 当前用这个
  3. backend/.env             — 仓库内位置（本地开发兜底）
```

模板见 `backend/.env.example`。新增 secret 步骤：
1. 在本地 `backend/.env.example` 加 `NEW_KEY=` 占位 + 注释说明用途
2. 提交 + push（不带真实值）
3. ssh 到服务器，编辑 `/etc/ai-app/backend.env` 填入真实值
4. `supervisorctl restart ai-app registry`

## 更新代码

在本地提交代码后，在服务器上执行以下命令更新最新代码：

```bash
cd /root/ai-app
git pull
```

## 依赖管理

后端的 Python 依赖由 `backend/requirements.txt` 管理。

### 安装依赖

首次部署或添加新依赖时，运行以下命令安装：

```bash
cd /root/ai-app/backend
pip install -r requirements.txt
```

### 依赖列表

当前依赖包括：
- Flask: Web 框架
- flask-sock: WebSocket 支持
- psycopg2-binary: PostgreSQL 数据库连接
- anthropic: AI API 客户端
- requests: HTTP 请求库
- python-dotenv: 环境变量管理

## PostgreSQL 数据库部署

### 新建 PostgreSQL 实例

我们使用官方 postgres:15.8 Docker 镜像创建独立的数据库实例，用于存储非用户数据（app_registry、chat_quotas）。

配置文件位于 `backend/docker-compose.yml`。

```bash
cd /root/ai-app/backend
docker-compose up -d
```

### 数据库配置

- 主机: 127.0.0.1
- 端口: 15433
- 数据库名: jsonapp
- 用户名: jsonapp
- 密码: 见 `/root/ai-app/backend/.env` 中的 `DB_PASSWORD`

> ⚠️ git 历史里曾出现过的老密码（`hOad2ANFL...`）只对老机有效，老机下线后即作废。新机已轮换。

### 数据库初始化

数据库启动时会自动执行 `backend/schema.sql` 创建所需的表。

### 数据库操作

后端代码使用 psycopg2 直接连接 PostgreSQL，不再使用 docker exec 方式操作数据库。

## 后端代码架构

后端代码已经重构为模块化架构，便于维护和扩展：

```
backend/
├── __init__.py        # 包初始化文件
├── app.py             # 主入口文件，Flask 应用创建和路由注册
├── config.py          # 配置模块 - 所有配置常量和环境变量
├── database.py        # 数据库模块 - PostgreSQL 连接和操作
├── auth.py            # 认证模块 - 用户认证相关接口
├── chat.py            # 聊天模块 - AI 对话和 JSON App 生成
├── store.py           # Store 模块 - JSON App 管理
├── docker-compose.yml # PostgreSQL 部署配置
└── schema.sql         # 数据库表结构定义
```

### 模块说明

- **config.py**: 集中管理所有配置，包括 Supabase、DeepSeek、MinIO、PostgreSQL 等
- **database.py**: 封装数据库连接和常用操作，包括配额管理
- **auth.py**: 用户认证相关功能，包括注册、登录、登出、用户信息更新等
- **chat.py**: AI 对话功能，包括 SSE 流式响应和 JSON App 生成
- **store.py**: JSON App 商店管理，包括发布、下架、列表等功能
- **app.py**: 主入口文件，整合所有模块并注册路由

## 启动后端服务

后端服务使用 Flask，主要文件为 `backend/app.py`。服务器环境使用 miniconda，默认已激活 base 环境。

启动命令：

```bash
cd /root/ai-app
python backend/app.py
```

服务默认运行在端口 5566。

## 服务管理

后端服务已配置 supervisor 进行管理。

### supervisor 配置文件位置
`/etc/supervisor/conf.d/ai-app.conf`

### 常用管理命令

```bash
# 查看服务状态
supervisorctl status

# 启动服务
supervisorctl start ai-app

# 停止服务
supervisorctl stop ai-app

# 重启服务
supervisorctl restart ai-app

# 重新加载配置文件
supervisorctl reread
supervisorctl update

# 查看日志
tail -f /var/log/ai-app/ai-app.log
tail -f /var/log/ai-app/ai-app-error.log
```

### 更新代码后重启服务

```bash
cd /root/ai-app
git pull
supervisorctl restart ai-app
```

### 日志文件位置
- 标准输出日志: `/var/log/ai-app/ai-app.log`
- 错误日志: `/var/log/ai-app/ai-app-error.log`

## nginx 反向代理与 Web CORS/SSE

生产环境的浏览器 Web 端会跨域访问 API、Registry、OSS，并通过浏览器原生 `EventSource` 读取 AI 对话 SSE。nginx 配置需要满足两点：

1. CORS 统一由 nginx 处理，后端业务代码不要再给同一个响应追加 `Access-Control-Allow-Origin`，否则浏览器会因为重复 ACAO 头判定 CORS 失败。
2. SSE 路径必须关闭 nginx buffering，并保持长连接超时足够长，否则 Web EventSource 会表现为连接超时或断流。

### 主后端 API

脱敏模板：

```nginx
server {
    listen 80;
    server_name <api.example.com>;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name <api.example.com>;
    include snippets/<ssl-snippet>.conf;
    client_max_body_size 20M;

    location /models/ {
        alias /path/to/app/static/models/;
        autoindex off;
    }

    location / {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin $http_origin always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers $http_access_control_request_headers always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Vary Origin always;
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
        }

        add_header Access-Control-Allow-Origin $http_origin always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With, X-OpenIM-Webhook-Secret" always;
        add_header Vary Origin always;

        proxy_pass http://127.0.0.1:<backend-port>;
        include snippets/proxy-common.conf;

        # AI 对话 SSE/EventSource 必须关闭 buffering。
        proxy_buffering off;
    }
}
```

`proxy-common.conf` 至少应包含：

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```

### AI 对话 Web SSE 注意事项

Web 端流程：

```text
POST /api/ai/chat/start
POST /api/ai/chat/<session_id>/stream_token
GET  /api/ai/chat/<session_id>/stream?last_id=0&stream_token=<short-lived-token>
```

`EventSource` 不能设置 `Authorization` header，所以 Web 端先用正常登录态换短期 `stream_token`，再把 token 放进 stream query。Android/iOS 仍可继续用 `Authorization: Bearer ...` 读取 SSE。

排障要点：

- `stream_token` 404：线上 Flask 路由未部署或服务未重启；确认 `app.url_map` 里有 `/api/ai/chat/<session_id>/stream_token`。
- `stream_token` 200 但 EventSource CORS error：检查 `/stream` 成功响应是否出现重复 `Access-Control-Allow-Origin`。nginx 加一份即可，Flask SSE Response 不要再加。
- EventSource 超时/断流：确认 `proxy_buffering off`，并确认 `X-Accel-Buffering: no` 由后端 SSE Response 返回。

验证命令：

```bash
# 预检请求应返回 204，并带 Access-Control-Allow-*。
curl -i -X OPTIONS "https://<api.example.com>/api/ai/chat/<sid>/stream_token" \
  -H "Origin: https://<web.example.com>" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization"

# 无效 token/session 可以返回 401/404，但仍必须带单份 Access-Control-Allow-Origin。
curl -i "https://<api.example.com>/api/ai/chat/<sid>/stream?last_id=0&stream_token=bad" \
  -H "Origin: https://<web.example.com>"
```

### Registry API

Registry 也被 Web 跨域访问，使用同样的 nginx CORS 处理方式：

```nginx
server {
    listen 443 ssl http2;
    server_name <registry.example.com>;
    include snippets/<ssl-snippet>.conf;

    location / {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin $http_origin always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers $http_access_control_request_headers always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Vary Origin always;
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
        }

        add_header Access-Control-Allow-Origin $http_origin always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        add_header Vary Origin always;

        proxy_pass http://127.0.0.1:<registry-port>;
        include snippets/proxy-common.conf;
    }
}
```

Registry 的 AI 摘要 / 标签体系升级后，不需要改包 JSON，也不需要重新发布所有
APP。部署新版 backend/registry 后，用管理员 token 触发一次 catalog backfill 即可：

```bash
curl -X POST "https://<registry.example.com>/catalog/backfill" \
  -H "Authorization: Bearer $REGISTRY_ADMIN_TOKEN"
```

这个接口会重新解析现有包的 `dependencies` / `widgets_used` / `builtins_used` /
`tech_stack`，并把包标记为 `pending`。后台 enrich worker 会异步用新版 prompt
重算 `summary_zh` / `summary_en` / `category` / `domains` / `capabilities`。
进度可用：

```bash
curl "https://<registry.example.com>/catalog" | jq '.packages | group_by(.status) | map({status: .[0].status, count: length})'
```

### OSS / MinIO

OSS endpoint 主要用于上传、下载头像和 JSON App 资源。nginx 侧重点是大文件、原始 header 和禁用 request buffering：

```nginx
server {
    listen 443 ssl http2;
    server_name <oss-endpoint.example.com>;
    include snippets/<ssl-snippet>.conf;
    client_max_body_size 1G;
    ignore_invalid_headers off;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:<minio-api-port>;
        include snippets/proxy-common.conf;
    }
}
```

MinIO bucket CORS 也要单独配置，nginx 只负责反代。头像或 OSS 图片在 Web 端加载失败时，同时检查：

- 浏览器 Network 响应是否带正确的 `Access-Control-Allow-Origin`
- bucket/object 权限或 presigned URL 是否有效
- nginx 是否代理到正确的 MinIO API 端口，而不是 Console 端口

## 发布 JSON-APP 到市场

### 通过 API 发布（需要用户认证）

客户端登录后，调用发布接口：

```bash
curl -X POST https://myapp-backend.dapangyu.work/api/store/publish \
  -H "Authorization: Bearer <用户token>" \
  -H "Content-Type: application/json" \
  -d '{"json_content": <JSON-APP内容>}'
```

要求：用户角色为 `pro` 或 `admin`。

### 通过服务器直接发布

SSH 登录服务器后，使用 Python 脚本直接操作数据库和 MinIO：

```bash
ssh root@myapp-backend.dapangyu.work
# 加载 .env 里的密钥后再 exec python，避免明文落盘
set -a && source /root/ai-app/backend/.env && set +a
/opt/ai-app-venv/bin/python -c "
import json, uuid, subprocess, tempfile, os, psycopg2, psycopg2.extras

DB_CONFIG = dict(host='127.0.0.1', port=15433, dbname='jsonapp', user='jsonapp',
                 password=os.environ['DB_PASSWORD'])
MINIO_PUBLIC_URL = os.environ.get('MINIO_PUBLIC_URL', 'https://myapp-oss-endpoint.dapangyu.work')

# 读取要发布的 JSON 文件
with open('/root/ai-app/templates/<文件名>.json', 'r') as f:
    json_content = json.load(f)

meta = json_content.get('meta', {})
name = meta.get('name', 'unnamed')
version = meta.get('version', '1.0.0')
description = meta.get('description', '')
icon_url = meta.get('icon_url', '')
app_type = 'app'  # 或 'component'

# 生成唯一 appid
conn = psycopg2.connect(**DB_CONFIG)
conn.autocommit = True
cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
app_id = uuid.uuid4().hex
json_content['appid'] = app_id

# 上传到 MinIO
bucket = 'json-app' if app_type == 'app' else 'json-component'
oss_key = f'{app_id}/{name}-{version}.json'
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
json.dump(json_content, tmp, ensure_ascii=False, indent=2)
tmp.close()
subprocess.run(['mc', 'cp', tmp.name, f'app/{bucket}/{oss_key}'], check=True)
os.unlink(tmp.name)
download_url = f'{MINIO_PUBLIC_URL}/{bucket}/{oss_key}'

# 写入数据库
cur.execute(
    '''INSERT INTO app_registry
       (id, type, name, version, description, author_id, author_name,
        oss_bucket, oss_key, download_url, meta_json, dsl_spec, icon_url)
       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)''',
    [app_id, app_type, name, version, description, None, meta.get('author',''),
     bucket, oss_key, download_url,
     json.dumps(meta, ensure_ascii=False), description, icon_url])
cur.close(); conn.close()
print(f'发布成功! appid={app_id}')
print(f'download_url={download_url}')
"
```

### 完整发版流程

```bash
# 1. 本地提交并推送
git add <files>
git commit -m "feat: ..."
git push

# 2. 服务器部署
ssh root@myapp-backend.dapangyu.work "cd /root/ai-app && git pull && supervisorctl restart ai-app"

# 3. 发布到市场（在服务器上执行上面的 Python 脚本）
```

## 目录结构

- `backend/`: 后端代码目录（原 tools 目录）
  - `__init__.py`: 包初始化文件
  - `app.py`: 主入口文件，Flask 应用创建和路由注册
  - `config.py`: 配置模块 - 所有配置常量和环境变量
  - `database.py`: 数据库模块 - PostgreSQL 连接和操作
  - `auth.py`: 认证模块 - 用户认证相关接口
  - `chat.py`: 聊天模块 - AI 对话和 JSON App 生成
  - `store.py`: Store 模块 - JSON App 管理
  - `requirements.txt`: Python 依赖列表
  - `docker-compose.yml`: PostgreSQL 部署配置
  - `schema.sql`: 数据库表结构定义
- `templates/`: JSON-APP 模板文件
- `lib/`: Flutter 框架代码
- `JSON-DSL.md`: JSON-APP 规范文档
