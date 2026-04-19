# 用户管理 + AI 生成 JSON-APP 系统设计方案 v2

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    Flutter 客户端                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐    │
│  │ 登录/注册 │  │ JSON-APP │  │ AI 对话  │  │ APP 市场     │    │
│  │ (Auth)   │  │ 运行沙盒 │  │ (悬浮球) │  │ (浏览/下载)  │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘    │
│       │             │             │               │             │
│       │  ┌──────────┴─────────────┴───────────────┘             │
│       │  │  所有请求带 Bearer Token                              │
└───────┼──┼──────────────────────────────────────────────────────┘
        │  │
        ▼  ▼
┌─────────────────────────────────────────────────────────────────┐
│              Flask 后端 (app-backend.dapangyu.work)              │
│                                                                 │
│  ┌─────────┐ ┌───────────┐ ┌──────────┐ ┌───────────────────┐  │
│  │ Auth    │ │ User Mgmt │ │ AI Chat  │ │ App Store         │  │
│  │ Proxy   │ │ & Quota   │ │ + Quota  │ │ CRUD + OSS        │  │
│  └────┬────┘ └─────┬─────┘ └────┬─────┘ └────────┬──────────┘  │
│       │            │            │                 │             │
│       ▼            ▼            ▼                 ▼             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌───────────────────┐  │
│  │Supabase │  │PostgreSQL│  │DeepSeek │  │MinIO OSS          │  │
│  │Auth     │  │(自建表)  │  │API      │  │json-app/component │  │
│  └─────────┘  └─────────┘  └─────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## 二、用户角色体系

### 2.1 角色定义

| 角色 | 标识 | AI 聊天/天 | 上传到市场 | 管理用户 | 说明 |
|------|------|-----------|-----------|---------|------|
| 普通用户 | `user` | 30 | ❌ | ❌ | 注册默认角色 |
| 专业用户 | `pro` | 60 | ✅ | ❌ | 管理员手动升级 |
| 管理员 | `admin` | 无限 | ✅ | ✅ | 管理员手动指定 |

### 2.2 角色存储

使用 Supabase `app_metadata.role`（只能通过 service_role key 修改，用户无法篡改）：

```json
{ "provider": "email", "role": "pro" }
```

### 2.3 用户管理后台

**直接使用 Supabase Studio**（`https://app-auth.dapangyu.work`）

操作流程：Authentication → Users → 编辑用户的 `app_metadata` → 设置 `"role": "pro"` 或 `"admin"`

## 三、聊天配额系统

### 3.1 数据库表

```sql
CREATE TABLE public.chat_quotas (
    id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    date        DATE NOT NULL DEFAULT CURRENT_DATE,
    used_count  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(user_id, date)
);
CREATE INDEX idx_chat_quotas_user_date ON public.chat_quotas(user_id, date);
```

### 3.2 检查流程

```
POST /chat 请求进入
  → @require_auth 验证 token
  → 读 app_metadata.role → 得到配额上限 (user:30, pro:60, admin:∞)
  → 查 chat_quotas 今日 used_count
  → 超额 → 403 "今日对话次数已用完（已用 30/30）"
  → 未超 → 转发 DeepSeek → used_count += 1 → 返回剩余次数
```

客户端在对话字幕底部显示：`剩余 27/30 次`

## 四、JSON-APP 唯一 ID 与注册表

### 4.1 ID 分配规则

**服务端分配全局唯一 ID**，格式：`app_{uuid_short}` / `comp_{uuid_short}`

- 用户本地生成的 JSON-APP 没有 ID（`meta.id` 为空）
- 用户选择「发布到市场」时，后端分配 ID 写入 `meta.id`
- 已有 ID 的 APP 再次上传视为更新（同 ID 新版本）

### 4.2 数据库表

```sql
CREATE TABLE public.app_registry (
    id           TEXT PRIMARY KEY,               -- 服务端分配: app_xxxx / comp_xxxx
    type         TEXT NOT NULL CHECK (type IN ('app', 'component')),
    name         TEXT NOT NULL,
    version      TEXT NOT NULL DEFAULT '1.0.0',
    description  TEXT NOT NULL DEFAULT '',
    author_id    UUID REFERENCES auth.users(id),
    author_name  TEXT NOT NULL DEFAULT '',
    oss_bucket   TEXT NOT NULL,                  -- 'json-app' 或 'json-component'
    oss_key      TEXT NOT NULL,                  -- MinIO 对象键
    download_url TEXT NOT NULL,                  -- 公开下载 URL
    tags         TEXT[] DEFAULT '{}',
    is_public    BOOLEAN DEFAULT true,
    meta_json    JSONB DEFAULT '{}',             -- 完整 meta（给 AI 参考）
    dsl_spec     TEXT DEFAULT '',                -- 功能描述（给 AI 参考）
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_app_registry_type ON public.app_registry(type);
CREATE INDEX idx_app_registry_author ON public.app_registry(author_id);
```

