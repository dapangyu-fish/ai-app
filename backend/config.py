#!/usr/bin/env python3
"""
配置模块 - 所有配置常量和环境变量
"""

import os
import shutil
from dotenv import load_dotenv

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

# Anthropic-compatible Claude CLI provider 配置。
#
# 内置 provider 只放非敏感默认值；token 只从环境变量读取，不能进仓库。
# 后续新增供应商优先用环境变量，不需要改代码：
#   AI_PROVIDER_IDS=deepseek,minimax,my-provider
#   MY_PROVIDER_ANTHROPIC_BASE_URL=https://example.com/anthropic
#   MY_PROVIDER_ANTHROPIC_AUTH_TOKEN=...
#   MY_PROVIDER_ANTHROPIC_MODEL=my-model
#
# 如果没有配置 AI_PROVIDER_IDS，系统默认保留 deepseek，并自动发现已
# 配置 Anthropic adapter 或 Codex Responses adapter 的 provider。已下线
# 的旧 provider 即使旧环境文件里残留变量也不会被自动注册。
_LEGACY_DISABLED_PROVIDER_IDS = {"glm", "cc"}
_ANTHROPIC_PROVIDER_SUFFIXES = (
    "_ANTHROPIC_BASE_URL",
    "_ANTHROPIC_AUTH_TOKEN",
    "_ANTHROPIC_MODEL",
    "_ANTHROPIC_DEFAULT_OPUS_MODEL",
    "_ANTHROPIC_DEFAULT_SONNET_MODEL",
    "_ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "_CODEX_BASE_URL",
    "_CODEX_MODEL",
    "_CODEX_ENV_KEY",
    "_CODEX_AUTH_TOKEN",
)
_BUILTIN_ANTHROPIC_PROVIDERS = {
    "deepseek": {
        "name": "DeepSeek V4 Pro",
        "description": "DeepSeek Anthropic-compatible Claude Code provider",
        "base_url": "https://api.deepseek.com/anthropic",
        "model": "deepseek-v4-pro[1m]",
        "auth_env_fallbacks": (),
        "visible": "1",
    },
    "minimax": {
        "name": "MiniMax M3",
        "description": "MiniMax native Responses provider for Codex",
        "base_url": "https://api.minimaxi.com/anthropic",
        "model": "MiniMax-M3",
        "auth_env_fallbacks": (),
        "visible": "1",
        # MiniMax's Anthropic endpoint is not currently stable with Claude Code
        # streaming JSON parsing. Keep the token/env shape for Codex, but only
        # expose the verified native Responses adapter by default.
        "supported_agents": ("codex",),
        "codex": {
            "provider_name": "MiniMax",
            "base_url": "https://api.minimaxi.com/v1",
            "model": "MiniMax-M3",
            "wire_api": "responses",
            "env_key": "MINIMAX_ANTHROPIC_AUTH_TOKEN",
            "context_window": 512000,
        },
    },
}


def _split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def _provider_prefix(provider_id: str) -> str:
    return "".join(ch.upper() if ch.isalnum() else "_" for ch in provider_id)


def _provider_id_from_prefix(prefix: str) -> str:
    return prefix.lower().replace("_", "-")


def _env_for_prefix(prefix: str, key: str, default: str = "") -> str:
    value = os.environ.get(f"{prefix}_{key}")
    return value if value is not None else default


def _env_bool_for_prefix(prefix: str, key: str, default: str = "1") -> bool:
    value = os.environ.get(f"{prefix}_{key}")
    if value is None and key == "PROVIDER_VISIBLE":
        value = os.environ.get(f"{prefix}_VISIBLE")
    if value is None:
        value = default
    value = value.strip().lower()
    return value not in {"0", "false", "no", "off", "disabled", "hidden"}


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _provider_auth_token(provider_id: str, prefix: str, builtin: dict) -> str:
    token = _env_for_prefix(prefix, "ANTHROPIC_AUTH_TOKEN")
    if token:
        return token
    for env_name in builtin.get("auth_env_fallbacks", ()):
        fallback = os.environ.get(env_name, "")
        if fallback:
            return fallback
    return ""


