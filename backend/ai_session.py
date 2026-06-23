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

import hashlib
import io
import json
import logging
import os
import re
import requests
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import timedelta
from typing import Any, List, Optional, Tuple
from urllib.parse import urlparse

from flask import jsonify, request
from minio import Minio
import jwt
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
    AGENT_NODE_REGISTRATION_TOKEN,
    AGENT_NODE_TOKEN,
    AGENT_NODE_URL,
    AGENT_NODE_URLS,
    AI_SERVER_REPAIR_MAX_ATTEMPTS,
    CLAUDE_BIN,
    CODEX_BIN,
    CODEX_HOME,
    CODEX_NODE_BIN_DIR,
    CODEX_NPM_CACHE,
    CODEX_NPX_PACKAGE,
    DEFAULT_AGENT,
    DEFAULT_PROVIDER,
    GENERATION_PIPELINE_V1,
    MINIO_ACCESS_KEY,
    MINIO_ENDPOINT,
    MINIO_PUBLIC_URL,
    MINIO_SECRET_KEY,
    MINIO_SECURE,
    PROJECT_ROOT,
    generation_prompt_reference,
    load_generate_prompt,
    normalize_generation_pipeline,
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


def _faas_manifest_for_user(user_id: str) -> Optional[dict]:
    if not _env_enabled("FAAS_ENABLED", "1"):
        return None
    try:
        try:
            from config import FAAS_MAX_SERVICES_PER_USER
            from faas_store import list_services, read_service_source
        except ModuleNotFoundError:
            from backend.config import FAAS_MAX_SERVICES_PER_USER
            from backend.faas_store import list_services, read_service_source
        services = []
        for item in list_services(user_id):
            service_id = str(item.get("service_id") or "")
            services.append({
                "service_id": service_id,
                "slug": item.get("service_slug"),
                "status": item.get("status"),
                "routes": item.get("routes") or [],
                "invoke_url": f"/api/faas/invoke/{service_id}",
                # Pull the WHOLE current service folder (zip) to edit any files; see note.
                "archive_path": f"services/{service_id}/archive",
                "active_commit": item.get("active_commit") or "",
                "updated_at": str(item.get("updated_at") or ""),
                # app.py preview for a quick single-file append; for multi-file edits
                # pull the archive instead of basing only on this.
                "source": read_service_source(service_id),
            })
        database = {
            "available": _env_enabled("FAAS_USER_DB_ENABLED", "1"),
            "helper": "myapp_db",
            "how": "ship schema.sql (idempotent DDL) + import myapp_db in app.py; provisioned on deploy",
            "provisioned": False,
        }
        try:
            try:
                from faas_userdb import get_user_db as _get_udb, list_user_tables as _list_tables
            except ModuleNotFoundError:
                from backend.faas_userdb import get_user_db as _get_udb, list_user_tables as _list_tables
            udb = _get_udb(user_id)
            if udb:
                database.update({"provisioned": True, "schema": udb.get("schema_name"), "tables": _list_tables(user_id)})
        except Exception as exc:  # noqa: BLE001 - manifest must not fail on DB introspection
            logger.warning("[FAAS] user-db manifest introspection failed user=%s: %s", user_id, exc)

        return {
            "version": 1,
            "owner_user_id": user_id,
            "max_services": FAAS_MAX_SERVICES_PER_USER,
            "services": services,
            "database": database,
            "note": (
                "Read-only manifest of your existing FaaS backends. To MODIFY one, "
                "reuse its service_id (updates it IN PLACE and does NOT consume a new "
                "slot). Two ways to edit: (1) single-file tweak — base app.py on the "
                "service's `source` and redeploy a faas_bundle.json; (2) MULTI-FILE — "
                "run `bash backend/faas_pull.sh <service_id>` to download and unzip the "
                "entire current service folder, edit or add any files (app.py is the "
                "entrypoint; helper .py modules, packages, templates/, and data files "
                "are supported), then redeploy the folder with "
                "`bash backend/faas_deploy.sh <folder>`. Always keep ALL existing routes "
                "plus the new ones in service.json. Create a NEW service_id only for an "
                "unrelated backend, and only while under max_services. The invoke proxy "
                "enforces the routes/methods listed in service.json."
            ),
        }
    except Exception as exc:
        logger.warning("[FAAS] failed to build service manifest for user=%s: %s", user_id, exc)
        return {
            "version": 1,
            "owner_user_id": user_id,
            "services": [],
            "error": str(exc)[-500:],
        }


def _faas_manifest_initial_file(user_id: str) -> Optional[dict]:
    manifest = _faas_manifest_for_user(user_id)
    if manifest is None:
        return None
    return {
        "path": "faas_services.json",
        "content": json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
    }


def _write_faas_manifest(workspace: str, user_id: str) -> None:
    item = _faas_manifest_initial_file(user_id)
    if not item:
        return
    path = os.path.join(workspace, item["path"])
    with open(path, "w", encoding="utf-8") as f:
        f.write(item["content"])


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
    return pid or DEFAULT_PROVIDER


def _provider_env_prefix(provider_id: Optional[str]) -> str:
    return "".join(ch.upper() if ch.isalnum() else "_" for ch in _normalize_provider_id(provider_id))


def _env_bool_value(value: Optional[str]) -> Optional[bool]:
    if value is None:
        return None
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on", "enabled"}:
        return True
    if normalized in {"0", "false", "no", "off", "disabled"}:
        return False
    return None


def claude_cli_resume_enabled(provider_id: Optional[str]) -> bool:
    """Whether backend may ask Claude CLI to replay its own conversation state.

    Third-party Anthropic-compatible providers have shown incompatible resume
    behavior through Claude CLI (`API Error: Failed to parse JSON` or missing
    local conversation files). Keep CLI resume opt-in and rely on explicit
    prompt context plus persistent workspace by default.
    """
    prefix = _provider_env_prefix(provider_id)
    explicit = _env_bool_value(os.environ.get(f"{prefix}_CLAUDE_CLI_RESUME"))
    if explicit is not None:
        return explicit

    raw = os.environ.get("AI_CLAUDE_CLI_RESUME_PROVIDERS", "").strip()
    if not raw:
        return False
    normalized = raw.lower()
    if normalized in {"*", "all"}:
        return True
    allowed = {
        item.strip().lower().replace("_", "-")
        for item in raw.split(",")
        if item.strip()
    }
    return _normalize_provider_id(provider_id) in allowed


def _agent_cli_session_id(session_id: str, run_id: str) -> str:
    try:
        uuid.UUID(str(session_id))
        base = str(session_id)
    except (TypeError, ValueError):
        base = _safe_path_part(str(session_id or "session"), "session")
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"myapp-ai-cli:{base}:{run_id}"))


def _uses_agent_pull_backend() -> bool:
    return AI_WORKER_EXECUTION_BACKEND in {"agent-pull", "agent-node-pull", "pull"}


def _provider_queue_id(provider_id: Optional[str]) -> Optional[str]:
    # Pull-mode jobs are constrained by agent-node capacity/queue and may use
    # node-local provider ids unknown to the backend. Keep the real provider_id
    # in the job payload, but use the shared backend pending queue so the daemon
    # can acquire every node-routed job without knowing all provider ids.
    return None if _uses_agent_pull_backend() else _normalize_provider_id(provider_id)


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


def _agent_pull_pending_key() -> str:
    return "ai:agent_pull:pending"


def _agent_pull_private_pending_key(user_id: str) -> str:
    safe_user = _safe_path_part(user_id, "user")
    return f"ai:agent_pull:pending:user:{safe_user}"


def _agent_pull_pending_key_for_scope(agent_scope: str = "public", user_id: str = "") -> str:
    return _agent_pull_private_pending_key(user_id) if agent_scope == "private" else _agent_pull_pending_key()


def _agent_pull_acquire_lock_key() -> str:
    return "ai:agent_pull:acquire_lock"


def _agent_pull_session_node_key(session_id: str) -> str:
    safe = _safe_path_part(session_id, "session")
    return f"ai:agent_pull:session_node:{safe}"


def _agent_pull_private_session_node_key(user_id: str, session_id: str) -> str:
    safe_user = _safe_path_part(user_id, "user")
    safe_session = _safe_path_part(session_id, "session")
    return f"ai:agent_pull:session_node:user:{safe_user}:{safe_session}"


def _agent_pull_job_key(run_id: str) -> str:
    return f"ai:agent_pull:job:{run_id}"


def _agent_pull_events_key(run_id: str) -> str:
    return f"ai:agent_pull:events:{run_id}"


def _agent_pull_artifact_key(run_id: str, relative_path: str) -> str:
    safe = os.path.normpath(relative_path or "app.json").replace("\\", "/")
    safe = safe.strip("/").replace("/", "__") or "app.json"
    return f"ai:agent_pull:artifact:{run_id}:{safe}"


def _agent_pull_node_running_key(node_id: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(node_id or "agent-node")).strip("._") or "agent-node"
    return f"ai:agent_pull:node_running:{safe}"


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
                    status: str = STATUS_RUNNING,
                    agent_scope: str = "public",
                    generation_pipeline: str = GENERATION_PIPELINE_V1) -> None:
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
            "agent_scope": agent_scope or "public",
            "generation_pipeline": normalize_generation_pipeline(generation_pipeline),
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
        if status in TERMINAL_STATUSES:
            pipe.hdel(_meta_key(session_id), "queued_job")
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
_SERVER_UPLOAD_ACTION = "server_upload_app_json"
_SERVER_FAAS_ACTION = "server_deploy_faas_service"
_TEMP_JSON_BUCKET = os.environ.get("AI_CHAT_TEMP_JSON_BUCKET", "ai-chat-temp")
_TEMP_JSON_EXPIRY_HOURS = int(os.environ.get("AI_CHAT_TEMP_JSON_EXPIRY_HOURS", "24"))


class ServerUploadValidationError(RuntimeError):
    """Server-side repair/validate failed before JSON-APP upload."""

    def __init__(self, script: str, detail: str) -> None:
        self.script = script
        self.detail = detail
        super().__init__(f"{script} failed: {detail}")


@dataclass
class _AgentNodeRunResult:
    run_id: str
    status: str
    returncode: Optional[int]
    remote_client_actions: List[dict]
    stderr_tail: List[str]
    line_count: int
    transport_errors: List[str]


_CLI_TRANSPORT_ERROR_MARKERS = (
    "API Error: Failed to parse JSON",
)


def _is_cli_transport_error(text: object) -> bool:
    value = str(text or "")
    return any(marker in value for marker in _CLI_TRANSPORT_ERROR_MARKERS)


def _is_internal_cli_event(event: dict) -> bool:
    return bool(event.get("_internal_cli_event"))


def _agent_cli_transport_retry_max() -> int:
    try:
        return max(0, min(5, int(os.environ.get("AI_AGENT_CLI_TRANSPORT_RETRY_MAX", "2"))))
    except (TypeError, ValueError):
        return 2


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

    if action_type == _SERVER_UPLOAD_ACTION:
        path = str(raw.get("path") or "app.json").strip() or "app.json"
        normalized = os.path.normpath(path).replace("\\", "/")
        if normalized.startswith("../") or normalized == ".." or os.path.isabs(normalized):
            _client_action_warning(session_id, "server_upload_app_json 路径非法", detail=raw)
            return None
        if normalized != "app.json" and not normalized.endswith(".json"):
            _client_action_warning(session_id, "server_upload_app_json 只允许 JSON 文件", detail=raw)
            return None
        return {"type": _SERVER_UPLOAD_ACTION, "path": normalized}

    if action_type == _SERVER_FAAS_ACTION:
        path = str(raw.get("path") or "faas_bundle.json").strip() or "faas_bundle.json"
        normalized = os.path.normpath(path).replace("\\", "/")
        if normalized.startswith("../") or normalized == ".." or os.path.isabs(normalized):
            _client_action_warning(session_id, "server_deploy_faas_service 路径非法", detail=raw)
            return None
        if not normalized.endswith(".json"):
            _client_action_warning(session_id, "server_deploy_faas_service 只允许 JSON bundle", detail=raw)
            return None
        out = {"type": _SERVER_FAAS_ACTION, "path": normalized}
        service_id = str(raw.get("service_id") or "").strip()
        if service_id:
            out["service_id"] = service_id[:96]
        return out

    _client_action_warning(session_id, "未知 client action type", detail=raw)
    return None


def _compact_client_actions(raw_actions: list, session_id: str) -> List[dict]:
    wants_upload_current_app = False
    last_json_app_ready: Optional[dict] = None
    server_uploads: List[dict] = []
    faas_deploys: List[dict] = []
    for raw in raw_actions[:20]:
        action = _normalize_client_action(raw, session_id)
        if not action:
            continue
        if action["type"] == "request_upload_current_app":
            wants_upload_current_app = True
        elif action["type"] == "json_app_ready":
            last_json_app_ready = action
        elif action["type"] == _SERVER_UPLOAD_ACTION:
            server_uploads.append(action)
        elif action["type"] == _SERVER_FAAS_ACTION:
            faas_deploys.append(action)

    out: List[dict] = []
    if wants_upload_current_app:
        out.append({"type": "request_upload_current_app"})
    if last_json_app_ready:
        out.append(last_json_app_ready)
    # One JSON app upload is the final app. FaaS bundles are independent, so
    # keep a few in case a single generated app intentionally creates multiple
    # tiny backend services. The backend-side per-user quota is still enforced.
    out.extend(server_uploads[-1:])
    out.extend(faas_deploys[-5:])
    return out


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

    return _compact_client_actions(raw_actions, session_id)


def _artifact_from_local_workspace(workspace: Optional[str], relative_path: str, session_id: str) -> bytes:
    if not workspace:
        raise RuntimeError("server upload requires workspace")
    root = os.path.abspath(workspace)
    candidate = os.path.abspath(os.path.join(root, relative_path or "app.json"))
    if os.path.commonpath([root, candidate]) != root:
        raise RuntimeError("server upload path escapes workspace")
    if not os.path.isfile(candidate):
        raise RuntimeError(f"server upload artifact not found: {relative_path}")
    with open(candidate, "rb") as f:
        return f.read()


def _artifact_from_agent_node(agent_node_url: str, run_id: str, relative_path: str) -> bytes:
    if not agent_node_url or not run_id:
        raise RuntimeError("server upload requires agent node url and run id")
    response = requests.get(
        f"{agent_node_url}/v1/runs/{run_id}/artifact",
        headers=_agent_node_headers(),
        params={"path": relative_path or "app.json"},
        timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
    )
    if response.status_code >= 400:
        raise RuntimeError(f"agent-node artifact fetch failed {response.status_code}: {response.text[:500]}")
    return response.content


def _artifact_from_agent_pull(run_id: str, relative_path: str) -> bytes:
    normalized = os.path.normpath(str(relative_path or "app.json").strip() or "app.json").replace("\\", "/")
    if normalized.startswith("../") or normalized == ".." or os.path.isabs(normalized):
        raise RuntimeError(f"invalid agent pull artifact path: {relative_path or 'app.json'}")
    raw = get_redis().get(_agent_pull_artifact_key(run_id, normalized))
    if not raw:
        raise RuntimeError(f"agent pull artifact not found: {normalized}")
    return raw if isinstance(raw, bytes) else str(raw).encode("utf-8")