### 4.3 后端 API

| API | 方法 | 权限 | 说明 |
|-----|------|------|------|
| `GET /api/store/apps` | GET | 公开 | 列出所有公开 app |
| `GET /api/store/components` | GET | 公开 | 列出所有公开组件 |
| `GET /api/store/detail/<id>` | GET | 公开 | 获取详情+下载链接 |
| `POST /api/store/publish` | POST | pro/admin | 发布：上传 JSON → OSS + 写 registry，返回分配的 ID |
| `PUT /api/store/update/<id>` | PUT | 作者/admin | 更新已发布的 APP |
| `DELETE /api/store/delete/<id>` | DELETE | 作者/admin | 下架 |

### 4.4 发布流程

```
用户在客户端点击"发布到市场"
  → POST /api/store/publish (带 JSON 内容)
  → 后端校验角色 (pro/admin)
  → 解析 meta 字段
  → 分配 ID: app_{uuid[:8]} 或 comp_{uuid[:8]}
  → 上传到 MinIO: json-app/{id}/{name}-{version}.json
  → 写入 app_registry
  → 返回 { id, download_url }
  → 客户端 JSON 的 meta.id 更新为服务端分配的 ID
```

## 五、AI 生成 JSON-APP 系统（核心）

### 5.1 对话模式 — 不是一上来就生成

AI 通过悬浮球对话，分为 **讨论阶段** 和 **生成阶段**：

```
┌─────────────────────────────────────────────────────┐
│ 讨论阶段（多轮对话）                                  │
│                                                     │
│ 用户: "帮我做一个天气查询APP"                         │
│ AI:   "好的！你想要哪些功能？                         │
│        1. 输入城市查天气？                            │
│        2. 自动定位？                                 │
│        3. 未来几天预报？"                             │
│ 用户: "就输入城市名查天气就行，简单点"                  │
│ AI:   "明白了。UI 上你想要什么风格？                   │
│        卡片式还是列表式？"                            │
│ 用户: "卡片式，好看一点"                              │
│ AI:   "好，我来帮你生成。需要以下功能：               │
│        - 输入框输入城市                              │
│        - 调用天气 API                                │
│        - 卡片展示结果                                │
│        确认可以生成吗？"                              │
│ 用户: "可以"                                         │
│                                                     │
├─────────────────────────────────────────────────────┤
│ 生成阶段                                            │
│                                                     │
│ AI → 后端解析出 JSON 代码块                          │
│    → 客户端收到 JSON → 弹出"试运行"                   │
│    → 沙盒运行                                       │
│    → 成功 → 保存在本地（不自动上传 OSS）              │
│    → 崩溃 → 崩溃日志 → 用户确认 → 发回 AI 修复       │
│                                                     │
├─────────────────────────────────────────────────────┤
│ 调试阶段（可选）                                      │
│                                                     │
│ 用户: "按钮颜色改成蓝色，再加个刷新按钮"               │
│ → 客户端把当前 JSON + 用户需求发给 AI                 │
│ → AI 返回修改后的 JSON                               │
│ → 再次试运行                                        │
└─────────────────────────────────────────────────────┘
```

### 5.2 后端如何判断"该生成了"

**不需要后端判断。** AI 自己决定何时输出 JSON 代码块。

后端逻辑：
- 每条 AI 回复都检查是否包含 ` ```json ` 代码块
- 有 → 提取 JSON，附在 SSE 最后一条事件里标记 `"has_json": true, "json_app": {...}`
- 没有 → 普通对话，正常 SSE 返回

客户端逻辑：
- 收到 `has_json: true` → 弹出"试运行"按钮
- 用户点击 → 沙盒运行 JSON-APP

### 5.3 AI System Prompt

```text
你是 JSON-DSL v3.3 应用设计师。用户会描述想要的 APP，你的职责：

1. **先讨论**：了解用户需求，确认功能和 UI 风格
2. **再生成**：用户确认后，输出完整可运行的 JSON-APP
3. **可修改**：用户提出调整，你修改 JSON 并重新输出

