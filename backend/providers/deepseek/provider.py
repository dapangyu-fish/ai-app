from __future__ import annotations

from .claude.adapter import ADAPTER as CLAUDE_ADAPTER
from .codex.adapter import ADAPTER as CODEX_ADAPTER
from .opencode.adapter import ADAPTER as OPENCODE_ADAPTER


PROVIDER = {
    "id": "deepseek",
    "name": "DeepSeek V4 Pro",
    "description": "DeepSeek Anthropic-compatible Claude Code provider and Chat Completions Codex provider",
    "setup_description": "DeepSeek Anthropic-compatible Claude Code provider",
    "visible": "1",
    "auth_env_fallbacks": (),
    "worker": {
        "max_concurrency": "20",
        "queue_max": "100",
    },
    "adapters": {
        "claude": CLAUDE_ADAPTER,
        "codex": CODEX_ADAPTER,
        "opencode": OPENCODE_ADAPTER,
    },
}

