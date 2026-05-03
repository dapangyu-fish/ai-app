# Registry 服务测试指南

## 测试环境准备

1. 确保 Registry 服务正在运行：
   ```bash
   curl https://myapp-registry.dapangyu.work/health
   ```
   应该返回：`{"status": "ok"}`

2. 确保你的 Flutter 应用已经更新了 `dependency_loader.dart`（已在 feature/registry-service 分支完成）

## 测试方法

### 方法 1：在 Flutter 应用中加载迁移后的 templates

1. **启动 Flutter 应用**
   ```bash
   flutter run
   ```

2. **加载测试文件**
   
   在应用中尝试加载以下已迁移的 templates：
   - `demo_camera.json` - 依赖 common-ui
   - `demo_with_deps.json` - 依赖 common-ui
   - `demo_user_profile.json` - 依赖 user

3. **观察日志输出**
   
   查看控制台日志，应该能看到：
   - ✅ 依赖解析成功：`Resolved dependency: common-ui -> https://...`
   - ✅ 依赖加载成功：`Loaded dependency: common-ui`
   - ❌ 如果失败会显示错误信息

4. **验证功能**
   
   - `demo_camera.json`: 点击"拍照"和"从相册选择"按钮，测试 common-ui 库的函数调用
   - `demo_with_deps.json`: 输入名字，点击"打招呼"按钮，测试依赖函数调用
   - `demo_user_profile.json`: 查看用户信息加载，测试 user 库的函数调用

### 方法 2：使用后端测试脚本

```bash
cd backend
python3 test_publish_user_package.py
```

这会测试：
- ✅ 命名空间创建
- ✅ 用户包发布
- ✅ 依赖解析
- ✅ 嵌套命名空间

### 方法 3：手动 API 测试

#### 测试依赖解析（官方包）
```bash
curl "https://myapp-registry.dapangyu.work/resolve?name=common-ui&version=^1.0.0"
```

预期返回：
```json
{
  "name": "common-ui",
  "version": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/.../common-ui-1.0.0.json"
}
```

#### 测试依赖解析（用户包）
```bash
curl "https://myapp-registry.dapangyu.work/resolve?name=mycompany/ui-kit&version=^1.0.0"
```

#### 测试包元数据查询
```bash
curl "https://myapp-registry.dapangyu.work/package/common-ui"
```

预期返回：
```json
{
  "name": "common-ui",
  "versions": ["1.0.0"],
  "latest": "1.0.0"
}
```

## 测试检查清单

### 基础功能测试
- [ ] Registry 服务健康检查通过
- [ ] 官方包依赖解析成功（common-ui, data-utils, user）
- [ ] 用户包依赖解析成功（mycompany/ui-kit, mycompany/frontend/form-kit）

### Flutter 客户端测试
- [ ] demo_camera.json 加载成功
- [ ] demo_with_deps.json 加载成功
- [ ] demo_user_profile.json 加载成功
- [ ] 依赖函数调用正常（@common-ui.showSuccess 等）
- [ ] 依赖变量访问正常（{{ common-ui.theme.primaryColor }}）

### 用户包发布测试
- [ ] 创建新命名空间成功
- [ ] 发布用户包成功
- [ ] 发布的包可以被解析
- [ ] 发布的包可以被下载

### 错误处理测试
- [ ] 不存在的包返回 404
- [ ] 版本约束不匹配返回错误
- [ ] 未认证的发布请求返回 401
- [ ] 重复命名空间返回错误

## 常见问题

### 1. 依赖解析失败
**症状**: 控制台显示 "Failed to resolve dependency"

**解决方法**:
- 检查 Registry 服务是否运行：`curl https://myapp-registry.dapangyu.work/health`
- 检查包是否存在：`curl "https://myapp-registry.dapangyu.work/package/common-ui"`
- 查看 Registry 服务日志：`ssh root@myapp-backend.dapangyu.work "tail -f /var/log/registry/registry.log"`

### 2. SSL 证书错误
**症状**: SSL handshake failed

**解决方法**:
- 在测试脚本中添加 `verify=False`（仅用于开发测试）
- 或者更新服务器的 SSL 证书

### 3. 认证失败
**症状**: "未提供认证 token" 或 "token 无效"

**解决方法**:
- 开发测试使用 `Authorization: Bearer test-token`
- 生产环境使用真实的 Supabase token

### 4. 包版本不存在
**症状**: "No matching version found"

**解决方法**:
- 检查 _index.json 中是否有该版本
- 运行 `python3 registry_init.py` 重建索引
- 检查 MinIO 中是否有对应的文件

## 下一步

测试通过后，可以：
1. 在 Flutter 应用中添加"发布到市场"功能入口
2. 将 feature/registry-service 分支合并到 main
3. 编写用户文档，说明如何发布和使用组件包
