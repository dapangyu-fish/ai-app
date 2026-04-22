#!/usr/bin/env python3
"""
JSON DSL Backend — Flask
Auth Proxy + User Roles + Chat Quota + AI Chat (SSE) + App Store (OSS)

启动: python backend/ai_server.py
"""

import json
import os
import re
import base64
import uuid
import time
import urllib.parse
from datetime import date
from functools import wraps

import requests
import anthropic
import psycopg2
from psycopg2.extras import DictCursor
from flask import Flask, request, jsonify, Response, stream_with_context, send_from_directory
from flask_sock import Sock

# ═══════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════

SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://127.0.0.1:8000")
SUPABASE_ANON_KEY = (
    "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9"
    ".eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3NzYzNjU0NjIsICJleHAiOiAyMDkxNzI1NDYyfQ"
    ".yDol0HCrVCJ_XlWTAb3k89aAwb-KzMlSMw-EHEIpB2k"
)
SUPABASE_SERVICE_KEY = (
    "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9"
    ".eyJyb2xlIjogInNlcnZpY2Vfcm9sZSIsICJpc3MiOiAic3VwYWJhc2UiLCAiaWF0IjogMTc3NjM2NTQ2MiwgImV4cCI6IDIwOTE3MjU0NjJ9"
    ".vF-RNvJfdUyhExR8cFdefdMVmw4yHCCaFMd_-gZC5Es"
)

DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"

AI_PROVIDERS = {
    "deepseek": {
        "id": "deepseek",
        "name": "DeepSeek",
        "description": "DeepSeek AI — 通用对话模型",
        "type": "anthropic",
        "base_url": "https://api.deepseek.com/anthropic",
        "api_key": DEEPSEEK_KEY,
        "models": {
            "default": "deepseek-chat",
        },
        "agent_model": "deepseek-chat",
    },
    "glm": {
        "id": "glm",
        "name": "GLM (智谱)",
        "description": "智谱 GLM — 多模型系列",
        "type": "anthropic",
        "base_url": os.environ.get("ANTHROPIC_BASE_URL", "http://14.103.26.181"),
        "api_key": os.environ.get("ANTHROPIC_AUTH_TOKEN", "sk-FUsE9Q3QaEjHo7qnad7ffBINpQHkkETW16K8OXl26SHfRUfN"),
        "models": {
            "default": os.environ.get("ANTHROPIC_MODEL", "glm-5"),
            "haiku": os.environ.get("ANTHROPIC_DEFAULT_HAIKU_MODEL", "glm-4.7"),
            "sonnet": os.environ.get("ANTHROPIC_DEFAULT_SONNET_MODEL", "glm-5-turbo"),
            "opus": os.environ.get("ANTHROPIC_DEFAULT_OPUS_MODEL", "glm-5.1"),
            "reasoning": os.environ.get("ANTHROPIC_REASONING_MODEL", "glm-5.1"),
        },
        "agent_model": os.environ.get("ANTHROPIC_MODEL", "glm-5"),
    },
}

DEFAULT_PROVIDER = "deepseek"

MINIO_ENDPOINT = "http://127.0.0.1:9000"
MINIO_ACCESS_KEY = "m3wZkIA5EgmEwkctueZM"
MINIO_SECRET_KEY = "m9M7M70F6SpsQxTZZ6roLklq33AUMV8mzAm1RJGk"
MINIO_PUBLIC_URL = "https://app-oss-endpoint.dapangyu.work"

# PostgreSQL 配置
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5433"))
DB_NAME = os.environ.get("DB_NAME", "jsonapp")
DB_USER = os.environ.get("DB_USER", "jsonapp")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "hOad2ANFLla23weqMU3c7IeYKOZRLL8rrXZVcDAkpjg")

PORT = 5566
TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates")
DSL_SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "JSON-DSL.md")
PROJECT_ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

AGENT_MAX_ITERATIONS = 8

def _get_provider(provider_id=None):
    pid = provider_id or DEFAULT_PROVIDER
    return AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])

def _get_agent_client(provider_id=None):
    p = _get_provider(provider_id)
    return anthropic.Anthropic(base_url=p["base_url"], api_key=p["api_key"])

def _get_agent_model(provider_id=None):
    p = _get_provider(provider_id)
    return p["agent_model"]

# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}

app = Flask(__name__)
sock = Sock(app)

# ═══════════════════════════════════════════════════════════
# 数据库连接
# ═══════════════════════════════════════════════════════════

def get_db_connection():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    return conn

