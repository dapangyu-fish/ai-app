#!/usr/bin/env python3
"""Generation pipeline prompt/config behavior checks."""

from __future__ import annotations

import json
import time
from pathlib import Path
import sys
import types

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.modules.setdefault("dotenv", types.SimpleNamespace(load_dotenv=lambda *_args, **_kwargs: False))

import config  # noqa: E402
import generation_pipeline  # noqa: E402


def _clear_pipeline_cache() -> None:
    generation_pipeline._cache_deadline = 0.0
    generation_pipeline._cache_payload = None
    generation_pipeline._cache_etag = None


def test_normalize_generation_pipeline() -> None:
    assert config.normalize_generation_pipeline(None) == "json_dsl_v1"
    assert config.normalize_generation_pipeline("legacy") == "json_dsl_v1"
    assert config.normalize_generation_pipeline("json-dsl-v1") == "json_dsl_v1"
    assert config.normalize_generation_pipeline("v2") == "dart_to_json_v2"
    assert config.normalize_generation_pipeline("dart-to-json") == "dart_to_json_v2"
    assert config.normalize_generation_pipeline("unknown") == "json_dsl_v1"


def test_prompt_loading() -> None:
    v1 = config.load_generate_prompt("json_dsl_v1")
    v2 = config.load_generate_prompt("dart_to_json_v2")
    assert "JSON-DSL" in v1
    assert "AI APP Generation Pipeline v2" in v2
    assert "app_dart_plan.dart" in v2
    assert "Translate Dart Plan To JSON-DSL" in v2
    assert config.generation_prompt_reference("dart_to_json_v2").endswith(
        "backend/prompts/pipelines/dart_to_json_v2/system.md"
    )


def test_resolve_generation_pipeline_from_cached_config() -> None:
    _clear_pipeline_cache()
    generation_pipeline._cache_payload = {"ai_generation_pipeline": "dart_to_json_v2"}
    generation_pipeline._cache_deadline = time.monotonic() + 60
    selected = generation_pipeline.resolve_generation_pipeline()
    assert selected.id == "dart_to_json_v2"
    assert selected.source == "config_center"
    assert selected.raw_value == "dart_to_json_v2"


def test_resolve_generation_pipeline_invalid_fallback() -> None:
    _clear_pipeline_cache()
    generation_pipeline._cache_payload = {"ai_generation_pipeline": "not-real"}
    generation_pipeline._cache_deadline = time.monotonic() + 60
    selected = generation_pipeline.resolve_generation_pipeline()
    assert selected.id == "json_dsl_v1"
    assert selected.source == "config_center_invalid"
    assert selected.raw_value == "not-real"


if __name__ == "__main__":
    test_normalize_generation_pipeline()
    test_prompt_loading()
    test_resolve_generation_pipeline_from_cached_config()
    test_resolve_generation_pipeline_invalid_fallback()
    print(json.dumps({"ok": True}, sort_keys=True))
