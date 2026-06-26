from __future__ import annotations

from .codex.adapter import ADAPTER as CODEX_ADAPTER


PROVIDER = {
    "id": "native-codex",
    "name": "Native Codex GPT-5.5",
    "description": "Host Codex CLI plan login mounted into the isolated runtime",
    "setup_description": "Native Codex CLI plan login; no API token is stored by MyApp",
    "visible": "1",
    "auth_env_fallbacks": (),
    "worker": {
        "max_concurrency": "1",
        "queue_max": "20",
    },
    "adapters": {
        "codex": CODEX_ADAPTER,
    },
}