def _repair_validate_json_bytes(data: bytes, session_id: str) -> bytes:
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as tmp:
        tmp.write(data)
        tmp_path = tmp.name
    try:
        for script in ("repair_json_app.py", "validate_json_app.py"):
            proc = subprocess.run(
                [sys.executable, os.path.join(PROJECT_ROOT, "backend", script), tmp_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
            )
            if proc.returncode != 0:
                detail = (proc.stdout + "\n" + proc.stderr)[-4000:]
                _client_action_warning(session_id, f"{script} failed", detail=detail)
                raise ServerUploadValidationError(script, detail)
        with open(tmp_path, "rb") as f:
            return f.read()
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _upload_temp_json_app(data: bytes) -> str:
    if not MINIO_ACCESS_KEY or not MINIO_SECRET_KEY:
        raise RuntimeError("backend MinIO credentials are not configured")
    object_name = f"{uuid.uuid4().hex}.json"
    client = Minio(
        MINIO_ENDPOINT,
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=MINIO_SECURE,
    )
    if not client.bucket_exists(_TEMP_JSON_BUCKET):
        client.make_bucket(_TEMP_JSON_BUCKET)
    client.put_object(
        _TEMP_JSON_BUCKET,
        object_name,
        io.BytesIO(data),
        len(data),
        content_type="application/json",
    )
    presign_client = client
    public_base = MINIO_PUBLIC_URL.rstrip("/")
    if public_base:
        parsed = urlparse(public_base)
        if parsed.netloc:
            presign_client = Minio(
                parsed.netloc,
                access_key=MINIO_ACCESS_KEY,
                secret_key=MINIO_SECRET_KEY,
                secure=parsed.scheme == "https",
            )
    return presign_client.presigned_get_object(
        _TEMP_JSON_BUCKET,
        object_name,
        expires=timedelta(hours=_TEMP_JSON_EXPIRY_HOURS),
    )


_FAAS_INVOKE_ID_RE = re.compile(r'(/api/faas/invoke/)([^/"\'\s\?\\]+)')


def _rewrite_faas_invoke_service_id(data: bytes, deployed: List[tuple]) -> bytes:
    """把 JSON-APP 里 `/api/faas/invoke/<x>/...` 的 `<x>` 改写成真实部署的 service_id。

    AI 常用 slug（或自造名）当 invoke id，而后端为保证全局唯一会生成 `svc-<hex>`，
    两者对不上 → 客户端调一个不存在的服务 → 404。后端在部署后已知真实 id，这里统一兜底：
    - 本轮只部署了 1 个服务（最常见）：所有 invoke id 一律改成它；
    - 多个服务：按 slug / 显式 id 别名映射改写，未命中的保持原样。
    """
    if not deployed:
        return data
    try:
        text = data.decode("utf-8")
    except Exception:
        return data
    if "/api/faas/invoke/" not in text:
        return data
    if len(deployed) == 1:
        only_id = deployed[0][1]
        return _FAAS_INVOKE_ID_RE.sub(
            lambda m: m.group(1) + only_id, text
        ).encode("utf-8")
    alias_map: dict = {}
    for aliases, service_id in deployed:
        for alias in aliases:
            alias_map[alias] = service_id
    return _FAAS_INVOKE_ID_RE.sub(
        lambda m: m.group(1) + alias_map.get(m.group(2), m.group(2)), text
    ).encode("utf-8")


def _resolve_server_upload_actions(
    actions: List[dict],
    session_id: str,
    *,
    workspace: Optional[str],
    agent_node_url: str = "",
    run_id: str = "",
    agent_pull_run_id: str = "",
    owner_user_id: str = "",
    allow_faas_repair: bool = False,
) -> List[dict]:
    resolved: List[dict] = []
    last_json_app_ready: Optional[dict] = None
    deployed_faas: List[tuple] = []  # [(aliases:set, real_service_id)] 供 app.json 改写
    for action in actions:
        if action.get("type") == _SERVER_FAAS_ACTION:
            # Deprecated: FaaS deploy is now agent-driven IN-RUN via
            # backend/faas_deploy.sh — the agent gets the real service_id, self-tests,
            # wires the JSON-APP itself, then uploads. Drop any stray legacy deploy
            # action so we never double-deploy. (Full removal of this path + the
            # service_id rewrite is a follow-up cleanup once the new flow is verified.)
            continue
        if action.get("type") != _SERVER_UPLOAD_ACTION:
            resolved.append(action)
            if action.get("type") == "json_app_ready":
                last_json_app_ready = action
            continue
        if last_json_app_ready:
            continue
        relative_path = str(action.get("path") or "app.json")
        raw = (
            _artifact_from_agent_node(agent_node_url, run_id, relative_path)
            if agent_node_url and run_id
            else _artifact_from_agent_pull(agent_pull_run_id, relative_path)
            if agent_pull_run_id
            else _artifact_from_local_workspace(workspace, relative_path, session_id)
        )
        repaired = _repair_validate_json_bytes(raw, session_id)
        repaired = _rewrite_faas_invoke_service_id(repaired, deployed_faas)
        url = _upload_temp_json_app(repaired)
        last_json_app_ready = {"type": "json_app_ready", "url": url}
        resolved.append(last_json_app_ready)
    return [
        action for action in resolved
        if action.get("type") not in {_SERVER_UPLOAD_ACTION, _SERVER_FAAS_ACTION}
    ]


def _build_server_repair_request(
    *,
    script: str,
    detail: str,
    relative_path: str,
    attempt: int,
    max_attempts: int,
) -> str:
    clipped_detail = detail[-6000:]
    if script == _SERVER_FAAS_ACTION:
        return (
            "服务端部署后端服务（FaaS）失败，后端正在自动请求你修复 bundle。"
            f"这是第 {attempt}/{max_attempts} 次自动修复。\n\n"
            "约束：\n"
            "- 只修复 `$AI_APP_WORKSPACE/faas_bundle.json`，不要重新设计应用，不要改变用户需求。\n"
            "- 不要向用户追问，不要输出客户端协议标签。\n"
            "- 让 `service.routes` 里声明的每个 path+method 都在 `app.py` 中实现："
            "用 `@app.get/post/put/patch/delete/options(...)` 或 `@app.route(..., methods=[...])`，"
            "路径形状要与声明一致（动态段如 `/items/<item_id>`，方法齐全）。\n"
            "- `app.py` 顶层只允许 imports、`app = Flask(__name__)`、literal 常量、路由函数和可选 "
            "`if __name__ == '__main__'` guard；不要顶层 IO/网络/线程，不要读环境变量或文件。\n"
            "- 不要声明保留路径（健康检查等由运行时自动提供，声明会被拒绝）。\n"
            "- 修复后必须保留 `client_actions.json` 里的 "
            "`{\"type\":\"server_deploy_faas_service\",\"path\":\"faas_bundle.json\"}`，让后端重新部署。\n\n"
            f"失败阶段：{script}\n"
            "部署错误如下：\n"
            "```text\n"
            f"{clipped_detail}\n"
            "```"
        )
    return (
        "服务端上传前校验失败，后端正在自动请求你修复当前 JSON-APP。"
        f"这是第 {attempt}/{max_attempts} 次自动修复。\n\n"
        "约束：\n"
        f"- 只修复 `$AI_APP_WORKSPACE/{relative_path or 'app.json'}`，不要重新设计应用，不要改变用户需求。\n"
        "- 不要向用户追问，不要输出客户端协议标签。\n"
        "- 优先做最小修改，让 JSON-APP 通过服务端校验并保持原有功能/UI。\n"
        "- 修复后必须在容器内重新运行 `python3 backend/validate_json_app.py \"$AI_APP_WORKSPACE/app.json\"`。\n"
        "- 校验通过后必须执行 `bash backend/upload_with_signature.sh \"$AI_APP_WORKSPACE/app.json\"`，"
        "让脚本重新写入 `$AI_APP_WORKSPACE/client_actions.json`。\n\n"
        f"失败脚本：{script}\n"
        "校验错误如下：\n"
        "```text\n"
        f"{clipped_detail}\n"
        "```"
    )


def _tool_status_message(tool_name: str, tool_input: dict) -> str:
    """工具调用 → 返回状态 key（前端根据 key 做 i18n）。

    返回格式：
    - 简单 key: "tool.reading"
    - 带参数: "tool.reading_file|config.json" (前端用 | 分割)
    """
    if tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        if file_path:
            return f"tool.reading_file|{os.path.basename(file_path)}"
        return "tool.reading"
    elif tool_name == "Write":
        file_path = tool_input.get("file_path", "")
        if file_path:
            return f"tool.writing_file|{os.path.basename(file_path)}"
        return "tool.writing"
    elif tool_name in ("Grep", "Glob"):
        return "tool.searching"
    elif tool_name == "Bash":
        return "tool.running_command"
    elif tool_name == "Edit":
        return "tool.editing"
    elif tool_name == "WebFetch":
        return "tool.fetching_web"
    elif tool_name == "WebSearch":
        return "tool.searching_web"
    elif tool_name in ("Task", "TodoWrite", "TaskUpdate"):
        return "tool.updating_plan"
    return f"tool.using_tool|{tool_name}"


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
        out.append({"status": "init", "message": "status.ai_engine_started"})

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
                    if event.get("error") and _is_cli_transport_error(text_value):
                        out.append({
                            "_internal_cli_event": True,
                            "cli_transport_error": text_value,
                        })
                    else:
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
            if _is_cli_transport_error(res):
                out.append({
                    "_internal_cli_event": True,
                    "cli_transport_error": str(res or ""),
                })
            else:
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


def parse_opencode_line(line_str: str) -> List[dict]:
    """Parse OpenCode `run --format json` plus runner export events."""
    line_str = line_str.strip()
    if not line_str:
        return []
    try:
        event = json.loads(line_str)
    except json.JSONDecodeError as e:
        logger.warning(f"[OPENCODE_PARSE] JSON 解析失败: {e}, line: {line_str[:100]}...")
        return []

    out: List[dict] = []
    evt_type = str(event.get("type") or "")
    if evt_type == "step_start":
        out.append({"status": "thinking", "message": "AI 正在思考..."})
        return out
    if evt_type == "opencode_export":
        reasoning = event.get("reasoning")
        text = event.get("text")
        if isinstance(reasoning, str) and reasoning.strip():
            out.append({"assistant_thinking": reasoning})
            out.append({"final_thinking": reasoning})
        if isinstance(text, str) and text.strip():
            out.append({"assistant_content": text})
            out.append({"final_content": text})
        return out
    if evt_type == "opencode_export_error":
        message = event.get("message") or "OpenCode export failed"
        out.append({"error": str(message), "needs_retry": True})
        return out
    if evt_type in {"error", "step_error"}:
        message = event.get("message") or event.get("error") or "OpenCode 执行失败"
        out.append({"error": str(message), "needs_retry": True})
        return out

    part = event.get("part")
    if isinstance(part, dict):
        part_type = str(part.get("type") or "")
        text = part.get("text")
        if part_type == "text" and isinstance(text, str) and text:
            out.append({"assistant_content": text})
        elif part_type == "reasoning" and isinstance(text, str) and text:
            out.append({"assistant_thinking": text})
        elif part_type in {"step-finish", "step_finish"}:
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
    agent_scope: str
    generation_pipeline: str
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


def is_session_proc_alive(
    session_id: str,
    provider_id: Optional[str] = None,
    meta: Optional[dict] = None,
) -> bool:
    """跨 gunicorn worker 判断运行租约是否还活着。"""
    if meta is None:
        try:
            meta = SessionStore().get_meta(session_id)
        except redis.exceptions.RedisError:
            meta = {}
    provider = provider_id or _job_provider_from_json((meta or {}).get("queued_job"), (meta or {}).get("provider"))
    lease_keys = [_running_lease_key()]
    if provider:
        lease_keys.append(_provider_running_lease_key(provider))
    now_ms = int(time.time() * 1000)
    try:
        r = get_redis()
        for key in dict.fromkeys(lease_keys):
            score = r.zscore(key, session_id)
            if score is not None and float(score) > now_ms:
                return True
    except redis.exceptions.RedisError as e:
        logger.warning(f"[WORKER_QUEUE] 读取 running lease 失败 sid={session_id}: {e}")
    return False


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
    queue_provider_id = _provider_queue_id(provider_id)
    try:
        raw_jobs = r.lrange(_pending_queue_key(queue_provider_id), 0, -1)
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


def reconcile_stale_queued(session_id: str) -> dict:
    """Turn impossible queued state into a terminal failure.

    queued is only valid while queued_job is still in a pending list or while a
    worker has already claimed the session lease and is about to mark running.
    If neither is true, the job was lost after LPOP or aborted before startup.
    """
    store = SessionStore()
    meta = store.get_meta(session_id)
    if meta.get("status") != STATUS_QUEUED:
        return meta
    if get_queue_position(session_id) is not None or is_session_proc_alive(session_id):
        return meta
    err_msg = "AI worker queue state lost; please retry"
    store.append_event(session_id, {"error": err_msg, "needs_retry": True})
    store.set_status(session_id, STATUS_FAILED, error=err_msg)
    return store.get_meta(session_id)


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
        agent_scope=str(data.get("agent_scope") or "public").strip().lower(),
        generation_pipeline=normalize_generation_pipeline(data.get("generation_pipeline")),
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


def _acquire_redis_job(provider_id: Optional[str], timeout_seconds: int = 0) -> Optional[_WorkerJob]:
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
                provider_id or "",
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
    store = SessionStore()

    def heartbeat_loop() -> None:
        while not stop_heartbeat.wait(_WORKER_HEARTBEAT_SECONDS):
            try:
                # If THIS job was aborted, stop renewing the lease and release it now,
                # so a force_restart can take over even while this worker is still
                # blocked in a long agent-node read. Gate on active_job_id == this job:
                # a stale session abort flag, or a job already replaced by a newer one,
                # must NOT free a lease that now belongs to the newer job. (The lease is
                # session-keyed; only the current owner may release it.)
                cur = store.get_meta(job.session_id)
                if cur and cur.get("active_job_id") == job.job_id and store.is_aborted(job.session_id):
                    logger.info(f"[WORKER_QUEUE] heartbeat 检测到 abort，释放 running lease sid={job.session_id} job={job.job_id}")
                    _complete_running(job.session_id, job.provider_id)
                    return
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
        meta = store.get_meta(job.session_id)
        expected_job = _job_to_json(job)
        if not meta:
            logger.info(f"[WORKER_QUEUE] sid={job.session_id} job={job.job_id} meta 不存在，跳过")
            return
        if store.is_aborted(job.session_id):
            logger.info(f"[WORKER_QUEUE] sid={job.session_id} job={job.job_id} 启动前已 abort")
            if meta.get("active_job_id") == job.job_id:
                store.set_status(job.session_id, STATUS_ABORTED, error="aborted before start")
            return
        if meta.get("status") in TERMINAL_STATUSES:
            logger.info(
                f"[WORKER_QUEUE] sid={job.session_id} job={job.job_id} 已是终态 "
                f"status={meta.get('status')}，跳过"
            )
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
            job.generation_pipeline,
            job.quota_used,
            job.quota_limit,
            job.quota_remaining,
            job_id=job.job_id,
        )
    except Exception as exc:
        logger.exception(
            "[WORKER_QUEUE] job 执行异常 sid=%s job=%s provider=%s: %s",
            job.session_id,
            job.job_id,
            job.provider_id,
            exc,
        )
        try:
            meta = store.get_meta(job.session_id)
            if meta.get("active_job_id") == job.job_id:
                err_msg = f"AI worker job failed: {exc}"
                store.append_event(job.session_id, {"error": err_msg, "needs_retry": True})
                store.set_status(job.session_id, STATUS_FAILED, error=err_msg)
        except Exception:
            logger.exception(
                "[WORKER_QUEUE] job 异常后写失败状态也失败 sid=%s job=%s",
                job.session_id,
                job.job_id,
            )
    finally:
        stop_heartbeat.set()
        # Only release the lease if this job still owns the session. A force_restart
        # (after this worker released the lease early on abort) may have handed the
        # session to a newer job — we must not clobber that newer job's lease.
        cur = store.get_meta(job.session_id)
        if not cur or cur.get("active_job_id") in (None, "", job.job_id):
            _complete_running(job.session_id, job.provider_id)


def _env_enabled(name: str, default: str = "0") -> bool:
    return str(os.environ.get(name, default)).strip().lower() in {"1", "true", "yes", "on", "enabled"}


def _provider_supports_vision(provider: dict) -> bool:
    """Whether the run's model accepts image input. Default False (safe: text-only
    review), opt in per provider via ``<PREFIX>_SUPPORTS_VISION=1`` (e.g.
    MINIMAX_SUPPORTS_VISION=1). A non-vision model that tries to Read a screenshot
    PNG fails the whole run with a 400, so we keep the visual review text-only unless
    the provider is explicitly known to read images."""
    pid = provider.get("id") if isinstance(provider, dict) else None
    prefix = _provider_env_prefix(pid)
    return _env_enabled(f"{prefix}_SUPPORTS_VISION", "0")


def _visual_review_env() -> dict[str, str]:
    keys = (
        "AI_APP_VISUAL_REVIEW_ENABLED",
        "AI_APP_VISUAL_REVIEW_CMD",
        "AI_APP_VISUAL_REVIEW_WEB_BASE",
        "AI_APP_VISUAL_REVIEW_REMOTE_PARAM",
        "AI_APP_VISUAL_REVIEW_PRIMARY_VIEWPORT",
        "AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT",
        "AI_APP_VISUAL_REVIEW_MAX_CLICKS",
        "AI_APP_VISUAL_REVIEW_TIMEOUT",
        "AI_APP_VISUAL_REVIEW_STABILIZE_SECONDS",
    )
    return {key: os.environ[key] for key in keys if os.environ.get(key)}


def _build_visual_review_prompt_note(*, workspace: Optional[str] = None) -> str:
    if not _env_enabled("AI_APP_VISUAL_REVIEW_ENABLED"):
        return ""
    cmd = os.environ.get("AI_APP_VISUAL_REVIEW_CMD", "myapp-visual-review").strip() or "myapp-visual-review"
    app_path = "$AI_APP_WORKSPACE/app.json" if workspace else "app.json"
    capture_small = " --capture-small" if os.environ.get("AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT", "").strip() else ""
    return (
        "\n\n视觉复检工具（本轮可选能力，不能替代 validate/upload）："
        f"\n- 运行命令：`{cmd} \"{app_path}\"{capture_small}`。"
        "\n- 该工具只负责用真实 Flutter Web JSON 解释器渲染、截图和生成 report.md/report.json；"
        "不会调用任何额外视觉 API。"
        "\n- 复杂 APP、视觉质量敏感 APP、游戏或多页面 APP 在最终上传前至少运行一次，"
        "然后**打开 `$AI_APP_WORKSPACE/visual_review/report.md` 并严格按它的「Agent Instruction」执行**。"
        "\n- ⚠️ 报告会按本轮模型能力自动裁剪：如果报告标注 text-only / 没有内嵌截图，"
        "说明**本轮模型不支持图片输入——绝对不要去 Read 或打开任何 PNG 截图**"
        "（无图片能力的模型读图会直接 400 失败整轮），只依据报告里的文字结论"
        "（渲染是否成功、交互是否变化、issues）来判断，不要声称做了图片级视觉评估。"
        "\n- 只有当报告内嵌了截图（说明本轮模型支持图片输入）时，才去读取这些 PNG 并据此修 JSON 再 repair/validate。"
        "\n- 视觉复检不是客户端动作；最终仍必须通过 upload_with_signature.sh 写入 client_actions。"
    )


