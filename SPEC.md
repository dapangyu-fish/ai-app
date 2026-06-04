# 项目编码规范（SPEC）

## 1. 项目架构

### 1.1 技术栈

- **客户端**：Flutter（跨平台）
- **后端**：Python Flask
- **数据库**：
  - Supabase PostgreSQL（用户认证、用户信息）
  - 独立 PostgreSQL（业务数据）
- **对象存储**：MinIO
- **AI 服务**：DeepSeek / MiniMax / 自定义 Anthropic-compatible provider

### 1.2 目录结构

```
ai-app/
├── lib/                    # Flutter 客户端代码
│   ├── main.dart          # 应用入口
│   ├── auth/              # 认证模块
│   ├── json_ui/           # JSON-DSL 引擎
│   ├── designer/          # 悬浮球和 AI 对话
│   └── config/            # 配置管理
├── backend/               # Python 后端服务
│   ├── ai_server.py       # 主服务入口
│   ├── auth.py            # 认证模块
│   ├── database.py        # 数据库操作
│   ├── store.py           # 应用商店
│   ├── registry_server.py # Registry 服务（独立进程）
│   └── config.py          # 配置管理
├── templates/             # JSON-APP 模板
└── JSON-DSL.md           # DSL 规范文档
```

---

## 2. 数据库使用规范

### 2.1 Supabase PostgreSQL

**用途**：用户认证、用户信息、头像存储

**访问规则**：
- ✅ **必须**使用 Supabase 官方 REST API 或 Python SDK
- ❌ **禁止**直接连接 Supabase PostgreSQL 数据库
- ❌ **禁止**使用 psycopg2 连接 Supabase

**示例**：

```python
# ✅ 正确：使用 Supabase Auth API
import requests
resp = requests.get(
    f"{SUPABASE_URL}/auth/v1/user",
    headers={"Authorization": f"Bearer {token}"}
)

# ❌ 错误：直接连接 Supabase 数据库
import psycopg2
conn = psycopg2.connect(host="supabase-host", ...)  # 禁止！
```

**涉及的功能**：
- 用户注册、登录、登出
- Token 刷新
- 用户信息更新
- 头像上传（Supabase Storage）

---

### 2.2 独立 PostgreSQL

**用途**：业务数据存储

**访问规则**：
- ✅ **必须**通过 `backend/database.py` 模块的封装函数访问
- ✅ 使用 psycopg2 连接
- ❌ **禁止**在业务代码中直接创建数据库连接

**配置**：
```python
# backend/config.py
DB_HOST = "127.0.0.1"
DB_PORT = 5433
DB_NAME = "jsonapp"
DB_USER = "jsonapp"
DB_PASSWORD = "..."
```

**封装函数**：
```python
# backend/database.py
def db_query(sql, params=None, fetch_one=False, fetch_all=False):
    """执行查询语句"""
    ...

def db_execute(sql, params=None):
    """执行更新/删除/插入语句"""
    ...
```

**使用示例**：

```python
# ✅ 正确：使用封装函数
from database import db_query, db_execute

# 查询
row = db_query(
    "SELECT * FROM namespaces WHERE id = %s",
    [namespace_id],
    fetch_one=True
)

# 插入
db_execute(
    "INSERT INTO namespaces (name, created_by) VALUES (%s, %s)",
    [name, user_id]
)

# ❌ 错误：直接创建连接
import psycopg2
conn = psycopg2.connect(...)  # 禁止！
```

**涉及的表**：
- `chat_quotas` - 聊天配额管理
- `app_registry` - 应用注册表（已废弃）
- `namespaces` - 命名空间表（新增）
- `namespace_members` - 命名空间成员表（新增）

---

## 3. MinIO 对象存储规范

### 3.1 访问方式

**规则**：
- ✅ **必须**使用 MinIO Python SDK
- ✅ 使用预签名 URL 进行文件上传/下载
- ❌ **禁止**直接暴露 MinIO 访问密钥到客户端

