from __future__ import annotations

from .claude.adapter import ADAPTER as CLAUDE_ADAPTER
from .codex.adapter import ADAPTER as CODEX_ADAPTER
from .opencode.adapter import ADAPTER as OPENCODE_ADAPTER


PROVIDER = {
    "id": "minimax",
    "name": "MiniMax M3",
    "description": "MiniMax Anthropic-compatible and native Responses provider",
    "setup_description": "MiniMax Anthropic-compatible and native Responses provider",
    "visible": "1",
    "auth_env_fallbacks": (),
    "worker": {
        "max_concurrency": "5",
        "queue_max": "20",
    },
    "adapters": {
        "claude": CLAUDE_ADAPTER,
        "codex": CODEX_ADAPTER,
        "opencode": OPENCODE_ADAPTER,
    },
}