_FAAS_GEN_EXAMPLE = """

下面是一份能通过服务端校验的最小参考骨架（声明与实现严格对齐，含集合与单条 CRUD）。
照这个**结构**写你自己的接口，但要换成真实业务，不要照抄 notes：

```json
{"service":{"slug":"notes-api","routes":[
  {"path":"/notes","methods":["GET","POST"]},
  {"path":"/notes/<note_id>","methods":["GET","PUT","DELETE"]}
]},"files":{"app.py":"<见下>","requirements.txt":"flask==3.0.3\\n"}}
```

```python
from flask import Flask, jsonify, request
app = Flask(__name__)
_NOTES = {}
_SEQ = {"n": 0}

@app.get("/notes")
def list_notes():
    return jsonify(list(_NOTES.values()))

@app.post("/notes")
def create_note():
    body = request.get_json(silent=True) or {}
    _SEQ["n"] += 1
    nid = str(_SEQ["n"])
    _NOTES[nid] = {"id": nid, "text": body.get("text", "")}
    return jsonify(_NOTES[nid]), 201

@app.get("/notes/<note_id>")
def get_note(note_id):
    note = _NOTES.get(note_id)
    return (jsonify(note), 200) if note else (jsonify(error="not found"), 404)

@app.put("/notes/<note_id>")
def update_note(note_id):
    if note_id not in _NOTES:
        return jsonify(error="not found"), 404
    body = request.get_json(silent=True) or {}
    _NOTES[note_id]["text"] = body.get("text", _NOTES[note_id]["text"])
    return jsonify(_NOTES[note_id])

@app.delete("/notes/<note_id>")
def delete_note(note_id):
    _NOTES.pop(note_id, None)
    return jsonify(ok=True)
```

要点：`service.routes` 里每个 path+method 都和某个 `@app.xxx` 装饰器一一对应；动态段写成 `/notes/<note_id>` 且声明与实现一致；不要写健康检查（运行时自动提供）。"""


def _build_faas_backend_prompt_note(*, workspace: Optional[str] = None) -> str:
    if not _env_enabled("FAAS_ENABLED", "1"):
        return ""
    bundle_path = "$AI_APP_WORKSPACE/faas_bundle.json" if workspace else "faas_bundle.json"
    return (
        "\n\n可选后端能力（FaaS，只有用户明确需要后端接口/持久计算/服务端逻辑时才使用）："
        "\n- **【强制·先分层选轨道】一旦判断本次涉及后端 / 持久化 / 社交，在写任何 bundle / app.py / JSON-APP 之前，"
        "先 `cat docs/playbooks/README.md`（总路由）按决策树选准一条「轨道」，再分层只读那条轨道要求的 playbook，"
        "不要盲读 demo 源码。** 三条轨道与读法："
        "\n  - **FaaS 全栈轨**（多用户 / 数据库持久化 / 论坛社区 / 应用内假名社交）：先 `cat docs/playbooks/faas-jsonapp.md`"
        "（受限 Flask、`faas` 调用库 + `app` 命名空间、绝不写死域名/URL、本轮内部署自测拿真实 service_id、`@faas.*` 接线），"
        "再 `cat docs/playbooks/faas-fullstack.md`（UUID 数据模型 / `myapp_db`+`myapp_auth` 三套路 / 不可伪造组内假名+真实昵称 / "
        "楼中楼 DFS+折叠 / 用户主页+好友+私信 / 部署自测）；范本 `docs/examples/tieba/`（前端 7 屏 + 后端 14 路由）。"
        "\n  - **简单 FaaS 轨**（要后端但无数据库：代理/计算/第三方 HTTP/定时）：只 `cat docs/playbooks/faas-jsonapp.md`。"
        "\n  - **平台 IM 轨**（微信式平台级实时社交：搜得到平台上任何人 / 推送 / 通讯录 / 跨 App 同一个人）→ **不该建 FaaS**，"
        "改 `cat docs/playbooks/platform-im.md`（范本 `docs/examples/demo-im/` + `templates/demo_im.json`，用 `lib_im` 平台 IM 能力、"
        "**完全不写后端**）。只有「论坛/社区内部、用假名、要自定义表」的轻社交才走 FaaS 全栈轨。"
        "\n- 跳过分层阅读、或直接照抄 demo 源码，是带后端 JSON-APP 生成失败的主因——务必先读对的 playbook 再动手。"
        f"\n- 你可以生成一个受限 Python/Flask 后端服务 bundle：`{bundle_path}`。"
        "\n- 你在本轮内自己完成部署、自测、接好前端（见下方后端工作流）；不要操作 Git/Docker/密钥，"
        "脚本会安全地代你调用后端部署。"
        "\n- 工作区会提供只读 `faas_services.json`，列出当前用户已有 FaaS 服务、路由、调用地址以及每个服务的现有源码 `source`；"
        "如果本轮是在给已有后端追加接口，请复用其 `service_id`，基于 `source` 里的 `app.py` 续写、"
        "并在 routes 中同时保留原有路由和新增路由（追加不占用新的服务配额）；"
        "只有当确实是无关的新后端、且未超过 `max_services` 时才创建新的 `service_id`。"
        "\n- 只允许 Python/Flask；最小 bundle JSON 结构是："
        "`{\"service\":{\"slug\":\"todo-api\",\"routes\":[{\"path\":\"/items\",\"methods\":[\"GET\",\"POST\"]}]},"
        "\"files\":{\"app.py\":\"...Flask app code...\",\"requirements.txt\":\"flask==3.0.3\\n\"}}`。"
        "\n- 一个服务可以是多文件：`files` 里除 `app.py`（入口，必须暴露 Flask `app`）和 `requirements.txt` 外，"
        "还可放多个 `.py` 模块/子包（`from helpers import ...`、`import lib.util`）、`templates/` 目录、"
        "以及 `.json/.txt/.csv/.md/.html/.css/.js` 等数据/模板文件（单服务上限约 60 个文件）。"
        "辅助模块可以写正常的类和函数（不受 app.py 顶层声明式写法限制），但**所有 .py 文件都受同一能力沙箱**："
        "只能 import 白名单标准库 + flask/pydantic + 本服务自己的模块，禁止 os/subprocess/socket/文件读写/eval/exec/open。"
        "\n- 修改已有后端（尤其多文件/较复杂的）流程：先 `bash backend/faas_pull.sh <service_id>` 把整份服务目录"
        "拉下来解压到 `$AI_APP_WORKSPACE/faas_pull/<service_id>/`，按需改或新增任意文件，"
        "再 `bash backend/faas_deploy.sh <该目录>` 整目录打包上传（后端会解压、校验、更新 git 后照常部署，复用 service_id 不占新配额）；"
        "务必让 `service.json` 的 routes 覆盖前端会用到的全部接口（旧的＋新增的）。"
        "\n- `app.py` 必须定义 Flask `app`，接口路径必须与 service.routes 保持一致；"
        "后端会静态校验每个 `service.routes` 路径/方法都能在 `@app.get/post/put/patch/delete(...)` "
        "或 `@app.route(..., methods=[...])` 中找到；"
        "（Flask 只有 get/post/put/patch/delete 这几个方法装饰器，没有 @app.head/@app.options，"
        "OPTIONS/HEAD 等方法必须用 `@app.route(path, methods=[...])` 声明，否则 app.py 加载即崩 503）；"
        "`app.py` 顶层只允许 imports、`app = Flask(__name__)`/`application = Flask(...)`、"
        "literal 常量/列表/字典、路由函数和可选 `if __name__ == '__main__': app.run()`；"
        "不要在顶层执行循环、网络/文件 IO、后台线程或任意函数调用；"
        "函数默认参数、类型注解和装饰器也不能调用运行时代码，装饰器只能使用 literal Flask route；"
        "后端代理会强制校验 `service.routes` 中声明的 path/method，JSON-APP 调用未声明路径会得到 404，"
        "调用未声明 method 会得到 405；因此前端会调用的每个接口都必须在 routes 中逐一声明。"
        "动态路径可使用 Flask 风格如 `/items/<item_id>` 或 `/files/<path:tail>`。"
        "不要读取环境变量、不要访问本机文件、不要启动额外 server、不要使用 subprocess/socket。"
        "\n- 持久化数据（可选，需要存储/查询数据时才用）：本服务可拥有一块**自己的 Postgres 库**，"
        "按 schema 隔离，只能访问自己的数据，别的用户/平台数据都碰不到。用法："
        "\n  1) 写 `schema.sql` 用幂等 DDL 声明表（`CREATE TABLE IF NOT EXISTS ...`）；部署时后端会在你的 schema 里执行它，"
        "**不要在 app.py 运行时建表/改表**。"
        "\n  2) `app.py` 里 `import myapp_db`，用 `myapp_db.query(sql, params)` / `myapp_db.queryone(sql, params)` / "
        "`myapp_db.execute(sql, params)` 读写，多语句事务用 `with myapp_db.tx() as cur: cur.execute(...)`。"
        "\n  3) 值一律用 `%s` 占位 + 第二个参数传 list（如 `myapp_db.query('SELECT * FROM todos WHERE done=%s',[False])`），"
        "**禁止用 f-string/格式化拼 SQL**（防注入）。"
        "\n  4) search_path 已指向你的 schema，直接写表名即可（`FROM todos`），无需 schema 前缀；单条语句超时 5s。"
        "\n  5) 不要 import psycopg2/os、不要读连接串——连接由 `myapp_db` 内部用注入的受限 DSN 完成；只有声明了 schema.sql "
        "或 import 了 myapp_db 的服务才会被分配数据库。"
        "\n  这块能力让 JSON-APP 能做真正有后端数据的应用（清单/订单/收藏/留言等 CRUD）。"
        "\n- 平台会把【公开】配置注入到运行时，通过 `current_app.config[\"MYAPP\"]` 读取（需在路由/请求上下文内）："
        "`supabase_url`、`supabase_anon_key`（公开 anon key）、`backend_base_url`、`faas_public_base_url`。"
        "**需要调用 Supabase 或回调平台时，从这里拼 URL，绝不要把域名/anon key 写死在 app.py**——换环境/换域名只重部署即可。"
        "例如：`cfg = current_app.config.get(\"MYAPP\", {}); url = cfg[\"supabase_url\"].rstrip(\"/\") + \"/auth/v1/user\"`，"
        "再用 `urllib.request` 带 `apikey: cfg[\"supabase_anon_key\"]` 调用（出网用 `urllib`，没有 `requests`）。"
        "平台只注入公开值，绝不会有 service_role 等密钥；需要密钥的操作不要在 FaaS 里做。"
        "\n\n后端工作流（生成 bundle 后必须严格按序执行，绝不能只写动作让服务端代劳）："
        f"\n1) 部署：直接在当前 shell 运行 `bash backend/faas_deploy.sh {bundle_path}`。"
        "部署所需的 `MYAPP_FAAS_PROXY_URL` 等环境变量已经在你的运行环境里——"
        "**务必在当前 shell 直接运行，不要用 `env -i`、`sudo`、新登录 shell 或清空环境的方式**，否则会丢失代理地址、报"
        "「MYAPP_FAAS_PROXY_URL is not set」而部署失败。"
        "运行后读 `$AI_APP_WORKSPACE/faas_deploy_result.json`：成功含真实 `service_id` 和 `routes`，失败含 `error`。"
        "\n2) 失败 → 按 `error` 最小化修 `faas_bundle.json` → 重跑第 1 步（最多 5 次）。"
        "\n3) 成功 → 自测：`bash backend/faas_invoke.sh <真实service_id> <route> [METHOD] [json体]` "
        "逐条验证关键接口返回 200 且结构符合预期（至少测一次集合 GET 和一次写操作）。"
        "\n4) 自测不通过 → 修 `app.py`/bundle → 回第 1 步。"
        "\n5) 自测通过 → 用第 1 步拿到的【真实 service_id】把 JSON-APP 里所有后端调用写成相对地址 "
        "`/api/faas/invoke/<真实service_id>/<route>`（客户端会自动拼后端域名）；"
        "严禁让用户手动填写后端 URL/接口地址，也不要用 slug 占位——必须是真实 service_id。"
        "\n   ⚠️ service_id 只能取自 `faas_deploy_result.json` 里真实部署成功（ok=true）的结果；"
        "严禁自己编造、猜测、或用 slug/哈希拼一个 service_id。"
        "若多次重试仍无法部署成功（脚本持续报错或 401/鉴权失败），就不要接后端、不要写任何后端调用，"
        "如实说明后端未接上，绝不能发一个调不通的 app（接一个不存在的 service_id 会让前端全部 404）。"
        "\n6) 未声明的 path 会 404、未声明的 method 会 405，所以前端会调用的每个接口都要在 routes 里逐一声明。"
        "\n7) 最后 `python3 backend/repair_json_app.py` + `python3 backend/validate_json_app.py`，"
        "再 `bash backend/upload_with_signature.sh \"$AI_APP_WORKSPACE/app.json\"` 上传。"
    ) + _FAAS_GEN_EXAMPLE


def _build_pipeline_turn_note(generation_pipeline: str, *, workspace: Optional[str] = None) -> str:
    pipeline = normalize_generation_pipeline(generation_pipeline)
    if pipeline != "dart_to_json_v2":
        return f"\n\n本轮生成链路: {pipeline}。"
    plan_path = "$AI_APP_WORKSPACE/app_dart_plan.dart" if workspace else "app_dart_plan.dart"
    json_path = "$AI_APP_WORKSPACE/app.json" if workspace else "app.json"
    return (
        f"\n\n本轮生成链路: {pipeline}。"
        f"\n必须先在受限 JSON-DSL 能力范围内生成 Flutter/Dart 风格设计稿 `{plan_path}`，"
        "该文件只能使用系统提示词允许的受限 Dart UI plan 语法，禁止使用 JSON-DSL 无法表达的 Flutter 能力。"
        f"\n然后把 `{plan_path}` 逐屏、逐状态、逐动作语义等效转换为 JSON-DSL `{json_path}`。"
        "\n最终仍必须执行 repair、validate、可选视觉复检和 upload_with_signature.sh；"
        "Dart plan 只是中间设计稿，绝不能作为最终交付物。"
    )


def _build_user_turn_prompt(
    last_msg: str,
    *,
    workspace: Optional[str] = None,
    generation_pipeline: str = GENERATION_PIPELINE_V1,
) -> str:
    workspace_note = ""
    if workspace:
        workspace_note = (
            "\n\n本轮后端已为你分配独立工作目录，必须使用它隔离所有临时文件："
            f"\nAI_APP_WORKSPACE={workspace}"
            "\n生成器、下载的 manifest、app.json、校验输出都放在 AI_APP_WORKSPACE 下；"
            "不要写 /tmp/app.json 或 /tmp/generate_app.py。"
        )
    visual_review_note = _build_visual_review_prompt_note(workspace=workspace)
    faas_backend_note = _build_faas_backend_prompt_note(workspace=workspace)
    pipeline = normalize_generation_pipeline(generation_pipeline)
    pipeline_note = _build_pipeline_turn_note(pipeline, workspace=workspace)
    prompt_reference = generation_prompt_reference(pipeline)
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
        "该脚本成功后会自动写入结构化动作文件；隔离运行时可能先请求后端代上传，"
        "后端会转换成客户端可用的 `json_app_ready` 事件。你只需在自然语言中简短说明已生成。"
        "如果需要请求用户上传当前应用，先写入 `request_upload_current_app` 动作文件，再用自然语言说明需要查看当前应用。"
    )
    return (
        f"本轮用户的请求:\n<user_request>\n{last_msg}\n</user_request>"
        f"{workspace_note}{pipeline_note}\n请实现用户要求并严格按照系统提示词{prompt_reference}中的信息答复用户；"
        "如果该提示词要求先分类、读取索引或按需阅读分层文档，每一轮都必须重新执行。"
        "不要遗忘工作目录、repair/validate、上传和 client_actions 结构化动作规则。"
        f"{visual_review_note}"
        f"{faas_backend_note}"
        f"{final_protocol_note}"
    )


def _build_cli_cmd(
    session_id: str,
    last_msg: str,
    sys_prompt: str,
    is_resume: bool,
    *,
    workspace: Optional[str] = None,
    cli_session_id: Optional[str] = None,
    generation_pipeline: str = GENERATION_PIPELINE_V1,
) -> list:
    cmd = [
        CLAUDE_BIN,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p", _build_user_turn_prompt(
            last_msg,
            workspace=workspace,
            generation_pipeline=generation_pipeline,
        ),
    ]
    if is_resume:
        cmd.extend(["-r", session_id])
    else:
        cmd.extend(["--session-id", cli_session_id or session_id])
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


def _dynamic_agent_node_provider(provider_id: Optional[str]) -> dict:
    pid = _normalize_provider_id(provider_id)
    static = AI_PROVIDERS.get(pid)
    if static:
        return static
    label = pid.replace("-", " ").strip().title() or "Custom"
    return {
        "id": pid,
        "name": label,
        "description": "Agent node local provider",
        "configured": True,
        "visible": True,
        "models": {"default": ""},
        "cli_env": {},
        "codex": {},
        "opencode": {},
        "worker": _provider_worker_limits(pid),
    }


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


def _build_codex_prompt(
    last_msg: str,
    sys_prompt: str,
    *,
    workspace: Optional[str],
    generation_pipeline: str = GENERATION_PIPELINE_V1,
) -> str:
    system_block = ""
    if sys_prompt:
        system_block = (
            "下面是本项目 JSON-APP 生成核心规则，必须作为最高优先级规则执行。\n"
            "<core_generation_prompt>\n"
            f"{sys_prompt}\n"
            "</core_generation_prompt>\n\n"
        )
    return system_block + _build_user_turn_prompt(
        last_msg,
        workspace=workspace,
        generation_pipeline=generation_pipeline,
    )