def db_query(sql, params=None, fetch_one=False, fetch_all=False):
    conn = get_db_connection()
    try:
        with conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(sql, params or ())
            if fetch_one:
                result = cur.fetchone()
                return dict(result) if result else None
            elif fetch_all:
                results = cur.fetchall()
                return [dict(row) for row in results]
            else:
                conn.commit()
                return None
    finally:
        conn.close()

def db_execute(sql, params=None):
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
        conn.commit()
    finally:
        conn.close()

# ═══════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════

def _supabase_headers(token=None):
    h = {"apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h

def _service_headers():
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }

def _get_user_role(user):
    """从 app_metadata 获取角色，默认 user"""
    return user.get("app_metadata", {}).get("role", "user")

def _extract_user_info(user):
    meta = user.get("user_metadata", {})
    return {
        "id": user.get("id"),
        "email": user.get("email"),
        "username": meta.get("username", ""),
        "avatar_url": meta.get("avatar_url", ""),
        "role": _get_user_role(user),
    }

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "未提供认证 token"}), 401
        token = auth[7:]
        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=10,
        )
        if resp.status_code != 200:
            return jsonify({"error": "token 无效或已过期"}), 401
        request.supabase_user = resp.json()
        request.supabase_token = token
        request.user_role = _get_user_role(request.supabase_user)
        return f(*args, **kwargs)
    return decorated

def require_role(*roles):
    """装饰器：要求特定角色"""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if request.user_role not in roles:
                return jsonify({"error": f"权限不足，需要 {'/'.join(roles)} 角色"}), 403
            return f(*args, **kwargs)
        return decorated
    return decorator

# ═══════════════════════════════════════════════════════════
# appid 生成和检查
# ═══════════════════════════════════════════════════════════

def _generate_appid():
    """生成不重复的 appid（UUID），先检查数据库"""
    max_attempts = 100
    for _ in range(max_attempts):
        appid = uuid.uuid4().hex
        # 检查数据库中是否已存在
        exists = db_query(
            "SELECT id FROM app_registry WHERE id = %s",
            [appid],
            fetch_one=True
        )
        if not exists:
            return appid
    raise Exception("无法生成唯一的 appid")

def _check_appid_exists(appid):
    """检查 appid 是否已在数据库中存在"""
    if not appid:
        return False
    exists = db_query(
        "SELECT id FROM app_registry WHERE id = %s",
        [appid],
        fetch_one=True
    )
    return bool(exists)

def _increment_version(version_str):
    """将版本号的 patch 部分 +1，如 1.0.0 → 1.0.1"""
    parts = version_str.split('.')
    if len(parts) == 3:
        parts[2] = str(int(parts[2]) + 1)
    elif len(parts) == 2:
        parts.append('1')
    else:
        return version_str + '.0.1'
    return '.'.join(parts)

# ═══════════════════════════════════════════════════════════
# 聊天配额
# ═══════════════════════════════════════════════════════════

def _get_quota_info(user_id, role):
    """返回 (used, limit, remaining)"""
    limit = ROLE_QUOTAS.get(role, 30)
    today = date.today().isoformat()
    row = db_query(
        "SELECT used_count FROM chat_quotas WHERE user_id = %s AND date = %s",
        [user_id, today],
        fetch_one=True
    )
    used = row["used_count"] if row else 0
    return used, limit, max(0, limit - used)

def _increment_quota(user_id):
    today = date.today().isoformat()
    # 使用 INSERT ... ON CONFLICT DO UPDATE
    db_execute(
        """INSERT INTO chat_quotas (user_id, date, used_count)
           VALUES (%s, %s, 1)
           ON CONFLICT (user_id, date)
           DO UPDATE SET used_count = chat_quotas.used_count + 1""",
        [user_id, today]
    )

# ═══════════════════════════════════════════════════════════
# Auth API（通过 Supabase Auth）
# ═══════════════════════════════════════════════════════════

