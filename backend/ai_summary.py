#!/usr/bin/env python3
"""AI summary —— 给 registry 富化用的"单次结构化摘要"，走 CLI（复杂 JSON 更稳）

跟生成（claude_chat / ai_session）的区别：
  - 生成是 agentic 多轮 + 流式 SSE，给用户交互用
  - summary 是单次：读一个 JSON-APP → 吐结构化双语摘要 → 写文件 → 返回

为什么也走 CLI 而不是裸 API：复杂/大 JSON（万行）CLI 能 Read 分块、容错强；
而且 AI 调用全集中在 backend 一处（registry 不碰 AI，只 HTTP 调这里）。

并发：独立小池 _summary_executor（默认 3），跟生成的 200 大池隔离，
后台批量摘要永远饿不死用户的交互式生成。

鉴权：内部接口，用 REGISTRY_ADMIN_TOKEN 校验，不公开（否则被白嫖 DeepSeek）。
"""

import json
import os
import subprocess
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from flask import request, jsonify
import requests

from config import (
    AGENT_NODE_CONNECT_TIMEOUT_SECONDS, AGENT_NODE_TOKEN, AGENT_NODE_URL, AGENT_NODE_URLS,
    AI_PROVIDERS, CLAUDE_BIN, DEFAULT_PROVIDER, AI_WORKER_EXECUTION_BACKEND,
    SUMMARY_AGENT_NODE_URL, SUMMARY_EXECUTION_BACKEND, SUMMARY_MAX_CONCURRENCY, SUMMARY_CLI_TIMEOUT,
)
import ai_session

# 受控词表 —— 让 CLI 只能从这里选，检索才对得齐。
#
# category 只描述“包的形态”，不要塞业务领域；业务领域放 domains，
# 框架能力由 registry_catalog.py 的 tech_stack 确定性推导。
CATEGORY_VOCAB = [
    "app", "library", "game", "tool", "demo",
    "launcher", "component", "template",
]
DOMAIN_VOCAB = [
    "ai", "chat", "social", "productivity", "game", "media",
    "data", "finance", "ui", "utility", "lifestyle", "education",
    "health", "developer", "business", "ecommerce", "maps",
    "creative", "system",
]

# summary 专用小池 —— 跟生成的大池隔离，限制同时跑的 CLI 数
_summary_executor = ThreadPoolExecutor(
    max_workers=SUMMARY_MAX_CONCURRENCY,
    thread_name_prefix="ai-summary",
)


def _build_summary_prompt(input_path: str, output_path: str) -> str:
    return f"""你是 JSON-DSL 应用的分析员。读取 `{input_path}` 这个 JSON-APP 文件，
理解它是什么、有什么能力，然后产出一份**结构化双语摘要**，写入 `{output_path}`。

用 Read 工具读 `{input_path}`（文件可能很大，按需分段读）。

输出**严格是一个 JSON 对象**写到 `{output_path}`，字段：
{{
  "summary_zh": "1-2 句中文：这是什么 + 关键能力",
  "summary_en": "1-2 sentences English: what it is + key capabilities",
  "category": "从这里单选一个：{CATEGORY_VOCAB}",
  "domains": "从这里多选（数组）：{DOMAIN_VOCAB}",
  "capabilities": ["关键能力点，3-6 个中文短语，如 好友管理 / 群聊 / 消息撤回"],
  "use_case_zh": "一句话：适合什么场景",
  "use_case_en": "one sentence: good for what"
}}

要求：
- category / domains 只能用上面给的受控词表里的值，不要自创
- category 是包形态：例如游戏选 game，组件库选 library/component，启动器选 launcher
- domains 是业务领域：例如大模型聊天选 ai/chat，IM 选 social/chat，平台游戏选 game
- summary 要具体（说清楚它能干啥），别写"这是一个应用"这种废话
- 只输出 JSON 到文件，不要输出多余内容
- 用 Write 工具把上面的 JSON 写到 `{output_path}`

写完后用一句话告诉我你总结的是什么 app 即可。"""


def _summary_provider() -> dict:
    provider_id = os.environ.get("SUMMARY_PROVIDER_ID", "deepseek").strip().lower().replace("_", "-") or DEFAULT_PROVIDER
    provider = AI_PROVIDERS.get(provider_id) or AI_PROVIDERS.get(DEFAULT_PROVIDER)
    if not provider:
        raise RuntimeError("summary provider is not configured")
    if not provider.get("configured"):
        raise RuntimeError(f"summary provider is not configured: {provider.get('id') or provider_id}")
    return provider


