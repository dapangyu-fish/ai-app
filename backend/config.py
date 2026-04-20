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
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"
DEEPSEEK_MODEL = "deepseek-chat"

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

# Claude Agent 配置
AGENT_MODEL = "deepseek-chat"
AGENT_MAX_ITERATIONS = 8

# OpenIM 配置
OPENIM_API_URL = os.environ.get("OPENIM_API_URL", "http://127.0.0.1:10002")
OPENIM_WS_URL = os.environ.get("OPENIM_WS_URL", "ws://127.0.0.1:10001")
OPENIM_ADMIN_SECRET = os.environ.get("OPENIM_ADMIN_SECRET", "openIM_secret_2024")

# 角色配额
ROLE_QUOTAS = {"user": 30, "pro": 60, "admin": 999999}