@app.route("/api/auth/register", methods=["POST"])
def register():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    username = body.get("username", "").strip()

    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400
    if len(password) < 6:
        return jsonify({"error": "密码至少 6 位"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/signup",
        headers=_supabase_headers(),
        json={"email": email, "password": password,
              "data": {"username": username or email.split("@")[0]}},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or data.get("message") or str(data)
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    needs_confirm = user.get("email_confirmed_at") is None

    result = {
        "message": "注册成功，请查收验证邮件" if needs_confirm else "注册成功",
        "needs_confirm": needs_confirm,
        "user": _extract_user_info(user),
    }
    if not needs_confirm and data.get("access_token"):
        result["access_token"] = data["access_token"]
        result["refresh_token"] = data["refresh_token"]
        result["expires_in"] = data.get("expires_in", 3600)

    return jsonify(result), 200

@app.route("/api/auth/verify", methods=["POST"])
def verify_otp():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    token = body.get("token", "").strip()
    if not email or not token:
        return jsonify({"error": "邮箱和验证码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/verify",
        headers=_supabase_headers(),
        json={"type": "signup", "email": email, "token": token},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or "验证失败"
        if "expired" in msg.lower() or "invalid" in msg.lower():
            msg = "验证码已过期或无效，请重新发送"
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "message": "邮箱验证成功",
        "access_token": data.get("access_token"),
        "refresh_token": data.get("refresh_token"),
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })

@app.route("/api/auth/resend", methods=["POST"])
def resend_verification():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    if not email:
        return jsonify({"error": "邮箱不能为空"}), 400
    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/resend",
        headers=_supabase_headers(),
        json={"type": "signup", "email": email},
        timeout=15,
    )
    if resp.status_code >= 400:
        return jsonify({"error": resp.json().get("msg", "发送失败")}), resp.status_code
    return jsonify({"message": "验证邮件已重新发送"})

@app.route("/api/auth/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    password = body.get("password", "").strip()
    if not email or not password:
        return jsonify({"error": "邮箱和密码不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers=_supabase_headers(),
        json={"email": email, "password": password},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        msg = data.get("msg") or data.get("error_description") or "登录失败"
        if "Invalid login" in msg:
            msg = "邮箱或密码错误"
        elif "Email not confirmed" in msg:
            msg = "邮箱未验证，请查收验证邮件"
        return jsonify({"error": msg}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })

@app.route("/api/auth/refresh", methods=["POST"])
def refresh_token():
    body = request.get_json(silent=True) or {}
    rt = body.get("refresh_token", "")
    if not rt:
        return jsonify({"error": "refresh_token 不能为空"}), 400

    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token",
        headers=_supabase_headers(),
        json={"refresh_token": rt},
        timeout=15,
    )
    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "刷新失败")}), resp.status_code

    user = data.get("user", {})
    return jsonify({
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "expires_in": data.get("expires_in", 3600),
        "user": _extract_user_info(user),
    })

@app.route("/api/auth/logout", methods=["POST"])
@require_auth
def logout():
    requests.post(f"{SUPABASE_URL}/auth/v1/logout",
                  headers=_supabase_headers(request.supabase_token), timeout=10)
    return jsonify({"message": "已登出"})

@app.route("/api/auth/user", methods=["GET"])
@require_auth
def get_user():
    return jsonify(_extract_user_info(request.supabase_user))

@app.route("/api/auth/user", methods=["PUT"])
@require_auth
def update_user():
    body = request.get_json(silent=True) or {}
    update_data = {}
    if "username" in body: update_data["username"] = body["username"]
    if "avatar_url" in body: update_data["avatar_url"] = body["avatar_url"]
    if not update_data:
        return jsonify({"error": "没有要更新的字段"}), 400

    resp = requests.put(f"{SUPABASE_URL}/auth/v1/user",
                        headers=_supabase_headers(request.supabase_token),
                        json={"data": update_data}, timeout=10)
    data = resp.json()
    if resp.status_code >= 400:
        return jsonify({"error": data.get("msg", "更新失败")}), resp.status_code
    return jsonify({"message": "更新成功", "user": _extract_user_info(data)})

@app.route("/api/auth/avatar", methods=["POST"])
@require_auth
def upload_avatar():
    body = request.get_json(silent=True) or {}
    avatar_base64 = body.get("avatar_base64", "")
    if not avatar_base64:
        return jsonify({"error": "avatar_base64 不能为空"}), 400
    if "," in avatar_base64:
        avatar_base64 = avatar_base64.split(",", 1)[1]
    try:
        image_bytes = base64.b64decode(avatar_base64)
    except Exception:
        return jsonify({"error": "无效的 Base64 数据"}), 400

    user_id = request.supabase_user.get("id", "unknown")
    file_name = f"{user_id}.png"
    upload_resp = requests.post(
        f"{SUPABASE_URL}/storage/v1/object/avatars/{file_name}",
        headers={"apikey": SUPABASE_SERVICE_KEY,
                 "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
                 "Content-Type": "image/png", "x-upsert": "true"},
        data=image_bytes, timeout=15,
    )
    if upload_resp.status_code >= 400:
        return jsonify({"error": f"存储上传失败: {upload_resp.text}"}), 502

    public_url = f"{SUPABASE_URL}/storage/v1/object/public/avatars/{file_name}?t={int(time.time())}"
    meta_resp = requests.put(f"{SUPABASE_URL}/auth/v1/user",
                 headers=_supabase_headers(request.supabase_token),
                 json={"data": {"avatar_url": public_url}}, timeout=10)
    if meta_resp.status_code >= 400:
        return jsonify({"error": f"头像已上传但更新用户信息失败: {meta_resp.text}"}), 502
    return jsonify({"message": "头像更新成功", "avatar_url": public_url})