## JSON-DSL 规范
{JSON-DSL.md 全文}

## 可用组件库（可直接通过 dependencies 引用）
{app_registry 中 type=component 的列表}

## 已有 APP 参考
{app_registry 中 type=app 的摘要列表}

## 输出要求
- 必须包含 meta（name/version/type:"app"/description）
- 必须是完整可运行的 JSON-APP
- 用 ```json ... ``` 代码块包裹
- 简单需求可一轮直接生成，复杂需求先讨论
- 优先复用可用组件库
```

### 5.4 崩溃修复对话

用户点击"发送崩溃日志"后，客户端自动在对话中追加：

```text
[系统] 刚才生成的 JSON-APP 运行崩溃了：

## 崩溃日志
{error + stackTrace}

## 当前 JSON
{完整 JSON}

请分析原因并修复，输出修复后的完整 JSON。
```

AI 修复后输出新的 JSON 代码块 → 客户端再次检测到 `has_json` → 试运行。

### 5.5 调试修改对话

用户通过悬浮球说话：

```text
用户: "按钮颜色改成蓝色"
```

客户端自动在发给后端的消息中附带当前 JSON：

```text
用户说: "按钮颜色改成蓝色"

当前 JSON-APP:
{完整 JSON}
```

AI 修改后输出新的 JSON → 试运行。

## 六、客户端 JSON-APP 运行沙盒

### 6.1 沙盒 try-catch

在 `JsonScreenView` 的 build 方法最外层：

```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  try {
    // ... 正常渲染逻辑 ...
    return Scaffold(...);
  } catch (e, stack) {
    return _CrashPage(
      error: e,
      stackTrace: stack,
      config: currentConfig,
    );
  }
}
```

### 6.2 崩溃页面

```
┌─────────────────────────────────────┐
│         ⚠️ APP 运行出错              │
│                                     │
│  错误信息:                           │
│  ┌─────────────────────────────┐    │
│  │ RangeError: index out of... │    │
│  └─────────────────────────────┘    │
│                                     │
│  [发送崩溃日志给 AI 修复]   [返回]     │
└─────────────────────────────────────┘
```

点击"发送崩溃日志给 AI 修复"→ 在悬浮球对话中自动追加崩溃信息 → AI 修复 → 新 JSON 推送。

### 6.3 本地保存

AI 生成的 JSON-APP **默认存在用户本地**（shared_preferences 或本地文件），不上传 OSS。
只有用户主动点击"发布到市场"才走 `/api/store/publish`。

## 七、数据流向总结

```
用户对话 → 后端(配额检查) → DeepSeek(带 DSL 规范) → AI 回复
                                                    │
                                          有 JSON 代码块？
                                          ├── 否 → 正常对话
                                          └── 是 → 提取 JSON
                                                    │
                                                    ▼
                                           客户端沙盒运行
                                          ├── 成功 → 本地保存
                                          │         └── 用户选择 → 发布市场(OSS)
                                          └── 崩溃 → 崩溃页
                                                    └── 发回 AI → 修复 → 重新运行
```

## 八、实施阶段

### Phase 1：用户角色 + 聊天配额
1. 建表：`chat_quotas`
2. 后端：`/chat` 加 `@require_auth` + 配额检查 + 剩余次数返回
3. 后端：`GET /api/auth/quota` 查询当前剩余配额
4. 客户端：对话字幕显示剩余次数，超额弹提示

### Phase 2：APP 注册表 + OSS 市场
1. 建表：`app_registry`
2. 后端：`/api/store/*` CRUD + MinIO 上传 + 服务端分配 ID
3. 客户端：市场页面改为从 registry 读取
4. 迁移现有 `templates/*.json` → MinIO + registry（初始数据）

### Phase 3：AI 生成 JSON-APP + 沙盒
1. 后端：`/chat` 增强 — 注入 DSL 规范 system prompt + 检测 JSON 代码块
2. 客户端：检测 SSE 中的 `has_json` → 弹出试运行
3. 客户端：JSON-APP 运行沙盒 try-catch + 崩溃页面
4. 客户端：调试修改 → 附带当前 JSON 重新发给 AI
5. 客户端：本地保存 + 可选发布到市场

### Phase 4：优化
1. AI prompt 调优（根据实际生成质量迭代）
2. APP 版本管理（同 ID 多版本）
3. 用户收藏/历史