def _extract_codex_thread_id(line_str: str) -> Optional[str]:
    try:
        event = json.loads(line_str)
    except json.JSONDecodeError:
        return None
    if event.get("type") != "thread.started":
        return None
    thread_id = event.get("thread_id")
    return str(thread_id) if thread_id else None


def _extract_opencode_thread_id(line_str: str) -> Optional[str]:
    try:
        event = json.loads(line_str)
    except json.JSONDecodeError:
        return None
    thread_id = event.get("sessionID") or event.get("session_id")
    return str(thread_id) if thread_id else None


def _parse_line_for_runner(runner: str):
    if runner == "codex":
        return parse_codex_line
    if runner == "opencode":
        return parse_opencode_line
    return parse_cli_line


def _extract_thread_id_for_runner(runner: str, line_str: str) -> Optional[str]:
    if runner == "codex":
        return _extract_codex_thread_id(line_str)
    if runner == "opencode":
        return _extract_opencode_thread_id(line_str)
    return None


def _runner_display_name(runner: str) -> str:
    if runner == "codex":
        return "Codex CLI"
    if runner == "opencode":
        return "OpenCode CLI"
    return "Claude CLI"


def _agent_node_headers() -> dict:
    headers = {"Content-Type": "application/json"}
    if AGENT_NODE_TOKEN:
        headers["Authorization"] = f"Bearer {AGENT_NODE_TOKEN}"
    return headers


def _agent_pull_auth_context() -> dict:
    expected = AGENT_NODE_REGISTRATION_TOKEN or AGENT_NODE_TOKEN
    auth_header = request.headers.get("Authorization", "")
    if expected and auth_header == f"Bearer {expected}":
        return {"ok": True, "kind": "public", "visibility": "public", "owner_user_id": "", "node_id": ""}
    if not expected:
        return {"ok": True, "kind": "public", "visibility": "public", "owner_user_id": "", "node_id": ""}
    private_token = request.headers.get("X-MyApp-Agent-JWT", "")
    if not private_token and auth_header.startswith("MyApp-Agent "):
        private_token = auth_header[len("MyApp-Agent "):].strip()
    if not private_token:
        return {"ok": False, "error": "unauthorized"}
    try:
        unverified = jwt.decode(private_token, options={"verify_signature": False})
        node_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(unverified.get("sub") or unverified.get("node_id") or "")).strip("._")
        if not node_id:
            return {"ok": False, "error": "missing node id"}
        import agent_node_registry

        record = agent_node_registry.get_node(node_id)
        if not record or record.get("visibility") != "private" or not record.get("auth_public_key"):
            return {"ok": False, "error": "unknown private agent node"}
        claims = jwt.decode(
            private_token,
            record["auth_public_key"],
            algorithms=["RS256"],
            audience="myapp-agent-pull",
        )
        if claims.get("sub") != node_id:
            return {"ok": False, "error": "node id mismatch"}
        owner_user_id = str(record.get("owner_user_id") or "")
        if claims.get("owner_user_id") and claims.get("owner_user_id") != owner_user_id:
            return {"ok": False, "error": "owner mismatch"}
        return {
            "ok": True,
            "kind": "private",
            "visibility": "private",
            "node_id": node_id,
            "owner_user_id": owner_user_id,
            "record": record,
        }
    except Exception as exc:
        logger.warning("[AGENT_PULL] private auth failed: %s", exc)
        return {"ok": False, "error": "unauthorized"}


def _agent_pull_auth_ok() -> bool:
    return bool(_agent_pull_auth_context().get("ok"))


def _agent_pull_authorized_for_job(run_id: str, auth_ctx: dict, *, node_id: str = "") -> tuple[bool, str]:
    if auth_ctx.get("kind") != "private":
        return True, ""
    spec = _agent_pull_job_spec(run_id) or {}
    meta = _agent_pull_job_meta(run_id)
    expected_node = str(auth_ctx.get("node_id") or "")
    actual_node = node_id or str(meta.get("node_id") or "")
    if actual_node and actual_node != expected_node:
        return False, "node mismatch"
    if str(spec.get("agent_scope") or "") != "private":
        return False, "not a private job"
    if str(spec.get("user_id") or "") != str(auth_ctx.get("owner_user_id") or ""):
        return False, "owner mismatch"
    assigned_node = str(meta.get("node_id") or "")
    if assigned_node and assigned_node != expected_node:
        return False, "assigned node mismatch"
    return True, ""


def _agent_node_label_mode(labels: Any) -> str:
    if not isinstance(labels, list):
        return "master"
    for item in labels:
        text = str(item or "").strip().lower().replace("_", "-")
        if text in {"provider-mode=local", "mode=local", "local-provider=true"}:
            return "local"
    return "master"


def _decode_redis_text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _node_supports(value: str, allowed: Any) -> bool:
    if not value:
        return True
    if isinstance(allowed, str):
        try:
            allowed = json.loads(allowed or "[]")
        except json.JSONDecodeError:
            allowed = [item.strip() for item in allowed.split(",")]
    if not isinstance(allowed, list) or not allowed:
        return True
    normalized = str(value or "").strip().lower().replace("_", "-")
    return normalized in {str(item or "").strip().lower().replace("_", "-") for item in allowed}


def _default_adapter_kind_for_agent(agent_id: str) -> str:
    normalized = str(agent_id or "").strip().lower().replace("_", "-")
    if normalized == "claude":
        return "anthropic"
    if normalized == "codex":
        return "openai-responses"
    if normalized == "opencode":
        return "opencode"
    return normalized or "unknown"


def _normalize_agent_node_capabilities(value: Any) -> list[dict]:
    if isinstance(value, str):
        try:
            value = json.loads(value or "[]")
        except json.JSONDecodeError:
            value = []
    if not isinstance(value, list):
        return []
    out: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    for raw in value:
        if not isinstance(raw, dict):
            continue
        provider_id = _normalize_provider_id(raw.get("provider_id") or raw.get("provider"))
        agent_id = str(raw.get("agent_id") or raw.get("agent") or "").strip().lower().replace("_", "-")
        if not provider_id or not agent_id:
            continue
        adapter_kind = str(
            raw.get("adapter_kind") or raw.get("adapter") or _default_adapter_kind_for_agent(agent_id)
        ).strip().lower().replace("_", "-")
        key = (provider_id, agent_id, adapter_kind)
        if key in seen:
            continue
        seen.add(key)
        enabled_raw = raw.get("enabled", True)
        enabled = (
            enabled_raw.strip().lower() not in {"0", "false", "no", "off", "disabled"}
            if isinstance(enabled_raw, str)
            else bool(enabled_raw)
        )
        out.append(
            {
                "provider_id": provider_id,
                "agent_id": agent_id,
                "adapter_kind": adapter_kind,
                "status": str(raw.get("status") or "configured").strip().lower().replace("_", "-"),
                "enabled": enabled,
            }
        )
    return out


def _agent_node_capability_enabled(capability: dict) -> bool:
    if not capability.get("enabled", True):
        return False
    status = str(capability.get("status") or "configured").strip().lower().replace("_", "-")
    return status not in {"disabled", "failed", "unsupported", "unavailable", "off"}


def _agent_node_capability_supports(capabilities: Any, provider_id: str, agent_id: str) -> Optional[bool]:
    caps = _normalize_agent_node_capabilities(capabilities)
    if not caps:
        return None
    wanted_provider = str(provider_id or "").strip().lower().replace("_", "-")
    wanted_agent = str(agent_id or "").strip().lower().replace("_", "-")
    if not wanted_provider and not wanted_agent:
        return True
    return any(
        _agent_node_capability_enabled(cap)
        and (not wanted_provider or cap.get("provider_id") == wanted_provider)
        and (not wanted_agent or cap.get("agent_id") == wanted_agent)
        for cap in caps
    )


def _static_provider_allows_agent(provider: dict | None, agent_id: str) -> bool:
    if not provider:
        return False
    normalized_agent = str(agent_id or "").strip().lower().replace("_", "-")
    supported = provider.get("supported_agents")
    if isinstance(supported, list) and supported and normalized_agent not in {str(item) for item in supported}:
        return False
    if normalized_agent == "claude":
        return bool(provider.get("anthropic_configured", provider.get("configured", False)))
    if normalized_agent == "codex":
        return bool((provider.get("codex") or {}).get("configured"))
    if normalized_agent == "opencode":
        return bool((provider.get("opencode") or {}).get("configured"))
    return False


def _public_master_node_static_supports(provider_id: str, agent_id: str) -> bool:
    provider_id = _normalize_provider_id(provider_id)
    agent_id = str(agent_id or "").strip().lower().replace("_", "-")
    if not provider_id or not agent_id:
        return True
    static = AI_PROVIDERS.get(provider_id)
    return _static_provider_allows_agent(static, agent_id)