@app.route("/api/auth/quota", methods=["GET"])
@require_auth
def get_quota():
    """查询当前用户今日配额"""
    user_id = request.supabase_user.get("id")
    used, limit, remaining = _get_quota_info(user_id, request.user_role)
    return jsonify({
        "role": request.user_role,
        "used": used,
        "limit": limit,
        "remaining": remaining,
    })

# ═══════════════════════════════════════════════════════════
# AI 供应商列表
# ═══════════════════════════════════════════════════════════

@app.route("/api/ai/providers", methods=["GET"])
def list_providers():
    providers = []
    for pid, p in AI_PROVIDERS.items():
        providers.append({
            "id": p["id"],
            "name": p["name"],
            "description": p.get("description", ""),
            "models": list(p["models"].keys()),
            "default_model": p["models"]["default"],
        })
    return jsonify({"providers": providers, "default": DEFAULT_PROVIDER})

# ═══════════════════════════════════════════════════════════
# AI Chat (SSE) — 带配额检查 + JSON 代码块检测
# ═══════════════════════════════════════════════════════════

def _load_dsl_spec():
    """加载 JSON-DSL.md 规范"""
    try:
        with open(DSL_SPEC_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""

def _load_registry_summary():
    """从 app_registry 加载已有 app/component 摘要"""
    try:
        rows = db_query(
            "SELECT type, name, version, description, dsl_spec FROM app_registry WHERE is_public = true ORDER BY type, name",
            fetch_all=True
        )
        if not rows:
            return ""
        lines = []
        for row in rows:
            lines.append(f"- [{row['type']}] {row['name']} v{row['version']}: {row['description']}")
            if row.get("dsl_spec"):
                lines.append(f"  规格: {row['dsl_spec']}")
        return "\n".join(lines)
    except Exception:
        return ""

AGENT_SYSTEM = """你是 JSON-DSL 应用设计师。用户通过语音与你交流，你帮助设计和生成 JSON-APP。

## 工作模式
1. 先理解用户需求
2. 生成 JSON-APP 前，必须用工具查阅框架代码，确认内置函数和组件确实存在
3. 参考 templates/ 目录下的已有模板 APP，学习正确的 JSON 结构和用法
4. 用 ```json ... ``` 代码块包裹完整可运行的 JSON-APP
5. 回复简洁（用户在手机上看字幕）

## 工具使用指引
- read_file: 读取框架源码或模板文件
- search_code: 搜索代码关键词
- list_builtin_functions: 获取所有可用 @函数列表
- list_templates: 列出所有可参考的模板 APP

## 生成 JSON-APP 的标准流程
1. 先调 list_builtin_functions 确认可用函数
2. 调 list_templates 查看有哪些模板
3. 用 read_file 读取一个相似的模板作为参考
4. 基于模板结构和真实函数生成 JSON-APP

## 输出要求
- JSON 必须包含 meta（name/version/type:"app"/description/icon_url）
- 只使用工具确认存在的 @函数和组件类型
- 不要自创框架中不存在的函数或属性
"""

AGENT_TOOLS = [
    {
        "name": "read_file",
        "description": "读取项目文件。常用: JSON-DSL.md (完整DSL规范), lib/json_ui/interpreter.dart (解释器+内置函数), lib/json_ui/widget_builder.dart (组件注册表), lib/json_ui/widgets/ (各组件实现)",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "从项目根目录的相对路径"}
            },
            "required": ["path"]
        }
    },
    {
        "name": "search_code",
        "description": "在项目代码中搜索关键词，返回匹配的行和文件路径",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "搜索关键词或正则"},
                "glob": {"type": "string", "description": "文件过滤，如 *.dart *.md"}
            },
            "required": ["pattern"]
        }
    },
    {
        "name": "list_builtin_functions",
        "description": "列出 JSON-DSL 框架所有可用的 @内置函数",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "list_templates",
        "description": "列出 templates/ 目录下所有模板 APP 文件及其简介。生成 JSON-APP 前应先查看，选一个相似的用 read_file 读取作为参考",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    }
]