**配置**：
```python
# backend/config.py
MINIO_PUBLIC_URL = "https://myapp-oss-endpoint.dapangyu.work"
MINIO_ENDPOINT = "myapp-oss-endpoint.dapangyu.work"
MINIO_ACCESS_KEY = "..."
MINIO_SECRET_KEY = "..."
```

**Bucket 列表**：
- `json-app` - JSON-APP 应用
- `json-component` - JSON 组件库
- `models` - AI 模型文件
- `avatars` - 用户头像（Supabase Storage）
- `ai-chat-temp` - AI 对话临时文件

**使用示例**：

```python
from minio import Minio

minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=MINIO_SECURE
)

# 上传文件
minio_client.put_object(
    bucket_name="json-app",
    object_name="path/to/file.json",
    data=io.BytesIO(data_bytes),
    length=len(data_bytes),
    content_type="application/json"
)

# 生成预签名 URL
from datetime import timedelta
url = minio_client.presigned_get_object(
    bucket_name="json-app",
    object_name="path/to/file.json",
    expires=timedelta(hours=1)
)
```

---

## 4. API 设计规范

### 4.1 RESTful API 规范

**URL 命名**：
- 使用小写字母和连字符
- 使用复数名词表示资源集合
- 使用路径参数表示资源 ID

**示例**：
```
✅ GET  /api/namespaces          # 获取命名空间列表
✅ POST /api/namespaces          # 创建命名空间
✅ GET  /api/namespaces/{id}     # 获取单个命名空间
✅ PUT  /api/namespaces/{id}     # 更新命名空间
✅ DELETE /api/namespaces/{id}   # 删除命名空间

❌ GET  /api/getNamespaces       # 不要在 URL 中使用动词
❌ POST /api/namespace           # 使用复数形式
```

### 4.2 HTTP 状态码

- `200 OK` - 请求成功
- `201 Created` - 创建成功
- `400 Bad Request` - 请求参数错误
- `401 Unauthorized` - 未认证
- `403 Forbidden` - 无权限
- `404 Not Found` - 资源不存在
- `409 Conflict` - 资源冲突（如重复创建）
- `410 Gone` - 资源已废弃
- `500 Internal Server Error` - 服务器错误
- `502 Bad Gateway` - 上游服务错误

### 4.3 响应格式

**成功响应**：
```json
{
  "message": "操作成功",
  "data": { ... }
}
```

**错误响应**：
```json
{
  "error": "错误描述",
  "code": "ERROR_CODE"  // 可选
}
```

### 4.4 认证装饰器

**规则**：
- 所有需要认证的接口必须使用 `@require_auth` 装饰器
- 需要特定角色的接口使用 `@require_role()` 装饰器

**示例**：

```python
from auth import require_auth, require_role

@app.route('/api/protected')
@require_auth
def protected_route():
    user = request.supabase_user
    user_id = user.get('id')
    return jsonify({"message": "已认证"})

@app.route('/api/admin-only')
@require_auth
@require_role('admin')
def admin_route():
    return jsonify({"message": "管理员专用"})
```

---

## 5. 代码风格规范

### 5.1 Python 代码规范

**遵循 PEP 8**：
- 使用 4 个空格缩进
- 每行最多 120 字符
- 函数和类之间空 2 行
- 导入顺序：标准库 → 第三方库 → 本地模块

**命名规范**：
- 变量和函数：`snake_case`
- 类名：`PascalCase`
- 常量：`UPPER_SNAKE_CASE`
- 私有变量/函数：`_leading_underscore`

**示例**：

```python
# ✅ 正确
def get_user_info(user_id):
    """获取用户信息"""
    return db_query("SELECT * FROM users WHERE id = %s", [user_id])

class UserService:
    """用户服务类"""
    
    def __init__(self):
        self._cache = {}
    
    def get_user(self, user_id):
        return self._cache.get(user_id)

# ❌ 错误
def GetUserInfo(userId):  # 函数名应该是 snake_case
    pass

class userService:  # 类名应该是 PascalCase
    pass
```

### 5.2 Dart 代码规范

**遵循 Effective Dart**：
- 使用 2 个空格缩进
- 类名：`PascalCase`
- 变量和函数：`camelCase`
- 常量：`lowerCamelCase`
- 私有成员：`_leadingUnderscore`

