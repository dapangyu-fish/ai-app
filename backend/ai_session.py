"""AI session 状态管理 + Redis worker 队列。

设计目标：把 claude CLI 的运行从 HTTP 连接生命周期里抽出来。
- Flask/gunicorn 只提交任务到 Redis pending queue
- ai_worker_daemon 独立消费队列、刷新 running lease、启动 claude CLI
- worker 把 claude CLI 输出实时写到 Redis Stream
- HTTP 端点 /api/ai/chat/<id>/stream 只是从 Redis 读流，可以随时断重连

Redis 数据：
    ai:session:<id>:meta    Hash    元信息（status / 起止时间 / 配额 / final_text）
    ai:session:<id>:stream  Stream  SSE 事件序列；entry id 即"位置"
    ai:session:<id>:abort   String  存在 = 已请求取消（SETEX 300s 自动失效）
    ai:queue:pending:<provider>            List    供应商独立等待队列
    ai:queue:running / running:leases      Hash/ZSet 全局运行租约，用于机器总并发
    ai:queue:running:<provider> / ...      Hash/ZSet 供应商运行租约，用于供应商级并发

详见 backend/ARCHITECTURE.md §3。
"""

from __future__ import annotations

import json
import hashlib
import logging
import os
import re
import requests
import shutil
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, List, Optional, Tuple

import redis

from config import (
    AI_AGENTS,
    AI_PROVIDERS,
    AI_PROVIDER_WORKER_LIMITS,
    AI_SESSION_REDIS_HOST,
    AI_SESSION_REDIS_PASSWORD,
    AI_SESSION_REDIS_PORT,
    AI_SESSION_REDIS_TTL_SECONDS,
    AI_WORKER_MAX_CONCURRENCY,
    AI_WORKER_QUEUE_MAX,
    AI_WORKER_EXECUTION_BACKEND,
    AGENT_NODE_ASSIGNMENT_TTL_SECONDS,
    AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
    AGENT_NODE_EVENT_TIMEOUT_SECONDS,
    AGENT_NODE_TOKEN,
    AGENT_NODE_URL,
    AGENT_NODE_URLS,
    CLAUDE_BIN,
    CODEX_BIN,
    CODEX_HOME,
    CODEX_NODE_BIN_DIR,
    CODEX_NPM_CACHE,
    CODEX_NPX_PACKAGE,
    DEFAULT_AGENT,
    DEFAULT_PROVIDER,
    GENERATE_PROMPT_PATH,
    PROJECT_ROOT,
    load_generate_prompt,
)

logger = logging.getLogger(__name__)


# ────────────────────────────── CLI 原始日志（排查用）──────────────────────────────
# 老 chat() 的 jsonl 日志在新 worker 里也保留：每个 session 一个文件，
# 包含 meta（起止）+ stdout 原始 stream-json 每行 + stderr。
# 路径可通过环境变量覆盖；默认 /mnt/storage00/log（生产盘）。
# 单文件追加，多 worker 并发用 lock 串行化（写入量小，不会成为瓶颈）。
_CLI_LOG_DIR = os.environ.get("CLAUDE_CLI_LOG_DIR", "/mnt/storage00/log")
_cli_log_lock = threading.Lock()
_cli_log_warned = False

_WORKSPACE_ROOT = os.environ.get("AI_AGENT_WORKSPACE_ROOT", "/tmp/ai-workspaces")
_WORKSPACE_RETENTION_SECONDS = int(os.environ.get("AI_AGENT_WORKSPACE_RETENTION_SECONDS", "604800"))


def _append_cli_log(session_id: str, kind: str, line) -> None:
    """把 Claude CLI 的原始输出按 session 追加到 JSONL 文件，便于事后排查。

    kind: stdout / stderr / meta，原样写入；stdout 不包 wrapper（CLI 已输出 jsonl）。
    line: bytes 或 str；不裁剪、不重格式化，最大化保留原始数据。
    """
    global _cli_log_warned
    if not session_id:
        return
    try:
        text = line.decode("utf-8", errors="replace") if isinstance(line, bytes) else str(line)
        if not text.endswith("\n"):
            text += "\n"
        with _cli_log_lock:
            os.makedirs(_CLI_LOG_DIR, exist_ok=True)
            path = os.path.join(_CLI_LOG_DIR, f"{session_id}.jsonl")
            with open(path, "a", encoding="utf-8") as f:
                if kind == "stdout":
                    f.write(text)
                else:
                    wrapper = json.dumps(
                        {"_log_kind": kind, "data": text.rstrip("\n")},
                        ensure_ascii=False,
                    )
                    f.write(wrapper + "\n")
    except Exception as e:
        if not _cli_log_warned:
            _cli_log_warned = True
            logger.warning(f"[CLI_LOG] 写入 CLI 日志失败（仅提示一次）: {e}")


def _safe_path_part(value: Optional[str], fallback: str) -> str:
    text = str(value or "").strip()
    cleaned = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in text)
    cleaned = cleaned.strip("._")
    return cleaned[:96] or fallback


def _cleanup_old_workspaces() -> None:
    if not os.path.isdir(_WORKSPACE_ROOT):
        return
    cutoff = time.time() - _WORKSPACE_RETENTION_SECONDS
    try:
        session_names = os.listdir(_WORKSPACE_ROOT)
    except OSError:
        return
    deleted = 0
    for session_name in session_names:
        session_path = os.path.join(_WORKSPACE_ROOT, session_name)
        if not os.path.isdir(session_path):
            continue
        try:
            job_names = os.listdir(session_path)
        except OSError:
            continue
        for job_name in job_names:
            path = os.path.join(session_path, job_name)
            if not os.path.isdir(path):
                continue
            try:
                if os.path.getmtime(path) < cutoff:
                    shutil.rmtree(path, ignore_errors=True)
                    deleted += 1
            except OSError:
                pass
        try:
            if not os.listdir(session_path):
                os.rmdir(session_path)
        except OSError:
            pass
    if deleted:
        logger.info("[WORKSPACE] 清理旧工作目录 %s 个 (> %ss)", deleted, _WORKSPACE_RETENTION_SECONDS)


def _prepare_worker_workspace(session_id: str, job_id: Optional[str]) -> str:
    _cleanup_old_workspaces()
    safe_session = _safe_path_part(session_id, "session")
    safe_job = _safe_path_part(job_id, "job")
    workspace = os.path.join(_WORKSPACE_ROOT, safe_session, safe_job)
    os.makedirs(workspace, exist_ok=True)
    return workspace


# ────────────────────────────── Redis 单例 ──────────────────────────────

_redis_client: Optional[redis.Redis] = None
_redis_client_lock = threading.Lock()


def get_redis() -> redis.Redis:
    """懒加载 Redis 连接（避免 import 时就连）。线程安全。"""
    global _redis_client
    if _redis_client is not None:
        return _redis_client
    with _redis_client_lock:
        if _redis_client is None:
            _redis_client = redis.Redis(
                host=AI_SESSION_REDIS_HOST,
                port=AI_SESSION_REDIS_PORT,
                password=AI_SESSION_REDIS_PASSWORD or None,
                socket_connect_timeout=2,
                socket_keepalive=True,
                decode_responses=False,
            )
    return _redis_client


# ────────────────────────────── Key 命名 ──────────────────────────────

def _meta_key(session_id: str) -> str:
    return f"ai:session:{session_id}:meta"


def _stream_key(session_id: str) -> str:
    return f"ai:session:{session_id}:stream"


def _abort_key(session_id: str) -> str:
    return f"ai:session:{session_id}:abort"


def _agent_node_assignment_key(session_id: str) -> str:
    return f"ai:session:{session_id}:agent_node"


def _agent_node_registry_key(node_id: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(node_id or "")).strip("._") or "node"
    return f"ai:agent_node:{safe}"


def _normalize_provider_id(provider_id: Optional[str]) -> str:
    pid = (provider_id or DEFAULT_PROVIDER).strip().lower().replace("_", "-")
    return pid if pid in AI_PROVIDERS else DEFAULT_PROVIDER


def _provider_queue_suffix(provider_id: Optional[str]) -> str:
    pid = _normalize_provider_id(provider_id)
    return re.sub(r"[^a-z0-9-]+", "-", pid).strip("-") or "default"


def _provider_worker_limits(provider_id: Optional[str]) -> dict:
    pid = _normalize_provider_id(provider_id)
    return AI_PROVIDER_WORKER_LIMITS.get(
        pid,
        {"max_concurrency": AI_WORKER_MAX_CONCURRENCY, "queue_max": AI_WORKER_QUEUE_MAX},
    )


def _pending_queue_key(provider_id: Optional[str] = None) -> str:
    if provider_id is None:
        return "ai:queue:pending"
    return f"ai:queue:pending:{_provider_queue_suffix(provider_id)}"


def _running_hash_key() -> str:
    return "ai:queue:running"


def _running_lease_key() -> str:
    return "ai:queue:running:leases"


def _provider_running_hash_key(provider_id: Optional[str]) -> str:
    return f"ai:queue:running:{_provider_queue_suffix(provider_id)}"


def _provider_running_lease_key(provider_id: Optional[str]) -> str:
    return f"ai:queue:running:leases:{_provider_queue_suffix(provider_id)}"