def _summary_agent_node_url() -> str:
    if SUMMARY_AGENT_NODE_URL:
        return SUMMARY_AGENT_NODE_URL
    if AGENT_NODE_URL:
        return AGENT_NODE_URL
    return AGENT_NODE_URLS[0] if AGENT_NODE_URLS else ""


def _summary_agent_node_headers() -> dict:
    headers = {"Content-Type": "application/json"}
    if AGENT_NODE_TOKEN:
        headers["Authorization"] = f"Bearer {AGENT_NODE_TOKEN}"
    return headers


def _summary_should_use_agent_node() -> bool:
    backend = SUMMARY_EXECUTION_BACKEND
    if backend in {"agent-node", "agent-pull", "isolated", "remote"}:
        return True
    if backend in {"local", "local-safe"}:
        return False
    return bool(_summary_agent_node_url()) and AI_WORKER_EXECUTION_BACKEND in {"agent-node", "agent-pull", "agent-node-pull", "pull"}


def _isolated_cli_env(provider: dict, workspace: str) -> dict:
    env = {
        "HOME": workspace,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        "IS_SANDBOX": "1",
        "AI_APP_WORKSPACE": workspace,
        "AI_APP_PROJECT_ROOT": os.environ.get("SERVER_PROJECT_PATH", ""),
    }
    cli_env = provider.get("cli_env", {})
    for k, v in cli_env.items():
        if k and "=" not in str(k):
            env[str(k)] = str(v)
    env.pop("ANTHROPIC_API_KEY", None)
    return env


def _run_summary_cli_local_safe(json_content: dict) -> dict:
    """Local fallback for development: no backend process env inheritance."""
    provider = _summary_provider()

    workdir = tempfile.mkdtemp(prefix="ai-summary-")
    input_path = os.path.join(workdir, "app.json")
    output_path = os.path.join(workdir, "summary.json")
    try:
        with open(input_path, "w", encoding="utf-8") as f:
            json.dump(json_content, f, ensure_ascii=False)

        prompt = _build_summary_prompt(input_path, output_path)
        cmd = [
            CLAUDE_BIN,
            "--dangerously-skip-permissions",
            "-p", prompt,
            "--session-id", str(uuid.uuid4()),
        ]
        subprocess.run(
            cmd, cwd=workdir, env=_isolated_cli_env(provider, workdir),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=SUMMARY_CLI_TIMEOUT,
        )

        if not os.path.exists(output_path):
            raise RuntimeError("CLI 未产出 summary 文件")
        with open(output_path, "r", encoding="utf-8") as f:
            result = json.load(f)

        validated = _validate(result)
        validated["model"] = provider.get("id") or DEFAULT_PROVIDER
        return validated
    finally:
        # 清临时目录
        try:
            import shutil
            shutil.rmtree(workdir, ignore_errors=True)
        except Exception:
            pass