**示例**：

```dart
// ✅ 正确
class UserService {
  final String _apiUrl;
  
  UserService(this._apiUrl);
  
  Future<User> getUserInfo(String userId) async {
    // ...
  }
}

// ❌ 错误
class user_service {  // 类名应该是 PascalCase
  String ApiUrl;  // 私有变量应该加下划线
  
  Future<User> get_user_info(String user_id) async {  // 函数名应该是 camelCase
    // ...
  }
}
```

---

## 6. 错误处理规范

### 6.1 Python 错误处理

**规则**：
- 使用 try-except 捕获异常
- 记录错误日志
- 返回友好的错误信息给客户端

**示例**：

```python
@app.route('/api/resource')
@require_auth
def get_resource():
    try:
        # 业务逻辑
        data = db_query("SELECT * FROM resources", fetch_all=True)
        return jsonify({"data": data})
    except Exception as e:
        # 记录错误日志
        print(f"[Error] Failed to get resource: {e}")
        # 返回友好的错误信息
        return jsonify({"error": "获取资源失败"}), 500
```

### 6.2 Flutter 错误处理

**规则**：
- 使用 try-catch 捕获异常
- 显示友好的错误提示（SnackBar / Dialog）
- 记录错误日志（debugPrint）

**示例**：

```dart
Future<void> fetchData() async {
  try {
    final response = await http.get(Uri.parse('$apiUrl/resource'));
    if (response.statusCode == 200) {
      // 处理成功响应
    } else {
      throw Exception('服务器错误 (${response.statusCode})');
    }
  } catch (e) {
    debugPrint('[Error] Failed to fetch data: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取数据失败: $e')),
      );
    }
  }
}
```

---

## 7. 安全规范

### 7.1 认证和授权

- ✅ 所有敏感接口必须使用 `@require_auth` 装饰器
- ✅ 使用 Bearer Token 进行认证
- ✅ Token 存储在客户端的 SharedPreferences 中
- ❌ **禁止**在 URL 参数中传递 Token
- ❌ **禁止**在日志中打印 Token

### 7.2 数据验证

- ✅ 后端必须验证所有用户输入
- ✅ 使用参数化查询防止 SQL 注入
- ✅ 验证文件类型和大小
- ❌ **禁止**信任客户端传来的数据

**示例**：

```python
# ✅ 正确：参数化查询
db_query("SELECT * FROM users WHERE id = %s", [user_id])

# ❌ 错误：字符串拼接（SQL 注入风险）
db_query(f"SELECT * FROM users WHERE id = '{user_id}'")
```

### 7.3 敏感信息

- ✅ 使用 `.env` 文件存储敏感配置
- ✅ `.env` 文件必须加入 `.gitignore`
- ❌ **禁止**在代码中硬编码密钥
- ❌ **禁止**提交 `.env` 文件到 Git

---

## 8. 测试规范

### 8.1 单元测试

- 测试文件命名：`test_<module_name>.py` 或 `<widget_name>_test.dart`
- 测试函数命名：`test_<function_name>_<scenario>`
- 使用 pytest（Python）或 flutter test（Dart）

### 8.2 集成测试

- 测试关键业务流程
- 测试 API 端到端流程
- 测试数据库操作

---

## 9. Git 提交规范

### 9.1 提交信息格式

```
<type>: <subject>

<body>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

**Type 类型**：
- `feat` - 新功能
- `fix` - Bug 修复
- `refactor` - 重构
- `docs` - 文档更新
- `style` - 代码格式调整
- `test` - 测试相关
- `chore` - 构建/工具相关

**示例**：

```
feat: add namespace permission system

- Add namespaces and namespace_members tables
- Implement permission check in publish API
- Add /my-namespaces endpoint for client

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

### 9.2 分支管理

- `main` - 主分支，稳定版本
- `feat/<feature-name>` - 功能分支
- `fix/<bug-name>` - Bug 修复分支

---

## 10. 文档规范

### 10.1 代码注释