# ────────────────────────────── 状态枚举 ──────────────────────────────

STATUS_RUNNING = "running"
STATUS_QUEUED = "queued"
STATUS_DONE = "done"
STATUS_FAILED = "failed"
STATUS_ABORTED = "aborted"

TERMINAL_STATUSES = {STATUS_DONE, STATUS_FAILED, STATUS_ABORTED}


# ────────────────────────────── SessionStore ──────────────────────────────

class SessionStore:
    """Redis 层的 session 元信息 + 事件流 CRUD。无业务逻辑。"""

    def __init__(self):
        self.r = get_redis()

    # ─── meta ───
    def create_meta(self, session_id: str, *, user_id: str, provider: str,
                    agent: str = DEFAULT_AGENT,
                    quota_used: int, quota_limit: int, quota_remaining: int,
                    status: str = STATUS_RUNNING) -> None:
        """新一轮 worker 起前调。会清掉旧 stream + 旧 meta（避免上一轮的 final_text /
        error / 老事件被新一轮的 client 当成本轮内容读到）。"""
        # 1. 旧 stream 整个删（如果存在）—— 上一轮的事件不能让本轮 client 重放
        # 2. 旧 meta 整个删（hset 是 merge，不删的话上一轮的 finished_at / final_text /
        #    error 字段会残留）
        pipe = self.r.pipeline()
        pipe.delete(_stream_key(session_id))
        pipe.delete(_meta_key(session_id))
        pipe.execute()

        meta = {
            "session_id": session_id,
            "user_id": user_id,
            "provider": provider,
            "agent": agent,
            "status": status,
            "started_at": str(int(time.time() * 1000)),
            "event_count": "0",
            "quota_used": str(quota_used),
            "quota_limit": str(quota_limit),
            "quota_remaining": str(quota_remaining),
        }
        pipe = self.r.pipeline()
        pipe.hset(_meta_key(session_id), mapping=meta)
        pipe.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
        pipe.execute()

    def mark_running(self, session_id: str, job_id: Optional[str] = None) -> None:
        """从 queued 切到 running，不写 finished_at。"""
        update = {
            "status": STATUS_RUNNING,
            "started_at": str(int(time.time() * 1000)),
        }
        if job_id is not None:
            update["active_job_id"] = job_id
        pipe = self.r.pipeline()
        pipe.hset(_meta_key(session_id), mapping=update)
        pipe.hdel(_meta_key(session_id), "queued_job")
        pipe.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
        pipe.execute()

    def get_meta(self, session_id: str) -> dict:
        raw = self.r.hgetall(_meta_key(session_id))
        if not raw:
            return {}
        return {k.decode(): v.decode() for k, v in raw.items()}

    def set_status(self, session_id: str, status: str, *,
                   final_text: Optional[str] = None,
                   final_thinking: Optional[str] = None,
                   client_actions: Optional[List[dict]] = None,
                   error: Optional[str] = None) -> None:
        update = {
            "status": status,
            "finished_at": str(int(time.time() * 1000)),
        }
        if final_text is not None:
            update["final_text"] = final_text
        if final_thinking is not None:
            update["final_thinking"] = final_thinking
        if client_actions is not None:
            update["client_actions"] = json.dumps(client_actions, ensure_ascii=False)
        if error is not None:
            update["error"] = error
        pipe = self.r.pipeline()
        pipe.hset(_meta_key(session_id), mapping=update)
        pipe.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
        pipe.execute()

    # ─── stream ───
    def append_event(self, session_id: str, event: dict) -> None:
        """append 一个业务事件到 stream。每个 entry 用单字段 'data' 装 JSON。"""
        try:
            pipe = self.r.pipeline()
            pipe.xadd(
                _stream_key(session_id),
                {"data": json.dumps(event, ensure_ascii=False).encode()},
                maxlen=10000,  # 防内存爆炸；正常一次会话不到 1000 条
                approximate=True,
            )
            pipe.hincrby(_meta_key(session_id), "event_count", 1)
            pipe.expire(_stream_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
            pipe.execute()
        except Exception as e:
            logger.exception(f"[SESSION] append_event 失败 sid={session_id}: {e}")

    def read_events(self, session_id: str, last_id: str = "0",
                    block_ms: int = 5000, count: int = 100) -> List[Tuple[str, dict]]:
        """从 stream 读事件，返回 [(entry_id, event_dict), ...]。

        - last_id="0"：从头读（重连补齐用）
        - last_id=<上次返回的最后一个 entry_id>：续读
        - block_ms > 0 期间没新事件 → 返回空 list（调用方循环 + 心跳）
        - block_ms <= 0：**非阻塞**读取（drain 兜底用）。⚠️ Redis 协议下
          `XREAD BLOCK 0` 是「无限阻塞」，所以这里必须把 block 参数省掉
          （redis-py 传 block=None 不发 BLOCK 子命令），否则 SSE handler
          会在 status=DONE 之后的 drain 阶段死锁，[DONE] 永远不发出。

        entry_id 形如 "1714838400000-0"，是 Redis Stream 的天然顺序游标。
        """
        try:
            result = self.r.xread(
                {_stream_key(session_id): last_id},
                count=count,
                block=block_ms if block_ms > 0 else None,
            )
        except redis.exceptions.RedisError as e:
            logger.warning(f"[SESSION] xread 失败 sid={session_id}: {e}")
            return []

        if not result:
            return []

        out: List[Tuple[str, dict]] = []
        for _, entries in result:
            for entry_id, fields in entries:
                eid = entry_id.decode() if isinstance(entry_id, bytes) else entry_id
                # fields key 在 redis-py 默认是 bytes，但 decode_responses 配置下也可能是 str
                raw = fields.get(b"data") if b"data" in fields else fields.get("data")
                if not raw:
                    continue
                try:
                    if isinstance(raw, bytes):
                        raw = raw.decode("utf-8", errors="replace")
                    out.append((eid, json.loads(raw)))
                except json.JSONDecodeError:
                    logger.warning(f"[SESSION] event JSON 解析失败 sid={session_id}")
        return out

    # ─── abort ───
    def request_abort(self, session_id: str) -> None:
        # 5 分钟自动过期；正常 worker 几秒内就检测到并退出
        self.r.set(_abort_key(session_id), b"1", ex=300)

    def is_aborted(self, session_id: str) -> bool:
        return self.r.exists(_abort_key(session_id)) > 0

    def clear_abort(self, session_id: str) -> None:
        """擦掉 abort 标记。force_restart 时用：旧 worker 已退，新 worker 别误杀。"""
        self.r.delete(_abort_key(session_id))


# ────────────────────────────── CLI 输出解析 ──────────────────────────────

_CLIENT_ACTIONS_FILE = "client_actions.json"
_CLIENT_ACTION_URL_RE = re.compile(
    r"https?://[^\s\]\[\)\(\<>\"]+",
    re.IGNORECASE,
)


def _final_protocol_warnings(final_text: Optional[str]) -> List[str]:
    if not final_text:
        return []
    warnings: List[str] = []
    lowered = final_text.lower()
    if "json_app_url" in lowered:
        warnings.append("unexpected_json_app_url_text_tag")
    if "request_action" in lowered:
        warnings.append("unexpected_request_action_text_tag")
    return warnings


def _client_action_warning(session_id: str, message: str, *, detail: Any = None) -> None:
    logger.warning("[CLIENT_ACTION] sid=%s %s detail=%r", session_id, message, detail)
    _append_cli_log(session_id, "meta", json.dumps({
        "event": "client_action_warning",
        "message": message,
        "detail": detail,
    }, ensure_ascii=False))


def _normalize_client_action(raw: Any, session_id: str) -> Optional[dict]:
    if not isinstance(raw, dict):
        _client_action_warning(session_id, "client action 不是对象", detail=raw)
        return None

    action_type = str(raw.get("type") or "").strip()
    if action_type == "request_upload_current_app":
        return {"type": "request_upload_current_app"}

    if action_type == "json_app_ready":
        url = str(raw.get("url") or "").strip()
        if not _CLIENT_ACTION_URL_RE.fullmatch(url):
            _client_action_warning(session_id, "json_app_ready 缺少合法 url", detail=raw)
            return None
        return {"type": "json_app_ready", "url": url}

    _client_action_warning(session_id, "未知 client action type", detail=raw)
    return None


def _load_client_actions(workspace: Optional[str], session_id: str) -> List[dict]:
    if not workspace:
        return []
    path = os.path.join(workspace, _CLIENT_ACTIONS_FILE)
    if not os.path.isfile(path):
        return []

    try:
        if os.path.getsize(path) > 65536:
            _client_action_warning(session_id, "client_actions.json 过大", detail=path)
            return []
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except Exception as e:
        _client_action_warning(session_id, "读取 client_actions.json 失败", detail=str(e))
        return []

    if isinstance(payload, dict):
        raw_actions = payload.get("client_actions")
    elif isinstance(payload, list):
        raw_actions = payload
    else:
        _client_action_warning(session_id, "client_actions.json 顶层格式错误", detail=payload)
        return []

    if not isinstance(raw_actions, list):
        _client_action_warning(session_id, "client_actions 不是数组", detail=payload)
        return []

    wants_upload_current_app = False
    last_json_app_ready: Optional[dict] = None
    for raw in raw_actions[:20]:
        action = _normalize_client_action(raw, session_id)
        if not action:
            continue
        if action["type"] == "request_upload_current_app":
            wants_upload_current_app = True
        elif action["type"] == "json_app_ready":
            last_json_app_ready = action

    out: List[dict] = []
    if wants_upload_current_app:
        out.append({"type": "request_upload_current_app"})
    if last_json_app_ready:
        out.append(last_json_app_ready)
    return out


def _tool_status_message(tool_name: str, tool_input: dict) -> str:
    """工具调用 → 用户友好提示文案。和旧 claude_chat 行为一致。"""
    if tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        return f"正在阅读 {os.path.basename(file_path)}..." if file_path else "正在阅读文件..."
    elif tool_name == "Write":
        file_path = tool_input.get("file_path", "")
        return f"正在写入 {os.path.basename(file_path)}..." if file_path else "正在写入文件..."
    elif tool_name in ("Grep", "Glob"):
        return "正在搜索代码..."
    elif tool_name == "Bash":
        return "正在运行终端命令..."
    elif tool_name == "Edit":
        return "正在编辑文件..."
    elif tool_name == "WebFetch":
        return "正在获取网页..."
    elif tool_name == "WebSearch":
        return "正在搜索网络..."
    elif tool_name in ("Task", "TodoWrite", "TaskUpdate"):
        return "正在更新执行计划..."
    return f"正在使用工具 {tool_name}..."


def parse_cli_line(line_str: str) -> List[dict]:
    """把 claude CLI 一行 stream-json 解析成业务事件 dict 列表。

    返回的每个 dict 就是 SSE 'data: <json>\\n\\n' 里那个 json 对象。

    旧 /chat 端点也调这个函数（保证两条路径行为完全一致）。
    """
    line_str = line_str.strip()
    if not line_str:
        return []

    out: List[dict] = []
    try:
        event = json.loads(line_str)
    except json.JSONDecodeError as e:
        logger.warning(f"[PARSE] JSON 解析失败: {e}, line: {line_str[:100]}...")
        return []

    evt_type = event.get("type")

    if evt_type == "system":
        out.append({"status": "init", "message": "AI 引擎已启动"})

    elif evt_type == "stream_event":
        ev = event.get("event", {})
        ev_type = ev.get("type")

        if ev_type == "message_start":
            out.append({"event": "message_start"})
        elif ev_type == "message_stop":
            out.append({"event": "message_stop"})
        elif ev_type == "content_block_start":
            content_block = ev.get("content_block", {})
            block_type = content_block.get("type")
            if block_type == "tool_use":
                tool_name = content_block.get("name", "")
                tool_input = content_block.get("input", {})
                if tool_name:
                    out.append({
                        "status": tool_name.lower(),
                        "message": _tool_status_message(tool_name, tool_input),
                    })
            elif block_type == "thinking":
                out.append({"status": "thinking", "message": "AI 正在思考..."})
        elif ev_type == "content_block_delta":
            delta = ev.get("delta", {})
            delta_type = delta.get("type")
            if delta_type == "text_delta":
                text_chunk = delta.get("text", "")
                if text_chunk:
                    out.append({"content": text_chunk})
            elif delta_type == "thinking_delta":
                think_chunk = delta.get("thinking", "")
                if think_chunk:
                    out.append({"thinking": think_chunk})
            elif delta_type == "input_json_delta":
                out.append({
                    "status": "tool_preparing",
                    "message": "AI 正在构造工具参数...",
                })

    elif evt_type == "assistant":
        msg = event.get("message", {})
        for block in msg.get("content", []):
            btype = block.get("type")
            if btype == "tool_use":
                tool_name = block.get("name", "")
                tool_input = block.get("input", {})
                if tool_name:
                    out.append({
                        "status": tool_name.lower(),
                        "message": _tool_status_message(tool_name, tool_input),
                    })
            elif btype == "text":
                text_value = block.get("text", "")
                if text_value:
                    out.append({"assistant_content": text_value})
            elif btype == "thinking":
                think_value = block.get("thinking", "")
                if think_value:
                    out.append({"assistant_thinking": think_value})

    elif evt_type == "result":
        # 实测 CLI 的 result event 结构是 `{"type":"result","result":"...完整文本..."}`，
        # 不是想象中的 `{"message":{"content":[{"type":"text","text":"..."}]}}`。
        # 老代码（搬自 claude_chat.py）一直读 message.content 拿不到东西，导致
        # meta.final_text 永远为空，恢复流程的 _fetchCompletedResult 因此返回 Nothing。
        if event.get("is_error"):
            res = event.get("result", "")
            out.append({"error": f"生成中断: {res}"})
        else:
            # 优先读 result 字段（CLI 实际行为）；message.content 兜底（防止 CLI 升级换 schema）
            result_text = event.get("result", "")
            if isinstance(result_text, str) and result_text:
                out.append({"final_content": result_text})
            else:
                msg = event.get("message", {})
                for block in msg.get("content", []):
                    if block.get("type") == "text":
                        ft = block.get("text", "")
                        if ft:
                            out.append({"final_content": ft})
                    elif block.get("type") == "thinking":
                        fth = block.get("thinking", "")
                        if fth:
                            out.append({"final_thinking": fth})

    return out


def parse_codex_line(line_str: str) -> List[dict]:
    """把 Codex CLI `exec --json` 的一行 JSONL 解析成现有业务事件。

    对客户端保持同一套 SSE payload：
    - agent_message.text -> assistant_content + final_content
    - tool/command items -> status/message
    - error/failure -> error
    """
    line_str = line_str.strip()
    if not line_str:
        return []

    try:
        event = json.loads(line_str)
    except json.JSONDecodeError as e:
        logger.warning(f"[CODEX_PARSE] JSON 解析失败: {e}, line: {line_str[:100]}...")
        return []

    out: List[dict] = []
    evt_type = str(event.get("type") or "")

    if evt_type == "thread.started":
        out.append({"status": "init", "message": "AI 引擎已启动"})
        return out

    if evt_type == "turn.started":
        out.append({"status": "thinking", "message": "AI 正在思考..."})
        return out

    if evt_type in {"error", "turn.failed"}:
        message = event.get("message") or event.get("error") or event.get("detail") or "Codex 执行失败"
        out.append({"error": str(message), "needs_retry": True})
        return out

    item = event.get("item")
    if isinstance(item, dict):
        item_type = str(item.get("type") or "")
        if item_type in {"agent_message", "message"}:
            text = item.get("text") or item.get("content") or ""
            if isinstance(text, str) and text:
                # Codex exec 当前不会像 Claude 一样稳定吐 text_delta；
                # 同时发 assistant_content 和 final_content，兼容客户端显示与最终恢复。
                out.append({"assistant_content": text})
                out.append({"final_content": text})
        elif item_type in {"reasoning", "thinking"}:
            text = item.get("text") or item.get("summary") or item.get("content") or ""
            if isinstance(text, str) and text:
                out.append({"assistant_thinking": text})
            else:
                out.append({"status": "thinking", "message": "AI 正在思考..."})
        elif item_type in {"tool_call", "function_call", "local_shell_call", "command_execution"}:
            name = item.get("name") or item.get("command") or item_type
            if isinstance(name, list):
                name = " ".join(str(part) for part in name[:3])
            out.append({
                "status": item_type,
                "message": f"正在执行 {str(name)[:80]}...",
            })
        elif item_type:
            out.append({
                "status": item_type,
                "message": f"正在处理 {item_type}...",
            })
        return out

    if evt_type == "item.completed":
        out.append({"status": "working", "message": "AI 正在处理..."})

    return out


def extract_final_texts(events: List[dict]) -> Tuple[Optional[str], Optional[str]]:
    """从所有事件里提取最终文本和 thinking。给 worker 完工时落 meta 用。"""
    final_text = None
    final_thinking = None
    for ev in events:
        if "final_content" in ev:
            final_text = ev["final_content"]
        elif "final_thinking" in ev:
            final_thinking = ev["final_thinking"]
    return final_text, final_thinking


# ────────────────────────────── Redis Queue + Worker 池 ──────────────────────────────

# ai_worker_daemon 内的本地线程池；全局并发仍由 Redis running lease 控制。
# 这里也设同样大小，避免单 daemon 本地堆积 executor 内部队列。
_executor = ThreadPoolExecutor(
    max_workers=AI_WORKER_MAX_CONCURRENCY,
    thread_name_prefix="ai-worker",
)


@dataclass(frozen=True)
class _WorkerJob:
    job_id: str
    session_id: str
    last_msg: str
    provider_id: Optional[str]
    agent_id: str
    agent_resume_id: Optional[str]
    user_id: str
    quota_used: int
    quota_limit: int
    quota_remaining: int


# Redis 负责全局 pending queue + running lease；Flask 可以多进程。
_WORKER_LEASE_MS = int(os.environ.get("AI_WORKER_LEASE_MS", "30000"))
_WORKER_HEARTBEAT_SECONDS = max(1, int(os.environ.get("AI_WORKER_HEARTBEAT_SECONDS", "10")))
_WORKER_ID = f"{os.uname().nodename}:{os.getpid()}:{uuid.uuid4().hex[:8]}"

# session_id -> Popen，给 abort 杀进程用
_session_procs: dict = {}
_session_procs_lock = threading.Lock()


def _register_proc(session_id: str, proc: subprocess.Popen) -> None:
    with _session_procs_lock:
        _session_procs[session_id] = proc


def _unregister_proc(session_id: str, proc: Optional[subprocess.Popen] = None) -> None:
    with _session_procs_lock:
        current = _session_procs.get(session_id)
        if proc is None or current is proc:
            _session_procs.pop(session_id, None)


def _kill_proc(session_id: str) -> bool:
    with _session_procs_lock:
        proc = _session_procs.get(session_id)
    if proc is None:
        return False
    try:
        proc.terminate()
    except Exception as e:
        logger.warning(f"[WORKER] terminate 失败 sid={session_id}: {e}")
    return True


def is_session_proc_alive(session_id: str) -> bool:
    """跨 gunicorn worker 判断运行租约是否还活着。"""
    try:
        score = get_redis().zscore(_running_lease_key(), session_id)
    except redis.exceptions.RedisError as e:
        logger.warning(f"[WORKER_QUEUE] 读取 running lease 失败 sid={session_id}: {e}")
        return False
    if score is None:
        return False
    return float(score) > int(time.time() * 1000)


def _queue_status_message(position: Optional[int]) -> str:
    if position is None:
        return "排队中，正在等待空闲 worker..."
    ahead = max(position - 1, 0)
    if ahead == 0:
        return "排队中，即将开始生成..."
    return f"排队中，前面还有 {ahead} 个任务..."


def _job_provider_from_json(job_text: str, fallback: Optional[str] = None) -> str:
    try:
        data = json.loads(job_text)
        return _normalize_provider_id(data.get("provider_id") or fallback)
    except Exception:
        return _normalize_provider_id(fallback)


def get_queue_position(session_id: str) -> Optional[int]:
    """返回 1-based 排队位置；不在等待队列则返回 None。"""
    r = get_redis()
    meta = SessionStore().get_meta(session_id)
    queued_job = meta.get("queued_job")
    if not queued_job:
        return None
    provider_id = _job_provider_from_json(queued_job, meta.get("provider"))
    try:
        raw_jobs = r.lrange(_pending_queue_key(provider_id), 0, -1)
    except redis.exceptions.RedisError as e:
        logger.warning(f"[WORKER_QUEUE] 读取 pending queue 失败 sid={session_id} provider={provider_id}: {e}")
        return None
    position = 0
    for raw in raw_jobs:
        job_text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else str(raw)
        try:
            job_data = json.loads(job_text)
            job_session_id = job_data.get("session_id", "")
            current_job = r.hget(_meta_key(job_session_id), "queued_job")
            if isinstance(current_job, bytes):
                current_job = current_job.decode("utf-8", errors="replace")
            if current_job != job_text:
                continue
        except Exception:
            continue
        position += 1
        if job_text == queued_job:
            return position
    return None


def get_queue_message(session_id: str) -> str:
    return _queue_status_message(get_queue_position(session_id))


def _job_to_json(job: _WorkerJob) -> str:
    return json.dumps(job.__dict__, ensure_ascii=False, separators=(",", ":"))


def _job_from_json(raw) -> _WorkerJob:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    data = json.loads(raw)
    return _WorkerJob(
        job_id=data["job_id"],
        session_id=data["session_id"],
        last_msg=data["last_msg"],
        provider_id=_normalize_provider_id(data.get("provider_id")),
        agent_id=data.get("agent_id") or DEFAULT_AGENT,
        agent_resume_id=data.get("agent_resume_id"),
        user_id=data["user_id"],
        quota_used=int(data["quota_used"]),
        quota_limit=int(data["quota_limit"]),
        quota_remaining=int(data["quota_remaining"]),
    )


_ENQUEUE_SCRIPT = """
local pending_key = KEYS[1]
local meta_key = KEYS[2]
local job_json = ARGV[1]
local queue_max = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
if redis.call('LLEN', pending_key) >= queue_max then
  return -1
end
redis.call('RPUSH', pending_key, job_json)
redis.call('HSET', meta_key, 'queued_job', job_json)
local job = cjson.decode(job_json)
redis.call('HSET', meta_key, 'active_job_id', job['job_id'])
redis.call('EXPIRE', meta_key, ttl)
return redis.call('LLEN', pending_key)
"""


_ACQUIRE_SCRIPT = """
local pending_key = KEYS[1]
local running_hash_key = KEYS[2]
local running_lease_key = KEYS[3]
local provider_running_hash_key = KEYS[4]
local provider_running_lease_key = KEYS[5]
local now_ms = tonumber(ARGV[1])
local lease_until_ms = tonumber(ARGV[2])
local max_total_running = tonumber(ARGV[3])
local max_provider_running = tonumber(ARGV[4])
local worker_id = ARGV[5]
local provider_id = ARGV[6]
local expired = redis.call('ZRANGEBYSCORE', running_lease_key, '-inf', now_ms)
for _, sid in ipairs(expired) do
  redis.call('HDEL', running_hash_key, sid)
end
if #expired > 0 then
  redis.call('ZREMRANGEBYSCORE', running_lease_key, '-inf', now_ms)
end
local provider_expired = redis.call('ZRANGEBYSCORE', provider_running_lease_key, '-inf', now_ms)
for _, sid in ipairs(provider_expired) do
  redis.call('HDEL', provider_running_hash_key, sid)
end
if #provider_expired > 0 then
  redis.call('ZREMRANGEBYSCORE', provider_running_lease_key, '-inf', now_ms)
end
if max_total_running <= 0 or redis.call('ZCARD', running_lease_key) >= max_total_running then
  return nil
end
if max_provider_running <= 0 or redis.call('ZCARD', provider_running_lease_key) >= max_provider_running then
  return nil
end
local job_json = redis.call('LPOP', pending_key)
if not job_json then
  return nil
end
local job = cjson.decode(job_json)
local running = cjson.encode({
  job_id = job['job_id'],
  provider_id = provider_id,
  worker_id = worker_id,
  started_at = now_ms,
  lease_until = lease_until_ms
})
redis.call('HSET', running_hash_key, job['session_id'], running)
redis.call('ZADD', running_lease_key, lease_until_ms, job['session_id'])
redis.call('HSET', provider_running_hash_key, job['session_id'], running)
redis.call('ZADD', provider_running_lease_key, lease_until_ms, job['session_id'])
return job_json
"""


def _acquire_redis_job(provider_id: str, timeout_seconds: int = 0) -> Optional[_WorkerJob]:
    r = get_redis()
    deadline = time.time() + timeout_seconds
    limits = _provider_worker_limits(provider_id)
    while True:
        now_ms = int(time.time() * 1000)
        try:
            raw = r.eval(
                _ACQUIRE_SCRIPT,
                5,
                _pending_queue_key(provider_id),
                _running_hash_key(),
                _running_lease_key(),
                _provider_running_hash_key(provider_id),
                _provider_running_lease_key(provider_id),
                now_ms,
                now_ms + _WORKER_LEASE_MS,
                AI_WORKER_MAX_CONCURRENCY,
                limits["max_concurrency"],
                _WORKER_ID,
                provider_id,
            )
        except redis.exceptions.RedisError as e:
            logger.warning(f"[WORKER_QUEUE] acquire 失败 provider={provider_id}: {e}")
            time.sleep(1)
            return None
        if raw:
            return _job_from_json(raw)
        if time.time() >= deadline:
            return None
        time.sleep(0.2)


def _refresh_running_lease(session_id: str, provider_id: Optional[str]) -> None:
    now_ms = int(time.time() * 1000)
    lease_until = now_ms + _WORKER_LEASE_MS
    provider_id = _normalize_provider_id(provider_id)
    running_payload = json.dumps(
        {
            "worker_id": _WORKER_ID,
            "provider_id": provider_id,
            "lease_until": lease_until,
            "updated_at": now_ms,
        },
        separators=(",", ":"),
    )
    r = get_redis()
    pipe = r.pipeline()
    pipe.zadd(_running_lease_key(), {session_id: lease_until})
    pipe.hset(_running_hash_key(), session_id, running_payload)
    pipe.zadd(_provider_running_lease_key(provider_id), {session_id: lease_until})
    pipe.hset(_provider_running_hash_key(provider_id), session_id, running_payload)
    pipe.execute()


def _complete_running(session_id: str, provider_id: Optional[str]) -> None:
    provider_id = _normalize_provider_id(provider_id)
    pipe = get_redis().pipeline()
    pipe.hdel(_running_hash_key(), session_id)
    pipe.zrem(_running_lease_key(), session_id)
    pipe.hdel(_provider_running_hash_key(provider_id), session_id)
    pipe.zrem(_provider_running_lease_key(provider_id), session_id)
    pipe.execute()


def _run_redis_job(job: _WorkerJob) -> None:
    stop_heartbeat = threading.Event()

    def heartbeat_loop() -> None:
        while not stop_heartbeat.wait(_WORKER_HEARTBEAT_SECONDS):
            try:
                _refresh_running_lease(job.session_id, job.provider_id)
            except Exception as e:
                logger.warning(f"[WORKER_QUEUE] heartbeat 失败 sid={job.session_id}: {e}")

    heartbeat_thread = threading.Thread(
        target=heartbeat_loop,
        name=f"ai-heartbeat-{job.session_id[:8]}",
        daemon=True,
    )
    heartbeat_thread.start()

    try:
        store = SessionStore()
        meta = store.get_meta(job.session_id)
        expected_job = _job_to_json(job)
        if not meta or store.is_aborted(job.session_id):
            return
        if meta.get("status") in TERMINAL_STATUSES:
            return
        if meta.get("queued_job") and meta.get("queued_job") != expected_job:
            logger.info(f"[WORKER_QUEUE] sid={job.session_id} 跳过过期 job={job.job_id}")
            return
        store.mark_running(job.session_id, job.job_id)
        if store.get_meta(job.session_id).get("active_job_id") != job.job_id:
            logger.info(f"[WORKER_QUEUE] sid={job.session_id} job={job.job_id} 刚启动即被替换")
            return
        store.append_event(
            job.session_id,
            {
                "status": STATUS_RUNNING,
                "message": "AI 已开始生成...",
            },
        )
        _worker_main(
            job.session_id,
            job.last_msg,
            job.provider_id,
            job.agent_id,
            job.agent_resume_id,
            job.quota_used,
            job.quota_limit,
            job.quota_remaining,
            job_id=job.job_id,
        )
    finally:
        stop_heartbeat.set()
        _complete_running(job.session_id, job.provider_id)


def _build_user_turn_prompt(last_msg: str, *, workspace: Optional[str] = None) -> str:
    workspace_note = ""
    if workspace:
        workspace_note = (
            "\n\n本轮后端已为你分配独立工作目录，必须使用它隔离所有临时文件："
            f"\nAI_APP_WORKSPACE={workspace}"
            "\n生成器、下载的 manifest、app.json、校验输出都放在 AI_APP_WORKSPACE 下；"
            "不要写 /tmp/app.json 或 /tmp/generate_app.py。"
        )
    final_protocol_note = (
        "\n\n最终交付协议（本轮普通提示重复注入，必须逐字符遵守）："
        "如果用户只是问能力、使用方式、普通闲聊、澄清问题或解释错误，且没有要求新建/修改/修复/发布 APP，"
        "本轮不进入生成流程，不读取分层索引，不运行命令，不上传文件，只用自然语言直接回答。"
        "这类普通回答禁止出现任何客户端协议标签字面量。"
        "如果本轮需要客户端执行动作，禁止在最终回答里写 `[json_app_url]` 或 `[request_action]` 标签；"
        "必须写入 `$AI_APP_WORKSPACE/client_actions.json`，格式为 "
        "`{\"client_actions\":[{\"type\":\"request_upload_current_app\"}]}` 或 "
        "`{\"client_actions\":[{\"type\":\"json_app_ready\",\"url\":\"https://...\"}]}`。"
        "上传 JSON-APP 时必须执行 `bash backend/upload_with_signature.sh \"$AI_APP_WORKSPACE/app.json\"`；"
        "该脚本上传成功后会自动写入 `json_app_ready` 动作文件，你只需在自然语言中简短说明已生成。"
        "如果需要请求用户上传当前应用，先写入 `request_upload_current_app` 动作文件，再用自然语言说明需要查看当前应用。"
    )
    return (
        f"本轮用户的请求:\n<user_request>\n{last_msg}\n</user_request>"
        f"{workspace_note}\n请实现用户要求并严格按照系统提示词{GENERATE_PROMPT_PATH}中的信息答复用户；"
        "如果该提示词要求先分类、读取索引或按需阅读分层文档，每一轮都必须重新执行。"
        "不要遗忘工作目录、repair/validate、上传和 client_actions 结构化动作规则。"
        f"{final_protocol_note}"
    )


def _build_cli_cmd(
    session_id: str,
    last_msg: str,
    sys_prompt: str,
    is_resume: bool,
    *,
    workspace: Optional[str] = None,
) -> list:
    cmd = [
        CLAUDE_BIN,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p", _build_user_turn_prompt(last_msg, workspace=workspace),
    ]
    if is_resume:
        cmd.extend(["-r", session_id])
    else:
        cmd.extend(["--session-id", session_id])
        if sys_prompt:
            cmd.extend(["--append-system-prompt", sys_prompt])
    return cmd


def _provider_env(provider_id: Optional[str]) -> Tuple[dict, dict]:
    """返回 (provider_dict, env_dict_for_subprocess)"""
    pid = (provider_id or DEFAULT_PROVIDER).strip().lower().replace("_", "-")
    provider = AI_PROVIDERS.get(pid)
    if not provider:
        raise ValueError(f"未知 AI 供应商: {pid}")
    if not provider.get("configured"):
        raise ValueError(f"AI 供应商未配置: {pid}")
    if not provider.get("visible", True):
        raise ValueError(f"AI 供应商当前不可用: {pid}")
    cli_env = provider.get("cli_env", {})
    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"
    return provider, env


def _agent_config(agent_id: Optional[str]) -> dict:
    aid = (agent_id or DEFAULT_AGENT).strip().lower().replace("_", "-") or DEFAULT_AGENT
    agent = AI_AGENTS.get(aid)
    if not agent:
        raise ValueError(f"未知 AI Agent: {aid}")
    if not agent.get("configured"):
        raise ValueError(f"AI Agent 未配置: {aid}")
    if not agent.get("visible", True):
        raise ValueError(f"AI Agent 当前不可用: {aid}")
    return agent


def _toml_string(value: object) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def _codex_env(provider: dict, workspace: str) -> Tuple[dict, dict]:
    codex = provider.get("codex") or {}
    if not codex.get("configured"):
        raise ValueError(f"供应商 {provider.get('id')} 未配置 Codex 运行参数")
    env_key = str(codex.get("env_key") or "").strip()
    if not env_key or not os.environ.get(env_key, ""):
        raise ValueError(f"供应商 {provider.get('id')} 缺少 Codex 鉴权环境变量")

    env = os.environ.copy()
    env["IS_SANDBOX"] = "1"
    env["AI_APP_WORKSPACE"] = workspace
    env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
    env["CODEX_HOME"] = CODEX_HOME
    env["npm_config_cache"] = CODEX_NPM_CACHE
    if CODEX_NODE_BIN_DIR:
        env["PATH"] = f"{CODEX_NODE_BIN_DIR}{os.pathsep}{env.get('PATH', '')}"
    os.makedirs(CODEX_HOME, exist_ok=True)
    os.makedirs(CODEX_NPM_CACHE, exist_ok=True)
    return codex, env


def _codex_bin_prefix() -> List[str]:
    if os.path.basename(CODEX_BIN) == "npx":
        return [CODEX_BIN, "-y", CODEX_NPX_PACKAGE]
    return [CODEX_BIN]


def _build_codex_cmd(
    provider: dict,
    workspace: str,
    *,
    resume_id: Optional[str],
) -> list:
    codex = provider.get("codex") or {}
    provider_key = str(codex.get("provider_id") or provider.get("id") or "custom").replace("-", "_")
    provider_name = codex.get("provider_name") or provider_key
    cmd = _codex_bin_prefix()
    cmd.extend(["-C", PROJECT_ROOT, "exec"])
    if resume_id:
        cmd.append("resume")
    cmd.extend([
        "--json",
        "--ignore-user-config",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        "--output-last-message", os.path.join(workspace, "codex-last-message.txt"),
        "-c", f"model_provider={_toml_string(provider_key)}",
        "-c", f"model={_toml_string(codex.get('model', ''))}",
        "-c", f"model_providers.{provider_key}.name={_toml_string(provider_name)}",
        "-c", f"model_providers.{provider_key}.base_url={_toml_string(codex.get('base_url', ''))}",
        "-c", f"model_providers.{provider_key}.env_key={_toml_string(codex.get('env_key', ''))}",
        "-c", f"model_providers.{provider_key}.wire_api={_toml_string(codex.get('wire_api', 'responses'))}",
    ])
    context_window = str(codex.get("context_window") or "").strip()
    if context_window.isdigit():
        cmd.extend(["-c", f"model_context_window={context_window}"])
    if resume_id:
        cmd.extend([resume_id, "-"])
    else:
        cmd.append("-")
    return cmd


def _build_codex_prompt(last_msg: str, sys_prompt: str, *, workspace: Optional[str]) -> str:
    system_block = ""
    if sys_prompt:
        system_block = (
            "下面是本项目 JSON-APP 生成核心规则，必须作为最高优先级规则执行。\n"
            "<core_generation_prompt>\n"
            f"{sys_prompt}\n"
            "</core_generation_prompt>\n\n"
        )
    return system_block + _build_user_turn_prompt(last_msg, workspace=workspace)


def _extract_codex_thread_id(line_str: str) -> Optional[str]:
    try:
        event = json.loads(line_str)
    except json.JSONDecodeError:
        return None
    if event.get("type") != "thread.started":
        return None
    thread_id = event.get("thread_id")
    return str(thread_id) if thread_id else None


def _agent_node_headers() -> dict:
    headers = {"Content-Type": "application/json"}
    if AGENT_NODE_TOKEN:
        headers["Authorization"] = f"Bearer {AGENT_NODE_TOKEN}"
    return headers


def _registered_agent_node_urls() -> List[str]:
    try:
        r = get_redis()
        urls: List[str] = []
        for key in r.scan_iter("ai:agent_node:*", count=100):
            data = r.hgetall(key)
            raw_url = data.get(b"url") or data.get("url")
            if not raw_url:
                continue
            url = raw_url.decode("utf-8", errors="replace") if isinstance(raw_url, bytes) else str(raw_url)
            url = url.rstrip("/")
            if url:
                urls.append(url)
        return sorted(set(urls))
    except Exception as exc:
        logger.warning("[AGENT_NODE] 读取注册节点失败: %s", exc)
        return []


def _configured_agent_node_urls() -> List[str]:
    urls = [url.rstrip("/") for url in AGENT_NODE_URLS if url.rstrip()]
    if not urls and AGENT_NODE_URL:
        urls = [AGENT_NODE_URL.rstrip("/")]
    for url in _registered_agent_node_urls():
        if url not in urls:
            urls.append(url)
    return urls


def _select_agent_node_url(session_id: str) -> str:
    urls = _configured_agent_node_urls()
    if not urls:
        raise RuntimeError("AI_WORKER_EXECUTION_BACKEND=agent-node 但 AGENT_NODE_URL/AGENT_NODE_URLS 未配置")
    r = get_redis()
    key = _agent_node_assignment_key(session_id)
    assigned = r.get(key)
    if isinstance(assigned, bytes):
        assigned = assigned.decode("utf-8", errors="replace")
    if assigned and assigned in urls:
        r.expire(key, AGENT_NODE_ASSIGNMENT_TTL_SECONDS)
        return assigned
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    selected = urls[int(digest[:12], 16) % len(urls)]
    r.set(key, selected, ex=AGENT_NODE_ASSIGNMENT_TTL_SECONDS)
    return selected


def _agent_node_provider_env(provider: dict) -> dict:
    """Only send the agent CLI env, never the backend process env."""
    env = dict(provider.get("cli_env") or {})
    env["IS_SANDBOX"] = "1"
    env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
    env["REGISTRY_BASE_URL"] = os.environ.get("REGISTRY_BASE_URL", "")
    env["MINIO_PUBLIC_URL"] = os.environ.get("MINIO_PUBLIC_URL", "")
    return {k: v for k, v in env.items() if v is not None}


def _agent_node_codex_config(provider: dict) -> dict:
    codex = dict(provider.get("codex") or {})
    if not codex:
        return {}
    # The real token is placed in the submit payload under a runtime-only env key;
    # agent-node rewrites it to a per-run proxy token before starting the container.
    env_key = str(codex.get("env_key") or "").strip()
    token = os.environ.get(env_key, "") if env_key else ""
    runtime_env_key = "MYAPP_CODEX_AUTH_TOKEN"
    codex["env_key"] = runtime_env_key
    codex["provider_id"] = str(provider.get("id") or "custom").replace("-", "_")
    codex["_runtime_token_env_key"] = runtime_env_key
    codex["_runtime_token"] = token
    return codex


def _run_agent_node_worker(
    *,
    store: SessionStore,
    session_id: str,
    job_id: Optional[str],
    last_msg: str,
    provider: dict,
    runner: str,
    agent_resume_id: Optional[str],
    sys_prompt: str,
    workspace: str,
    quota_used: int,
    quota_limit: int,
    quota_remaining: int,
    append_event,
    set_status,
    all_events: List[dict],
) -> None:
    agent_node_url = _select_agent_node_url(session_id)
    try:
        store.r.hset(_meta_key(session_id), "agent_node_url", agent_node_url)
        store.r.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
    except Exception:
        pass

    parse_line = parse_codex_line if runner == "codex" else parse_cli_line
    runtime_workspace = "/workspace"
    if runner == "codex":
        codex = _agent_node_codex_config(provider)
        env = _agent_node_provider_env(provider)
        for key in list(env.keys()):
            if key.startswith("ANTHROPIC_") or key.startswith("CLAUDE_CODE_") or key == "API_TIMEOUT_MS":
                env.pop(key, None)
        runtime_token_env_key = codex.pop("_runtime_token_env_key", "")
        runtime_token = codex.pop("_runtime_token", "")
        if runtime_token_env_key and runtime_token:
            env[runtime_token_env_key] = runtime_token
        prompt = _build_codex_prompt(last_msg, sys_prompt, workspace=runtime_workspace)
        resume_id = agent_resume_id or ""
    else:
        codex = {}
        env = _agent_node_provider_env(provider)
        prompt = _build_user_turn_prompt(last_msg, workspace=runtime_workspace)
        resume_id = agent_resume_id or ""

    run_id = _safe_path_part(job_id or uuid.uuid4().hex, "job")
    payload = {
        "run_id": run_id,
        "session_id": session_id,
        "job_id": job_id or run_id,
        "user_id": store.get_meta(session_id).get("user_id") or "user",
        "provider_id": provider.get("id"),
        "agent_id": runner,
        "resume_id": resume_id,
        "prompt": prompt,
        "system_prompt": sys_prompt if runner == "claude" and not resume_id else "",
        "env": env,
        "codex": codex,
    }

    _append_cli_log(session_id, "meta", json.dumps({
        "event": "agent_node_submit",
        "url": agent_node_url,
        "run_id": run_id,
        "provider": provider.get("id"),
        "agent": runner,
        "resume": bool(resume_id),
    }, ensure_ascii=False))
    response = requests.post(
        f"{agent_node_url}/v1/runs",
        headers=_agent_node_headers(),
        json=payload,
        timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
    )
    if response.status_code >= 400:
        raise RuntimeError(f"agent-node create run failed {response.status_code}: {response.text[:500]}")

    line_count = 0
    final_text: Optional[str] = None
    final_thinking: Optional[str] = None
    stderr_tail: List[str] = []
    remote_client_actions: List[dict] = []
    returncode: Optional[int] = None
    status = "failed"
    with requests.get(
        f"{agent_node_url}/v1/runs/{run_id}/events",
        headers=_agent_node_headers(),
        params={"follow": "1", "timeout": str(AGENT_NODE_EVENT_TIMEOUT_SECONDS)},
        stream=True,
        timeout=(AGENT_NODE_CONNECT_TIMEOUT_SECONDS, AGENT_NODE_EVENT_TIMEOUT_SECONDS + 30),
    ) as events_response:
        if events_response.status_code >= 400:
            raise RuntimeError(
                f"agent-node events failed {events_response.status_code}: {events_response.text[:500]}"
            )
        for raw_line in events_response.iter_lines(decode_unicode=True):
            if store.is_aborted(session_id):
                try:
                    requests.post(
                        f"{agent_node_url}/v1/runs/{run_id}/abort",
                        headers=_agent_node_headers(),
                        timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
                    )
                except Exception:
                    pass
                set_status(STATUS_ABORTED)
                return
            if not raw_line:
                continue
            try:
                item = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            item_type = item.get("type")
            if item_type == "stdout":
                line = str(item.get("line") or "")
                _append_cli_log(session_id, "stdout", line)
                if runner == "codex":
                    thread_id = _extract_codex_thread_id(line)
                    if thread_id:
                        store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
                for ev in parse_line(line):
                    if not append_event(ev):
                        return
                    all_events.append(ev)
                    line_count += 1
            elif item_type == "stderr":
                line = str(item.get("line") or "")
                stderr_tail.append(line)
                stderr_tail = stderr_tail[-20:]
                _append_cli_log(session_id, "stderr", line)
            elif item_type == "client_actions":
                payload = item.get("payload")
                if isinstance(payload, dict):
                    raw_actions = payload.get("client_actions")
                elif isinstance(payload, list):
                    raw_actions = payload
                else:
                    raw_actions = []
                if isinstance(raw_actions, list):
                    wants_upload_current_app = False
                    last_json_app_ready: Optional[dict] = None
                    for raw_action in raw_actions[:20]:
                        action = _normalize_client_action(raw_action, session_id)
                        if not action:
                            continue
                        if action["type"] == "request_upload_current_app":
                            wants_upload_current_app = True
                        elif action["type"] == "json_app_ready":
                            last_json_app_ready = action
                    remote_client_actions = []
                    if wants_upload_current_app:
                        remote_client_actions.append({"type": "request_upload_current_app"})
                    if last_json_app_ready:
                        remote_client_actions.append(last_json_app_ready)
            elif item_type == "stop":
                returncode = item.get("returncode")
                status = str(item.get("status") or "failed")
                break
            else:
                _append_cli_log(session_id, "meta", json.dumps(item, ensure_ascii=False))

    if store.is_aborted(session_id):
        set_status(STATUS_ABORTED)
        return
    if status != "done" or returncode not in (0, None):
        err_text = "".join(stderr_tail)[-2000:]
        err_msg = f"agent-node run failed status={status} returncode={returncode}: {err_text}"
        append_event({"error": err_msg, "needs_retry": True})
        set_status(STATUS_FAILED, error=err_msg)
        return

    final_text, final_thinking = extract_final_texts(all_events)
    protocol_warnings = _final_protocol_warnings(final_text)
    if protocol_warnings:
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "final_protocol_warning",
            "warnings": protocol_warnings,
            "tail": (final_text or "")[-500:],
        }, ensure_ascii=False))
    client_actions = remote_client_actions or _load_client_actions(workspace, session_id)
    for action in client_actions:
        if append_event({"client_action": action}):
            all_events.append({"client_action": action})
    append_event({"quota": {"used": quota_used, "limit": quota_limit, "remaining": quota_remaining}})
    set_status(
        STATUS_DONE,
        final_text=final_text or "",
        final_thinking=final_thinking or "",
        client_actions=client_actions,
    )
    _append_cli_log(session_id, "meta", json.dumps({
        "event": "agent_node_worker_done",
        "run_id": run_id,
        "lines": line_count,
        "final_text_len": len(final_text or ""),
        "final_thinking_len": len(final_thinking or ""),
        "client_actions": client_actions,
    }, ensure_ascii=False))