def _provider_has_auth_env(provider_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    if os.environ.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", ""):
        return True
    codex_env_key = os.environ.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN")
    if (
        os.environ.get(f"{prefix}_CODEX_BASE_URL", "")
        and os.environ.get(f"{prefix}_CODEX_MODEL", "")
        and codex_env_key
        and os.environ.get(codex_env_key, "")
    ):
        return True
    builtin = _BUILTIN_ANTHROPIC_PROVIDERS.get(provider_id, {})
    return any(os.environ.get(env_name, "") for env_name in builtin.get("auth_env_fallbacks", ()))


def _discover_anthropic_provider_ids() -> list[str]:
    explicit_ids = _split_csv(os.environ.get("AI_PROVIDER_IDS", ""))
    if explicit_ids:
        provider_ids = explicit_ids
    else:
        provider_ids = ["deepseek"]
        if _provider_has_auth_env("minimax"):
            provider_ids.append("minimax")

    for env_name in os.environ:
        for suffix in _ANTHROPIC_PROVIDER_SUFFIXES:
            if not env_name.endswith(suffix):
                continue
            prefix = env_name[: -len(suffix)]
            if prefix in {"", "ANTHROPIC"}:
                continue
            provider_id = _provider_id_from_prefix(prefix)
            if provider_id in _LEGACY_DISABLED_PROVIDER_IDS:
                continue
            if provider_id in provider_ids:
                continue
            # 自动发现只接受已配置 token 的供应商，避免仅有默认 base_url 时污染列表。
            codex_env_key = os.environ.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN")
            if (
                os.environ.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", "")
                or (
                    os.environ.get(f"{prefix}_CODEX_BASE_URL", "")
                    and os.environ.get(f"{prefix}_CODEX_MODEL", "")
                    and codex_env_key
                    and os.environ.get(codex_env_key, "")
                )
            ):
                provider_ids.append(provider_id)
            break

    result = []
    seen = set()
    for provider_id in provider_ids:
        normalized = provider_id.strip().lower().replace("_", "-")
        if not normalized or normalized in _LEGACY_DISABLED_PROVIDER_IDS or normalized in seen:
            continue
        seen.add(normalized)
        result.append(normalized)
    return result or ["deepseek"]


def _build_anthropic_provider(provider_id: str) -> dict:
    prefix = _provider_prefix(provider_id)
    builtin = _BUILTIN_ANTHROPIC_PROVIDERS.get(provider_id, {})
    default_model = builtin.get("model", "")

    base_url = _env_for_prefix(prefix, "ANTHROPIC_BASE_URL", builtin.get("base_url", ""))
    auth_token = _provider_auth_token(provider_id, prefix, builtin)
    model = _env_for_prefix(prefix, "ANTHROPIC_MODEL", default_model)
    opus_model = _env_for_prefix(prefix, "ANTHROPIC_DEFAULT_OPUS_MODEL", model)
    sonnet_model = _env_for_prefix(prefix, "ANTHROPIC_DEFAULT_SONNET_MODEL", model)
    haiku_model = _env_for_prefix(prefix, "ANTHROPIC_DEFAULT_HAIKU_MODEL", model)
    subagent_model = _env_for_prefix(prefix, "CLAUDE_CODE_SUBAGENT_MODEL", model)
    effort_level = _env_for_prefix(prefix, "CLAUDE_CODE_EFFORT_LEVEL", "max")
    timeout_ms = _env_for_prefix(prefix, "API_TIMEOUT_MS", "600000")

    cli_env = {
        "ANTHROPIC_BASE_URL": base_url,
        "ANTHROPIC_AUTH_TOKEN": auth_token,
        "ANTHROPIC_MODEL": model,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": opus_model,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnet_model,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": haiku_model,
        "CLAUDE_CODE_SUBAGENT_MODEL": subagent_model,
        "CLAUDE_CODE_EFFORT_LEVEL": effort_level,
        "API_TIMEOUT_MS": timeout_ms,
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": _env_for_prefix(
            prefix, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"
        ),
    }

    anthropic_configured = bool(base_url and auth_token and model)
    return {
        "id": provider_id,
        "name": _env_for_prefix(prefix, "PROVIDER_NAME", builtin.get("name", provider_id)),
        "description": _env_for_prefix(
            prefix,
            "PROVIDER_DESCRIPTION",
            builtin.get("description", "Anthropic-compatible Claude Code provider"),
        ),
        "type": "anthropic",
        "base_url": base_url,
        "api_key": auth_token,
        "models": {
            "default": model,
            "haiku": haiku_model,
            "sonnet": sonnet_model,
            "opus": opus_model,
        },
        "agent_model": subagent_model,
        "cli_env": cli_env,
        "cli_model": model,
        "supported_agents": _split_csv(_env_for_prefix(
            prefix,
            "SUPPORTED_AGENTS",
            ",".join(builtin.get("supported_agents", ())),
        )),
        "anthropic_configured": anthropic_configured,
        "configured": anthropic_configured,
        "visible": _env_bool_for_prefix(
            prefix,
            "PROVIDER_VISIBLE",
            builtin.get("visible", "1"),
        ),
    }


