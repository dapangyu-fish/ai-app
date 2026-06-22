#!/usr/bin/env python3
"""
配置模块 - 所有配置常量和环境变量
"""

import json
import os
import shutil
from dotenv import load_dotenv

try:
    from providers.registry import build_providers
    from providers.schema import (
        env_bool_for_prefix as _registry_env_bool_for_prefix,
        env_for_prefix as _registry_env_for_prefix,
        provider_prefix as _provider_prefix,
        split_csv as _split_csv,
    )
except ModuleNotFoundError:
    from backend.providers.registry import build_providers
    from backend.providers.schema import (
        env_bool_for_prefix as _registry_env_bool_for_prefix,
        env_for_prefix as _registry_env_for_prefix,
        provider_prefix as _provider_prefix,
        split_csv as _split_csv,
    )

# .env 加载顺序（首个存在的文件生效）：
#   1. $BACKEND_ENV_PATH 环境变量指定的路径（本地/临时调试用）
#   2. backend/.env             （仓库内位置，仅本地开发兜底）
# 当前 myapp-ctl 生产部署通过 Docker Compose env_file 注入
# /etc/myapp/secrets.d/*.env，不依赖这里的文件加载。
_env_candidates = [
    os.environ.get("BACKEND_ENV_PATH"),
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
# B1-G2: GoTrue HS256 JWT secret for LOCAL token verification on the FaaS invoke
# hot path (avoids a blocking GoTrue round-trip per call). Optional — when unset,
# invoke falls back to remote verify_access_token.
SUPABASE_JWT_SECRET = os.environ.get("SUPABASE_JWT_SECRET", "").strip()

def _env_for_prefix(prefix: str, key: str, default: str = "") -> str:
    return _registry_env_for_prefix(os.environ, prefix, key, default)


def _env_bool_for_prefix(prefix: str, key: str, default: str = "1") -> bool:
    return _registry_env_bool_for_prefix(os.environ, prefix, key, default)


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    try:
        return int(value)
    except ValueError:
        return default


# AI provider 配置入口。
#
# 非敏感默认值按 provider/agent adapter 存在 backend/providers/<provider>/<agent>/。
# 这里保持原有 AI_PROVIDERS dict 形状，避免影响 ai_session、claude_chat 和
# 生产 env 文件；真实 token 仍只从环境变量读取。
AI_PROVIDERS = build_providers(os.environ)

DEFAULT_PROVIDER = os.environ.get("AI_DEFAULT_PROVIDER", "deepseek").strip().lower().replace("_", "-") or "deepseek"
_VISIBLE_PROVIDER_IDS = [
    provider_id for provider_id, provider in AI_PROVIDERS.items()
    if provider.get("visible", True)
]
if DEFAULT_PROVIDER not in AI_PROVIDERS or not AI_PROVIDERS[DEFAULT_PROVIDER].get("visible", True):
    if "deepseek" in _VISIBLE_PROVIDER_IDS:
        DEFAULT_PROVIDER = "deepseek"
    elif _VISIBLE_PROVIDER_IDS:
        DEFAULT_PROVIDER = _VISIBLE_PROVIDER_IDS[0]
    else:
        DEFAULT_PROVIDER = "deepseek" if "deepseek" in AI_PROVIDERS else next(iter(AI_PROVIDERS))

# Registry 配置 —— 给 store.py 和 AI prompt 渲染用。
# 测试环境 docker compose 会注入 http://IP:port 覆盖；生产保持默认即可。
REGISTRY_BASE_URL = os.environ.get("REGISTRY_BASE_URL", "https://myapp-registry.dapangyu.work")

# User-generated FaaS backend code.
#
# The Agent never receives Git credentials. It can only produce a structured
# bundle in its workspace. The backend validates that bundle, writes it to
# FAAS_CODE_ROOT, optionally commits/pushes through host-local Git config, and
# starts the self-managed Docker FaaS container for the service.
FAAS_ENABLED = os.environ.get("FAAS_ENABLED", "1").strip().lower() in {"1", "true", "yes", "on"}
FAAS_REQUIRE_AUTH = os.environ.get("FAAS_REQUIRE_AUTH", "0").strip().lower() in {"1", "true", "yes", "on"}
# B3-G3: enforce the per-app access_policy ladder (owner-only/allowlist/install-
# required/public) on invoke, fail-closed + per-call live grant. Default OFF so
# existing open invoke isn't broken; flip on per-deployment once apps set policies.
FAAS_ENFORCE_ACCESS_POLICY = os.environ.get("FAAS_ENFORCE_ACCESS_POLICY", "0").strip().lower() in {"1", "true", "yes", "on"}
# B3-G7: per-(app, caller) invoke rate limit (requests/minute). 0 = disabled.
# Fail-open if Redis is unavailable (never blocks a legit call on infra blips).
FAAS_INVOKE_RATE_PER_MIN = _env_int("FAAS_INVOKE_RATE_PER_MIN", 0)
# B3-G7: per-app DB storage soft cap in MB (0 = disabled). Enforced at deploy time
# (a new deploy is rejected if the app's schema already exceeds the cap).
FAAS_APP_STORAGE_CAP_MB = _env_int("FAAS_APP_STORAGE_CAP_MB", 0)
# Even when FAAS_REQUIRE_AUTH is off (invoke stays open), a DEPLOY must be scoped
# to a trusted owner — the agent-node token path or a verified Bearer token — so a
# client cannot pass an arbitrary/rotating user_id to bypass the per-user service
# quota. Real deploys always go through the agent-node (trusted), so this is safe
# to default on.
FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER = os.environ.get(
    "FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER", "1"
).strip().lower() in {"1", "true", "yes", "on"}
# B0-G1 (R13): do NOT inject the Supabase anon key into every FaaS container by
# default. Owner code + an open egress could otherwise drive GoTrue's public auth
# surface (signup/recovery/OTP/anon-RLS). Functions that genuinely need it must be
# opted in explicitly. Default OFF (no anon key in the container).
FAAS_INJECT_SUPABASE_ANON_KEY = os.environ.get(
    "FAAS_INJECT_SUPABASE_ANON_KEY", "0"
).strip().lower() in {"1", "true", "yes", "on"}
# B1-G2 / A7: server-only secret for the app-scoped caller PSEUDONYM injected into
# FaaS functions. pseudonym = HMAC(secret, app_id || uid). Keeps the raw platform
# uid/token out of owner code and prevents an owner from reversing/​correlating a
# consumer across apps (the secret is server-only). Falls back to AGENT_NODE_TOKEN
# so a deployment that hasn't set it still gets a non-empty, non-guessable key.
FAAS_CALLER_PSEUDONYM_SECRET = (
    os.environ.get("FAAS_CALLER_PSEUDONYM_SECRET", "").strip()
    or os.environ.get("AGENT_NODE_TOKEN", "").strip()
)
FAAS_CODE_ROOT = os.environ.get("FAAS_CODE_ROOT", "/mnt/myapp/faas/code")
FAAS_MAX_SERVICES_PER_USER = _env_int("FAAS_MAX_SERVICES_PER_USER", 5)
FAAS_GIT_ENABLED = os.environ.get("FAAS_GIT_ENABLED", "1").strip().lower() in {"1", "true", "yes", "on"}
FAAS_GIT_PUSH_ENABLED = os.environ.get("FAAS_GIT_PUSH_ENABLED", "0").strip().lower() in {"1", "true", "yes", "on"}
FAAS_GIT_REMOTE = os.environ.get("FAAS_GIT_REMOTE", "").strip()
FAAS_GIT_BRANCH = os.environ.get("FAAS_GIT_BRANCH", "main").strip() or "main"
FAAS_GIT_AUTHOR_NAME = os.environ.get("FAAS_GIT_AUTHOR_NAME", "myapp-faas-bot").strip() or "myapp-faas-bot"
FAAS_GIT_AUTHOR_EMAIL = os.environ.get("FAAS_GIT_AUTHOR_EMAIL", "myapp-faas-bot@localhost").strip() or "myapp-faas-bot@localhost"
FAAS_GIT_SSH_KEY_PATH = os.environ.get("FAAS_GIT_SSH_KEY_PATH", "").strip()
FAAS_GIT_KNOWN_HOSTS_PATH = os.environ.get("FAAS_GIT_KNOWN_HOSTS_PATH", "").strip()
# Commit/push generated code through an isolated worker (outside the request path
# and outside Agent containers) instead of in-process during deploy.
FAAS_GIT_ASYNC_PUSH = os.environ.get("FAAS_GIT_ASYNC_PUSH", "1").strip().lower() in {"1", "true", "yes", "on"}
# Strict git source-of-truth: when set, the runtime bundle is served from this
# GitHub-pulled checkout (reconciled from FAAS_GIT_REMOTE) instead of the local
# write tree, so served code provably comes from git, not a backend-local write.
FAAS_BUNDLE_SERVE_ROOT = os.environ.get("FAAS_BUNDLE_SERVE_ROOT", "").rstrip("/")
# Self-managed Docker FaaS is the only runtime. 'local-docker' runs a container
# per service; 'metadata'/'none' are no-op modes used by tests/dev.
FAAS_DEPLOY_MODE = os.environ.get("FAAS_DEPLOY_MODE", "local-docker").strip().lower().replace("_", "-") or "local-docker"
FAAS_DEPLOY_SCRIPT = os.environ.get("FAAS_DEPLOY_SCRIPT", "").strip()
FAAS_RUNTIME_BUNDLE_BASE_URL = os.environ.get("FAAS_RUNTIME_BUNDLE_BASE_URL", "").rstrip("/")
FAAS_RUNTIME_TOKEN = os.environ.get("FAAS_RUNTIME_TOKEN", "").strip()
FAAS_PUBLIC_BASE_URL = os.environ.get("FAAS_PUBLIC_BASE_URL", "").rstrip("/")
# Optional public base URL for FaaS invokes, injected into every FaaS function as
# MYAPP_CFG_FAAS_PUBLIC_BASE_URL so generated code reads it from config instead of
# hardcoding a domain. Invokes normally go through the backend /api/faas/invoke proxy.
FAAS_NODE_PUBLIC_URL = os.environ.get("FAAS_NODE_PUBLIC_URL", "").rstrip("/")
FAAS_FUNCTION_PREFIX = os.environ.get("FAAS_FUNCTION_PREFIX", "myapp").strip().lower() or "myapp"
FAAS_LOCAL_DOCKER_IMAGE = os.environ.get(
    "FAAS_LOCAL_DOCKER_IMAGE",
    os.environ.get("MYAPP_FAAS_RUNTIME_IMAGE", "dapangyu/myapp-faas-runtime:agent-control-plane"),
).strip()
FAAS_LOCAL_DOCKER_NETWORK = os.environ.get("FAAS_LOCAL_DOCKER_NETWORK", "myapp_default").strip() or "myapp_default"
FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT = os.environ.get("FAAS_LOCAL_DOCKER_CONTAINER_CODE_ROOT", "/mnt/myapp/faas/code").rstrip("/")
FAAS_LOCAL_DOCKER_HOST_CODE_ROOT = os.environ.get("FAAS_LOCAL_DOCKER_HOST_CODE_ROOT", FAAS_CODE_ROOT).rstrip("/")
FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS = _env_int("FAAS_LOCAL_DOCKER_START_TIMEOUT_SECONDS", 15)
FAAS_LOCAL_DOCKER_START_ON_DEPLOY = os.environ.get("FAAS_LOCAL_DOCKER_START_ON_DEPLOY", "1").strip().lower() in {"1", "true", "yes", "on"}
FAAS_BUNDLE_MAX_BYTES = _env_int("FAAS_BUNDLE_MAX_BYTES", 512 * 1024)
FAAS_FILE_MAX_BYTES = _env_int("FAAS_FILE_MAX_BYTES", 256 * 1024)
FAAS_REQUIREMENTS_MAX_LINES = _env_int("FAAS_REQUIREMENTS_MAX_LINES", 40)

# Registry Mirror —— 上游 registry 地址。空字符串表示不开 mirror（独立运行）。
# 开启后：每 REGISTRY_MIRROR_SYNC_INTERVAL_SEC 秒拉一次上游 /mirror/manifest，
# 合并到本地索引；客户端请求镜像版本的文件时按需代理到上游 /mirror/file 并缓存到本地 MinIO。
REGISTRY_UPSTREAM = os.environ.get("REGISTRY_UPSTREAM", "").rstrip("/")
REGISTRY_MIRROR_SYNC_INTERVAL_SEC = int(os.environ.get("REGISTRY_MIRROR_SYNC_INTERVAL_SEC", "600"))

# MinIO 配置
MINIO_PUBLIC_URL = os.environ.get("MINIO_PUBLIC_URL", "https://myapp-oss-endpoint.dapangyu.work")
_minio_url_parts = MINIO_PUBLIC_URL.split("://")
_minio_default_secure = _minio_url_parts[0] == "https" if len(_minio_url_parts) > 1 else True
MINIO_SECURE = os.environ.get(
    "MINIO_SECURE",
    "true" if _minio_default_secure else "false",
).lower() in ("1", "true", "yes", "on")
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", _minio_url_parts[-1])
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
# 但保留以防未来加扩展时埋雷）。生产由 myapp-ctl compose env_file 注入。
# 空值时 app.py 会生成临时随机值并打 WARNING（仅本地开发兜底，重启后失效）。
FLASK_SECRET_KEY = os.environ.get("FLASK_SECRET_KEY", "")

# 路径配置
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get("SERVER_PROJECT_PATH", os.path.realpath(os.path.join(BASE_DIR, "..")))
TEMPLATES_DIR = os.path.join(PROJECT_ROOT, "templates")
DSL_SPEC_PATH = os.path.join(PROJECT_ROOT, "JSON-DSL.md")
PROMPTS_DIR = os.path.join(BASE_DIR, "prompts")
GENERATE_PROMPT_MODE = os.environ.get("AI_GENERATION_PROMPT_MODE", "indexed").strip().lower()
LEGACY_GENERATE_PROMPT_PATH = os.path.join(PROMPTS_DIR, "generate_app_prompt.md")
INDEXED_GENERATE_PROMPT_PATH = os.path.join(PROMPTS_DIR, "generate_app_prompt_indexed.md")
GENERATE_PROMPT_PATH = (
    LEGACY_GENERATE_PROMPT_PATH
    if GENERATE_PROMPT_MODE in ("legacy", "full")
    else INDEXED_GENERATE_PROMPT_PATH
)
GENERATION_PIPELINE_V1 = "json_dsl_v1"
GENERATION_PIPELINE_V2 = "dart_to_json_v2"
SUPPORTED_GENERATION_PIPELINES = {GENERATION_PIPELINE_V1, GENERATION_PIPELINE_V2}
AI_GENERATION_PIPELINE_DEFAULT = (
    os.environ.get("AI_GENERATION_PIPELINE_DEFAULT")
    or os.environ.get("AI_GENERATION_PIPELINE")
    or GENERATION_PIPELINE_V1
).strip().lower().replace("-", "_") or GENERATION_PIPELINE_V1
if AI_GENERATION_PIPELINE_DEFAULT not in SUPPORTED_GENERATION_PIPELINES:
    AI_GENERATION_PIPELINE_DEFAULT = GENERATION_PIPELINE_V1
CONFIG_CENTER_URL = os.environ.get("CONFIG_CENTER_URL", "").rstrip("/")
AI_GENERATION_PIPELINE_CONFIG_KEY = os.environ.get(
    "AI_GENERATION_PIPELINE_CONFIG_KEY",
    "ai_generation_pipeline",
).strip() or "ai_generation_pipeline"
AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS = max(
    1,
    _env_int("AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS", 30),
)
PIPELINE_PROMPTS_DIR = os.path.join(PROMPTS_DIR, "pipelines")
V2_PROMPT_DIR = os.path.join(PIPELINE_PROMPTS_DIR, GENERATION_PIPELINE_V2)
V2_PROMPT_FILES = (
    "system.md",
    "capability_inventory.md",
    "dart_subset.md",
    "dart_generation.md",
    "json_translation.md",
    "validation_upload.md",
)


def normalize_generation_pipeline(value: str | None) -> str:
    normalized = (value or "").strip().lower().replace("-", "_")
    if normalized in {"v1", "json", "json_dsl", "json_dsl_v1", "legacy"}:
        return GENERATION_PIPELINE_V1
    if normalized in {"v2", "dart", "dart_to_json", "dart_to_json_v2"}:
        return GENERATION_PIPELINE_V2
    return GENERATION_PIPELINE_V1


def generation_prompt_reference(pipeline: str | None = None) -> str:
    pipeline_id = normalize_generation_pipeline(pipeline or AI_GENERATION_PIPELINE_DEFAULT)
    if pipeline_id == GENERATION_PIPELINE_V2:
        return os.path.join(V2_PROMPT_DIR, "system.md")
    return GENERATE_PROMPT_PATH


def _load_v2_generate_prompt() -> str:
    parts = []
    for filename in V2_PROMPT_FILES:
        path = os.path.join(V2_PROMPT_DIR, filename)
        if not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            parts.append(f.read().strip())
    if not parts:
        raise FileNotFoundError(os.path.join(V2_PROMPT_DIR, "system.md"))
    return "\n\n".join(part for part in parts if part)


def load_generate_prompt(pipeline: str | None = None) -> str:
    """读取系统 prompt，**运行时**把硬编码的生产域名替换成当前环境实际地址。

    生产：REGISTRY_BASE_URL / MINIO_PUBLIC_URL 都是 dapangyu.work，replace 是 no-op
    测试环境：env 注入 http://IP:port，prompt 里 AI 看到的引用就指向测试服了
    （否则 AI 生成的 JSON-APP 会硬塞生产 URL，跑起来仍然访问生产）。
    """
    pipeline_id = normalize_generation_pipeline(pipeline or AI_GENERATION_PIPELINE_DEFAULT)
    if pipeline_id == GENERATION_PIPELINE_V2:
        content = _load_v2_generate_prompt()
    else:
        prompt_path = GENERATE_PROMPT_PATH
        if not os.path.isfile(prompt_path):
            prompt_path = LEGACY_GENERATE_PROMPT_PATH
        with open(prompt_path, "r", encoding="utf-8") as f:
            content = f.read()
    return (
        content
        .replace("https://myapp-registry.dapangyu.work", REGISTRY_BASE_URL)
        .replace("https://myapp-oss-endpoint.dapangyu.work", MINIO_PUBLIC_URL)
    )

# Claude CLI 路径（可通过环境变量覆盖）
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/root/.nvm/versions/node/v22.22.2/bin/claude")

# Codex CLI 运行配置。生产默认使用 npx 固定版本，不写 config.toml；
# token 通过 provider 的 CODEX_ENV_KEY 指向现有环境变量，不能出现在命令行参数里。
CODEX_BIN = os.environ.get("CODEX_BIN", "npx")
CODEX_NPX_PACKAGE = os.environ.get("CODEX_NPX_PACKAGE", "@openai/codex@0.136.0")
CODEX_NODE_BIN_DIR = os.environ.get("CODEX_NODE_BIN_DIR", "/root/.nvm/versions/node/v22.22.2/bin")
CODEX_NPM_CACHE = os.environ.get("CODEX_NPM_CACHE", "/var/lib/ai-app/codex-npm-cache")
CODEX_HOME = os.environ.get("CODEX_HOME", "/var/lib/ai-app/codex-home")
OPENCODE_BIN = os.environ.get("OPENCODE_BIN", "/usr/local/bin/opencode")
OPENCODE_HOME = os.environ.get("OPENCODE_HOME", "/var/lib/ai-app/opencode-home")


def _path_has_executable(exe: str, extra_dir: str = "") -> bool:
    if os.path.isabs(exe):
        return os.path.isfile(exe) and os.access(exe, os.X_OK)
    search_path = os.environ.get("PATH", "")
    if extra_dir:
        search_path = f"{extra_dir}{os.pathsep}{search_path}"
    return shutil.which(exe, path=search_path) is not None


def _agent_ids() -> list[str]:
    explicit = _split_csv(os.environ.get("AI_AGENT_IDS", ""))
    return explicit or ["claude", "codex", "opencode"]


def _build_agent(agent_id: str) -> dict:
    normalized = agent_id.strip().lower().replace("_", "-")
    prefix = _provider_prefix(normalized)
    if normalized == "claude":
        return {
            "id": "claude",
            "name": _env_for_prefix(prefix, "AGENT_NAME", "Claude Code"),
            "description": _env_for_prefix(prefix, "AGENT_DESCRIPTION", "Claude CLI runner"),
            "configured": bool(CLAUDE_BIN),
            "visible": _env_bool_for_prefix(prefix, "AGENT_VISIBLE", "1"),
        }
    if normalized == "codex":
        return {
            "id": "codex",
            "name": _env_for_prefix(prefix, "AGENT_NAME", "Codex"),
            "description": _env_for_prefix(prefix, "AGENT_DESCRIPTION", "Codex CLI runner"),
            "configured": _path_has_executable(CODEX_BIN, CODEX_NODE_BIN_DIR),
            "visible": _env_bool_for_prefix(prefix, "AGENT_VISIBLE", "1"),
        }
    if normalized == "opencode":
        return {
            "id": "opencode",
            "name": _env_for_prefix(prefix, "AGENT_NAME", "OpenCode"),
            "description": _env_for_prefix(prefix, "AGENT_DESCRIPTION", "OpenCode CLI runner"),
            "configured": _path_has_executable(OPENCODE_BIN, CODEX_NODE_BIN_DIR),
            "visible": _env_bool_for_prefix(prefix, "AGENT_VISIBLE", "1"),
        }
    return {
        "id": normalized,
        "name": _env_for_prefix(prefix, "AGENT_NAME", normalized),
        "description": _env_for_prefix(prefix, "AGENT_DESCRIPTION", "AI execution agent"),
        "configured": bool(os.environ.get(f"{prefix}_AGENT_CONFIGURED", "")),
        "visible": _env_bool_for_prefix(prefix, "AGENT_VISIBLE", "0"),
    }


AI_AGENTS = {
    agent_id: _build_agent(agent_id)
    for agent_id in _agent_ids()
}
DEFAULT_AGENT = os.environ.get("AI_DEFAULT_AGENT", "claude").strip().lower().replace("_", "-") or "claude"
_VISIBLE_AGENT_IDS = [
    agent_id for agent_id, agent in AI_AGENTS.items()
    if agent.get("visible", True)
]
if DEFAULT_AGENT not in AI_AGENTS or not AI_AGENTS[DEFAULT_AGENT].get("visible", True):
    DEFAULT_AGENT = "claude" if "claude" in _VISIBLE_AGENT_IDS else (_VISIBLE_AGENT_IDS[0] if _VISIBLE_AGENT_IDS else "claude")

# AI session Redis（独立部署的 ai-session-redis，与 OpenIM 那个 Redis 隔离）
# 数据：24h TTL 的 AI session 状态 + SSE 事件序列。详见 ARCHITECTURE.md §3
AI_SESSION_REDIS_HOST = os.environ.get("AI_SESSION_REDIS_HOST", "127.0.0.1")
AI_SESSION_REDIS_PORT = int(os.environ.get("AI_SESSION_REDIS_PORT", "16379"))
AI_SESSION_REDIS_PASSWORD = os.environ.get("AI_SESSION_REDIS_PASSWORD", "")
AI_SESSION_REDIS_TTL_SECONDS = int(os.environ.get("AI_SESSION_REDIS_TTL_SECONDS", "86400"))

# AI worker 并发上限。
# - AI_WORKER_MAX_CONCURRENCY / AI_WORKER_QUEUE_MAX 保留为全局总上限和默认队列上限。
# - <PROVIDER>_AI_WORKER_MAX_CONCURRENCY / <PROVIDER>_AI_WORKER_QUEUE_MAX 用于供应商级限流。
#   例：DEEPSEEK_AI_WORKER_MAX_CONCURRENCY=3，MINIMAX_AI_WORKER_QUEUE_MAX=20。
# - AI_WORKER_PROVIDER_DEFAULT_* 可给所有未显式配置的 provider 设置默认值。
# 瓶颈是同时跑的 Claude/Codex/OpenCode CLI 进程数、provider 限速和机器内存，不是 Redis 队列本身。
AI_WORKER_MAX_CONCURRENCY = max(1, _env_int("AI_WORKER_MAX_CONCURRENCY", 3))
AI_WORKER_QUEUE_MAX = max(0, _env_int("AI_WORKER_QUEUE_MAX", 50))
AI_WORKER_PROVIDER_DEFAULT_MAX_CONCURRENCY = max(
    1,
    _env_int("AI_WORKER_PROVIDER_DEFAULT_MAX_CONCURRENCY", AI_WORKER_MAX_CONCURRENCY),
)
AI_WORKER_PROVIDER_DEFAULT_QUEUE_MAX = max(
    0,
    _env_int("AI_WORKER_PROVIDER_DEFAULT_QUEUE_MAX", AI_WORKER_QUEUE_MAX),
)

# AI 执行后端：
# - local：保持旧行为，在 ai-worker 容器/进程内直接启动 Claude/Codex CLI；OpenCode 仅支持 agent-node。
# - agent-node：旧 direct 模式，ai-worker 主动连接 agent-node。
# - agent-pull：runner 模式，agent-node 主动拉任务并回传事件，适合内网节点。
# 默认 local 是为了向前兼容；生产容器化后由 compose/env 显式切到 agent-pull。
AI_WORKER_EXECUTION_BACKEND = (
    os.environ.get("AI_WORKER_EXECUTION_BACKEND", "local").strip().lower().replace("_", "-")
    or "local"
)
AGENT_NODE_URL = os.environ.get("AGENT_NODE_URL", "").rstrip("/")
AGENT_NODE_URLS = [
    item.rstrip("/")
    for item in _split_csv(os.environ.get("AGENT_NODE_URLS", ""))
    if item.rstrip("/")
]
if not AGENT_NODE_URLS and AGENT_NODE_URL:
    AGENT_NODE_URLS = [AGENT_NODE_URL]
AGENT_NODE_TOKEN = os.environ.get("AGENT_NODE_TOKEN", "")
AGENT_NODE_CONNECT_TIMEOUT_SECONDS = _env_int("AGENT_NODE_CONNECT_TIMEOUT_SECONDS", 10)
AGENT_NODE_EVENT_TIMEOUT_SECONDS = _env_int("AGENT_NODE_EVENT_TIMEOUT_SECONDS", 7200)
AGENT_NODE_ASSIGNMENT_TTL_SECONDS = _env_int("AGENT_NODE_ASSIGNMENT_TTL_SECONDS", 86400)
AGENT_NODE_REGISTRATION_TOKEN = os.environ.get("AGENT_NODE_REGISTRATION_TOKEN", AGENT_NODE_TOKEN)
AI_SERVER_REPAIR_MAX_ATTEMPTS = max(0, _env_int("AI_SERVER_REPAIR_MAX_ATTEMPTS", 3))


def _provider_worker_env_int(provider_id: str, key: str, default: int) -> int:
    prefix = _provider_prefix(provider_id)
    value = os.environ.get(f"{prefix}_{key}")
    if value is None and key.startswith("AI_WORKER_"):
        value = os.environ.get(f"{prefix}_{key.removeprefix('AI_')}")
    if value is None or value.strip() == "":
        return default
    try:
        return int(value)
    except ValueError:
        return default


AI_PROVIDER_WORKER_LIMITS = {}
for _provider_id in AI_PROVIDERS:
    _max_concurrency = max(
        0,
        _provider_worker_env_int(
            _provider_id,
            "AI_WORKER_MAX_CONCURRENCY",
            AI_WORKER_PROVIDER_DEFAULT_MAX_CONCURRENCY,
        ),
    )
    _queue_max = max(
        0,
        _provider_worker_env_int(
            _provider_id,
            "AI_WORKER_QUEUE_MAX",
            AI_WORKER_PROVIDER_DEFAULT_QUEUE_MAX,
        ),
    )
    AI_PROVIDER_WORKER_LIMITS[_provider_id] = {
        "max_concurrency": _max_concurrency,
        "queue_max": _queue_max,
    }
    AI_PROVIDERS[_provider_id]["worker"] = AI_PROVIDER_WORKER_LIMITS[_provider_id]

# Registry summary 富化：后台批量摘要的 CLI 小池（跟生成的大池隔离，饿不死用户生成）
SUMMARY_MAX_CONCURRENCY = _env_int("SUMMARY_MAX_CONCURRENCY", 3)
SUMMARY_CLI_TIMEOUT = _env_int("SUMMARY_CLI_TIMEOUT", 120)
SUMMARY_EXECUTION_BACKEND = (
    os.environ.get("SUMMARY_EXECUTION_BACKEND", "auto").strip().lower().replace("_", "-")
    or "auto"
)
SUMMARY_AGENT_NODE_URL = os.environ.get("SUMMARY_AGENT_NODE_URL", "").rstrip("/")


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

# FCM 配置（Android 推送）
# service-account.json 不进 git，存在服务器 /etc/fcm/，权限 600 给 root
# 从 Firebase Console → Project Settings → Service Accounts 下载
FCM_SERVICE_ACCOUNT_PATH = os.environ.get("FCM_SERVICE_ACCOUNT_PATH", "/etc/fcm/service-account.json")
# Firebase 项目 ID（如 myapp-4b49d）。空字符串时 fcm provider 推送会返回错误
FCM_PROJECT_ID = os.environ.get("FCM_PROJECT_ID", "")

# GeTui 配置（国内 Android / 可选 iOS 推送）
# 真实 AppID/AppKey/AppSecret/MasterSecret 由 myapp-ctl 写入
# /etc/myapp/secrets.d/push.env，不进 git。
GETUI_BASE_URL = os.environ.get("GETUI_BASE_URL", "https://restapi.getui.com/v2")
GETUI_APP_ID = os.environ.get("GETUI_APP_ID", "")
GETUI_APP_KEY = os.environ.get("GETUI_APP_KEY", "")
GETUI_APP_SECRET = os.environ.get("GETUI_APP_SECRET", "")
GETUI_MASTER_SECRET = os.environ.get("GETUI_MASTER_SECRET", "")
GETUI_TTL_MS = int(os.environ.get("GETUI_TTL_MS", str(2 * 60 * 60 * 1000)))