def _execute_agent_tool(name, inputs):
    """执行 Agent 工具调用"""
    if name == "read_file":
        path = os.path.join(PROJECT_ROOT, inputs["path"])
        real = os.path.realpath(path)
        if not real.startswith(PROJECT_ROOT):
            return "Access denied: path outside project"
        try:
            with open(path, 'r') as f:
                content = f.read()
            if len(content) > 15000:
                content = content[:15000] + "\n\n... (truncated)"
            return content
        except FileNotFoundError:
            return f"File not found: {inputs['path']}"
        except Exception as e:
            return f"Error: {e}"

    elif name == "search_code":
        import subprocess
        pattern = inputs["pattern"]
        glob_pat = inputs.get("glob", "*.dart")
        try:
            result = subprocess.run(
                ["grep", "-rn", "--include", glob_pat, pattern, PROJECT_ROOT],
                capture_output=True, text=True, timeout=10
            )
            output = result.stdout[:8000] if result.stdout else "No matches found"
            return output
        except Exception as e:
            return f"Search error: {e}"

    elif name == "list_builtin_functions":
        path = os.path.join(PROJECT_ROOT, "lib/json_ui/interpreter.dart")
        try:
            with open(path, 'r') as f:
                content = f.read()
            funcs = sorted(set(re.findall(r"'(@\w+)'", content)))
            return "可用的内置函数:\n" + "\n".join(funcs)
        except Exception as e:
            return f"Error: {e}"

    elif name == "list_templates":
        tpl_dir = os.path.join(PROJECT_ROOT, "templates")
        try:
            files = sorted(f for f in os.listdir(tpl_dir) if f.endswith('.json'))
            result = []
            for f in files:
                path = os.path.join(tpl_dir, f)
                try:
                    with open(path, 'r', encoding='utf-8') as fh:
                        data = json.load(fh)
                    meta = data.get("meta", {})
                    name_str = meta.get("name", f)
                    desc = meta.get("description", "")
                    result.append(f"- {f}: {name_str} — {desc}")
                except Exception:
                    result.append(f"- {f}: (parse error)")
            return "可参考的模板 APP:\n" + "\n".join(result) + "\n\n用 read_file('templates/xxx.json') 读取完整内容作为参考"
        except Exception as e:
            return f"Error: {e}"

    return f"Unknown tool: {name}"