AI_PROVIDERS = {
    provider_id: _build_anthropic_provider(provider_id)
    for provider_id in _discover_anthropic_provider_ids()
}

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


def load_generate_prompt() -> str:
    """读取系统 prompt，**运行时**把硬编码的生产域名替换成当前环境实际地址。

    生产：REGISTRY_BASE_URL / MINIO_PUBLIC_URL 都是 dapangyu.work，replace 是 no-op
    测试环境：env 注入 http://IP:port，prompt 里 AI 看到的引用就指向测试服了
    （否则 AI 生成的 JSON-APP 会硬塞生产 URL，跑起来仍然访问生产）。
    """
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


def _path_has_executable(exe: str, extra_dir: str = "") -> bool:
    if os.path.isabs(exe):
        return os.path.isfile(exe) and os.access(exe, os.X_OK)
    search_path = os.environ.get("PATH", "")
    if extra_dir:
        search_path = f"{extra_dir}{os.pathsep}{search_path}"
    return shutil.which(exe, path=search_path) is not None


def _provider_codex_config(provider_id: str, prefix: str, builtin: dict) -> dict:
    default_codex = builtin.get("codex", {})
    model = _env_for_prefix(prefix, "CODEX_MODEL", default_codex.get("model", ""))
    base_url = _env_for_prefix(prefix, "CODEX_BASE_URL", default_codex.get("base_url", ""))
    env_key = _env_for_prefix(
        prefix,
        "CODEX_ENV_KEY",
        default_codex.get("env_key", f"{prefix}_CODEX_AUTH_TOKEN"),
    )
    wire_api = _env_for_prefix(prefix, "CODEX_WIRE_API", default_codex.get("wire_api", "responses"))
    context_window = _env_for_prefix(
        prefix,
        "CODEX_CONTEXT_WINDOW",
        str(default_codex.get("context_window", "")),
    )
    provider_name = _env_for_prefix(prefix, "CODEX_PROVIDER_NAME", default_codex.get("provider_name", provider_id))
    auth_token = os.environ.get(env_key, "") if env_key else ""
    return {
        "provider_name": provider_name,
        "base_url": base_url,
        "model": model,
        "wire_api": wire_api,
        "env_key": env_key,
        "context_window": context_window,
        "configured": bool(base_url and model and env_key and auth_token),
    }


for _provider_id, _provider in AI_PROVIDERS.items():
    _provider["codex"] = _provider_codex_config(
        _provider_id,
        _provider_prefix(_provider_id),
        _BUILTIN_ANTHROPIC_PROVIDERS.get(_provider_id, {}),
    )
    _provider["configured"] = bool(
        _provider.get("anthropic_configured")
        or ((_provider.get("codex") or {}).get("configured"))
    )


def _agent_ids() -> list[str]:
    explicit = _split_csv(os.environ.get("AI_AGENT_IDS", ""))
    return explicit or ["claude", "codex"]


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
# 瓶颈是同时跑的 Claude/Codex CLI 进程数、provider 限速和机器内存，不是 Redis 队列本身。
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
# - local：保持旧行为，在 ai-worker 容器/进程内直接启动 Claude/Codex CLI。
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