def _worker_main(session_id: str, last_msg: str, provider_id: Optional[str],
                 agent_id: Optional[str], agent_resume_id: Optional[str],
                 quota_used: int, quota_limit: int, quota_remaining: int,
                 job_id: Optional[str] = None) -> None:
    """线程池 worker 入口。
    把 claude CLI 输出解析为业务事件 + 写到 Redis stream，
    完成后落 meta status。

    任何异常都不能让线程崩——否则 status 永远停在 running，client 拉不到结果。
    """
    store = SessionStore()
    proc: Optional[subprocess.Popen] = None
    final_text: Optional[str] = None
    final_thinking: Optional[str] = None
    all_events: List[dict] = []

    def is_current_job() -> bool:
        if job_id is None:
            return True
        return store.get_meta(session_id).get("active_job_id") == job_id

    def append_event(event: dict) -> bool:
        if not is_current_job():
            logger.info(f"[WORKER] sid={session_id} job={job_id} 已被新 job 替换，停止写 stream")
            return False
        store.append_event(session_id, event)
        return True

    def set_status(status: str, **kwargs) -> bool:
        if not is_current_job():
            logger.info(f"[WORKER] sid={session_id} job={job_id} 已被新 job 替换，停止写 status={status}")
            return False
        store.set_status(session_id, status, **kwargs)
        return True

    try:
        # ─── 1. 起进程 ───
        # load_generate_prompt() 在生产是 no-op，测试环境会把 prompt 里硬编码的
        # 生产 URL 替换成实际环境 URL，避免 AI 生成的 JSON-APP 嵌入生产域名
        sys_prompt = ""
        try:
            sys_prompt = load_generate_prompt()
        except FileNotFoundError:
            logger.warning(f"[WORKER] 系统提示词文件未找到: {GENERATE_PROMPT_PATH}")

        provider, env = _provider_env(provider_id)
        agent = _agent_config(agent_id)
        runner = agent["id"]
        workspace = _prepare_worker_workspace(session_id, job_id)
        env["AI_APP_WORKSPACE"] = workspace
        env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
        parse_line = parse_cli_line

        _append_cli_log(session_id, "meta", json.dumps({
            "event": "worker_start",
            "provider": provider.get("id"),
            "agent": runner,
            "execution_backend": AI_WORKER_EXECUTION_BACKEND,
            "agent_resume_id": agent_resume_id or "",
            "user_msg_len": len(last_msg),
            "workspace": workspace,
            "ts": int(time.time() * 1000),
        }, ensure_ascii=False))

        if AI_WORKER_EXECUTION_BACKEND == "agent-node":
            _run_agent_node_worker(
                store=store,
                session_id=session_id,
                job_id=job_id,
                last_msg=last_msg,
                provider=provider,
                runner=runner,
                agent_resume_id=agent_resume_id,
                sys_prompt=sys_prompt,
                workspace=workspace,
                quota_used=quota_used,
                quota_limit=quota_limit,
                quota_remaining=quota_remaining,
                append_event=append_event,
                set_status=set_status,
                all_events=all_events,
            )
            return
        if AI_WORKER_EXECUTION_BACKEND != "local":
            raise ValueError(f"未知 AI_WORKER_EXECUTION_BACKEND: {AI_WORKER_EXECUTION_BACKEND}")

        if runner == "codex":
            _, env = _codex_env(provider, workspace)
            parse_line = parse_codex_line
            prompt = _build_codex_prompt(last_msg, sys_prompt, workspace=workspace)
            cmd = _build_codex_cmd(provider, workspace, resume_id=agent_resume_id)
            logger.info(
                f"[WORKER] sid={session_id} 起 Codex CLI "
                f"({'resume' if agent_resume_id else 'new'}): {cmd[0]}..."
            )
            proc = subprocess.Popen(
                cmd, cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.PIPE, env=env, bufsize=1,
            )
            _register_proc(session_id, proc)
            assert proc.stdin is not None
            proc.stdin.write(prompt.encode("utf-8"))
            proc.stdin.close()
            first_lines = []
        else:
            # Claude 有历史时 resume；首次会话直接指定 session-id 创建，避免无意义 fallback。
            resume_first = bool(agent_resume_id)
            cmd = _build_cli_cmd(
                session_id,
                last_msg,
                sys_prompt,
                is_resume=resume_first,
                workspace=workspace,
            )
            logger.info(
                f"[WORKER] sid={session_id} 起 Claude CLI "
                f"({'resume' if resume_first else 'new'}): {cmd[0]}..."
            )

            proc = subprocess.Popen(
                cmd, cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL, env=env, bufsize=1,
            )
            _register_proc(session_id, proc)

            # ─── 2. 读首行 ───
            first_lines = []
            line = proc.stdout.readline()
            if line:
                first_lines.append(line)

            # ─── 3. 检查是否是"resume 不存在"错误 → fallback 创建新会话 ───
            try:
                proc.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                pass

            if proc.returncode is not None and proc.returncode != 0:
                # 关键区分：
                # - is_aborted=True：是我们自己 abort 的（force_restart 或客户端 /abort）
                #   → 静默 ABORTED，不写 error 事件（避免下一轮 worker 复用 stream 时
                #     把这条假错误当真错误重放给 client）
                # - is_aborted=False 但 returncode 是信号 -15/-9：被外部 kill
                #   （管理员手动 kill / OOM Killer / supervisor 杀进程等），
                #   也不是我们自己干的 → 写 needs_retry 事件让客户端弹重试按钮
                # - 其他非 0 退出：CLI 真正异常，同样写 needs_retry
                if store.is_aborted(session_id):
                    logger.info(
                        f"[WORKER] sid={session_id} 启动阶段 self-abort "
                        f"(code {proc.returncode})，静默退出"
                    )
                    _append_cli_log(session_id, "meta", json.dumps({
                        "event": "aborted_during_startup",
                        "returncode": proc.returncode,
                    }, ensure_ascii=False))
                    set_status(STATUS_ABORTED)
                    return

                stderr_text = proc.stderr.read().decode("utf-8", errors="replace")
                stdout_text = b"".join(first_lines).decode("utf-8", errors="replace") + \
                              proc.stdout.read().decode("utf-8", errors="replace")
                full_err = stderr_text + "\n" + stdout_text

                if resume_first and ("No conversation found" in full_err or "requires a valid session ID" in full_err):
                    logger.info(f"[WORKER] sid={session_id} resume 失败，fallback 新会话")
                    _unregister_proc(session_id, proc)
                    cmd = _build_cli_cmd(
                        session_id,
                        last_msg,
                        sys_prompt,
                        is_resume=False,
                        workspace=workspace,
                    )
                    proc = subprocess.Popen(
                        cmd, cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        stdin=subprocess.DEVNULL, env=env, bufsize=1,
                    )
                    _register_proc(session_id, proc)
                    first_lines = []
                else:
                    # 信号 kill (-15/-9) 不是 self-abort 的话，那就是外部干的，按 retry 处理
                    killed_externally = proc.returncode in (-15, -9)
                    err_msg = (
                        f"Claude CLI 被外部信号 {proc.returncode} 终止"
                        if killed_externally
                        else f"Claude CLI 启动失败 (code {proc.returncode}): {stderr_text}"
                    )
                    _append_cli_log(session_id, "stderr", stderr_text)
                    _append_cli_log(session_id, "meta", json.dumps({
                        "event": "startup_failed_or_killed",
                        "returncode": proc.returncode,
                        "killed_externally": killed_externally,
                    }, ensure_ascii=False))
                    # needs_retry=True 让客户端 emit needsRetry → UI 弹重试按钮
                    # 启动失败基本都值得让用户重试一次（CLI 进程问题 / 临时网络等都是瞬态的）
                    err_evt = {"error": err_msg, "needs_retry": True}
                    append_event(err_evt)
                    set_status(STATUS_FAILED, error=err_msg)
                    return

        # ─── 4. 主循环：读 CLI 输出 → 解析 → 写 Redis ───
        line_count = 0
        for buffered in first_lines:
            _append_cli_log(session_id, "stdout", buffered)
            line_str = buffered.decode("utf-8", errors="replace")
            if runner == "codex":
                thread_id = _extract_codex_thread_id(line_str)
                if thread_id:
                    store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
            for ev in parse_line(line_str):
                if not append_event(ev):
                    try:
                        proc.terminate()
                    except Exception:
                        pass
                    return
                all_events.append(ev)
                line_count += 1

        # 然后实时读
        while True:
            if store.is_aborted(session_id):
                logger.info(f"[WORKER] sid={session_id} 收到 abort，杀进程")
                try:
                    proc.terminate()
                except Exception:
                    pass
                _append_cli_log(session_id, "meta", json.dumps({
                    "event": "aborted_by_flag",
                    "lines": line_count,
                }, ensure_ascii=False))
                set_status(STATUS_ABORTED)
                return

            line = proc.stdout.readline()
            if not line:
                # CLI 结束
                break

            _append_cli_log(session_id, "stdout", line)
            line_str = line.decode("utf-8", errors="replace")
            if runner == "codex":
                thread_id = _extract_codex_thread_id(line_str)
                if thread_id:
                    store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
            for ev in parse_line(line_str):
                if not append_event(ev):
                    try:
                        proc.terminate()
                    except Exception:
                        pass
                    return
                all_events.append(ev)
                line_count += 1

        proc.wait()

        # self-abort：静默 ABORTED，不写 error（避免下一轮 worker 复用 stream 时假错误重放）
        if store.is_aborted(session_id):
            logger.info(
                f"[WORKER] sid={session_id} 主循环结束 self-abort "
                f"(code {proc.returncode})，静默退出"
            )
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "self_aborted_in_main_loop",
                "returncode": proc.returncode,
                "lines": line_count,
            }, ensure_ascii=False))
            set_status(STATUS_ABORTED)
            return

        # ─── 5. 退出码 != 0 → 失败（含外部 kill） ───
        if proc.returncode != 0:
            killed_externally = proc.returncode in (-15, -9)
            runner_name = "Codex CLI" if runner == "codex" else "Claude CLI"
            err_text = proc.stderr.read().decode("utf-8", errors="replace")
            err_msg = (
                f"{runner_name} 被外部信号 {proc.returncode} 终止"
                if killed_externally
                else f"{runner_name} 异常退出 (code {proc.returncode}): {err_text}"
            )
            _append_cli_log(session_id, "stderr", err_text)
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "cli_exit_nonzero_or_killed",
                "returncode": proc.returncode,
                "killed_externally": killed_externally,
                "lines": line_count,
            }, ensure_ascii=False))
            # needs_retry=True → 客户端 emit needsRetry → UI 弹重试按钮
            err_evt = {"error": err_msg, "needs_retry": True}
            append_event(err_evt)
            set_status(STATUS_FAILED, error=err_msg)
            return

        # ─── 6. 正常完成 ───
        final_text, final_thinking = extract_final_texts(all_events)
        protocol_warnings = _final_protocol_warnings(final_text)
        if protocol_warnings:
            tail = (final_text or "")[-500:]
            logger.warning(
                "[WORKER] sid=%s final protocol warnings=%s tail=%r",
                session_id,
                protocol_warnings,
                tail,
            )
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "final_protocol_warning",
                "warnings": protocol_warnings,
                "tail": tail,
            }, ensure_ascii=False))
        client_actions = _load_client_actions(workspace, session_id)
        for action in client_actions:
            if append_event({"client_action": action}):
                all_events.append({"client_action": action})

        # 配额事件 + DONE 标记保留发到 stream（给老客户端兼容；新客户端从 meta 读）
        append_event({"quota": {
            "used": quota_used, "limit": quota_limit, "remaining": quota_remaining,
        }})
        set_status(
            STATUS_DONE,
            final_text=final_text or "",
            final_thinking=final_thinking or "",
            client_actions=client_actions,
        )
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "worker_done",
            "lines": line_count,
            "final_text_len": len(final_text or ""),
            "final_thinking_len": len(final_thinking or ""),
            "client_actions": client_actions,
        }, ensure_ascii=False))
        logger.info(
            f"[WORKER] sid={session_id} 完成 lines={line_count} "
            f"final_text_len={len(final_text or '')}"
        )

    except Exception as e:
        logger.exception(f"[WORKER] sid={session_id} 异常: {e}")
        try:
            append_event({"error": f"worker 异常: {e}"})
            set_status(STATUS_FAILED, error=str(e))
        except Exception:
            pass

    finally:
        if proc is not None:
            _unregister_proc(session_id, proc)
            try:
                # 兜底：如果还没退就再 kill 一次
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
            except Exception:
                pass


