# Registry 服务实施总结

## 分支信息
- **分支名称**: `feature/registry-service`
- **基于**: `main` 分支
- **状态**: 开发完成，待测试和合并

## 新增文件

### 1. 后端服务
- `backend/registry_server.py` - 独立的 Registry 服务（端口 3254）
- `backend/registry_init.py` - 索引初始化脚本（从数据库迁移）
- `backend/test_registry.py` - API 测试脚本
- `backend/REGISTRY_README.md` - Registry 服务文档

### 2. 客户端
- `lib/json_ui/dependency_loader.dart` - 更新依赖加载器，支持简化格式

### 3. 示例文件
- `templates/demo_with_deps_v2.json` - 使用新格式的示例应用

### 4. 文档更新
- `JSON-DSL.md` - 添加简化依赖格式说明和命名空间规则
- `CLAUDE.md` - 移除旧的 SSH 发布流程，添加 Registry 发布说明

## 核心功能

### 1. 命名空间管理

**官方包（无 `/`）**:
- 示例: `common-ui`, `data-utils`
- 权限: 只有 admin 可发布
- 路径: `common-ui/common-ui-1.0.0.json`

**用户包（1-2 级 `/`）**:
- 一级: `mycompany/app-name`
- 二级: `mycompany/frontend/ui-kit`
- 权限: 命名空间所有者
- 路径: `mycompany/frontend/ui-kit/ui-kit-1.0.0.json`

### 2. 简化依赖声明

**旧格式（兼容）**:
```json
"dependencies": {
  "common-ui": {
    "url": "https://myapp-oss-endpoint.dapangyu.work/json-component/xxx/common-ui-1.0.0.json",
    "version": "^1.0.0"
  }
}
```

**新格式（推荐）**:
```json
"dependencies": {
  "common-ui": "^1.0.0",
  "data-utils": "~1.2.0",
  "mycompany/frontend/ui-kit": ">=1.0.0"
}
```

### 3. Registry API

| 接口 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/resolve` | GET | 依赖解析（name + version → download_url） |
| `/package/<name>` | GET | 包元数据 |
| `/namespace/check` | GET | 检查命名空间是否可用 |
| `/namespace/create` | POST | 创建命名空间（需认证） |
| `/publish` | POST | 发布包（需认证） |

### 4. 索引文件结构

存储在 MinIO: `json-component/_index.json`

```json
{
  "version": "1.0",
  "updated_at": "2026-04-21T10:30:00Z",
  "packages": {
    "common-ui": {
      "type": "official",
      "latest": "1.0.0",
      "versions": ["1.0.0"],
      "path": "common-ui"
    }
  },
  "namespaces": {
    "mycompany": {
      "owner_id": "uuid-xxx",
      "owner_email": "user@example.com",
      "created_at": "2026-04-21T09:00:00Z",
      "sub_namespaces": ["frontend"]
    }
  }
}
```

## 部署步骤

### 1. 初始化索引

```bash
ssh root@myapp-backend.dapangyu.work
cd /path/to/ai-app
python3 backend/registry_init.py
```

### 2. 启动服务

```bash
nohup python3 backend/registry_server.py > logs/registry.log 2>&1 &
```

### 3. 配置 Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name myapp-registry.dapangyu.work;
    
    location / {
        proxy_pass http://127.0.0.1:3254;
    }
}
```

### 4. 测试

```bash
# 本地测试
python3 backend/test_registry.py

# 远程测试
curl https://myapp-registry.dapangyu.work/health
curl "https://myapp-registry.dapangyu.work/resolve?name=common-ui&version=^1.0.0"
```

## 向后兼容性

✅ **完全向后兼容**

- 旧的完整 URL 格式仍然支持
- 客户端优先使用 URL，如果没有则通过 Registry 解析
- 现有 JSON 文件无需修改即可运行

## 迁移建议

### 阶段 1: 部署 Registry 服务
1. 初始化索引文件
2. 启动 Registry 服务
3. 配置域名和 SSL

### 阶段 2: 测试新格式
1. 使用 `demo_with_deps_v2.json` 测试
2. 验证依赖解析功能
3. 确认客户端加载正常

### 阶段 3: 迁移现有 JSON
1. 批量更新 templates/ 目录
2. 更新已发布的 JSON（可选）
3. 通知用户使用新格式

## 优势

1. **简化依赖声明**: 无需手动填写完整 URL
2. **命名空间隔离**: 避免用户包名冲突
3. **版本管理**: 自动选择最佳匹配版本
4. **权限控制**: 官方包和用户包分离
5. **易于维护**: 索引文件集中管理
6. **向后兼容**: 不破坏现有功能

## 注意事项

1. **索引文件**: 所有操作都会更新 `_index.json`，确保 MinIO 可写
2. **并发安全**: 当前实现不支持高并发写入，生产环境建议加锁
3. **命名空间**: 首次发布用户包前必须创建命名空间
4. **版本不可变**: 已发布的版本不能修改（除非 `force_update=true`）

## 下一步

1. ✅ 代码实现完成
2. ⏳ 部署到服务器测试
3. ⏳ 客户端集成测试
4. ⏳ 迁移现有 JSON 文件
5. ⏳ 合并到 main 分支

## 相关文档

- `backend/REGISTRY_README.md` - Registry 服务详细文档
- `JSON-DSL.md` - DSL 规范（已更新）
- `CLAUDE.md` - 项目指南（已更新）