**Python**：
```python
def get_user_info(user_id: str) -> dict:
    """
    获取用户信息
    
    Args:
        user_id: 用户 ID
        
    Returns:
        用户信息字典
        
    Raises:
        ValueError: 用户 ID 无效
    """
    pass
```

**Dart**：
```dart
/// 获取用户信息
///
/// [userId] 用户 ID
///
/// Returns 用户信息对象
///
/// Throws [Exception] 如果请求失败
Future<User> getUserInfo(String userId) async {
  // ...
}
```

### 10.2 API 文档

- 每个 API 接口必须在函数文档字符串中说明：
  - 请求方法和路径
  - 请求参数
  - 响应格式
  - 错误码

**示例**：

```python
@app.route('/api/namespaces', methods=['GET'])
@require_auth
def get_namespaces():
    """
    获取用户的命名空间列表
    
    GET /api/namespaces
    
    Headers:
        Authorization: Bearer <token>
    
    Response:
        {
            "namespaces": [
                {
                    "id": "uuid",
                    "name": "mycompany",
                    "role": "owner"
                }
            ]
        }
    
    Errors:
        401: 未认证
        500: 服务器错误
    """
    pass
```

---

## 11. 性能优化规范

### 11.1 数据库查询

- ✅ 使用索引优化查询
- ✅ 避免 N+1 查询问题
- ✅ 使用分页限制返回数据量
- ❌ **禁止**在循环中执行数据库查询

### 11.2 缓存策略

- ✅ 使用 MinIO 预签名 URL 缓存
- ✅ 客户端缓存用户信息
- ✅ 使用 HTTP 缓存头

---

## 12. 部署规范

### 12.1 环境变量

**必需的环境变量**：
```bash
# Supabase
SUPABASE_URL=https://myapp-auth.dapangyu.work
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_KEY=...

# PostgreSQL
DB_HOST=127.0.0.1
DB_PORT=5433
DB_NAME=jsonapp
DB_USER=jsonapp
DB_PASSWORD=...

# MinIO
MINIO_PUBLIC_URL=https://myapp-oss-endpoint.dapangyu.work
MINIO_ACCESS_KEY=...
MINIO_SECRET_KEY=...

# AI Provider
DEEPSEEK_KEY=...
```

### 12.2 服务启动

**后端服务**：
```bash
# 主服务（端口 5566）
python backend/ai_server.py

# Registry 服务（端口 3254）
python backend/registry_server.py
```

**客户端**：
```bash
flutter run
```

---

## 13. 废弃功能处理

### 13.1 标记废弃

- 在代码中添加 `@deprecated` 注释
- 在 API 响应中返回 `deprecated: true`
- 返回 HTTP 410 Gone 状态码

**示例**：

```python
@app.route('/api/old-endpoint')
def old_endpoint():
    """
    [已废弃] 旧接口
    请使用新接口: /api/new-endpoint
    """
    return jsonify({
        "deprecated": True,
        "message": "此接口已废弃",
        "new_endpoint": "/api/new-endpoint"
    }), 410
```

---

## 14. 常见问题

### Q1: 如何区分 Supabase 和独立 PostgreSQL？

**A**: 
- Supabase：用户认证、用户信息 → 使用 Supabase Auth API
- 独立 PostgreSQL：业务数据 → 使用 `database.py` 封装函数

### Q2: 如何添加新的数据库表？

**A**:
1. 在独立 PostgreSQL 中创建表
2. 在 `backend/database.py` 中添加封装函数
3. 在业务代码中使用封装函数

### Q3: 如何处理跨域问题？

**A**: 
在 Flask 中使用 `flask-cors`：
```python
from flask_cors import CORS
app = Flask(__name__)
CORS(app)
```

---

## 15. 参考资料

- [Flutter 官方文档](https://flutter.dev/docs)
- [Flask 官方文档](https://flask.palletsprojects.com/)
- [Supabase 官方文档](https://supabase.com/docs)
- [MinIO Python SDK](https://min.io/docs/minio/linux/developers/python/minio-py.html)
- [PEP 8 Python 代码规范](https://pep8.org/)
- [Effective Dart](https://dart.dev/guides/language/effective-dart)