def _registered_agent_node_records(
    *,
    agent_scope: str = "public",
    owner_user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> List[dict]:
    wanted_scope = "private" if agent_scope == "private" else "public"
    try:
        from agent_node_registry import list_nodes

        records: List[dict] = []
        now_ms = int(time.time() * 1000)
        for item in list_nodes():
            visibility = str(item.get("visibility") or "public").strip().lower()
            item_owner = str(item.get("owner_user_id") or "")
            if wanted_scope == "private":
                if visibility != "private" or item_owner != owner_user_id:
                    continue
            elif visibility == "private":
                continue
            labels = item.get("labels") if isinstance(item.get("labels"), list) else []
            record_mode = str(item.get("provider_mode") or "").strip().lower().replace("_", "-") or _agent_node_label_mode(labels)
            if wanted_scope == "public" and record_mode not in {"local", "node", "self", "agent-local"}:
                if not _public_master_node_static_supports(provider_id, agent_id):
                    continue
            capabilities = _normalize_agent_node_capabilities(item.get("capabilities"))
            capability_match = _agent_node_capability_supports(capabilities, provider_id, agent_id)
            if capability_match is False:
                continue
            if capability_match is None:
                if not _node_supports(provider_id, item.get("provider_ids")):
                    continue
                if not _node_supports(agent_id, item.get("agent_ids")):
                    continue
            if bool(item.get("paused") or False):
                continue
            url = str(item.get("url") or "").rstrip("/")
            if not url:
                continue
            try:
                last_seen = int(item.get("last_seen") or 0)
                ttl_seconds = int(item.get("ttl_seconds") or 0)
            except (TypeError, ValueError):
                last_seen = 0
                ttl_seconds = 0
            if not last_seen or not ttl_seconds or last_seen + ttl_seconds * 1000 <= now_ms:
                continue
            try:
                capacity = max(1, min(100, int(item.get("capacity") or 1)))
            except (TypeError, ValueError):
                capacity = 1
            try:
                queue_max = max(0, min(10000, int(item.get("queue_max") or capacity)))
            except (TypeError, ValueError):
                queue_max = capacity
            records.append(
                {
                    "node_id": str(item.get("node_id") or ""),
                    "url": url,
                    "capacity": capacity,
                    "queue_max": queue_max,
                    "provider_mode": record_mode,
                    "visibility": visibility,
                    "owner_user_id": item_owner,
                    "provider_ids": item.get("provider_ids") if isinstance(item.get("provider_ids"), list) else [],
                    "agent_ids": item.get("agent_ids") if isinstance(item.get("agent_ids"), list) else [],
                    "capabilities": capabilities,
                }
            )
        if records:
            return sorted(records, key=lambda item: item["url"])
    except Exception as exc:
        logger.warning("[AGENT_NODE] 读取数据库注册节点失败: %s", exc)

    try:
        r = get_redis()
        records: List[dict] = []
        if wanted_scope == "private":
            return []
        for key in r.scan_iter("ai:agent_node:*", count=100):
            data = r.hgetall(key)
            raw_url = data.get(b"url") or data.get("url")
            if not raw_url:
                continue
            url = _decode_redis_text(raw_url).rstrip("/")
            if not url:
                continue
            raw_capacity = data.get(b"capacity") or data.get("capacity") or b"1"
            try:
                capacity = max(1, min(100, int(_decode_redis_text(raw_capacity, "1"))))
            except (TypeError, ValueError):
                capacity = 1
            raw_queue_max = data.get(b"queue_max") or data.get("queue_max") or str(capacity).encode()
            try:
                queue_max = max(0, min(10000, int(_decode_redis_text(raw_queue_max, str(capacity)))))
            except (TypeError, ValueError):
                queue_max = capacity
            raw_labels = data.get(b"labels") or data.get("labels") or b"[]"
            try:
                labels = json.loads(_decode_redis_text(raw_labels, "[]") or "[]")
            except json.JSONDecodeError:
                labels = []
            raw_paused = data.get(b"paused") or data.get("paused") or b"0"
            if _decode_redis_text(raw_paused, "0").strip().lower() in {"1", "true", "yes", "on"}:
                continue
            raw_capabilities = data.get(b"capabilities") or data.get("capabilities") or b"[]"
            capabilities = _normalize_agent_node_capabilities(_decode_redis_text(raw_capabilities, "[]"))
            record_mode = _agent_node_label_mode(labels)
            if wanted_scope == "public" and record_mode not in {"local", "node", "self", "agent-local"}:
                if not _public_master_node_static_supports(provider_id, agent_id):
                    continue
            records.append(
                {
                    "url": url,
                    "capacity": capacity,
                    "queue_max": queue_max,
                    "provider_mode": record_mode,
                    "visibility": "public",
                    "owner_user_id": "",
                    "capabilities": capabilities,
                }
            )
        return sorted(records, key=lambda item: item["url"])
    except Exception as exc:
        logger.warning("[AGENT_NODE] 读取注册节点失败: %s", exc)
        return []


def _static_provider_supports_agent(provider: dict, agent_id: str) -> bool:
    return _static_provider_allows_agent(provider, agent_id)


def _visible_configured_agent_ids_for_provider(provider: dict) -> list[str]:
    out = [
        aid for aid, agent in AI_AGENTS.items()
        if agent.get("visible", True)
        and agent.get("configured", False)
        and _static_provider_supports_agent(provider, aid)
    ]
    return out or ["claude"]


def _visible_agent_ids() -> set[str]:
    return {
        aid for aid, agent in AI_AGENTS.items()
        if agent.get("visible", True) and agent.get("configured", False)
    }


def _provider_catalog_entry(
    provider_id: str,
    supported_agents: set[str],
    *,
    scope: str,
    trust_node_agents: bool = False,
) -> dict:
    provider_id = _normalize_provider_id(provider_id)
    static = AI_PROVIDERS.get(provider_id)
    if static:
        default_model = str(((static.get("models") or {}).get("default")) or "")
        static_agents = _visible_agent_ids() if trust_node_agents else set(_visible_configured_agent_ids_for_provider(static))
        effective_agents = (
            set(supported_agents) & static_agents
            if supported_agents
            else static_agents
        )
        return {
            "id": static["id"],
            "name": static.get("name") or static["id"],
            "description": static.get("description", ""),
            "default_model": default_model,
            "configured": bool(static.get("configured", True)),
            "supported_agents": sorted(effective_agents),
            "worker": static.get("worker", {}),
            "source": "agent-node",
            "scope": scope,
        }
    label = provider_id.replace("-", " ").strip().title() or provider_id
    effective_agents = sorted(set(supported_agents) & _visible_agent_ids()) if supported_agents else []
    return {
        "id": provider_id,
        "name": label,
        "description": "Agent node local provider",
        "default_model": "",
        "configured": True,
        "supported_agents": effective_agents or ["claude"],
        "worker": _provider_worker_limits(provider_id),
        "source": "agent-node",
        "scope": scope,
    }


def agent_node_provider_catalog(*, agent_scope: str = "public", owner_user_id: str = "") -> list[dict]:
    requested_scope = str(agent_scope or "public").strip().lower().replace("_", "-")
    scope = "private" if requested_scope == "private" else "public"
    providers: dict[str, set[str]] = {}
    provider_scope: dict[str, str] = {}
    provider_trust_node_agents: dict[str, bool] = {}
    records = _registered_agent_node_records(
        agent_scope=scope,
        owner_user_id=owner_user_id if scope == "private" else "",
    )
    for record in records:
        record_mode = str(record.get("provider_mode") or "master").strip().lower().replace("_", "-")
        trust_record_agents = scope == "private" or record_mode in {"local", "node", "self", "agent-local"}
        capabilities = [
            cap for cap in _normalize_agent_node_capabilities(record.get("capabilities"))
            if _agent_node_capability_enabled(cap)
        ]
        if capabilities:
            for cap in capabilities:
                provider_id = _normalize_provider_id(cap.get("provider_id"))
                agent_id = str(cap.get("agent_id") or "").strip().lower().replace("_", "-")
                if not provider_id or not agent_id:
                    continue
                providers.setdefault(provider_id, set()).add(agent_id)
                provider_scope.setdefault(provider_id, scope)
                if trust_record_agents:
                    provider_trust_node_agents[provider_id] = True
            continue
        raw_agents = record.get("agent_ids") if isinstance(record.get("agent_ids"), list) else []
        agent_ids = {
            str(item or "").strip().lower().replace("_", "-")
            for item in raw_agents
            if str(item or "").strip()
        } or {"claude"}
        raw_provider_ids = record.get("provider_ids") if isinstance(record.get("provider_ids"), list) else []
        provider_ids = [
            _normalize_provider_id(str(item or ""))
            for item in raw_provider_ids
            if str(item or "").strip()
        ]
        # Legacy public master nodes may not report provider_ids. They use
        # backend-managed providers, so expose the backend visible providers
        # only as a compatibility fallback for those old nodes.
        if not provider_ids and scope == "public" and record_mode != "local":
            provider_ids = [
                pid for pid, provider in AI_PROVIDERS.items()
                if provider.get("visible", True) and provider.get("configured", False)
            ]
        for provider_id in provider_ids:
            if not provider_id:
                continue
            current = providers.setdefault(provider_id, set())
            static = AI_PROVIDERS.get(provider_id)
            if static and not raw_agents and scope == "public" and record_mode != "local":
                current.update(_visible_configured_agent_ids_for_provider(static))
            else:
                current.update(agent_ids)
            provider_scope.setdefault(provider_id, scope)
            if trust_record_agents:
                provider_trust_node_agents[provider_id] = True
    entries = [
        _provider_catalog_entry(
            provider_id,
            agents,
            scope=provider_scope.get(provider_id, scope),
            trust_node_agents=provider_trust_node_agents.get(provider_id, False),
        )
        for provider_id, agents in sorted(providers.items())
    ]
    return [entry for entry in entries if entry.get("supported_agents")]


def _configured_agent_node_records() -> List[dict]:
    by_url: dict[str, dict] = {}
    static_records = [
        {"url": url.rstrip("/"), "capacity": 1, "provider_mode": "master"}
        for url in AGENT_NODE_URLS
        if url.rstrip("/")
    ]
    if not static_records and AGENT_NODE_URL:
        static_records = [{"url": AGENT_NODE_URL.rstrip("/"), "capacity": 1, "provider_mode": "master"}]
    for record in static_records:
        by_url[record["url"]] = record
    for record in _registered_agent_node_records():
        url = str(record.get("url") or "").rstrip("/")
        if url:
            by_url[url] = {**record, "url": url}
    return list(by_url.values())


def _configured_agent_node_urls() -> List[str]:
    urls: List[str] = []
    for record in _configured_agent_node_records():
        url = str(record.get("url") or "").rstrip("/")
        if not url:
            continue
        try:
            capacity = max(1, min(100, int(record.get("capacity") or 1)))
        except (TypeError, ValueError):
            capacity = 1
        urls.extend([url] * capacity)
    return urls


def _agent_node_provider_mode_for_url(agent_node_url: str) -> str:
    needle = agent_node_url.rstrip("/")
    mode = "master"
    for record in _configured_agent_node_records():
        url = str(record.get("url") or "").rstrip("/")
        if url != needle:
            continue
        record_mode = str(record.get("provider_mode") or "master").strip().lower().replace("_", "-")
        if record_mode in {"local", "node", "self", "agent-local"}:
            return "local"
        mode = "master"
    return mode


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


def _agent_node_provider_env(provider: dict, *, include_provider_secrets: bool = True) -> dict:
    """Only send the agent CLI env, never the backend process env."""
    env = dict(provider.get("cli_env") or {})
    if not include_provider_secrets:
        for key in list(env.keys()):
            normalized = str(key).upper()
            if normalized.endswith("_AUTH_TOKEN") or normalized.endswith("_API_KEY") or normalized.endswith("_SECRET"):
                env.pop(key, None)
    env["IS_SANDBOX"] = "1"
    env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
    env["REGISTRY_BASE_URL"] = os.environ.get("REGISTRY_BASE_URL", "")
    env["MINIO_PUBLIC_URL"] = os.environ.get("MINIO_PUBLIC_URL", "")
    env.update(_visual_review_env())
    env["AI_APP_MODEL_SUPPORTS_VISION"] = "1" if _provider_supports_vision(provider) else "0"
    return {k: v for k, v in env.items() if v is not None}


def _agent_node_codex_config(provider: dict, *, include_provider_secrets: bool = True) -> dict:
    codex = dict(provider.get("codex") or {})
    if not codex:
        return {}
    auth_mode = str(codex.get("auth_mode") or "").strip().lower().replace("_", "-")
    wire_api = str(codex.get("wire_api") or "").strip().lower().replace("_", "-")
    adapter_kind = str(codex.get("adapter_kind") or "").strip().lower().replace("_", "-")
    if auth_mode in {"native", "native-codex"} or wire_api in {"native", "native-codex"} or adapter_kind == "native-codex":
        codex["auth_mode"] = "native"
        codex["wire_api"] = "native"
        codex["adapter_kind"] = "native-codex"
        codex["env_key"] = ""
        codex["provider_id"] = str(provider.get("id") or "native-codex").replace("-", "_")
        codex.pop("_runtime_token_env_key", None)
        codex.pop("_runtime_token", None)
        return codex
    # The real token is placed in the submit payload under a runtime-only env key;
    # agent-node rewrites it to a per-run proxy token before starting the container.
    env_key = str(codex.get("env_key") or "").strip()
    token = os.environ.get(env_key, "") if include_provider_secrets and env_key else ""
    runtime_env_key = "MYAPP_CODEX_AUTH_TOKEN"
    codex["env_key"] = runtime_env_key
    codex["provider_id"] = str(provider.get("id") or "custom").replace("-", "_")
    codex["_runtime_token_env_key"] = runtime_env_key
    codex["_runtime_token"] = token
    return codex


def _agent_node_opencode_config(provider: dict, *, include_provider_secrets: bool = True) -> dict:
    opencode = dict(provider.get("opencode") or {})
    codex = dict(provider.get("codex") or {})
    if not opencode:
        opencode = {
            "provider_name": codex.get("provider_name"),
            "base_url": codex.get("base_url"),
            "model": codex.get("model"),
            "env_key": codex.get("env_key"),
            "provider_npm": "@ai-sdk/openai-compatible",
        }
    if not opencode:
        return {}
    env_key = str(opencode.get("env_key") or "").strip()
    token = os.environ.get(env_key, "") if include_provider_secrets and env_key else ""
    runtime_env_key = "MYAPP_CODEX_AUTH_TOKEN"
    return {
        "provider_name": opencode.get("provider_name") or codex.get("provider_name") or provider.get("id"),
        "base_url": opencode.get("base_url") or codex.get("base_url"),
        "model": opencode.get("model") or codex.get("model"),
        "env_key": runtime_env_key,
        "provider_id": str(provider.get("id") or "custom").replace("-", "_"),
        "opencode_provider_npm": opencode.get("provider_npm") or "@ai-sdk/openai-compatible",
        "opencode_base_url": opencode.get("base_url") or codex.get("base_url"),
        "opencode_model": opencode.get("model") or codex.get("model"),
        "opencode_env_key": runtime_env_key,
        "opencode_provider_name": opencode.get("provider_name") or codex.get("provider_name") or provider.get("id"),
        "_runtime_token_env_key": runtime_env_key,
        "_runtime_token": token,
    }


def _agent_node_runtime_config(provider: dict, runner: str, *, include_provider_secrets: bool) -> tuple[dict, dict]:
    if runner in {"codex", "opencode"}:
        codex = (
            _agent_node_opencode_config(provider, include_provider_secrets=include_provider_secrets)
            if runner == "opencode"
            else _agent_node_codex_config(provider, include_provider_secrets=include_provider_secrets)
        )
        env = _agent_node_provider_env(provider, include_provider_secrets=include_provider_secrets)
        for key in list(env.keys()):
            if key.startswith("ANTHROPIC_") or key.startswith("CLAUDE_CODE_") or key == "API_TIMEOUT_MS":
                env.pop(key, None)
        runtime_token_env_key = codex.pop("_runtime_token_env_key", "")
        runtime_token = codex.pop("_runtime_token", "")
        if runtime_token_env_key and runtime_token:
            env[runtime_token_env_key] = runtime_token
        return codex, env
    return {}, _agent_node_provider_env(provider, include_provider_secrets=include_provider_secrets)


def _build_agent_node_payload(
    *,
    run_id: str,
    session_id: str,
    user_id: str,
    provider: dict,
    runner: str,
    resume_id: str,
    turn_msg: str,
    sys_prompt: str,
    generation_pipeline: str,
    include_provider_secrets: bool,
) -> dict:
    runtime_workspace = "/workspace"
    codex, env = _agent_node_runtime_config(
        provider,
        runner,
        include_provider_secrets=include_provider_secrets,
    )
    if runner in {"codex", "opencode"}:
        prompt = _build_codex_prompt(
            turn_msg,
            sys_prompt,
            workspace=runtime_workspace,
            generation_pipeline=generation_pipeline,
        )
    else:
        prompt = _build_user_turn_prompt(
            turn_msg,
            workspace=runtime_workspace,
            generation_pipeline=generation_pipeline,
        )
    # X-G2 (binding): mint a BACKEND-signed run-scoped token (the agent-node forwards
    # it on in-run FaaS deploys). Lets the backend trust the run's owner from a token
    # the node cannot forge, instead of a free-text header. Best-effort; ignored
    # downstream unless FAAS_REQUIRE_RUN_TOKEN is on.
    faas_run_token = ""
    try:
        try:
            from faas import mint_run_token as _mint_run_token
        except ModuleNotFoundError:
            from backend.faas import mint_run_token as _mint_run_token
        faas_run_token = _mint_run_token(user_id or "user", run_id)
    except Exception:
        faas_run_token = ""
    return {
        "run_id": run_id,
        "session_id": session_id,
        "cli_session_id": "" if resume_id else _agent_cli_session_id(session_id, run_id),
        "job_id": run_id,
        "user_id": user_id or "user",
        "faas_run_token": faas_run_token,
        "provider_id": provider.get("id"),
        "agent_id": runner,
        "generation_pipeline": normalize_generation_pipeline(generation_pipeline),
        "resume_id": resume_id or "",
        "prompt": prompt,
        "system_prompt": sys_prompt if runner == "claude" and not resume_id else "",
        "env": dict(env),
        "codex": dict(codex),
        "initial_files": [item for item in [_faas_manifest_initial_file(user_id or "user")] if item],
    }


def _agent_pull_enqueue_run(
    *,
    run_id: str,
    session_id: str,
    user_id: str,
    provider_id: str,
    runner: str,
    resume_id: str,
    turn_msg: str,
    sys_prompt: str,
    generation_pipeline: str = GENERATION_PIPELINE_V1,
    agent_scope: str = "public",
) -> None:
    now_ms = int(time.time() * 1000)
    agent_scope = "private" if str(agent_scope or "").strip().lower() == "private" else "public"
    spec = {
        "run_id": run_id,
        "session_id": session_id,
        "user_id": user_id or "user",
        "provider_id": provider_id,
        "agent_id": runner,
        "agent_scope": agent_scope,
        "generation_pipeline": normalize_generation_pipeline(generation_pipeline),
        "resume_id": resume_id or "",
        "turn_msg": turn_msg,
        "sys_prompt": sys_prompt,
        "created_at": now_ms,
    }
    r = get_redis()
    _wait_for_agent_pull_queue_slot(
        r,
        timeout_seconds=float(os.environ.get("AGENT_PULL_QUEUE_WAIT_SECONDS", "30")),
        agent_scope=agent_scope,
        owner_user_id=user_id or "user",
        provider_id=provider_id,
        agent_id=runner,
    )
    queue_key = _agent_pull_pending_key_for_scope(agent_scope, user_id or "user")
    pipe = r.pipeline()
    pipe.hset(
        _agent_pull_job_key(run_id),
        mapping={
            "spec": json.dumps(spec, ensure_ascii=False),
            "status": "queued",
            "session_id": session_id,
            "provider_id": provider_id,
            "agent_id": runner,
            "agent_scope": agent_scope,
            "created_at": str(now_ms),
        },
    )
    pipe.expire(_agent_pull_job_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.delete(_agent_pull_events_key(run_id))
    pipe.rpush(queue_key, run_id)
    pipe.expire(queue_key, AI_SESSION_REDIS_TTL_SECONDS)
    pipe.execute()


def _agent_pull_job_spec(run_id: str) -> Optional[dict]:
    raw = get_redis().hget(_agent_pull_job_key(run_id), "spec")
    if not raw:
        return None
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    try:
        spec = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return spec if isinstance(spec, dict) else None


def _agent_pull_job_meta(run_id: str) -> dict:
    try:
        raw = get_redis().hgetall(_agent_pull_job_key(run_id))
    except redis.exceptions.RedisError:
        return {}
    out = {}
    for key, value in (raw or {}).items():
        k = key.decode("utf-8", errors="replace") if isinstance(key, bytes) else str(key)
        v = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
        out[k] = v
    return out


def _agent_pull_meta_int(meta: dict, key: str) -> int:
    try:
        return int(meta.get(key) or 0)
    except (TypeError, ValueError):
        return 0


def is_remote_agent_session_alive(session_id: str, meta: Optional[dict] = None) -> bool:
    """判断 agent-pull 远端 run 是否仍处于可恢复/可等待状态。

    SSE handler 不能只靠 backend worker lease 判定 pull-mode 任务是否死亡：
    实际 agent 进程在 agent-node 容器里，且 run 刚 stop 后还需要一点时间
    让 ai-worker 完成校验、上传、写 final status。
    """
    if meta is None:
        try:
            meta = SessionStore().get_meta(session_id)
        except redis.exceptions.RedisError:
            meta = {}
    run_id = str((meta or {}).get("agent_pull_run_id") or "").strip()
    if not run_id:
        return False
    job_meta = _agent_pull_job_meta(run_id)
    if not job_meta:
        return False
    if str(job_meta.get("abort_requested") or "") == "1":
        return False

    now_ms = int(time.time() * 1000)
    status = str(job_meta.get("status") or "").strip().lower()
    try:
        idle_timeout_seconds = max(
            30.0,
            float(os.environ.get("AGENT_PULL_EVENT_IDLE_TIMEOUT_SECONDS", "180")),
        )
    except (TypeError, ValueError):
        idle_timeout_seconds = 180.0
    try:
        post_stop_grace_seconds = max(
            10.0,
            float(os.environ.get("AGENT_PULL_REMOTE_STATUS_GRACE_SECONDS", "120")),
        )
    except (TypeError, ValueError):
        post_stop_grace_seconds = 120.0
    post_stop_grace_ms = int(post_stop_grace_seconds * 1000)

    if status in {"assigned", "running", "started"}:
        last_seen_ms = max(
            _agent_pull_meta_int(job_meta, "last_seen_at"),
            _agent_pull_meta_int(job_meta, "assigned_at"),
        )
        return bool(last_seen_ms and now_ms - last_seen_ms <= int((idle_timeout_seconds + 30.0) * 1000))

    if status in {"queued", "pending"}:
        created_ms = _agent_pull_meta_int(job_meta, "created_at")
        return bool(created_ms and now_ms - created_ms <= post_stop_grace_ms)

    if status in {"done", "failed", "aborted"}:
        finished_ms = max(
            _agent_pull_meta_int(job_meta, "finished_at"),
            _agent_pull_meta_int(job_meta, "last_seen_at"),
        )
        return bool(finished_ms and now_ms - finished_ms <= post_stop_grace_ms)

    created_ms = _agent_pull_meta_int(job_meta, "created_at")
    return bool(created_ms and now_ms - created_ms <= post_stop_grace_ms)


def _agent_pull_release_node_running(run_id: str, node_id: str = "") -> None:
    node = node_id.strip()
    if not node:
        node = str(_agent_pull_job_meta(run_id).get("node_id") or "").strip()
    if not node:
        return
    try:
        get_redis().srem(_agent_pull_node_running_key(node), run_id)
    except redis.exceptions.RedisError as exc:
        # A swallowed release used to leak a phantom 'running' run for the whole 24h
        # TTL. Log it; agent_pull_live_running_count() reconciles it away on read.
        logger.warning("[AGENT_PULL] release node_running failed node=%s run=%s: %s", node, run_id, exc)


# Statuses that mean a run is no longer occupying a node slot. Broad on purpose so a
# release that never happened (worker crash / swallowed srem) can't keep the run "live".
_AGENT_PULL_RUN_TERMINAL = {
    "done", "completed", "failed", "error", "aborted", "cancelled", "canceled", "stopped", "timeout",
}
# A non-terminal run whose last_seen_at is older than this is treated as dead (its
# worker/node died before writing a terminal status). Generous so a long, quiet but
# live run is never falsely reaped — a live worker would have failed it at its own
# idle timeout (~180s) long before this.
AGENT_PULL_RUN_STALE_SECONDS = max(120, int(os.environ.get("AGENT_PULL_RUN_STALE_SECONDS", "900")))


def _agent_pull_job_metas(run_ids: list) -> dict:
    """Pipelined hgetall of many job-meta hashes (one round-trip, not N)."""
    out: dict = {}
    if not run_ids:
        return out
    try:
        pipe = get_redis().pipeline()
        for rid in run_ids:
            pipe.hgetall(_agent_pull_job_key(rid))
        results = pipe.execute()
    except redis.exceptions.RedisError:
        return {rid: {} for rid in run_ids}
    for rid, raw in zip(run_ids, results):
        meta = {}
        for k, v in (raw or {}).items():
            kk = k.decode("utf-8", errors="replace") if isinstance(k, bytes) else str(k)
            vv = v.decode("utf-8", errors="replace") if isinstance(v, bytes) else str(v)
            meta[kk] = vv
        out[rid] = meta
    return out


def _agent_pull_run_is_dead(meta: dict, now_ms: int, stale_ms: int) -> bool:
    if not meta:
        return True
    if str(meta.get("status") or "").strip().lower() in _AGENT_PULL_RUN_TERMINAL:
        return True
    last_seen = _agent_pull_meta_int(meta, "last_seen_at")
    return bool(last_seen and (now_ms - last_seen) > stale_ms)


def agent_pull_live_running_count(node_id: str) -> int:
    """Reconciled count of runs ACTUALLY still running on a pull node.

    The node_running set is the dashboard's active_runs source but is only cleaned on
    the happy path (stop event / idle release). Worker crash, node death, or a dropped
    srem leak a phantom run until the 24h TTL. This reads the set, drops any member
    whose job is terminal / has no meta / is stale, and returns the live count — so the
    displayed number self-heals instead of over-counting. Stale (last_seen-based)
    candidates are re-read right before removal so a run that emitted an event during
    the scan is not falsely reaped.
    """
    node = (node_id or "").strip()
    if not node:
        return 0
    key = _agent_pull_node_running_key(node)
    try:
        raw_members = get_redis().smembers(key)
    except redis.exceptions.RedisError:
        return 0
    members = [m.decode() if isinstance(m, bytes) else str(m) for m in (raw_members or [])]
    if not members:
        return 0
    now_ms = int(time.time() * 1000)
    stale_ms = AGENT_PULL_RUN_STALE_SECONDS * 1000
    metas = _agent_pull_job_metas(members)
    live = 0
    dead: list = []
    stale_candidates: list = []
    for run_id in members:
        meta = metas.get(run_id) or {}
        # terminal / no-meta are definitively dead; last_seen staleness is re-checked
        # below to avoid a scan-vs-event race.
        if not meta or str(meta.get("status") or "").strip().lower() in _AGENT_PULL_RUN_TERMINAL:
            dead.append(run_id)
        elif _agent_pull_run_is_dead(meta, now_ms, stale_ms):
            stale_candidates.append(run_id)
        else:
            live += 1
    if stale_candidates:
        fresh = _agent_pull_job_metas(stale_candidates)
        now2 = int(time.time() * 1000)
        for run_id in stale_candidates:
            if _agent_pull_run_is_dead(fresh.get(run_id) or {}, now2, stale_ms):
                dead.append(run_id)
            else:
                live += 1  # emitted an event during the scan → still alive
    if dead:
        try:
            get_redis().srem(key, *dead)
            logger.info("[AGENT_PULL] reconciled %d dead run(s) off node=%s", len(dead), node)
        except redis.exceptions.RedisError as exc:
            logger.warning("[AGENT_PULL] reconcile srem failed node=%s: %s", node, exc)
    return live


def _agent_pull_append_job_event(run_id: str, item: dict) -> None:
    r = get_redis()
    pipe = r.pipeline()
    pipe.xadd(
        _agent_pull_events_key(run_id),
        {"data": json.dumps(item, ensure_ascii=False).encode()},
        maxlen=20000,
        approximate=True,
    )
    pipe.expire(_agent_pull_events_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.expire(_agent_pull_job_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.execute()


def _agent_pull_read_job_events(run_id: str, last_id: str = "0", block_ms: int = 5000) -> List[Tuple[str, dict]]:
    try:
        result = get_redis().xread(
            {_agent_pull_events_key(run_id): last_id},
            count=100,
            block=block_ms if block_ms > 0 else None,
        )
    except redis.exceptions.RedisError as exc:
        logger.warning("[AGENT_PULL] xread failed run=%s: %s", run_id, exc)
        return []
    out: List[Tuple[str, dict]] = []
    for _, entries in result or []:
        for entry_id, fields in entries:
            eid = entry_id.decode() if isinstance(entry_id, bytes) else entry_id
            raw = fields.get(b"data") if b"data" in fields else fields.get("data")
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", errors="replace")
            try:
                item = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                continue
            if isinstance(item, dict):
                out.append((eid, item))
    return out


def _agent_pull_mark_abort(run_id: str) -> None:
    try:
        get_redis().hset(_agent_pull_job_key(run_id), "abort_requested", "1")
        get_redis().expire(_agent_pull_job_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    except redis.exceptions.RedisError:
        pass


def _agent_pull_job_abort_requested(run_id: str, session_id: str = "") -> bool:
    if session_id and SessionStore().is_aborted(session_id):
        return True
    try:
        return get_redis().hget(_agent_pull_job_key(run_id), "abort_requested") in {b"1", "1"}
    except redis.exceptions.RedisError:
        return False


def _agent_pull_session_node(session_id: str, *, agent_scope: str = "public", owner_user_id: str = "") -> str:
    if not session_id:
        return ""
    key = (
        _agent_pull_private_session_node_key(owner_user_id, session_id)
        if agent_scope == "private"
        else _agent_pull_session_node_key(session_id)
    )
    try:
        raw = get_redis().get(key)
    except redis.exceptions.RedisError:
        return ""
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace").strip()
    return str(raw or "").strip()


def _agent_pull_sticky_node_available(node_id: str, *, agent_scope: str = "public", owner_user_id: str = "") -> bool:
    if not node_id:
        return False
    try:
        import agent_node_registry

        record = agent_node_registry.get_node(node_id)
    except Exception as exc:
        logger.warning("[AGENT_PULL] sticky node lookup failed node=%s: %s", node_id, exc)
        return False
    if not record or record.get("paused"):
        return False
    if agent_scope == "private":
        if record.get("visibility") != "private" or record.get("owner_user_id") != owner_user_id:
            return False
    elif record.get("visibility") == "private":
        return False
    url = str(record.get("url") or "").rstrip("/")
    if not url.startswith("pull://"):
        return False
    try:
        last_seen = int(record.get("last_seen") or 0)
        ttl_ms = max(1, int(record.get("ttl_seconds") or 120)) * 1000
    except (TypeError, ValueError):
        return False
    return bool(last_seen and last_seen + ttl_ms > int(time.time() * 1000))


def _agent_pull_job_assignable_to_node(spec: dict, node_id: str) -> bool:
    session_id = str(spec.get("session_id") or "")
    agent_scope = str(spec.get("agent_scope") or "public").strip().lower()
    owner_user_id = str(spec.get("user_id") or "")
    provider_id = _normalize_provider_id(spec.get("provider_id"))
    agent_id = str(spec.get("agent_id") or "claude").strip().lower().replace("_", "-")
    try:
        import agent_node_registry

        record = agent_node_registry.get_node(node_id)
    except Exception as exc:
        logger.warning("[AGENT_PULL] node capability lookup failed node=%s: %s", node_id, exc)
        return False
    if not record or bool(record.get("paused") or False):
        return False
    if agent_scope == "private":
        if record.get("visibility") != "private" or str(record.get("owner_user_id") or "") != owner_user_id:
            return False
    elif record.get("visibility") == "private":
        return False
    capability_match = _agent_node_capability_supports(record.get("capabilities"), provider_id, agent_id)
    if capability_match is False:
        return False
    if capability_match is None:
        if not _node_supports(provider_id, record.get("provider_ids")):
            return False
        if not _node_supports(agent_id, record.get("agent_ids")):
            return False
    sticky_node = _agent_pull_session_node(session_id, agent_scope=agent_scope, owner_user_id=owner_user_id)
    if not sticky_node or sticky_node == node_id:
        return True
    # Keep follow-up turns on the same agent host while it is alive. If it is
    # paused or stale, allow another node to steal the session and refresh the
    # binding during assignment.
    return not _agent_pull_sticky_node_available(sticky_node, agent_scope=agent_scope, owner_user_id=owner_user_id)


def _agent_pull_claim_pending_job_for_node(r: redis.Redis, node_id: str, *, queue_key: str) -> Tuple[str, Optional[dict]]:
    lock = r.lock(_agent_pull_acquire_lock_key(), timeout=15, blocking_timeout=1)
    have_lock = False
    try:
        have_lock = lock.acquire(blocking=True)
        if not have_lock:
            return "", None
        try:
            queue_len = int(r.llen(queue_key) or 0)
        except redis.exceptions.RedisError:
            return "", None
        scan_limit = max(1, int(os.environ.get("AGENT_PULL_ASSIGNMENT_SCAN_LIMIT", "200")))
        for index in range(min(queue_len, scan_limit)):
            raw = r.lindex(queue_key, index)
            if not raw:
                continue
            run_id = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else str(raw)
            spec = _agent_pull_job_spec(run_id)
            if not spec:
                r.lrem(queue_key, 1, run_id)
                continue
            session_id = str(spec.get("session_id") or "")
            if session_id and SessionStore().is_aborted(session_id):
                _agent_pull_mark_abort(run_id)
                r.lrem(queue_key, 1, run_id)
                continue
            if not _agent_pull_job_assignable_to_node(spec, node_id):
                continue
            marker = f"__claimed__:{run_id}:{uuid.uuid4().hex}"
            try:
                pipe = r.pipeline()
                pipe.lset(queue_key, index, marker)
                pipe.lrem(queue_key, 1, marker)
                pipe.execute()
            except redis.exceptions.RedisError as exc:
                logger.warning("[AGENT_PULL] pending claim failed node=%s run=%s: %s", node_id, run_id, exc)
                return "", None
            return run_id, spec
        return "", None
    except redis.exceptions.RedisError as exc:
        logger.warning("[AGENT_PULL] pending acquire failed node=%s: %s", node_id, exc)
        return "", None
    finally:
        if have_lock:
            try:
                lock.release()
            except Exception:
                pass


def _has_registered_agent_pull_node(
    *,
    agent_scope: str = "public",
    owner_user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> bool:
    for record in _registered_agent_node_records(
        agent_scope=agent_scope,
        owner_user_id=owner_user_id,
        provider_id=provider_id,
        agent_id=agent_id,
    ):
        if str(record.get("url") or "").rstrip("/").startswith("pull://"):
            return True
    return False


def has_available_private_agent_node(user_id: str, provider_id: str = "", agent_id: str = "") -> bool:
    return _has_registered_agent_pull_node(
        agent_scope="private",
        owner_user_id=user_id,
        provider_id=provider_id,
        agent_id=agent_id,
    )


def has_available_agent_node(
    *,
    agent_scope: str = "public",
    user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> bool:
    scope = "private" if str(agent_scope or "").strip().lower() == "private" else "public"
    return _has_registered_agent_pull_node(
        agent_scope=scope,
        owner_user_id=user_id if scope == "private" else "",
        provider_id=provider_id,
        agent_id=agent_id,
    )


def _wait_for_agent_pull_node(
    timeout_seconds: float = 5.0,
    *,
    agent_scope: str = "public",
    owner_user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> bool:
    deadline = time.time() + max(0.0, timeout_seconds)
    while True:
        if _has_registered_agent_pull_node(
            agent_scope=agent_scope,
            owner_user_id=owner_user_id,
            provider_id=provider_id,
            agent_id=agent_id,
        ):
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.5)


def _agent_pull_total_queue_max(
    *,
    agent_scope: str = "public",
    owner_user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> int:
    total = 0
    for record in _registered_agent_node_records(
        agent_scope=agent_scope,
        owner_user_id=owner_user_id,
        provider_id=provider_id,
        agent_id=agent_id,
    ):
        try:
            total += max(0, int(record.get("queue_max") or 0))
        except (TypeError, ValueError):
            continue
    return total


def _wait_for_agent_pull_queue_slot(
    r: redis.Redis,
    *,
    timeout_seconds: float = 30.0,
    agent_scope: str = "public",
    owner_user_id: str = "",
    provider_id: str = "",
    agent_id: str = "",
) -> None:
    limit = _agent_pull_total_queue_max(
        agent_scope=agent_scope,
        owner_user_id=owner_user_id,
        provider_id=provider_id,
        agent_id=agent_id,
    )
    if limit <= 0:
        return
    queue_key = _agent_pull_pending_key_for_scope(agent_scope, owner_user_id)
    deadline = time.time() + max(0.0, timeout_seconds)
    while True:
        try:
            queued = int(r.llen(queue_key) or 0)
        except redis.exceptions.RedisError as exc:
            logger.warning("[AGENT_PULL] queue length check failed: %s", exc)
            return
        if queued < limit:
            return
        if time.time() >= deadline:
            raise RuntimeError(f"agent-node queue is full: queued={queued} queue_max={limit}")
        time.sleep(0.2)


def agent_pull_acquire():
    auth_ctx = _agent_pull_auth_context()
    if not auth_ctx.get("ok"):
        return jsonify({"error": "unauthorized"}), 401
    body = request.get_json(silent=True) or {}
    node_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(body.get("node_id") or "agent-node")).strip("._") or "agent-node"
    if auth_ctx.get("kind") == "private":
        if node_id != auth_ctx.get("node_id"):
            return jsonify({"error": "private agent node id mismatch"}), 403
    labels = body.get("labels") if isinstance(body.get("labels"), list) else []
    build_commit = str(body.get("build_commit") or body.get("commit") or "").strip()[:128]
    build_version = str(body.get("build_version") or body.get("version") or build_commit or "").strip()[:128]
    provider_mode = str(body.get("provider_mode") or "master").strip().lower().replace("_", "-") or "master"
    if auth_ctx.get("kind") == "private":
        provider_mode = "local"
        if not any(str(label).replace("_", "-").startswith("visibility=") for label in labels):
            labels.append("visibility=private")
    if not any(str(label).replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={provider_mode}")
    try:
        capacity = max(1, min(100, int(body.get("capacity") or 1)))
    except (TypeError, ValueError):
        capacity = 1
    try:
        queue_max = max(0, min(10000, int(body.get("queue_max") if body.get("queue_max") is not None else capacity)))
    except (TypeError, ValueError):
        queue_max = capacity
    try:
        timeout_seconds = max(0.0, min(10.0, float(body.get("timeout_seconds") or 5)))
    except (TypeError, ValueError):
        timeout_seconds = 5.0
    try:
        active_runs = max(0, int(body.get("active_runs") or 0))
    except (TypeError, ValueError):
        active_runs = 0
    accept_jobs = bool(body.get("accept_jobs", True))

    try:
        import agent_node_registry

        existing_node = agent_node_registry.get_node(node_id)
        if auth_ctx.get("kind") != "private" and existing_node and existing_node.get("visibility") == "private":
            return jsonify({"error": "node_id belongs to a private agent node"}), 403
        agent_node_registry.upsert_node(
            node_id=node_id,
            name=str(body.get("name") or body.get("display_name") or "").strip()[:128],
            url=str(body.get("url") or f"pull://{node_id}").strip() or f"pull://{node_id}",
            capacity=capacity,
            queue_max=queue_max,
            build_commit=build_commit,
            build_version=build_version,
            labels=labels,
            ttl_seconds=max(30, int(body.get("ttl_seconds") or 120)),
            owner_user_id=str(auth_ctx.get("owner_user_id") or ""),
            visibility="private" if auth_ctx.get("kind") == "private" else "public",
            auth_key_id=str((auth_ctx.get("record") or {}).get("auth_key_id") or ""),
            provider_mode=provider_mode,
            provider_ids=body.get("provider_ids") if isinstance(body.get("provider_ids"), list) else [],
            agent_ids=body.get("agent_ids") if isinstance(body.get("agent_ids"), list) else [],
            capabilities=body.get("capabilities") if isinstance(body.get("capabilities"), list) else [],
        )
        current_node = agent_node_registry.get_node(node_id)
        if current_node and current_node.get("paused"):
            return ("", 204)
    except Exception as exc:
        logger.warning("[AGENT_PULL] registry heartbeat failed node=%s: %s", node_id, exc)

    if not accept_jobs or active_runs >= capacity:
        return ("", 204)

    r = get_redis()
    deadline = time.time() + timeout_seconds
    run_id = ""
    spec: Optional[dict] = None
    queue_key = _agent_pull_pending_key_for_scope(
        "private" if auth_ctx.get("kind") == "private" else "public",
        str(auth_ctx.get("owner_user_id") or ""),
    )
    while True:
        run_id, spec = _agent_pull_claim_pending_job_for_node(r, node_id, queue_key=queue_key)
        if run_id and spec:
            break
        if time.time() >= deadline:
            return ("", 204)
        time.sleep(0.2)

    assert spec is not None
    provider_id = _normalize_provider_id(spec.get("provider_id"))
    provider = _dynamic_agent_node_provider(provider_id)
    include_provider_secrets = provider_mode not in {"local", "node", "self", "agent-local"}
    payload = _build_agent_node_payload(
        run_id=run_id,
        session_id=str(spec.get("session_id") or ""),
        user_id=str(spec.get("user_id") or "user"),
        provider=provider,
        runner=str(spec.get("agent_id") or "claude"),
        resume_id=str(spec.get("resume_id") or ""),
        turn_msg=str(spec.get("turn_msg") or ""),
        sys_prompt=str(spec.get("sys_prompt") or ""),
        generation_pipeline=normalize_generation_pipeline(spec.get("generation_pipeline")),
        include_provider_secrets=include_provider_secrets,
    )
    now_ms = int(time.time() * 1000)
    session_id = str(payload.get("session_id") or "")
    agent_scope = str(spec.get("agent_scope") or "public").strip().lower()
    owner_user_id = str(spec.get("user_id") or "")
    pipe = r.pipeline()
    pipe.hset(
        _agent_pull_job_key(run_id),
        mapping={
            "status": "assigned",
            "node_id": node_id,
            "assigned_at": str(now_ms),
            "last_seen_at": str(now_ms),
            "provider_mode": provider_mode,
            "visibility": "private" if auth_ctx.get("kind") == "private" else "public",
            "owner_user_id": owner_user_id if auth_ctx.get("kind") == "private" else "",
        },
    )
    pipe.sadd(_agent_pull_node_running_key(node_id), run_id)
    if session_id:
        sticky_key = (
            _agent_pull_private_session_node_key(owner_user_id, session_id)
            if agent_scope == "private"
            else _agent_pull_session_node_key(session_id)
        )
        pipe.set(sticky_key, node_id, ex=AI_SESSION_REDIS_TTL_SECONDS)
        pipe.hset(_meta_key(session_id), "agent_pull_node_id", node_id)
        pipe.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.expire(_agent_pull_node_running_key(node_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.expire(_agent_pull_job_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    pipe.execute()
    return jsonify({"job": payload, "run_id": run_id, "abort": _agent_pull_job_abort_requested(run_id, payload["session_id"])})


def agent_pull_job_events(run_id: str):
    auth_ctx = _agent_pull_auth_context()
    if not auth_ctx.get("ok"):
        return jsonify({"error": "unauthorized"}), 401
    run_id = _safe_path_part(run_id, "run")
    body = request.get_json(silent=True) or {}
    events = body.get("events") if isinstance(body.get("events"), list) else []
    session_id = ""
    spec = _agent_pull_job_spec(run_id)
    if spec:
        session_id = str(spec.get("session_id") or "")
    node_id = str(body.get("node_id") or "")
    authorized, reason = _agent_pull_authorized_for_job(run_id, auth_ctx, node_id=node_id)
    if not authorized:
        return jsonify({"error": "forbidden", "reason": reason}), 403
    now_ms = int(time.time() * 1000)
    try:
        mapping = {"last_seen_at": str(now_ms)}
        if node_id:
            mapping["node_id"] = node_id
        get_redis().hset(_agent_pull_job_key(run_id), mapping=mapping)
        get_redis().expire(_agent_pull_job_key(run_id), AI_SESSION_REDIS_TTL_SECONDS)
    except redis.exceptions.RedisError:
        pass
    for item in events[:500]:
        if not isinstance(item, dict):
            continue
        _agent_pull_append_job_event(run_id, item)
        if item.get("type") == "stop":
            status = str(item.get("status") or "failed")
            mapping = {
                "status": status,
                "finished_at": str(int(time.time() * 1000)),
                "returncode": str(item.get("returncode")),
            }
            if node_id:
                _agent_pull_release_node_running(run_id, node_id)
            get_redis().hset(_agent_pull_job_key(run_id), mapping=mapping)
    abort = _agent_pull_job_abort_requested(run_id, session_id)
    return jsonify({"ok": True, "abort": abort})


def agent_pull_job_artifact(run_id: str):
    auth_ctx = _agent_pull_auth_context()
    if not auth_ctx.get("ok"):
        return jsonify({"error": "unauthorized"}), 401
    run_id = _safe_path_part(run_id, "run")
    authorized, reason = _agent_pull_authorized_for_job(run_id, auth_ctx)
    if not authorized:
        return jsonify({"error": "forbidden", "reason": reason}), 403
    relative_path = str(request.args.get("path") or "app.json").strip() or "app.json"
    normalized = os.path.normpath(relative_path).replace("\\", "/")
    if normalized.startswith("../") or normalized == ".." or os.path.isabs(normalized):
        return jsonify({"error": "invalid artifact path"}), 400
    data = request.get_data() or b""
    max_bytes = int(os.environ.get("AGENT_PULL_ARTIFACT_MAX_BYTES", "52428800"))
    if len(data) > max_bytes:
        return jsonify({"error": "artifact too large"}), 413
    r = get_redis()
    r.set(_agent_pull_artifact_key(run_id, normalized), data, ex=AI_SESSION_REDIS_TTL_SECONDS)
    return jsonify({"ok": True, "run_id": run_id, "path": normalized, "bytes": len(data)})


def _run_agent_pull_worker(
    *,
    store: SessionStore,
    session_id: str,
    job_id: Optional[str],
    last_msg: str,
    provider: dict,
    runner: str,
    agent_resume_id: Optional[str],
    sys_prompt: str,
    generation_pipeline: str,
    quota_used: int,
    quota_limit: int,
    quota_remaining: int,
    agent_scope: str,
    append_event,
    set_status,
    all_events: List[dict],
) -> None:
    parse_line = _parse_line_for_runner(runner)
    current_resume_id = agent_resume_id or ""
    owner_user_id = store.get_meta(session_id).get("user_id") or "user"

    def run_once(current_run_id: str, turn_msg: str) -> Optional[_AgentNodeRunResult]:
        if store.is_aborted(session_id):
            set_status(STATUS_ABORTED)
            return None
        scope = "private" if agent_scope == "private" else "public"
        provider_id = str(provider.get("id") or DEFAULT_PROVIDER)
        if not _wait_for_agent_pull_node(
            float(os.environ.get("AGENT_PULL_NODE_WAIT_SECONDS", "5")),
            agent_scope=scope,
            owner_user_id=owner_user_id,
            provider_id=provider_id,
            agent_id=runner,
        ):
            err_msg = (
                "没有在线私有 agent-node，无法启动 AI 生成任务"
                if scope == "private"
                else "没有在线 agent-node pull 节点，无法启动 AI 生成任务"
            )
            append_event({"error": err_msg, "needs_retry": True})
            set_status(STATUS_FAILED, error=err_msg)
            return None
        _agent_pull_enqueue_run(
            run_id=current_run_id,
            session_id=session_id,
            user_id=owner_user_id,
            provider_id=provider_id,
            runner=runner,
            resume_id=current_resume_id,
            turn_msg=turn_msg,
            sys_prompt=sys_prompt,
            generation_pipeline=generation_pipeline,
            agent_scope=scope,
        )
        try:
            store.r.hset(
                _meta_key(session_id),
                mapping={
                    "agent_pull_run_id": current_run_id,
                    "agent_node_run_id": current_run_id,
                },
            )
            store.r.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
        except Exception:
            pass
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "agent_pull_enqueue",
            "run_id": current_run_id,
            "provider": provider.get("id"),
            "agent": runner,
            "agent_scope": scope,
            "resume": bool(current_resume_id),
        }, ensure_ascii=False))

        line_count = 0
        stderr_tail: List[str] = []
        transport_errors: List[str] = []
        remote_client_actions: List[dict] = []
        returncode: Optional[int] = None
        status = "failed"
        last_id = "0"
        try:
            idle_timeout_seconds = max(
                30.0,
                float(os.environ.get("AGENT_PULL_EVENT_IDLE_TIMEOUT_SECONDS", "180")),
            )
        except (TypeError, ValueError):
            idle_timeout_seconds = 180.0
        while True:
            if store.is_aborted(session_id):
                _agent_pull_mark_abort(current_run_id)
                set_status(STATUS_ABORTED)
                return None
            entries = _agent_pull_read_job_events(current_run_id, last_id=last_id, block_ms=5000)
            if not entries:
                job_meta = _agent_pull_job_meta(current_run_id)
                if str(job_meta.get("status") or "") == "assigned":
                    last_seen_ms = max(
                        _agent_pull_meta_int(job_meta, "last_seen_at"),
                        _agent_pull_meta_int(job_meta, "assigned_at"),
                    )
                    if last_seen_ms and int(time.time() * 1000) - last_seen_ms > int(idle_timeout_seconds * 1000):
                        _agent_pull_mark_abort(current_run_id)
                        _agent_pull_release_node_running(current_run_id, str(job_meta.get("node_id") or ""))
                        err_msg = (
                            "agent-node 运行失联，已停止等待；"
                            f"{int(idle_timeout_seconds)} 秒内未收到事件或心跳"
                        )
                        append_event({"error": err_msg, "needs_retry": True})
                        set_status(STATUS_FAILED, error=err_msg)
                        return None
                continue
            for entry_id, item in entries:
                last_id = entry_id
                item_type = item.get("type")
                if item_type == "stdout":
                    line = str(item.get("line") or "")
                    _append_cli_log(session_id, "stdout", line)
                    thread_id = _extract_thread_id_for_runner(runner, line)
                    if thread_id:
                        store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
                    for ev in parse_line(line):
                        if _is_internal_cli_event(ev):
                            error_text = str(ev.get("cli_transport_error") or "")
                            if error_text:
                                transport_errors.append(error_text)
                                transport_errors = transport_errors[-5:]
                            all_events.append(ev)
                            line_count += 1
                            continue
                        if not append_event(ev):
                            _agent_pull_mark_abort(current_run_id)
                            return None
                        all_events.append(ev)
                        line_count += 1
                elif item_type == "stderr":
                    line = str(item.get("line") or "")
                    stderr_tail.append(line)
                    stderr_tail = stderr_tail[-20:]
                    _append_cli_log(session_id, "stderr", line)
                elif item_type == "error":
                    message = str(item.get("message") or item.get("error") or "")
                    if message:
                        stderr_tail.append(message)
                        stderr_tail = stderr_tail[-20:]
                    _append_cli_log(session_id, "meta", json.dumps(item, ensure_ascii=False))
                elif item_type == "client_actions":
                    payload = item.get("payload")
                    if isinstance(payload, dict):
                        raw_actions = payload.get("client_actions")
                    elif isinstance(payload, list):
                        raw_actions = payload
                    else:
                        raw_actions = []
                    if isinstance(raw_actions, list):
                        remote_client_actions = _compact_client_actions(raw_actions, session_id)
                elif item_type == "stop":
                    returncode = item.get("returncode")
                    status = str(item.get("status") or "failed")
                    if store.is_aborted(session_id):
                        set_status(STATUS_ABORTED)
                        return None
                    return _AgentNodeRunResult(
                        run_id=current_run_id,
                        status=status,
                        returncode=returncode,
                        remote_client_actions=remote_client_actions,
                        stderr_tail=stderr_tail,
                        line_count=line_count,
                        transport_errors=transport_errors,
                    )
                else:
                    _append_cli_log(session_id, "meta", json.dumps(item, ensure_ascii=False))

    base_run_id = _safe_path_part(job_id or uuid.uuid4().hex, "job")
    repair_run_prefix = base_run_id[:80].rstrip("-_.") or "job"
    current_run_id = base_run_id
    current_msg = last_msg
    repair_attempts = 0
    transport_retry_attempts = 0
    max_transport_retries = _agent_cli_transport_retry_max()
    total_line_count = 0
    last_validation_hash = ""
    client_actions: List[dict] = []
    while True:
        run_result = run_once(current_run_id, current_msg)
        if run_result is None:
            return
        total_line_count += run_result.line_count

        if run_result.status != "done" or run_result.returncode not in (0, None):
            err_text = "".join(run_result.stderr_tail)[-2000:]
            transport_error = next(
                (item for item in reversed(run_result.transport_errors) if _is_cli_transport_error(item)),
                "",
            )
            if not transport_error and _is_cli_transport_error(err_text):
                transport_error = err_text
            if transport_error and transport_retry_attempts < max_transport_retries:
                transport_retry_attempts += 1
                if not append_event({
                    "status": "retrying",
                    "message": (
                        "AI 接口返回临时兼容错误，正在重试 "
                        f"({transport_retry_attempts}/{max_transport_retries})..."
                    ),
                    "retry_attempt": transport_retry_attempts,
                    "max_retry_attempts": max_transport_retries,
                }):
                    return
                _append_cli_log(session_id, "meta", json.dumps({
                    "event": "cli_transport_retry",
                    "run_id": run_result.run_id,
                    "next_run_id": f"{repair_run_prefix}-transport-retry-{transport_retry_attempts}",
                    "attempt": transport_retry_attempts,
                    "max_attempts": max_transport_retries,
                    "error": transport_error[-500:],
                }, ensure_ascii=False))
                current_run_id = _safe_path_part(
                    f"{repair_run_prefix}-transport-retry-{transport_retry_attempts}",
                    "retry",
                )
                continue
            err_msg = f"agent-pull run failed status={run_result.status} returncode={run_result.returncode}: {err_text}"
            if transport_error and not err_text:
                err_msg = (
                    f"agent-pull run failed status={run_result.status} "
                    f"returncode={run_result.returncode}: {transport_error}"
                )
            append_event({"error": err_msg, "needs_retry": True})
            set_status(STATUS_FAILED, error=err_msg)
            return

        candidate_actions = run_result.remote_client_actions
        if repair_attempts > 0 and not candidate_actions:
            err_msg = "生成结果自动修复结束，但 Agent 没有重新请求上传 app.json"
            append_event({
                "error": err_msg,
                "stage": "server_upload_app_json",
                "repair_attempts": repair_attempts,
                "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "needs_retry": True,
            })
            set_status(STATUS_FAILED, error=err_msg)
            return
        try:
            client_actions = _resolve_server_upload_actions(
                candidate_actions,
                session_id,
                workspace=None,
                agent_pull_run_id=run_result.run_id,
                owner_user_id=owner_user_id,
                allow_faas_repair=True,
            )
            break
        except ServerUploadValidationError as exc:
            detail = exc.detail[-4000:]
            detail_hash = hashlib.sha256(detail.encode("utf-8", errors="replace")).hexdigest()
            repeated_error = bool(last_validation_hash and detail_hash == last_validation_hash)
            if repair_attempts >= AI_SERVER_REPAIR_MAX_ATTEMPTS:
                reason = f"自动修复 {repair_attempts} 次后仍未通过"
                err_msg = f"生成结果校验失败，{reason}"
                append_event({
                    "error": err_msg,
                    "stage": exc.script,
                    "validator_error": detail[-2000:],
                    "repair_attempts": repair_attempts,
                    "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                    "repeated_validator_error": repeated_error,
                    "needs_retry": True,
                })
                set_status(STATUS_FAILED, error=f"{err_msg}: {detail[-1000:]}")
                return

            repair_attempts += 1
            last_validation_hash = detail_hash
            if not append_event({
                "status": "repairing",
                "message": (
                    f"生成结果校验失败，正在自动修复 "
                    f"({repair_attempts}/{AI_SERVER_REPAIR_MAX_ATTEMPTS})..."
                ),
                "repair_attempt": repair_attempts,
                "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "repeated_validator_error": repeated_error,
                "stage": exc.script,
            }):
                return
            if (
                runner == "claude"
                and not current_resume_id
                and claude_cli_resume_enabled(provider.get("id"))
            ):
                current_resume_id = session_id
            elif runner in {"codex", "opencode"} and not current_resume_id:
                current_resume_id = store.get_meta(session_id).get("agent_thread_id") or ""
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "server_validation_repair_start",
                "run_id": run_result.run_id,
                "next_run_id": f"{repair_run_prefix}-repair-{repair_attempts}",
                "attempt": repair_attempts,
                "max_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "script": exc.script,
                "resume": bool(current_resume_id),
                "repeated_validator_error": repeated_error,
            }, ensure_ascii=False))
            current_run_id = _safe_path_part(f"{repair_run_prefix}-repair-{repair_attempts}", "repair")
            current_msg = _build_server_repair_request(
                script=exc.script,
                detail=exc.detail,
                relative_path="app.json",
                attempt=repair_attempts,
                max_attempts=AI_SERVER_REPAIR_MAX_ATTEMPTS,
            )

    final_text, final_thinking = extract_final_texts(all_events)
    protocol_warnings = _final_protocol_warnings(final_text)
    if protocol_warnings:
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "final_protocol_warning",
            "warnings": protocol_warnings,
            "tail": (final_text or "")[-500:],
        }, ensure_ascii=False))
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
        "event": "agent_pull_worker_done",
        "run_id": current_run_id,
        "lines": total_line_count,
        "repair_attempts": repair_attempts,
        "final_text_len": len(final_text or ""),
        "final_thinking_len": len(final_thinking or ""),
        "client_actions": client_actions,
    }, ensure_ascii=False))


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
    generation_pipeline: str,
    workspace: str,
    quota_used: int,
    quota_limit: int,
    quota_remaining: int,
    append_event,
    set_status,
    all_events: List[dict],
) -> None:
    agent_node_url = _select_agent_node_url(session_id)
    agent_node_provider_mode = _agent_node_provider_mode_for_url(agent_node_url)
    include_provider_secrets = agent_node_provider_mode != "local"
    try:
        store.r.hset(_meta_key(session_id), "agent_node_url", agent_node_url)
        store.r.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
    except Exception:
        pass

    parse_line = _parse_line_for_runner(runner)
    current_resume_id = agent_resume_id or ""
    owner_user_id = store.get_meta(session_id).get("user_id") or "user"

    def run_once(current_run_id: str, turn_msg: str) -> Optional[_AgentNodeRunResult]:
        if store.is_aborted(session_id):
            set_status(STATUS_ABORTED)
            return None
        payload = _build_agent_node_payload(
            run_id=current_run_id,
            session_id=session_id,
            user_id=owner_user_id,
            provider=provider,
            runner=runner,
            resume_id=current_resume_id,
            turn_msg=turn_msg,
            sys_prompt=sys_prompt,
            generation_pipeline=generation_pipeline,
            include_provider_secrets=include_provider_secrets,
        )
        try:
            store.r.hset(
                _meta_key(session_id),
                mapping={
                    "agent_node_url": agent_node_url,
                    "agent_node_run_id": current_run_id,
                },
            )
            store.r.expire(_meta_key(session_id), AI_SESSION_REDIS_TTL_SECONDS)
        except Exception:
            pass

        _append_cli_log(session_id, "meta", json.dumps({
            "event": "agent_node_submit",
            "url": agent_node_url,
            "run_id": current_run_id,
            "provider": provider.get("id"),
            "agent": runner,
            "resume": bool(current_resume_id),
            "provider_mode": agent_node_provider_mode,
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
        stderr_tail: List[str] = []
        transport_errors: List[str] = []
        remote_client_actions: List[dict] = []
        returncode: Optional[int] = None
        status = "failed"
        with requests.get(
            f"{agent_node_url}/v1/runs/{current_run_id}/events",
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
                            f"{agent_node_url}/v1/runs/{current_run_id}/abort",
                            headers=_agent_node_headers(),
                            timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
                        )
                    except Exception:
                        pass
                    set_status(STATUS_ABORTED)
                    return None
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
                    thread_id = _extract_thread_id_for_runner(runner, line)
                    if thread_id:
                        store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
                    for ev in parse_line(line):
                        if _is_internal_cli_event(ev):
                            error_text = str(ev.get("cli_transport_error") or "")
                            if error_text:
                                transport_errors.append(error_text)
                                transport_errors = transport_errors[-5:]
                            all_events.append(ev)
                            line_count += 1
                            continue
                        if not append_event(ev):
                            try:
                                requests.post(
                                    f"{agent_node_url}/v1/runs/{current_run_id}/abort",
                                    headers=_agent_node_headers(),
                                    timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
                                )
                            except Exception:
                                pass
                            return None
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
                        remote_client_actions = _compact_client_actions(raw_actions, session_id)
                elif item_type == "stop":
                    returncode = item.get("returncode")
                    status = str(item.get("status") or "failed")
                    break
                else:
                    _append_cli_log(session_id, "meta", json.dumps(item, ensure_ascii=False))

        if store.is_aborted(session_id):
            set_status(STATUS_ABORTED)
            return None
        return _AgentNodeRunResult(
            run_id=current_run_id,
            status=status,
            returncode=returncode,
            remote_client_actions=remote_client_actions,
            stderr_tail=stderr_tail,
            line_count=line_count,
            transport_errors=transport_errors,
        )

    base_run_id = _safe_path_part(job_id or uuid.uuid4().hex, "job")
    repair_run_prefix = base_run_id[:80].rstrip("-_.") or "job"
    current_run_id = base_run_id
    current_msg = last_msg
    repair_attempts = 0
    transport_retry_attempts = 0
    max_transport_retries = _agent_cli_transport_retry_max()
    total_line_count = 0
    last_validation_hash = ""
    client_actions: List[dict] = []
    while True:
        run_result = run_once(current_run_id, current_msg)
        if run_result is None:
            return
        total_line_count += run_result.line_count

        if run_result.status != "done" or run_result.returncode not in (0, None):
            err_text = "".join(run_result.stderr_tail)[-2000:]
            transport_error = next(
                (item for item in reversed(run_result.transport_errors) if _is_cli_transport_error(item)),
                "",
            )
            if not transport_error and _is_cli_transport_error(err_text):
                transport_error = err_text
            if transport_error and transport_retry_attempts < max_transport_retries:
                transport_retry_attempts += 1
                if not append_event({
                    "status": "retrying",
                    "message": (
                        "AI 接口返回临时兼容错误，正在重试 "
                        f"({transport_retry_attempts}/{max_transport_retries})..."
                    ),
                    "retry_attempt": transport_retry_attempts,
                    "max_retry_attempts": max_transport_retries,
                }):
                    return
                _append_cli_log(session_id, "meta", json.dumps({
                    "event": "cli_transport_retry",
                    "run_id": run_result.run_id,
                    "next_run_id": f"{repair_run_prefix}-transport-retry-{transport_retry_attempts}",
                    "attempt": transport_retry_attempts,
                    "max_attempts": max_transport_retries,
                    "error": transport_error[-500:],
                }, ensure_ascii=False))
                current_run_id = _safe_path_part(
                    f"{repair_run_prefix}-transport-retry-{transport_retry_attempts}",
                    "retry",
                )
                continue
            err_msg = f"agent-node run failed status={run_result.status} returncode={run_result.returncode}: {err_text}"
            if transport_error and not err_text:
                err_msg = (
                    f"agent-node run failed status={run_result.status} "
                    f"returncode={run_result.returncode}: {transport_error}"
                )
            append_event({"error": err_msg, "needs_retry": True})
            set_status(STATUS_FAILED, error=err_msg)
            return

        candidate_actions = run_result.remote_client_actions or _load_client_actions(workspace, session_id)
        if repair_attempts > 0 and not candidate_actions:
            err_msg = "生成结果自动修复结束，但 Agent 没有重新请求上传 app.json"
            append_event({
                "error": err_msg,
                "stage": "server_upload_app_json",
                "repair_attempts": repair_attempts,
                "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "needs_retry": True,
            })
            set_status(STATUS_FAILED, error=err_msg)
            return
        try:
            client_actions = _resolve_server_upload_actions(
                candidate_actions,
                session_id,
                workspace=workspace,
                agent_node_url=agent_node_url,
                run_id=run_result.run_id,
                owner_user_id=owner_user_id,
                allow_faas_repair=True,
            )
            break
        except ServerUploadValidationError as exc:
            detail = exc.detail[-4000:]
            detail_hash = hashlib.sha256(detail.encode("utf-8", errors="replace")).hexdigest()
            repeated_error = bool(last_validation_hash and detail_hash == last_validation_hash)
            if repair_attempts >= AI_SERVER_REPAIR_MAX_ATTEMPTS:
                reason = f"自动修复 {repair_attempts} 次后仍未通过"
                err_msg = f"生成结果校验失败，{reason}"
                append_event({
                    "error": err_msg,
                    "stage": exc.script,
                    "validator_error": detail[-2000:],
                    "repair_attempts": repair_attempts,
                    "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                    "repeated_validator_error": repeated_error,
                    "needs_retry": True,
                })
                set_status(STATUS_FAILED, error=f"{err_msg}: {detail[-1000:]}")
                return

            repair_attempts += 1
            last_validation_hash = detail_hash
            if not append_event({
                "status": "repairing",
                "message": (
                    f"生成结果校验失败，正在自动修复 "
                    f"({repair_attempts}/{AI_SERVER_REPAIR_MAX_ATTEMPTS})..."
                ),
                "repair_attempt": repair_attempts,
                "max_repair_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "repeated_validator_error": repeated_error,
                "stage": exc.script,
            }):
                return
            if (
                runner == "claude"
                and not current_resume_id
                and claude_cli_resume_enabled(provider.get("id"))
            ):
                current_resume_id = session_id
            elif runner in {"codex", "opencode"} and not current_resume_id:
                current_resume_id = store.get_meta(session_id).get("agent_thread_id") or ""
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "server_validation_repair_start",
                "run_id": run_result.run_id,
                "next_run_id": f"{repair_run_prefix}-repair-{repair_attempts}",
                "attempt": repair_attempts,
                "max_attempts": AI_SERVER_REPAIR_MAX_ATTEMPTS,
                "script": exc.script,
                "resume": bool(current_resume_id),
                "repeated_validator_error": repeated_error,
            }, ensure_ascii=False))
            current_run_id = _safe_path_part(f"{repair_run_prefix}-repair-{repair_attempts}", "repair")
            current_msg = _build_server_repair_request(
                script=exc.script,
                detail=exc.detail,
                relative_path="app.json",
                attempt=repair_attempts,
                max_attempts=AI_SERVER_REPAIR_MAX_ATTEMPTS,
            )

    final_text, final_thinking = extract_final_texts(all_events)
    protocol_warnings = _final_protocol_warnings(final_text)
    if protocol_warnings:
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "final_protocol_warning",
            "warnings": protocol_warnings,
            "tail": (final_text or "")[-500:],
        }, ensure_ascii=False))
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
        "run_id": current_run_id,
        "lines": total_line_count,
        "repair_attempts": repair_attempts,
        "final_text_len": len(final_text or ""),
        "final_thinking_len": len(final_thinking or ""),
        "client_actions": client_actions,
    }, ensure_ascii=False))