def submit_worker(session_id: str, last_msg: str, provider_id: Optional[str],
                  *, agent_id: str = DEFAULT_AGENT,
                  agent_resume_id: Optional[str] = None,
                  user_id: str, quota_used: int, quota_limit: int,
                  quota_remaining: int) -> Tuple[bool, Optional[int]]:
    """提交 worker 到 Redis 显式等待队列。立刻返回，不等任务完成。

    调用前应先 SessionStore.create_meta(status=queued)；这里只负责排队。
    返回 (accepted, queue_position)。
    """
    provider_id = _normalize_provider_id(provider_id)
    limits = _provider_worker_limits(provider_id)
    if limits["max_concurrency"] <= 0 or limits["queue_max"] <= 0:
        logger.warning(
            "[WORKER_QUEUE] provider disabled or queue closed sid=%s provider=%s limits=%s",
            session_id,
            provider_id,
            limits,
        )
        return False, None
    job = _WorkerJob(
        job_id=uuid.uuid4().hex,
        session_id=session_id,
        last_msg=last_msg,
        provider_id=provider_id,
        agent_id=agent_id,
        agent_resume_id=agent_resume_id,
        user_id=user_id,
        quota_used=quota_used,
        quota_limit=quota_limit,
        quota_remaining=quota_remaining,
    )
    job_json = _job_to_json(job)
    try:
        queued_len = get_redis().eval(
            _ENQUEUE_SCRIPT,
            2,
            _pending_queue_key(provider_id),
            _meta_key(session_id),
            job_json,
            limits["queue_max"],
            AI_SESSION_REDIS_TTL_SECONDS,
        )
    except redis.exceptions.RedisError as e:
        logger.exception(f"[WORKER_QUEUE] enqueue 失败 sid={session_id} provider={provider_id}: {e}")
        return False, None
    if int(queued_len) < 0:
        return False, None

    position = get_queue_position(session_id)
    if position is not None:
        SessionStore().append_event(
            session_id,
            {
                "status": STATUS_QUEUED,
                "queue_position": position,
                "message": _queue_status_message(position),
            },
        )
    return True, position


