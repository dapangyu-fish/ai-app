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
