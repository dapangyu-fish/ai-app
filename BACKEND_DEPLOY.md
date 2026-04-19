# 后端部署文档

## 登录服务器

通过 SSH 登录到后端服务器：

```bash
ssh root@app-backend.dapangyu.work
```

（本机已配置免密登录，无需输入密码）

## 代码位置

代码位于服务器的 `/root/ai-app` 目录。

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
- 端口: 5433
- 数据库名: jsonapp
- 用户名: jsonapp
- 密码: hOad2ANFLla23weqMU3c7IeYKOZRLL8rrXZVcDAkpjg

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

## 发布 JSON-APP 到市场

### 通过 API 发布（需要用户认证）

客户端登录后，调用发布接口：

```bash
curl -X POST https://app-backend.dapangyu.work/api/store/publish \
  -H "Authorization: Bearer <用户token>" \
  -H "Content-Type: application/json" \
  -d '{"json_content": <JSON-APP内容>}'
```

要求：用户角色为 `pro` 或 `admin`。

### 通过服务器直接发布

SSH 登录服务器后，使用 Python 脚本直接操作数据库和 MinIO：

```bash
ssh root@app-backend.dapangyu.work
/opt/miniconda3/bin/python -c "
import json, uuid, subprocess, tempfile, os, psycopg2, psycopg2.extras

DB_CONFIG = dict(host='127.0.0.1', port=5433, dbname='jsonapp', user='jsonapp',
                 password='hOad2ANFLla23weqMU3c7IeYKOZRLL8rrXZVcDAkpjg')
MINIO_PUBLIC_URL = 'https://app-oss-endpoint.dapangyu.work'

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
ssh root@app-backend.dapangyu.work "cd /root/ai-app && git pull && supervisorctl restart ai-app"

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