@app.route("/chat", methods=["POST"])
@require_auth
def chat():
    """SSE 流式 AI 对话 — Claude Agent + 工具调用"""
    user_id = request.supabase_user.get("id")
    role = request.user_role

    # 配额检查
    used, limit, remaining = _get_quota_info(user_id, role)
    if remaining <= 0:
        return jsonify({
            "error": f"今日对话次数已用完（{used}/{limit}）",
            "quota": {"used": used, "limit": limit, "remaining": 0},
        }), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    if not messages:
        return jsonify({"error": "messages is required"}), 400

    provider_id = body.get("provider", DEFAULT_PROVIDER)
    agent_client = _get_agent_client(provider_id)
    agent_model = _get_agent_model(provider_id)

    # 构建 Agent 消息（过滤 system，Anthropic 用单独 system 参数）
    agent_messages = []
    for m in messages:
        if m["role"] == "system":
            continue
        agent_messages.append({"role": m["role"], "content": m["content"]})

    # 系统提示
    system_prompt = AGENT_SYSTEM
    registry = _load_registry_summary()
    if registry:
        system_prompt += f"\n## 已注册的 APP 和组件\n{registry}"

    # 递增配额
    _increment_quota(user_id)
    new_remaining = remaining - 1

    def generate():
        full_content = ""
        msgs = list(agent_messages)

        try:
            for iteration in range(AGENT_MAX_ITERATIONS):
                print(f"[Agent] Iteration {iteration + 1}, messages={len(msgs)}")

                # 流式调用 — 文本实时推送给客户端，工具调用在结束后处理
                response = None
                try:
                    with agent_client.messages.stream(
                        model=agent_model,
                        max_tokens=8192,
                        system=system_prompt,
                        messages=msgs,
                        tools=AGENT_TOOLS,
                    ) as stream:
                        for text in stream.text_stream:
                            full_content += text
                            yield f'data: {json.dumps({"content": text}, ensure_ascii=False)}\n\n'
                        response = stream.get_final_message()
                except Exception as e:
                    # 流式不支持时 fallback 到非流式
                    print(f"[Agent] Stream failed ({e}), falling back to non-stream")
                    response = agent_client.messages.create(
                        model=agent_model,
                        max_tokens=8192,
                        system=system_prompt,
                        messages=msgs,
                        tools=AGENT_TOOLS,
                    )
                    # 非流式：手动发送文本
                    for block in response.content:
                        if block.type == 'text' and block.text:
                            full_content += block.text
                            yield f'data: {json.dumps({"content": block.text}, ensure_ascii=False)}\n\n'

                # 检查是否有工具调用
                tool_calls = [b for b in response.content if b.type == 'tool_use']
                if not tool_calls:
                    print(f"[Agent] Done after {iteration + 1} iterations")
                    break

                # 构建 assistant 消息（包含 text + tool_use blocks）
                assistant_content = []
                for block in response.content:
                    if block.type == 'text':
                        assistant_content.append({"type": "text", "text": block.text})
                    elif block.type == 'tool_use':
                        assistant_content.append({
                            "type": "tool_use",
                            "id": block.id,
                            "name": block.name,
                            "input": block.input,
                        })
                msgs.append({"role": "assistant", "content": assistant_content})

                # 执行工具
                tool_results = []
                for tc in tool_calls:
                    result = _execute_agent_tool(tc.name, tc.input)
                    print(f"[Agent] Tool {tc.name}: {len(result)} chars")
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tc.id,
                        "content": result,
                    })
                msgs.append({"role": "user", "content": tool_results})

            # JSON-APP 检测
            json_match = re.search(r'```(?:json|JSON)?\s*\n?\s*(\{.*?\})\s*\n?```', full_content, re.DOTALL)
            if not json_match:
                json_match = re.search(r'(\{[\s\S]*"screens"[\s\S]*\})\s*$', full_content)
            print(f"[Agent] JSON detect: match={'YES' if json_match else 'NO'}, content_len={len(full_content)}")
            if json_match:
                try:
                    json_app = json.loads(json_match.group(1))
                    yield f'data: {json.dumps({"has_json": True, "json_app": json_app}, ensure_ascii=False)}\n\n'
                    print(f"[Agent] JSON-APP sent, keys: {list(json_app.keys())}")
                except json.JSONDecodeError as e:
                    print(f"[Agent] JSON parse failed: {e}")

            # 配额
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        except Exception as e:
            print(f"[Agent] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )

# ═══════════════════════════════════════════════════════════
# AI 崩溃修复
# ═══════════════════════════════════════════════════════════

@app.route("/api/ai/fix-app", methods=["POST"])
@require_auth
def fix_app():
    """接收崩溃日志 + JSON，返回修复建议"""
    body = request.get_json(silent=True) or {}
    crash_log = body.get("crash_log", "")
    json_config = body.get("json_config", "")

    if not crash_log or not json_config:
        return jsonify({"error": "crash_log 和 json_config 不能为空"}), 400

    provider_id = body.get("provider", DEFAULT_PROVIDER)
    fix_client = _get_agent_client(provider_id)
    fix_model = _get_agent_model(provider_id)

    # 不额外消耗配额，但需要登录
    prompt = f"""以下 JSON-APP 运行时崩溃了，请修复：

## 崩溃日志
{crash_log}

## 当前 JSON
```json
{json_config if isinstance(json_config, str) else json.dumps(json_config, ensure_ascii=False, indent=2)}
```

请分析原因并输出修复后的完整 JSON（用 ```json 代码块包裹）。"""

    dsl_spec = _load_dsl_spec()
    system_prompt = f"你是 JSON-DSL 调试专家。\n\n## 规范\n{dsl_spec}"
    messages = [
        {"role": "user", "content": prompt},
    ]

    def generate():
        full_content = ""
        try:
            try:
                with fix_client.messages.stream(
                    model=fix_model,
                    max_tokens=8192,
                    system=system_prompt,
                    messages=messages,
                ) as stream:
                    for text in stream.text_stream:
                        full_content += text
                        yield f'data: {json.dumps({"content": text}, ensure_ascii=False)}\n\n'
            except Exception as e:
                print(f"[FixApp] Stream failed ({e}), falling back to non-stream")
                response = fix_client.messages.create(
                    model=fix_model,
                    max_tokens=8192,
                    system=system_prompt,
                    messages=messages,
                )
                for block in response.content:
                    if block.type == 'text' and block.text:
                        full_content += block.text
                        yield f'data: {json.dumps({"content": block.text}, ensure_ascii=False)}\n\n'

            json_match = re.search(r'```(?:json|JSON)?\s*\n?\s*(\{.*?\})\s*\n?```', full_content, re.DOTALL)
            if json_match:
                try:
                    fixed = json.loads(json_match.group(1))
                    yield f'data: {json.dumps({"has_json": True, "json_app": fixed}, ensure_ascii=False)}\n\n'
                except Exception: pass
            yield "data: [DONE]\n\n"
        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(stream_with_context(generate()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"})

# ═══════════════════════════════════════════════════════════
# App Store — 基于 app_registry + MinIO
# ═══════════════════════════════════════════════════════════

def _minio_upload(bucket, key, data, content_type="application/json"):
    """上传文件到 MinIO（使用 Python SDK）"""
    import io
    from minio import Minio
    client = Minio(
        "127.0.0.1:9000",
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=False,
    )
    if isinstance(data, dict):
        data = json.dumps(data, ensure_ascii=False, indent=2)
    data_bytes = data.encode("utf-8") if isinstance(data, str) else data

    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)

    client.put_object(
        bucket, key, io.BytesIO(data_bytes), len(data_bytes),
        content_type=content_type,
    )
    return f"{MINIO_PUBLIC_URL}/{bucket}/{key}"

@app.route("/api/store/apps", methods=["GET"])
def store_apps():
    """列出所有公开 APP"""
    rows = db_query(
        "SELECT id, name, version, description, author_name, download_url, tags, icon_url, meta_json FROM app_registry WHERE type = 'app' AND is_public = true ORDER BY created_at DESC",
        fetch_all=True
    )
    apps = []
    for row in rows:
        app_data = {
            "id": row["id"],
            "name": row["name"],
            "version": row["version"],
            "description": row["description"],
            "author": row["author_name"],
            "download_url": row["download_url"],
            "tags": row["tags"] or []
        }
        # 优先从 icon_url 字段读取，如果没有则从 meta_json 读取
        if row.get("icon_url"):
            app_data["icon_url"] = row["icon_url"]
        elif row.get("meta_json") and isinstance(row["meta_json"], dict):
            app_data["icon_url"] = row["meta_json"].get("icon_url", "")
        else:
            app_data["icon_url"] = ""
        apps.append(app_data)
    return jsonify({"apps": apps})

@app.route("/api/store/components", methods=["GET"])
def store_components():
    """列出所有公开组件"""
    rows = db_query(
        "SELECT id, name, version, description, author_name, download_url, icon_url FROM app_registry WHERE type = 'component' AND is_public = true ORDER BY name",
        fetch_all=True
    )
    components = []
    for row in rows:
        comp_data = {
            "id": row["id"],
            "name": row["name"],
            "version": row["version"],
            "description": row["description"],
            "author": row["author_name"],
            "download_url": row["download_url"],
            "icon_url": row.get("icon_url", "")
        }
        components.append(comp_data)
    return jsonify({"components": components})

@app.route("/api/appid/new", methods=["GET"])
@require_auth
def new_appid():
    """生成一个新的唯一 appid"""
    try:
        appid = _generate_appid()
        return jsonify({
            "appid": appid,
            "status": "success"
        })
    except Exception as e:
        return jsonify({
            "error": str(e),
            "status": "error"
        }), 500

@app.route("/api/store/publish", methods=["POST"])
@require_auth
@require_role("pro", "admin")
def store_publish():
    """发布 JSON-APP/组件到市场（支持新建和更新）"""
    try:
        return _do_store_publish()
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": f"服务器内部错误: {e}"}), 500

def _do_store_publish():
    body = request.get_json(silent=True) or {}
    json_content = body.get("json_content")
    force_update = body.get("force_update", False)
    if not json_content:
        return jsonify({"error": "json_content 不能为空"}), 400

    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "无效的 JSON"}), 400

    meta = json_content.get("meta", {})
    app_type = meta.get("type", "app")
    if app_type not in ("app", "component", "library"):
        return jsonify({"error": "meta.type 必须是 app 或 component"}), 400
    if app_type == "library":
        app_type = "component"

    name = meta.get("name", "unnamed")
    version = meta.get("version", "1.0.0")
    description = meta.get("description", "")
    dsl_spec = meta.get("dsl_spec", description)
    icon_url = meta.get("icon_url", "")

    app_id = json_content.get("appid")

    # appid 已存在 → 检测冲突或执行更新
    if app_id and _check_appid_exists(app_id):
        if not force_update:
            existing = db_query(
                "SELECT name, version, description FROM app_registry WHERE id = %s",
                [app_id], fetch_one=True
            )
            suggested = _increment_version(existing["version"])
            return jsonify({
                "conflict": True,
                "message": "该 appid 已存在，这将是一个更新操作",
                "existing": {
                    "appid": app_id,
                    "name": existing["name"],
                    "version": existing["version"],
                },
                "suggested_version": suggested,
            }), 409

        # force_update=true → 更新已有记录
        json_content["appid"] = app_id
        bucket = "json-app" if app_type == "app" else "json-component"
        oss_key = f"{app_id}/{name}-{version}.json"
        try:
            download_url = _minio_upload(bucket, oss_key, json_content)
        except Exception as e:
            return jsonify({"error": str(e)}), 502

        user = request.supabase_user
        author_name = user.get("user_metadata", {}).get("username", user.get("email", ""))
        db_execute(
            """UPDATE app_registry
               SET name = %s, version = %s, description = %s,
                   oss_key = %s, download_url = %s, meta_json = %s,
                   dsl_spec = %s, icon_url = %s
               WHERE id = %s""",
            [name, version, description, oss_key, download_url,
             json.dumps(meta, ensure_ascii=False), dsl_spec, icon_url, app_id]
        )
        return jsonify({
            "message": "更新成功",
            "appid": app_id,
            "download_url": download_url,
        })

    # 新 APP → 生成 appid 并 INSERT
    if not app_id:
        app_id = _generate_appid()
    json_content["appid"] = app_id

    bucket = "json-app" if app_type == "app" else "json-component"
    oss_key = f"{app_id}/{name}-{version}.json"
    try:
        download_url = _minio_upload(bucket, oss_key, json_content)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

    user = request.supabase_user
    user_id = user.get("id")
    author_name = user.get("user_metadata", {}).get("username", user.get("email", ""))
    db_execute(
        """INSERT INTO app_registry
           (id, type, name, version, description, author_id, author_name,
            oss_bucket, oss_key, download_url, meta_json, dsl_spec, icon_url)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        [
            app_id, app_type, name, version, description, user_id, author_name,
            bucket, oss_key, download_url,
            json.dumps(meta, ensure_ascii=False), dsl_spec, icon_url
        ]
    )

    return jsonify({
        "message": "发布成功",
        "appid": app_id,
        "download_url": download_url,
    })

@app.route("/api/store/delete/<app_id>", methods=["DELETE"])
@require_auth
def store_delete(app_id):
    """下架 APP/组件"""
    row = db_query("SELECT author_id FROM app_registry WHERE id = %s", [app_id], fetch_one=True)
    if not row:
        return jsonify({"error": "未找到"}), 404

    user_id = request.supabase_user.get("id")
    if str(row["author_id"]) != str(user_id) and request.user_role != "admin":
        return jsonify({"error": "只有作者或管理员可以删除"}), 403

    db_execute("DELETE FROM app_registry WHERE id = %s", [app_id])
    return jsonify({"message": "已删除"})

# ═══════════════════════════════════════════════════════════
# 兼容旧市场接口（从 templates/ 读取）
# ═══════════════════════════════════════════════════════════

@app.route("/app-list", methods=["GET"])
def app_list():
    """旧接口：列出 templates/ 目录下的 JSON 应用"""
    apps = []
    try:
        files = sorted(os.listdir(TEMPLATES_DIR))
        for f in files:
            if not f.endswith(".json"):
                continue
            try:
                with open(os.path.join(TEMPLATES_DIR, f), 'r', encoding='utf-8') as fh:
                    data = json.load(fh)
                meta = data.get("meta", {})
                apps.append({
                    "name": meta.get("name", f),
                    "version": meta.get("version", "1.0.0"),
                    "description": meta.get("description", ""),
                    "icon_url": meta.get("icon_url", ""),
                    "file": f,
                })
            except Exception:
                continue
    except Exception:
        pass
    return jsonify({"apps": apps})

@app.route("/download/<path:filename>", methods=["GET"])
def download_file(filename):
    """下载 templates/ 目录下的文件"""
    return send_from_directory(TEMPLATES_DIR, filename)

# ═══════════════════════════════════════════════════════════
# 启动
# ═══════════════════════════════════════════════════════════

if __name__ == "__main__":
    print(f"🚀 JSON DSL Backend on http://0.0.0.0:{PORT}")
    print("   Auth: /api/auth/{register,login,verify,refresh,logout,user,avatar,quota}")
    print("   Chat: POST /chat (SSE, quota-limited, DSL-aware)")
    print("   Fix: POST /api/ai/fix-app (crash repair)")
    print("   Store: /api/store/{apps,components,publish,delete}")
    print("   Providers: GET /api/ai/providers")
    print("   Old: /app-list, /download/<file>")
    print(f"   Available AI providers: {', '.join(AI_PROVIDERS.keys())}")
    app.run(host="0.0.0.0", port=PORT)
