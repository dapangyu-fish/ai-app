#!/usr/bin/env python3
"""
配置模块 - 所有配置常量和环境变量
"""

import os
from dotenv import load_dotenv

# .env 加载顺序（首个存在的文件生效）：
#   1. $BACKEND_ENV_PATH 环境变量指定的路径（生产环境用 supervisor 注入）
#   2. /etc/ai-app/backend.env （系统标准位置，root:root 600）
#   3. backend/.env             （仓库内位置，仅本地开发兜底）
# 这样 prod 的 secret 不放在 git 工作树里，git pull / checkout 都不会受影响。
_env_candidates = [
    os.environ.get("BACKEND_ENV_PATH"),
    "/etc/ai-app/backend.env",
    os.path.join(os.path.dirname(__file__), ".env"),
]
for _p in _env_candidates:
    if _p and os.path.isfile(_p):
        load_dotenv(_p)
        break

# Supabase 配置
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://myapp-auth.dapangyu.work")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")

# DeepSeek 配置
DEEPSEEK_KEY = os.environ.get("DEEPSEEK_KEY", "")

# AI 供应商注册表
AI_PROVIDERS = {
    "deepseek": {
        "id": "deepseek",
        "name": "DeepSeek",
        "description": "DeepSeek AI — 通用对话模型",
        "type": "anthropic",
        "base_url": "https://api.deepseek.com/anthropic",
        "api_key": DEEPSEEK_KEY,
        "models": {
            "default": "deepseek-v4-pro",
        },
        "agent_model": "deepseek-v4-pro",
        "cli_env": {
            "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
            "ANTHROPIC_AUTH_TOKEN": DEEPSEEK_KEY,
            "ANTHROPIC_MODEL": "deepseek-v4-pro",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-pro",
            "API_TIMEOUT_MS": "600000",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        },
        "cli_model": "deepseek-v4-pro",
    },
    "glm": {
        "id": "glm",
        "name": "GLM (智谱)",
        "description": "智谱 GLM — 多模型系列",
        "type": "anthropic",
        "base_url": os.environ.get("GLM_ANTHROPIC_BASE_URL", ""),
        "api_key": os.environ.get("GLM_ANTHROPIC_AUTH_TOKEN", ""),
        "models": {
            "default": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
            "haiku": os.environ.get("GLM_ANTHROPIC_DEFAULT_HAIKU_MODEL", "glm-4.7"),
            "sonnet": os.environ.get("GLM_ANTHROPIC_DEFAULT_SONNET_MODEL", "glm-5-turbo"),
            "opus": os.environ.get("GLM_ANTHROPIC_DEFAULT_OPUS_MODEL", "glm-5.1"),
            "reasoning": os.environ.get("GLM_ANTHROPIC_REASONING_MODEL", "glm-5.1"),
        },
        "agent_model": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
        "cli_env": {
            "ANTHROPIC_BASE_URL": os.environ.get("GLM_ANTHROPIC_BASE_URL", ""),
            "ANTHROPIC_AUTH_TOKEN": os.environ.get("GLM_ANTHROPIC_AUTH_TOKEN", ""),
            "ANTHROPIC_MODEL": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ.get("GLM_ANTHROPIC_DEFAULT_HAIKU_MODEL", "glm-4.7"),
            "API_TIMEOUT_MS": "600000",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        },
        "cli_model": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
    },
    "cc": {
        "id": "cc",
        "name": "CC-4.7",
        "description": "CC Anthropic API Proxy",
        "type": "anthropic",
        "base_url": os.environ.get("CC_ANTHROPIC_BASE_URL", ""),
        "api_key": os.environ.get("CC_ANTHROPIC_AUTH_TOKEN", ""),
        "models": {
            "default": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
            "opus": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
        },
        "agent_model": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
        "extra_body": {
            "skipDangerousModePermissionPrompt": True
        },
        "cli_env": {
            "ANTHROPIC_BASE_URL": os.environ.get("CC_ANTHROPIC_BASE_URL", ""),
            "ANTHROPIC_AUTH_TOKEN": os.environ.get("CC_ANTHROPIC_AUTH_TOKEN", ""),
            "ANTHROPIC_MODEL": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
            "API_TIMEOUT_MS": "600000",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        },
        "cli_model": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
    },
}

DEFAULT_PROVIDER = "deepseek"

# Registry 配置 —— 给 store.py 和 AI prompt 渲染用。
# 测试环境 docker compose 会注入 http://IP:port 覆盖；生产保持默认即可。
REGISTRY_BASE_URL = os.environ.get("REGISTRY_BASE_URL", "https://myapp-registry.dapangyu.work")

# Registry Mirror —— 上游 registry 地址。空字符串表示不开 mirror（独立运行）。
# 开启后：每 REGISTRY_MIRROR_SYNC_INTERVAL_SEC 秒拉一次上游 /mirror/manifest，
# 合并到本地索引；客户端请求镜像版本的文件时按需代理到上游 /mirror/file 并缓存到本地 MinIO。
REGISTRY_UPSTREAM = os.environ.get("REGISTRY_UPSTREAM", "").rstrip("/")
REGISTRY_MIRROR_SYNC_INTERVAL_SEC = int(os.environ.get("REGISTRY_MIRROR_SYNC_INTERVAL_SEC", "600"))

