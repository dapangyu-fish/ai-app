"""Runtime selection for AI app generation pipelines.

The backend chooses the pipeline once when a chat turn is accepted, then stores
that value in the queued job/session metadata. Workers must use that frozen
value instead of reading config-center again, otherwise a config flip could
change the prompt halfway through a session turn.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

try:
    from config import (
        AI_GENERATION_PIPELINE_CONFIG_KEY,
        AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS,
        AI_GENERATION_PIPELINE_DEFAULT,
        CONFIG_CENTER_URL,
        GENERATION_PIPELINE_V1,
        normalize_generation_pipeline,
    )
except ModuleNotFoundError:
    from backend.config import (
        AI_GENERATION_PIPELINE_CONFIG_KEY,
        AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS,
        AI_GENERATION_PIPELINE_DEFAULT,
        CONFIG_CENTER_URL,
        GENERATION_PIPELINE_V1,
        normalize_generation_pipeline,
    )

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class GenerationPipelineSelection:
    id: str
    source: str
    raw_value: str


_cache_deadline = 0.0
_cache_payload: dict | None = None
_cache_etag: str | None = None


def _fallback(source: str = "fallback") -> GenerationPipelineSelection:
    pipeline = normalize_generation_pipeline(AI_GENERATION_PIPELINE_DEFAULT)
    return GenerationPipelineSelection(
        id=pipeline,
        source=source,
        raw_value=AI_GENERATION_PIPELINE_DEFAULT or GENERATION_PIPELINE_V1,
    )


def _fetch_config_center_payload() -> dict | None:
    global _cache_deadline, _cache_payload, _cache_etag
    now = time.monotonic()
    if _cache_payload is not None and now < _cache_deadline:
        return _cache_payload
    if not CONFIG_CENTER_URL:
        return None

    url = f"{CONFIG_CENTER_URL.rstrip('/')}/api/v1/public"
    headers = {}
    if _cache_etag:
        headers["If-None-Match"] = _cache_etag
    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=1.5) as response:
            if response.status == 304 and _cache_payload is not None:
                _cache_deadline = now + AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS
                return _cache_payload
            if response.status != 200:
                logger.warning("[GEN_PIPELINE] config-center HTTP %s", response.status)
                return _cache_payload
            body = response.read(128 * 1024)
            payload = json.loads(body.decode("utf-8"))
            if not isinstance(payload, dict):
                logger.warning("[GEN_PIPELINE] config-center payload is not object")
                return _cache_payload
            _cache_payload = payload
            _cache_etag = response.headers.get("ETag") or _cache_etag
            _cache_deadline = now + AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS
            return payload
    except HTTPError as exc:
        if exc.code == 304 and _cache_payload is not None:
            _cache_deadline = now + AI_GENERATION_PIPELINE_CONFIG_TTL_SECONDS
            return _cache_payload
        logger.warning("[GEN_PIPELINE] config-center HTTP error: %s", exc)
        if _cache_payload is not None:
            return _cache_payload
        return None
    except (URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        logger.warning("[GEN_PIPELINE] config-center fetch failed: %s", exc)
        if _cache_payload is not None:
            return _cache_payload
        return None


def resolve_generation_pipeline() -> GenerationPipelineSelection:
    """Return the pipeline for a newly accepted chat turn.

    This function is intentionally fail-open: if config-center is absent,
    slow, invalid, or returns an unsupported value, app generation keeps using
    the stable v1 chain.
    """

    payload = _fetch_config_center_payload()
    if payload is None:
        return _fallback("env_default")

    raw = str(payload.get(AI_GENERATION_PIPELINE_CONFIG_KEY) or "").strip()
    if not raw:
        return _fallback("config_center_missing")
    pipeline = normalize_generation_pipeline(raw)
    if pipeline == GENERATION_PIPELINE_V1 and raw.lower().replace("-", "_") not in {
        "v1",
        "json",
        "json_dsl",
        "json_dsl_v1",
        "legacy",
        GENERATION_PIPELINE_V1,
    }:
        logger.warning("[GEN_PIPELINE] unsupported pipeline %r, fallback to v1", raw)
        return GenerationPipelineSelection(
            id=GENERATION_PIPELINE_V1,
            source="config_center_invalid",
            raw_value=raw,
        )
    return GenerationPipelineSelection(
        id=pipeline,
        source="config_center",
        raw_value=raw,
    )
