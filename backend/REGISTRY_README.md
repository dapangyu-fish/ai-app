# JSON-DSL Registry 服务

独立的包注册中心服务，负责 JSON-DSL 组件和应用的依赖解析、命名空间管理、发布校验、市场列表和富化索引。

生产部署以 [`deploy/production/README.md`](../deploy/production/README.md) 和
`myapp-ctl deploy` 为准。本文件主要记录 Registry API、数据结构和本地开发调试方式。

## 服务信息

- **端口**: 3254
- **域名**: https://myapp-registry.dapangyu.work
- **运行时包存储**: MinIO `json-component` bucket
- **运行时解析真源**: `json-component/_index.json` + 对应 JSON 包文件
- **市场富化索引**: Postgres `registry_packages`，用于详情、AI 摘要、tech_stack、点赞和安装统计；不替代 `_index.json`

## 命名空间规则

### 官方包（无 `/`）
- 示例: `common-ui`, `data-utils`, `calculator`
- 权限: 只有 **admin** 角色可以发布
- 路径: `common-ui/common-ui-1.0.0.json`

### 用户包（1-2 级 `/`）
- 一级: `mycompany/app-name`
- 二级: `mycompany/frontend/ui-kit`
- 权限: 用户只能发布自己命名空间下的包
- 路径: `mycompany/frontend/ui-kit/ui-kit-1.0.0.json`

## 本地开发 / 手工调试

生产请不要按下面的 `nohup python3 ...` 裸跑流程部署。当前支持的生产路径是：

```bash
./deploy/production/install_ctl.sh
myapp-ctl setup --host <public-ip-or-domain>
myapp-ctl deploy --build   # or --pull
```

### 1. 初始化索引文件

从旧 `app_registry` 迁移数据到 MinIO `_index.json` 时才需要运行：

```bash
cd /path/to/ai-app
python3 backend/registry_init.py
```

这会生成 `json-component/_index.json` 文件。

### 2. 启动 Registry 服务

```bash
cd /path/to/ai-app
python3 backend/registry_server.py
```

### 3. 配置 Nginx 反向代理

```nginx
# /etc/nginx/sites-available/myapp-registry.dapangyu.work
server {
    listen 443 ssl http2;
    server_name myapp-registry.dapangyu.work;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:3254;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/myapp-registry.dapangyu.work /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## API 接口

### 1. 健康检查

```bash
GET /health
```

响应:
```json
{
  "status": "ok",
  "service": "json-dsl-registry",
  "version": "1.0.0"
}
```

### 2. 依赖解析

```bash
GET /resolve?name=common-ui&version=^1.0.0
GET /resolve?appid=<uuid>
GET /resolve_appid?appid=<uuid>
```

响应:
```json
{
  "name": "common-ui",
  "version": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/common-ui/common-ui-1.0.0.json",
  "type": "official",
  "latest": "1.0.0"
}
```

### 3. 包元数据

```bash
GET /package/common-ui
GET /package/mycompany/frontend/ui-kit
```

响应:
```json
{
  "name": "common-ui",
  "type": "official",
  "latest": "1.0.0",
  "versions": ["1.0.0"],
  "path": "common-ui",
  "created_at": "2026-04-21T10:00:00Z",
  "author_id": "uuid-xxx"
}
```

### 4. 检查命名空间

```bash
GET /namespace/check?name=mycompany
GET /namespace/check?name=mycompany/frontend
```

响应:
```json
{
  "name": "mycompany",
  "available": true,
  "exists": false
}
```

### 5. 创建命名空间（需要认证）

```bash
POST /namespace/create
Authorization: Bearer <token>
Content-Type: application/json

{
  "namespace": "mycompany",
  "sub_namespace": "frontend"  // 可选
}
```

响应:
```json
{
  "message": "命名空间创建成功",
  "namespace": "mycompany/frontend",
  "owner_id": "uuid-xxx"
}
```

### 6. 发布包（需要认证）

```bash
POST /publish
Authorization: Bearer <token>
Content-Type: application/json

