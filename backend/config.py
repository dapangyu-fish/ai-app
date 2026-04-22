#!/usr/bin/env python3
"""
配置模块 - 所有配置常量和环境变量
"""

import os
from dotenv import load_dotenv

# 加载 .env 文件
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

# Supabase 配置
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://app-auth.dapangyu.work")
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
            "default": "deepseek-chat",
        },
        "agent_model": "deepseek-chat",
    },
    "glm": {
        "id": "glm",
        "name": "GLM (智谱)",
        "description": "智谱 GLM — 多模型系列",
        "type": "anthropic",
        "base_url": os.environ.get("GLM_ANTHROPIC_BASE_URL", "http://14.103.26.181"),
        "api_key": os.environ.get("GLM_ANTHROPIC_AUTH_TOKEN", "sk-FUsE9Q3QaEjHo7qnad7ffBINpQHkkETW16K8OXl26SHfRUfN"),
        "models": {
            "default": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
            "haiku": os.environ.get("GLM_ANTHROPIC_DEFAULT_HAIKU_MODEL", "glm-4.7"),
            "sonnet": os.environ.get("GLM_ANTHROPIC_DEFAULT_SONNET_MODEL", "glm-5-turbo"),
            "opus": os.environ.get("GLM_ANTHROPIC_DEFAULT_OPUS_MODEL", "glm-5.1"),
            "reasoning": os.environ.get("GLM_ANTHROPIC_REASONING_MODEL", "glm-5.1"),
        },
        "agent_model": os.environ.get("GLM_ANTHROPIC_MODEL", "glm-5"),
    },
    "cc": {
        "id": "cc",
        "name": "CC-4.7",
        "description": "CC Anthropic API Proxy",
        "type": "anthropic",
        "base_url": os.environ.get("CC_ANTHROPIC_BASE_URL", "https://cc-vibe.com"),
        "api_key": os.environ.get("CC_ANTHROPIC_AUTH_TOKEN", "sk-68900ea64051c89cbba31fa0a3f4198fdaffd8272c3d6b2ce3acf82bd098e6a5"),
        "models": {
            "default": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
            "opus": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
        },
        "agent_model": os.environ.get("CC_ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-4-7"),
        "extra_body": {
            "skipDangerousModePermissionPrompt": True
        }
    },
}

DEFAULT_PROVIDER = "deepseek"

# MinIO 配置
MINIO_PUBLIC_URL = os.environ.get("MINIO_PUBLIC_URL", "https://app-oss-endpoint.dapangyu.work")
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

# 路径配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get("SERVER_PROJECT_PATH", os.path.realpath(os.path.join(BASE_DIR, "..")))
TEMPLATES_DIR = os.path.join(PROJECT_ROOT, "templates")
DSL_SPEC_PATH = os.path.join(PROJECT_ROOT, "JSON-DSL.md")

# Agent 配置
AGENT_MAX_ITERATIONS = 8

# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}
