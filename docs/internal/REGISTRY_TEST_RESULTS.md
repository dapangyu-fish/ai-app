# Registry 服务测试报告

> 历史测试报告，不代表当前线上实时状态。当前 Registry 行为以
> `backend/registry_server.py`、`backend/REGISTRY_README.md` 和
> `deploy/production/README.md` 为准。

## 测试环境
- **服务地址**: https://myapp-registry.dapangyu.work
- **服务端口**: 3254
- **部署方式**: Supervisor
- **测试时间**: 2024

## 测试结果总览

✅ **所有核心功能测试通过**

## 详细测试结果

### 1. 服务健康检查
```bash
curl https://myapp-registry.dapangyu.work/health
```
**结果**: ✅ 通过
```json
{
  "service": "json-dsl-registry",
  "status": "ok",
  "version": "1.0.0"
}
```

### 2. 命名空间管理

#### 2.1 检查命名空间可用性
```bash
curl "https://myapp-registry.dapangyu.work/namespace/check?name=mycompany"
```
**结果**: ✅ 通过
```json
{
  "available": false,
  "exists": true,
  "name": "mycompany"
}
```

#### 2.2 创建命名空间
```bash
curl -X POST https://myapp-registry.dapangyu.work/namespace/create \
  -H "Authorization: Bearer test-token" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mycompany"}'
```
**结果**: ✅ 通过
```json
{
  "message": "命名空间创建成功",
  "namespace": "mycompany",
  "owner_id": "test-user-id"
}
```

#### 2.3 创建嵌套命名空间（2级）
```bash
curl -X POST https://myapp-registry.dapangyu.work/namespace/create \
  -H "Authorization: Bearer test-token" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mycompany", "sub_namespace": "frontend"}'
```
**结果**: ✅ 通过
```json
{
  "message": "命名空间创建成功",
  "namespace": "mycompany/frontend",
  "owner_id": "test-user-id"
}
```

### 3. 用户包发布

#### 3.1 发布用户包（1级命名空间）
**包名**: mycompany/ui-kit  
**版本**: 1.0.0  
**结果**: ✅ 通过

```json
{
  "message": "发布成功",
  "name": "mycompany/ui-kit",
  "version": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/ui-kit/ui-kit-1.0.0.json"
}
```

#### 3.2 发布嵌套包（2级命名空间）
**包名**: mycompany/frontend/form-kit  
**版本**: 1.0.0  
**结果**: ✅ 通过

```json
{
  "message": "发布成功",
  "name": "mycompany/frontend/form-kit",
  "version": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/frontend/form-kit/form-kit-1.0.0.json"
}
```

#### 3.3 版本冲突检测
**测试**: 重复发布相同版本  
**结果**: ✅ 通过（正确拒绝）

```json
{
  "error": "版本 1.0.0 已存在",
  "existing_versions": ["1.0.0"]
}
```

### 4. 依赖解析

#### 4.1 解析用户包依赖
```bash
curl "https://myapp-registry.dapangyu.work/resolve?name=mycompany/ui-kit&version=^1.0.0"
```
**结果**: ✅ 通过
```json
{
  "name": "mycompany/ui-kit",
  "version": "1.0.0",
  "type": "user",
  "latest": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/ui-kit/ui-kit-1.0.0.json"
}
```

#### 4.2 解析嵌套包依赖
```bash
curl "https://myapp-registry.dapangyu.work/resolve?name=mycompany/frontend/form-kit&version=^1.0.0"
```
**结果**: ✅ 通过
```json
{
  "name": "mycompany/frontend/form-kit",
  "version": "1.0.0",
  "type": "user",
  "latest": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/frontend/form-kit/form-kit-1.0.0.json"
}
```

#### 4.3 解析官方包依赖
```bash
curl "https://myapp-registry.dapangyu.work/resolve?name=common-ui&version=^1.0.0"
```
**结果**: ✅ 通过
```json
{
  "name": "common-ui",
  "version": "1.0.0",
  "type": "official",
  "latest": "1.0.0",
  "download_url": "https://myapp-oss-endpoint.dapangyu.work/json-component/common-ui-1.0.0.json"
}
```

### 5. 包下载验证

#### 5.1 下载用户包
```bash
curl "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/ui-kit/ui-kit-1.0.0.json"
```
**结果**: ✅ 通过
- 包名: mycompany/ui-kit
- 版本: 1.0.0
- 组件数: 2 (CustomButton, CustomCard)

#### 5.2 下载嵌套包
```bash
curl "https://myapp-oss-endpoint.dapangyu.work/json-component/mycompany/frontend/form-kit/form-kit-1.0.0.json"
```
**结果**: ✅ 通过
- 包名: mycompany/frontend/form-kit
- 版本: 1.0.0
- 组件数: 1 (FormInput)

## 功能验证清单

- [x] 服务健康检查
- [x] 命名空间可用性检查
- [x] 创建1级命名空间
- [x] 创建2级嵌套命名空间
- [x] 发布用户包（1级命名空间）
- [x] 发布嵌套包（2级命名空间）
- [x] 版本冲突检测
- [x] 依赖解析（用户包）
- [x] 依赖解析（嵌套包）
- [x] 依赖解析（官方包）
- [x] 包文件下载
- [x] MinIO 存储集成
- [x] 索引文件管理
- [x] 认证机制（测试 token）

## 性能表现

- **健康检查响应时间**: ~4s（通过 Cloudflare）
- **依赖解析响应时间**: ~1-2s
- **包下载速度**: 正常
- **服务稳定性**: 稳定运行

## 已知问题

1. **SSL 连接问题**: Python requests 库直接访问 HTTPS 时遇到 SSL 握手错误
   - **解决方案**: 使用 `verify=False` 参数（测试环境）
   - **原因**: 可能是 Cloudflare 代理或证书配置问题
   - **影响**: 不影响 curl 和浏览器访问

2. **测试 token**: 当前使用硬编码的 `test-token` 用于测试
   - **生产环境**: 需要使用真实的 Supabase 认证 token
   - **安全性**: 测试 token 仅在开发环境使用

## 下一步计划

- [ ] 测试客户端（Flutter）依赖加载器集成
- [ ] 迁移现有 templates 文件到新格式
- [ ] 添加客户端"发布到市场"功能
- [ ] 生产环境移除测试 token 支持
- [ ] 添加更多的错误处理和日志
- [ ] 性能优化和缓存策略

## 测试脚本

完整的测试脚本位于: `backend/test_publish_user_package.py`

运行测试:
```bash
cd backend
python3 test_publish_user_package.py
```

## 结论

✅ **Registry 服务已成功部署并通过所有核心功能测试**

服务已准备好用于：
1. 用户包发布和管理
2. 命名空间管理
3. 依赖解析
4. 与客户端集成

建议在生产环境使用前：
1. 移除测试 token 支持
2. 配置真实的认证机制
3. 添加监控和告警
4. 优化性能和缓存