{
  "namespace": "mycompany/frontend",
  "name": "ui-kit",
  "appid": "08ad186c-0000-4000-8000-000000000000",
  "version": "1.0.0",
  "description": "Reusable UI kit",
  "type": "library",
  "json_content": {
    "dsl": "3.3",
    "appid": "08ad186c-0000-4000-8000-000000000000",
    "meta": {
      "name": "mycompany/frontend/ui-kit",
      "version": "1.0.0",
      "type": "library"
    },
    "global": { ... }
  }
}
```

响应:
```json
{
  "message": "发布成功",
  "name": "mycompany/frontend/ui-kit",
  "version": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/frontend/ui-kit/ui-kit-1.0.0.json"
}
```

## 客户端使用

### 简化的依赖声明

```json
{
  "dsl": "3.3",
  "meta": {
    "name": "my-app",
    "version": "1.0.0"
  },
  "dependencies": {
    "common-ui": "^1.0.0",
    "data-utils": "~1.2.0",
    "mycompany/frontend/ui-kit": ">=1.0.0"
  }
}
```

客户端会自动通过 Registry 解析依赖 URL。

### 兼容旧格式

```json
{
  "dependencies": {
    "common-ui": {
      "url": "https://myapp-oss-endpoint.dapangyu.work/json-component/common-ui/common-ui-1.0.0.json",
      "version": "^1.0.0"
    }
  }
}
```

旧对象格式仍可被解析，但当前加载器实际使用包名和 `version` 约束通过
`CacheManager` / Registry 下载；`url` 字段只作为历史兼容元数据保留，不再作为直接下载入口。

## 测试

```bash
# 本地测试
python3 backend/test_registry.py

# 手动测试
curl http://localhost:3254/health
curl "http://localhost:3254/resolve?name=common-ui&version=^1.0.0"
curl http://localhost:3254/package/common-ui
```

## 索引文件结构

`json-component/_index.json`:

```json
{
  "version": "1.0",
  "updated_at": "2026-04-21T10:30:00Z",
  "packages": {
    "common-ui": {
      "type": "official",
      "latest": "1.0.0",
      "versions": ["1.0.0"],
      "path": "common-ui",
      "author_id": "uuid-xxx",
      "appid": "08ad186c-0000-4000-8000-000000000000",
      "created_at": "2026-04-21T10:00:00Z",
      "version_sources": {"1.0.0": "local"},
      "meta_type": "library",
      "description": "Common UI widgets",
      "author": "admin",
      "displayName": "Common UI"
    },
    "mycompany/frontend/ui-kit": {
      "type": "user",
      "latest": "1.0.0",
      "versions": ["1.0.0"],
      "path": "mycompany/frontend/ui-kit",
      "author_id": "uuid-yyy",
      "appid": "08ad186c-1111-4000-8000-000000000000",
      "created_at": "2026-04-21T11:00:00Z",
      "version_sources": {"1.0.0": "local"},
      "meta_type": "library"
    }
  },
  "namespaces": {}
}
```

`namespaces` 字段是历史兼容字段。当前命名空间和发布权限以 Postgres
`namespaces` / `namespace_members` 表为准。

## 注意事项

1. **命名空间唯一性**: 首次发布时必须先创建命名空间
2. **权限控制**: 用户只能发布自己命名空间下的包
3. **版本不可变**: 已发布的同名同版本不能覆盖；发布新内容必须递增版本号
4. **索引文件**: 运行时解析依赖 `_index.json`，确保 MinIO 可写
5. **富化索引**: `registry_packages` 只服务市场详情/搜索增强/统计，不是运行时依赖解析的唯一真源

## 故障排查

### 索引文件损坏

```bash
# 重新生成索引
python3 backend/registry_init.py
```

### 命名空间冲突

```bash
# 检查命名空间所有者
curl "http://localhost:3254/namespace/check?name=mycompany"
```

### 依赖解析失败

检查日志:
```bash
tail -f logs/registry.log
```

常见原因:
- 包名拼写错误
- 版本约束不满足
- MinIO 连接失败