def abort_session(session_id: str) -> None:
    """请求 abort：写 abort 标记 + 尝试从 Redis pending 移除 + 本进程主动 kill。
    运行中的 worker 主循环会检测 abort 标记；跨 gunicorn worker 时不依赖本地进程表。
    """
    store = SessionStore()
    store.request_abort(session_id)
    meta = store.get_meta(session_id)
    queued_job = meta.get("queued_job")
    if queued_job:
        provider_id = _job_provider_from_json(queued_job, meta.get("provider"))
        queue_keys = [_pending_queue_key(provider_id), _pending_queue_key()]
        try:
            pipe = get_redis().pipeline()
            for queue_key in queue_keys:
                pipe.lrem(queue_key, 1, queued_job)
            removed_values = pipe.execute()
            removed = sum(int(value or 0) for value in removed_values)
        except redis.exceptions.RedisError as e:
            logger.warning(f"[WORKER_QUEUE] pending 移除失败 sid={session_id}: {e}")
            removed = 0
        if removed:
            store.set_status(session_id, STATUS_ABORTED, error="aborted before start")
    _kill_proc(session_id)


def clear_abort(session_id: str) -> None:
    """擦掉 abort 标记。force_restart 重启 worker 时用。"""
    SessionStore().clear_abort(session_id)