# MinIO 配置
MINIO_PUBLIC_URL = os.environ.get("MINIO_PUBLIC_URL", "https://myapp-oss-endpoint.dapangyu.work")
_minio_url_parts = MINIO_PUBLIC_URL.split("://")
MINIO_SECURE = _minio_url_parts[0] == "https" if len(_minio_url_parts) > 1 else True
MINIO_ENDPOINT = _minio_url_parts[-1]
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "")

# PostgreSQL 配置
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5433"))
DB_NAME = os.environ.get("DB_NAME", "jsonapp")
DB_USER = os.environ.get("DB_USER", "jsonapp")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

# 服务器配置
PORT = int(os.environ.get("PORT", "5566"))

# Flask SECRET_KEY —— 给 session/CSRF 等扩展签名用（当前业务没用 session，
# 但保留以防未来加扩展时埋雷）。生产从 /etc/ai-app/backend.env 注入。
# 空值时 app.py 会生成临时随机值并打 WARNING（仅本地开发兜底，重启后失效）。
FLASK_SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", "")

# 路径配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get("SERVER_PROJECT_PATH", os.path.realpath(os.path.join(BASE_DIR, "..")))
TEMPLATES_DIR = os.path.join(PROJECT_ROOT, "templates")
DSL_SPEC_PATH = os.path.join(PROJECT_ROOT, "JSON-DSL.md")
PROMPTS_DIR = os.path.join(BASE_DIR, "prompts")
GENERATE_PROMPT_PATH = os.path.join(PROMPTS_DIR, "generate_app_prompt.md")


def load_generate_prompt() -> str:
    """读取系统 prompt，**运行时**把硬编码的生产域名替换成当前环境实际地址。

    生产：REGISTRY_BASE_URL / MINIO_PUBLIC_URL 都是 dapangyu.work，replace 是 no-op
    测试环境：env 注入 http://IP:port，prompt 里 AI 看到的引用就指向测试服了
    （否则 AI 生成的 JSON-APP 会硬塞生产 URL，跑起来仍然访问生产）。
    """
    with open(GENERATE_PROMPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()
    return (
        content
        .replace("https://myapp-registry.dapangyu.work", REGISTRY_BASE_URL)
        .replace("https://myapp-oss-endpoint.dapangyu.work", MINIO_PUBLIC_URL)
    )

# Claude CLI 路径（可通过环境变量覆盖）
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/root/.nvm/versions/node/v22.22.2/bin/claude")

# AI session Redis（独立部署的 ai-session-redis，与 OpenIM 那个 Redis 隔离）
# 数据：24h TTL 的 AI session 状态 + SSE 事件序列。详见 ARCHITECTURE.md §3
AI_SESSION_REDIS_HOST = os.environ.get("AI_SESSION_REDIS_HOST", "127.0.0.1")
AI_SESSION_REDIS_PORT = int(os.environ.get("AI_SESSION_REDIS_PORT", "16379"))
AI_SESSION_REDIS_PASSWORD = os.environ.get("AI_SESSION_REDIS_PASSWORD", "")
AI_SESSION_REDIS_TTL_SECONDS = int(os.environ.get("AI_SESSION_REDIS_TTL_SECONDS", "86400"))

# AI worker 并发上限（线程池大小）
# eventlet monkey_patch 后 thread 实际是 greenlet，开销低；瓶颈是同时跑的 claude CLI 进程数 + RAM
AI_WORKER_MAX_CONCURRENCY = int(os.environ.get("AI_WORKER_MAX_CONCURRENCY", "200"))


# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}

# OpenIM 配置（全部走 .env，不再硬编码）
OPENIM_API_URL = os.environ.get("OPENIM_API_URL", "")
OPENIM_WS_URL = os.environ.get("OPENIM_WS_URL", "")
OPENIM_SECRET = os.environ.get("OPENIM_SECRET", "")
OPENIM_PLATFORM_IOS = 1     # OpenIM SDK 平台号：1=iOS / 2=Android / 5=Web / 7=Linux / 8=Windows / 9=macOS
OPENIM_PLATFORM_WEB = 5     # 后端代签 token 时用（web 端就用 5）

# OpenIM webhook 共享密钥
# OpenIM 调我们 /api/im/offline_push_hook 时不带任何 auth header，我们自己加一个简易 secret
# 通过 query string ?secret=xxx 或 header X-OpenIM-Webhook-Secret 校验
OPENIM_WEBHOOK_SECRET = os.environ.get("OPENIM_WEBHOOK_SECRET", "")

# APNs 配置（仅 iOS 推送）
# .p8 私钥文件不进 git，存在服务器 /etc/apns/，权限 600 给 root
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "/etc/apns/AuthKey_8NM9U7CJCJ.p8")
APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "8NM9U7CJCJ")
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "5CD2U23TPH")
APNS_BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "dapangyu.fish.myapp")
# Sandbox & Production 共用同一把 .p8 key，host 不同
# 开发版 / TestFlight 默认走 sandbox；App Store 上线版走 production
APNS_USE_SANDBOX = os.environ.get("APNS_USE_SANDBOX", "true").lower() in ("1", "true", "yes")
