#!/usr/bin/env python3
"""
配置模块 - 所有配置常量和环境变量
"""

import os

# Supabase 配置
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

# DeepSeek 配置
DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"

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

# MinIO 配置
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

# 服务器配置
PORT = 5566

# 路径配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.realpath(os.path.join(BASE_DIR, ".."))
TEMPLATES_DIR = os.path.join(PROJECT_ROOT, "templates")
DSL_SPEC_PATH = os.path.join(PROJECT_ROOT, "JSON-DSL.md")

# Agent 配置
AGENT_MAX_ITERATIONS = 8

# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}