def _provider_ids_for_scheduler() -> list[str]:
    provider_ids = [
        pid for pid in AI_PROVIDERS
        if _provider_worker_limits(pid).get("max_concurrency", 0) > 0
    ]
    return provider_ids or [_normalize_provider_id(DEFAULT_PROVIDER)]


def run_worker_daemon() -> None:
    """独立 AI worker daemon 入口。

    Flask/gunicorn 进程只提交任务到 Redis；这个进程负责消费队列、启动 Claude CLI、
    刷新 running lease。这样 backend 可以多 worker，不会让队列和并发计数分裂。
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    logger.info(
        "[WORKER_DAEMON] start worker_id=%s total_max_concurrency=%s default_queue_max=%s provider_limits=%s",
        _WORKER_ID,
        AI_WORKER_MAX_CONCURRENCY,
        AI_WORKER_QUEUE_MAX,
        AI_PROVIDER_WORKER_LIMITS,
    )
    provider_ids = _provider_ids_for_scheduler()
    provider_index = 0
    while True:
        job = None
        for _ in range(len(provider_ids)):
            provider_id = provider_ids[provider_index % len(provider_ids)]
            provider_index += 1
            job = _acquire_redis_job(provider_id, timeout_seconds=0)
            if job is not None:
                break
        if job is None:
            time.sleep(0.2)
            continue
        logger.info(
            "[WORKER_DAEMON] acquired sid=%s job=%s provider=%s",
            job.session_id,
            job.job_id,
            job.provider_id,
        )
        _executor.submit(_run_redis_job, job)
