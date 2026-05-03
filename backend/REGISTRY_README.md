# JSON-DSL Registry 服务

独立的包注册中心服务，负责 JSON-DSL 组件和应用的依赖解析、命名空间管理。

## 服务信息

- **端口**: 3254
- **域名**: https://myapp-registry.dapangyu.work
- **存储**: MinIO (`json-component` bucket)
- **索引文件**: `_index.json`

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

## 部署步骤

### 1. 初始化索引文件

从现有数据库迁移数据到 MinIO：

```bash
# 在服务器上执行
ssh root@myapp-backend.dapangyu.work
cd /path/to/ai-app
python3 backend/registry_init.py
```

这会生成 `json-component/_index.json` 文件。

### 2. 启动 Registry 服务

```bash
# 在服务器上执行
cd /path/to/ai-app
nohup python3 backend/registry_server.py > logs/registry.log 2>&1 &
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
  "json_content": {
    "dsl": "3.3",
    "meta": {
      "name": "mycompany/frontend/ui-kit",
      "version": "1.0.0",
      "type": "library"
    },
    "global": { ... }
  },
  "force_update": false
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

如果提供了 `url`，客户端会直接使用，不通过 Registry 解析。

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
      "created_at": "2026-04-21T10:00:00Z"
    },
    "mycompany/frontend/ui-kit": {
      "type": "user",
      "latest": "1.0.0",
      "versions": ["1.0.0"],
      "path": "mycompany/frontend/ui-kit",
      "author_id": "uuid-yyy",
      "created_at": "2026-04-21T11:00:00Z"
    }
  },
  "namespaces": {
    "mycompany": {
      "owner_id": "uuid-yyy",
      "owner_email": "user@example.com",
      "created_at": "2026-04-21T09:00:00Z",
      "sub_namespaces": ["frontend"]
    },
    "mycompany/frontend": {
      "owner_id": "uuid-yyy",
      "created_at": "2026-04-21T09:30:00Z"
    }
  }
}
```

## 注意事项

1. **命名空间唯一性**: 首次发布时必须先创建命名空间
2. **权限控制**: 用户只能发布自己命名空间下的包
3. **版本不可变**: 已发布的版本不能修改（除非 `force_update=true`）
4. **索引文件**: 所有操作都会更新 `_index.json`，确保 MinIO 可写
5. **并发安全**: 当前实现不支持高并发写入，生产环境建议加锁

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