def _worker_main(session_id: str, last_msg: str, provider_id: Optional[str],
                 agent_id: Optional[str], agent_resume_id: Optional[str],
                 generation_pipeline: str,
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
        generation_pipeline = normalize_generation_pipeline(generation_pipeline)
        # ─── 1. 起进程 ───
        # load_generate_prompt() 在生产是 no-op，测试环境会把 prompt 里硬编码的
        # 生产 URL 替换成实际环境 URL，避免 AI 生成的 JSON-APP 嵌入生产域名
        sys_prompt = ""
        try:
            sys_prompt = load_generate_prompt(generation_pipeline)
        except FileNotFoundError:
            logger.warning(
                "[WORKER] 系统提示词文件未找到 pipeline=%s ref=%s",
                generation_pipeline,
                generation_prompt_reference(generation_pipeline),
            )

        if _uses_agent_pull_backend():
            provider = _dynamic_agent_node_provider(provider_id)
            env = os.environ.copy()
            env["IS_SANDBOX"] = "1"
        else:
            provider, env = _provider_env(provider_id)
        agent = _agent_config(agent_id)
        runner = agent["id"]
        workspace = _prepare_worker_workspace(session_id, job_id)
        meta_user_id = store.get_meta(session_id).get("user_id") or "user"
        _write_faas_manifest(workspace, str(meta_user_id))
        env["AI_APP_WORKSPACE"] = workspace
        env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
        parse_line = parse_cli_line

        _append_cli_log(session_id, "meta", json.dumps({
            "event": "worker_start",
            "provider": provider.get("id"),
            "agent": runner,
            "execution_backend": AI_WORKER_EXECUTION_BACKEND,
            "generation_pipeline": generation_pipeline,
            "agent_resume_id": agent_resume_id or "",
            "user_msg_len": len(last_msg),
            "workspace": workspace,
            "ts": int(time.time() * 1000),
        }, ensure_ascii=False))

        if AI_WORKER_EXECUTION_BACKEND in {"agent-pull", "agent-node-pull", "pull"}:
            _run_agent_pull_worker(
                store=store,
                session_id=session_id,
                job_id=job_id,
                last_msg=last_msg,
                provider=provider,
                runner=runner,
                agent_resume_id=agent_resume_id,
                sys_prompt=sys_prompt,
                generation_pipeline=generation_pipeline,
                quota_used=quota_used,
                quota_limit=quota_limit,
                quota_remaining=quota_remaining,
                agent_scope=store.get_meta(session_id).get("agent_scope") or "public",
                append_event=append_event,
                set_status=set_status,
                all_events=all_events,
            )
            return
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
                generation_pipeline=generation_pipeline,
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

        if runner == "opencode":
            raise ValueError("本地 worker 暂不支持 OpenCode，请使用 agent-node 执行后端")

        if runner == "codex":
            _, env = _codex_env(provider, workspace)
            parse_line = parse_codex_line
            prompt = _build_codex_prompt(
                last_msg,
                sys_prompt,
                workspace=workspace,
                generation_pipeline=generation_pipeline,
            )
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
        elif runner == "claude":
            # Claude 有历史时 resume；首次会话直接指定 session-id 创建，避免无意义 fallback。
            resume_first = bool(agent_resume_id)
            cli_run_id = job_id or uuid.uuid4().hex
            cmd = _build_cli_cmd(
                session_id,
                last_msg,
                sys_prompt,
                is_resume=resume_first,
                workspace=workspace,
                cli_session_id=_agent_cli_session_id(session_id, cli_run_id),
                generation_pipeline=generation_pipeline,
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
                        cli_session_id=_agent_cli_session_id(session_id, cli_run_id),
                        generation_pipeline=generation_pipeline,
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
        else:
            raise ValueError(f"未知 AI Agent: {runner}")

        # ─── 4. 主循环：读 CLI 输出 → 解析 → 写 Redis ───
        line_count = 0
        for buffered in first_lines:
            _append_cli_log(session_id, "stdout", buffered)
            line_str = buffered.decode("utf-8", errors="replace")
            thread_id = _extract_thread_id_for_runner(runner, line_str)
            if thread_id:
                store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
            for ev in parse_line(line_str):
                if _is_internal_cli_event(ev):
                    all_events.append(ev)
                    line_count += 1
                    continue
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
            thread_id = _extract_thread_id_for_runner(runner, line_str)
            if thread_id:
                store.r.hset(_meta_key(session_id), "agent_thread_id", thread_id)
            for ev in parse_line(line_str):
                if _is_internal_cli_event(ev):
                    all_events.append(ev)
                    line_count += 1
                    continue
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
            runner_name = _runner_display_name(runner)
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
        client_actions = _resolve_server_upload_actions(
            client_actions,
            session_id,
            workspace=workspace,
            owner_user_id=str(meta_user_id),
        )
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
                  quota_remaining: int,
                  agent_scope: str = "public",
                  generation_pipeline: str = GENERATION_PIPELINE_V1) -> Tuple[bool, Optional[int]]:
    """提交 worker 到 Redis 显式等待队列。立刻返回，不等任务完成。

    调用前应先 SessionStore.create_meta(status=queued)；这里只负责排队。
    返回 (accepted, queue_position)。
    """
    provider_id = _normalize_provider_id(provider_id)
    queue_provider_id = _provider_queue_id(provider_id)
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
        agent_scope="private" if str(agent_scope or "").strip().lower() == "private" else "public",
        generation_pipeline=normalize_generation_pipeline(generation_pipeline),
        quota_used=quota_used,
        quota_limit=quota_limit,
        quota_remaining=quota_remaining,
    )
    job_json = _job_to_json(job)
    try:
        queued_len = get_redis().eval(
            _ENQUEUE_SCRIPT,
            2,
            _pending_queue_key(queue_provider_id),
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


def abort_session(session_id: str) -> bool:
    """请求 abort：写 abort 标记 + 尝试从 Redis pending 移除 + 本进程主动 kill。
    运行中的 worker 主循环会检测 abort 标记；跨 gunicorn worker 时不依赖本地进程表。
    """
    store = SessionStore()
    store.request_abort(session_id)
    meta = store.get_meta(session_id)
    remote_abort_requested = False
    remote_abort_requested = _abort_agent_node_run(session_id, meta) or remote_abort_requested
    remote_abort_requested = _abort_agent_pull_run(session_id, meta) or remote_abort_requested
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
        if removed or not is_session_proc_alive(session_id):
            store.set_status(session_id, STATUS_ABORTED, error="aborted before start")
    _kill_proc(session_id)
    return remote_abort_requested


def _abort_agent_pull_run(session_id: str, meta: dict) -> bool:
    run_id = (meta.get("agent_pull_run_id") or meta.get("agent_node_run_id") or "").strip()
    if not run_id:
        return False
    _agent_pull_mark_abort(run_id)
    logger.info("[AGENT_PULL] abort requested sid=%s run=%s", session_id, run_id)
    return True


def _abort_agent_node_run(session_id: str, meta: dict) -> bool:
    agent_node_url = (meta.get("agent_node_url") or "").rstrip("/")
    run_id = (meta.get("agent_node_run_id") or "").strip()
    if not agent_node_url or not run_id:
        return False
    try:
        response = requests.post(
            f"{agent_node_url}/v1/runs/{run_id}/abort",
            headers=_agent_node_headers(),
            timeout=AGENT_NODE_CONNECT_TIMEOUT_SECONDS,
        )
        if response.status_code >= 500:
            logger.warning(
                "[AGENT_NODE] abort failed sid=%s run=%s status=%s body=%s",
                session_id,
                run_id,
                response.status_code,
                response.text[:300],
            )
            return False
        logger.info(
            "[AGENT_NODE] abort requested sid=%s run=%s status=%s",
            session_id,
            run_id,
            response.status_code,
        )
        return True
    except Exception as exc:
        logger.warning("[AGENT_NODE] abort request error sid=%s run=%s: %s", session_id, run_id, exc)
        return False


def clear_abort(session_id: str) -> None:
    """擦掉 abort 标记。force_restart 重启 worker 时用。"""
    SessionStore().clear_abort(session_id)


def _provider_ids_for_scheduler() -> list[Optional[str]]:
    if _uses_agent_pull_backend():
        return [None]
    provider_ids = [
        pid for pid in AI_PROVIDERS
        if _provider_worker_limits(pid).get("max_concurrency", 0) > 0
    ]
    return provider_ids or [_normalize_provider_id(DEFAULT_PROVIDER)]


def _maybe_start_faas_push_worker() -> None:
    """Start the isolated FaaS git push worker as a daemon thread in this host.

    The worker commits/pushes generated code to the shared myapp-faas-services
    repo outside the request path; the deploy SSH key is only available here, not
    in Agent containers.
    """
    try:
        from config import FAAS_ENABLED, FAAS_GIT_ASYNC_PUSH, FAAS_GIT_ENABLED
    except ModuleNotFoundError:
        from backend.config import FAAS_ENABLED, FAAS_GIT_ASYNC_PUSH, FAAS_GIT_ENABLED
    if not (FAAS_ENABLED and FAAS_GIT_ENABLED and FAAS_GIT_ASYNC_PUSH):
        return
    try:
        try:
            from faas_push_worker import run_push_worker_loop
        except ModuleNotFoundError:
            from backend.faas_push_worker import run_push_worker_loop
        threading.Thread(target=run_push_worker_loop, name="faas-push-worker", daemon=True).start()
        logger.info("[WORKER_DAEMON] started faas git push worker")
    except Exception as exc:  # noqa: BLE001 - never block the AI worker on this
        logger.warning("[WORKER_DAEMON] faas push worker not started: %s", exc)


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
    _maybe_start_faas_push_worker()
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