def _run_summary_agent_node(json_content: dict) -> dict:
    """Run summary inside the same agent-node isolation boundary as generation."""
    provider = _summary_provider()
    agent_node_url = _summary_agent_node_url()
    if not agent_node_url:
        raise RuntimeError("summary agent-node url is not configured")

    provider_mode = ai_session._agent_node_provider_mode_for_url(agent_node_url)
    include_provider_secrets = provider_mode != "local"
    run_id = f"summary-{uuid.uuid4().hex}"
    session_id = f"summary-{uuid.uuid4().hex}"
    prompt = _build_summary_prompt("/workspace/app.json", "/workspace/summary.json")
    payload = ai_session._build_agent_node_payload(
        run_id=run_id,
        session_id=session_id,
        user_id="registry-summary",
        provider=provider,
        runner="claude",
        resume_id="",
        turn_msg=prompt,
        sys_prompt="",
        include_provider_secrets=include_provider_secrets,
    )
    payload["initial_files"] = [
        {
            "path": "app.json",
            "content": json.dumps(json_content, ensure_ascii=False),
        }
    ]

    headers = _summary_agent_node_headers()
    response = requests.post(
        f"{agent_node_url}/v1/runs",
        headers=headers,
        json=payload,
        timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
    )
    if response.status_code >= 400:
        raise RuntimeError(f"agent-node summary create failed {response.status_code}: {response.text[:500]}")

    stop = None
    stderr_tail: list[str] = []
    deadline = time.time() + SUMMARY_CLI_TIMEOUT + 10
    with requests.get(
        f"{agent_node_url}/v1/runs/{run_id}/events",
        headers=headers,
        params={"follow": "1", "timeout": str(SUMMARY_CLI_TIMEOUT + 5)},
        stream=True,
        timeout=(AGENT_NODE_CONNECT_TIMEOUT_SECONDS, SUMMARY_CLI_TIMEOUT + 30),
    ) as events_response:
        if events_response.status_code >= 400:
            raise RuntimeError(f"agent-node summary events failed {events_response.status_code}: {events_response.text[:500]}")
        for raw_line in events_response.iter_lines(decode_unicode=True):
            if time.time() > deadline:
                break
            if not raw_line:
                continue
            try:
                item = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            item_type = item.get("type")
            if item_type == "stderr":
                stderr_tail.append(str(item.get("line") or ""))
                stderr_tail = stderr_tail[-10:]
            elif item_type == "stop":
                stop = item
                break

    if not stop:
        try:
            requests.post(
                f"{agent_node_url}/v1/runs/{run_id}/abort",
                headers=headers,
                timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
            )
        except Exception:
            pass
        raise RuntimeError("agent-node summary timed out")
    if stop.get("status") != "done" or str(stop.get("returncode")) not in {"0", "None", ""}:
        tail = "".join(stderr_tail)[-500:]
        raise RuntimeError(f"agent-node summary failed status={stop.get('status')} returncode={stop.get('returncode')}: {tail}")

    artifact = requests.get(
        f"{agent_node_url}/v1/runs/{run_id}/artifact",
        headers=headers,
        params={"path": "summary.json"},
        timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
    )
    if artifact.status_code >= 400:
        raise RuntimeError(f"agent-node summary artifact failed {artifact.status_code}: {artifact.text[:500]}")
    result = json.loads(artifact.text)
    validated = _validate(result)
    validated["model"] = provider.get("id") or DEFAULT_PROVIDER
    return validated


def _run_summary_cli(json_content: dict) -> dict:
    """同步跑一次 summary CLI，返回结构化 dict。抛异常表示失败（调用方重试）。"""
    if _summary_should_use_agent_node():
        return _run_summary_agent_node(json_content)
    return _run_summary_cli_local_safe(json_content)


def _validate(r: dict) -> dict:
    """校验 + 归一化 CLI 产出，受控词表外的值丢弃。"""
    if not isinstance(r, dict):
        raise ValueError("summary 不是 JSON 对象")
    summary_zh = (r.get("summary_zh") or "").strip()
    summary_en = (r.get("summary_en") or "").strip()
    if not summary_zh and not summary_en:
        raise ValueError("summary 双语都为空")

    category = r.get("category") if r.get("category") in CATEGORY_VOCAB else None
    domains = [d for d in (r.get("domains") or []) if d in DOMAIN_VOCAB]
    caps = [str(c) for c in (r.get("capabilities") or [])][:8]

    return {
        "summary_zh": summary_zh,
        "summary_en": summary_en,
        "category": category,
        "domains": domains,
        "capabilities": caps,
        "use_case_zh": (r.get("use_case_zh") or "").strip() or None,
        "use_case_en": (r.get("use_case_en") or "").strip() or None,
        "model": "deepseek",
    }


# ═══════════════════════════════════════════════════════════
# Flask 端点：POST /api/ai/summarize（内部，registry 调）
# ═══════════════════════════════════════════════════════════

def summarize_endpoint():
    # 内部鉴权：REGISTRY_ADMIN_TOKEN（backend + registry 同一份 env）
    admin_token = os.environ.get("REGISTRY_ADMIN_TOKEN", "")
    auth = request.headers.get("Authorization", "")
    if not admin_token or auth != f"Bearer {admin_token}":
        return jsonify({"error": "unauthorized"}), 401

    body = request.get_json(silent=True) or {}
    json_content = body.get("json_content")
    if not json_content:
        return jsonify({"error": "缺少 json_content"}), 400
    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "json_content 不是合法 JSON"}), 400

    # 丢进小池跑，限制并发；同步等结果返回
    try:
        future = _summary_executor.submit(_run_summary_cli, json_content)
        result = future.result(timeout=SUMMARY_CLI_TIMEOUT + 30)
        return jsonify(result)
    except Exception as e:
        return jsonify({"error": f"summary 失败: {e}"}), 502
