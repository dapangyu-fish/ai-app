import json
import os
import logging
from flask import current_app, request, jsonify, Response, stream_with_context
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from config import (
    AI_AGENTS,
    AI_PROVIDERS,
    DEFAULT_AGENT,
    DEFAULT_PROVIDER,
)
from auth import require_auth, verify_access_token
from database import get_quota_info, increment_quota
from config import ROLE_QUOTAS
try:
    from generation_pipeline import resolve_generation_pipeline
except ModuleNotFoundError:
    from backend.generation_pipeline import resolve_generation_pipeline

logger = logging.getLogger(__name__)
_STREAM_TOKEN_SALT = "ai-chat-stream-token-v1"
_STREAM_TOKEN_MAX_AGE = 120


def _stream_token_serializer():
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"])


def _make_stream_token(session_id: str, user_id: str) -> str:
    return _stream_token_serializer().dumps(
        {"sid": session_id, "uid": user_id},
        salt=_STREAM_TOKEN_SALT,
    )


def _verify_stream_token(token: str, session_id: str):
    try:
        data = _stream_token_serializer().loads(
            token,
            salt=_STREAM_TOKEN_SALT,
            max_age=_STREAM_TOKEN_MAX_AGE,
        )
    except (BadSignature, SignatureExpired):
        return None
    if data.get("sid") != session_id:
        return None
    uid = data.get("uid")
    return str(uid) if uid else None


def _authenticate_stream_reader(session_id: str):
    """SSE 鉴权：移动端走 Authorization，Web EventSource 走短期 stream_token。"""
    token = request.args.get("stream_token", "").strip()
    if token:
        return _verify_stream_token(token, session_id)

    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    user = verify_access_token(auth[7:])
    if user is None:
        return None
    return str(user.get("id", ""))


def _optional_auth_user_id() -> str:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return ""
    user = verify_access_token(auth[7:])
    if user is None:
        return ""
    return str(user.get("id") or "")


def _normalize_provider_id(provider_id=None):
    return (provider_id or DEFAULT_PROVIDER).strip().lower().replace("_", "-") or DEFAULT_PROVIDER


def _normalize_agent_id(agent_id=None):
    return (agent_id or DEFAULT_AGENT).strip().lower().replace("_", "-") or DEFAULT_AGENT


def _get_agent(agent_id=None):
    aid = _normalize_agent_id(agent_id)
    cfg = AI_AGENTS.get(aid)
    if not cfg:
        raise ValueError(f"未知 AI Agent: {aid}")
    if not cfg.get("configured"):
        raise ValueError(f"AI Agent 未配置: {aid}")
    if not cfg.get("visible", True):
        raise ValueError(f"AI Agent 当前不可用: {aid}")
    return cfg


def _provider_supports_agent(provider: dict, agent_id: str) -> bool:
    supported = provider.get("supported_agents")
    if isinstance(supported, list) and supported and agent_id not in {str(item) for item in supported}:
        return False
    if agent_id == "claude":
        return bool(provider.get("anthropic_configured", provider.get("configured", False)))
    if agent_id == "codex":
        return bool((provider.get("codex") or {}).get("configured"))
    if agent_id == "opencode":
        return bool((provider.get("opencode") or {}).get("configured"))
    return False


def _dynamic_node_provider(provider_id: str, *, supported_agents: list[str] | None = None) -> dict:
    pid = _normalize_provider_id(provider_id)
    return {
        "id": pid,
        "name": pid.replace("-", " ").strip().title() or pid,
        "description": "Agent node local provider",
        "configured": True,
        "visible": True,
        "models": {"default": ""},
        "cli_env": {},
        "codex": {},
        "opencode": {},
        "supported_agents": supported_agents or ["claude"],
        "worker": {},
    }


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default


_CHAT_CONTEXT_MAX_MESSAGES = _env_int("AI_CHAT_CONTEXT_MAX_MESSAGES", 16)
_CHAT_CONTEXT_MAX_CHARS = _env_int("AI_CHAT_CONTEXT_MAX_CHARS", 24000)
_CHAT_CONTEXT_MESSAGE_MAX_CHARS = _env_int("AI_CHAT_CONTEXT_MESSAGE_MAX_CHARS", 5000)


def _clean_chat_message_content(value) -> str:
    if isinstance(value, str):
        text = value
    elif value is None:
        return ""
    else:
        text = str(value)
    text = text.replace("\x00", "").strip()
    if len(text) > _CHAT_CONTEXT_MESSAGE_MAX_CHARS:
        keep = max(500, _CHAT_CONTEXT_MESSAGE_MAX_CHARS)
        text = text[:keep] + "\n...[truncated]"
    return text


def _normalize_chat_messages(messages) -> list[dict]:
    if not isinstance(messages, list):
        return []
    result = []
    for raw in messages:
        if not isinstance(raw, dict):
            continue
        role = str(raw.get("role") or "").strip().lower()
        if role not in {"user", "assistant"}:
            continue
        content = _clean_chat_message_content(raw.get("content"))
        if not content:
            continue
        # 失败提示和重试按钮是客户端 UI 状态，不应作为下一轮语义上下文污染 Agent。
        if role == "assistant" and (
            "API Error: Failed to parse JSON" in content
            or "AI任务被中断" in content
            or "AI task was interrupted" in content
        ):
            continue
        result.append({"role": role, "content": content})
    return result


def _last_user_message(messages) -> str:
    for m in reversed(_normalize_chat_messages(messages)):
        if m.get("role") == "user":
            return m.get("content", "")
    return ""


def _build_contextual_turn_message(messages, latest_user_message: str) -> str:
    normalized = _normalize_chat_messages(messages)
    if not normalized:
        return latest_user_message

    recent_reversed = []
    total = 0
    for item in reversed(normalized):
        content = item["content"]
        cost = len(content) + 32
        if recent_reversed and (
            len(recent_reversed) >= _CHAT_CONTEXT_MAX_MESSAGES
            or total + cost > _CHAT_CONTEXT_MAX_CHARS
        ):
            break
        recent_reversed.append(item)
        total += cost
    recent = list(reversed(recent_reversed))

    if (
        len(recent) == 1
        and recent[0].get("role") == "user"
        and recent[0].get("content") == latest_user_message
    ):
        return latest_user_message

    lines = [
        "以下是本会话最近对话上下文，只用于理解用户意图和连续打磨同一个 APP；"
        "不要把 assistant 的历史描述当成必须照抄的最终事实，最终以本轮最新用户请求为准。",
        "<conversation_context>",
    ]
    for item in recent:
        role = "user" if item["role"] == "user" else "assistant"
        lines.append(f"<message role=\"{role}\">")
        lines.append(item["content"])
        lines.append("</message>")
    lines.extend([
        "</conversation_context>",
        "本轮最新用户请求:",
        "<latest_user_request>",
        latest_user_message,
        "</latest_user_request>",
    ])
    return "\n".join(lines)


def _get_request_provider(provider_id: str, *, agent_scope: str, user_id: str, agent_id: str) -> dict:
    pid = _normalize_provider_id(provider_id)
    cfg = AI_PROVIDERS.get(pid)
    node_available = ai_session.has_available_agent_node(
        agent_scope=agent_scope,
        user_id=user_id,
        provider_id=pid,
        agent_id=agent_id,
    )
    if not node_available:
        raise ValueError(f"当前 {agent_scope} Agent Node 没有可用供应商: {pid}")
    if cfg and cfg.get("configured") and cfg.get("visible", True):
        if _provider_supports_agent(cfg, agent_id) or node_available:
            return cfg
        raise ValueError(f"供应商 {pid} 不支持 Agent {agent_id}")
    return _dynamic_node_provider(pid, supported_agents=[agent_id])


def list_providers():
    """获取所有可用的 AI 供应商列表"""
    scope = str(request.args.get("agent_scope") or request.args.get("agentNodeScope") or "public").strip().lower().replace("_", "-")
    if scope not in {"public", "private"}:
        scope = "public"
    owner_user_id = _optional_auth_user_id() if scope == "private" else ""
    providers = ai_session.agent_node_provider_catalog(
        agent_scope=scope,
        owner_user_id=owner_user_id,
    )
    return jsonify({"providers": providers, "agent_scope": scope})


def list_agents():
    """获取所有可用的执行 Agent 列表"""
    agents = []
    for aid, cfg in AI_AGENTS.items():
        if not cfg.get("visible", True):
            continue
        agents.append({
            "id": cfg["id"],
            "name": cfg["name"],
            "description": cfg.get("description", ""),
            "configured": bool(cfg.get("configured", False)),
            "default": cfg["id"] == DEFAULT_AGENT,
        })
    return jsonify({"agents": agents, "default_agent": DEFAULT_AGENT})


# ════════════════════════════════════════════════════════════════════════════
# 当前 Chat 流：worker 与 HTTP 连接解耦
#
#   POST /api/ai/chat/start             → 起 worker，立刻返 session_id
#   GET  /api/ai/chat/<id>/stream       → SSE 从 Redis 读，可断重连（last_id 续）
#   GET  /api/ai/chat/<id>/result       → 一次性返回最终文本（任务完成后）
#   GET  /api/ai/chat/<id>/status       → meta 元信息（轻量轮询用）
#   POST /api/ai/chat/<id>/abort        → 请求取消
#
# 详见 ARCHITECTURE.md §3。
# ════════════════════════════════════════════════════════════════════════════

import time as _time
import ai_session

_CHAT_START_LOCK_TTL_SECONDS = int(os.environ.get("AI_CHAT_START_LOCK_TTL_SECONDS", "45"))
_CHAT_START_LOCK_WAIT_SECONDS = float(os.environ.get("AI_CHAT_START_LOCK_WAIT_SECONDS", "3"))
_CHAT_ABORT_INTENTS = {"manual_stop", "delete_session", "clear_session"}


def _chat_start_lock_key(session_id: str) -> str:
    return f"ai:session:{session_id}:start_lock"


def _acquire_chat_start_lock(session_id: str) -> str | None:
    token = os.urandom(12).hex()
    deadline = _time.time() + max(0.0, _CHAT_START_LOCK_WAIT_SECONDS)
    redis_client = ai_session.get_redis()
    while True:
        try:
            ok = redis_client.set(
                _chat_start_lock_key(session_id),
                token,
                nx=True,
                ex=max(5, _CHAT_START_LOCK_TTL_SECONDS),
            )
        except Exception as exc:
            logger.warning("[CHAT_START] sid=%s start lock unavailable: %s", session_id, exc)
            return token
        if ok:
            return token
        if _time.time() >= deadline:
            return None
        _time.sleep(0.1)


def _release_chat_start_lock(session_id: str, token: str | None) -> None:
    if not token:
        return
    script = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
"""
    try:
        ai_session.get_redis().eval(script, 1, _chat_start_lock_key(session_id), token)
    except Exception as exc:
        logger.warning("[CHAT_START] sid=%s release start lock failed: %s", session_id, exc)


def _chat_abort_intent() -> str:
    body = request.get_json(silent=True) or {}
    return str(body.get("intent") or request.args.get("intent") or "").strip()


@require_auth
def chat_start():
    """提交 AI 任务到 worker，立即返回 session_id。

    Body: {messages, session_id, provider?, agent?}
    Resp: {session_id, status: "running"}
    """
    user_id = request.supabase_user.get("id")
    role = request.user_role

    used, limit, remaining = get_quota_info(
        user_id, role, ROLE_QUOTAS,
        app_metadata=request.supabase_user.get("app_metadata"),
    )
    if remaining <= 0:
        return jsonify({"error": "配额已用完", "quota": {"used": used, "limit": limit}}), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    session_id = body.get("session_id")
    provider_id = body.get("provider")
    agent_id = body.get("agent")
    agent_scope = str(body.get("agent_scope") or body.get("agentNodeScope") or "public").strip().lower().replace("_", "-")
    if agent_scope not in {"public", "private"}:
        return jsonify({"error": "agent_scope must be public or private", "code": "AI_AGENT_SCOPE_INVALID"}), 400
    # force_restart=true：用户输入新消息时用，先杀掉同 session 还在跑的 worker 再起新的
    # 默认 false：双击 send / 重连等场景幂等返回 resumed:true
    force_restart = bool(body.get("force_restart", False))

    if not messages or not session_id:
        return jsonify({"error": "messages 和 session_id 是必需的"}), 400

    last_msg = _last_user_message(messages)
    if not last_msg:
        return jsonify({"error": "未找到用户消息"}), 400
    turn_msg = _build_contextual_turn_message(messages, last_msg)

    try:
        agent = _get_agent(agent_id)
    except ValueError as e:
        logger.warning(f"[CHAT_START] agent rejected: {e}")
        return jsonify({"error": str(e), "code": "AI_AGENT_UNAVAILABLE"}), 400
    agent_id = agent["id"]
    provider_id = _normalize_provider_id(provider_id)
    if agent_scope == "private" and not ai_session.has_available_private_agent_node(user_id, provider_id, agent_id):
        return jsonify({
            "error": "没有在线的私有 Agent Node，请先启动你的私有节点或切换到平台 Agent",
            "code": "AI_PRIVATE_AGENT_OFFLINE",
        }), 409
    try:
        provider = _get_request_provider(
            provider_id,
            agent_scope=agent_scope,
            user_id=user_id,
            agent_id=agent_id,
        )
    except ValueError as e:
        logger.warning(f"[CHAT_START] provider rejected: {e}")
        return jsonify({"error": str(e), "code": "AI_PROVIDER_UNAVAILABLE"}), 400
    provider_id = provider["id"]
    if not _provider_supports_agent(provider, agent_id) and not ai_session.has_available_agent_node(
        agent_scope=agent_scope,
        user_id=user_id,
        provider_id=provider_id,
        agent_id=agent_id,
    ):
        return jsonify({
            "error": f"供应商 {provider_id} 不支持 Agent {agent_id}",
            "code": "AI_AGENT_PROVIDER_UNAVAILABLE",
        }), 400

    start_lock = _acquire_chat_start_lock(session_id)
    if not start_lock:
        existing = ai_session.SessionStore().get_meta(session_id)
        status = existing.get("status") if existing else ""
        logger.info("[CHAT_START] sid=%s start already in progress; return current status=%s", session_id, status)
        if force_restart:
            return jsonify({
                "error": "上一轮 AI 启动请求仍在处理中，请稍后再试",
                "code": "AI_TASK_STARTING",
            }), 409
        if status in (ai_session.STATUS_RUNNING, ai_session.STATUS_QUEUED):
            return jsonify({
                "session_id": session_id,
                "status": status,
                "queue_position": ai_session.get_queue_position(session_id) if status == ai_session.STATUS_QUEUED else None,
                "resumed": True,
            })
        return jsonify({
            "error": "上一轮 AI 启动请求仍在处理中，请稍后再试",
            "code": "AI_TASK_STARTING",
        }), 409

    try:
        store = ai_session.SessionStore()
        existing = store.get_meta(session_id)
        if existing.get("status") == ai_session.STATUS_QUEUED:
            existing = ai_session.reconcile_stale_queued(session_id)
        existing_user_id = existing.get("user_id") if existing else None
        same_session_owner = bool(existing and (not existing_user_id or existing_user_id == user_id))
        interrupted_previous = False

        if existing and not same_session_owner and existing.get("status") not in ai_session.TERMINAL_STATUSES:
            logger.warning(
                f"[CHAT_START] sid={session_id} belongs to another user and is still active; "
                "refuse to overwrite"
            )
            return jsonify({
                "error": "该会话正在其他登录状态下运行，请新建会话后重试",
                "code": "AI_SESSION_OWNER_MISMATCH",
            }), 409

        if same_session_owner and existing and existing.get("status") in (ai_session.STATUS_RUNNING, ai_session.STATUS_QUEUED):
            if force_restart:
                # 用户发了新消息：杀掉旧 worker，等它真的结束再起新的
                # 关键不变量：必须确认旧 worker 已经写完 STATUS_ABORTED 才能 create_meta，
                # 否则旧 worker 后写的 set_status 会覆盖新 worker 的 fresh meta，
                # 导致客户端 /status 看到 status=aborted → 又触发重试 → 死循环
                logger.info(f"[CHAT_START] sid={session_id} force_restart：先 abort 旧 worker/queued job")
                interrupted_previous = True
                ai_session.abort_session(session_id)
                # agent-node 模式下 abort_session 会直接通知远端 run 停容器。
                # 这里仍然等旧 worker 完成清理：running lease 以 session_id 为 key，
                # 不能让旧 worker 的 finally 把新 worker 的 lease 删掉。
                terminal_observed = False
                for _ in range(200):  # 最长 20s，客户端 POST 超时是 30s
                    _time.sleep(0.1)
                    m = store.get_meta(session_id)
                    if not m or m.get("status") in ai_session.TERMINAL_STATUSES:
                        terminal_observed = True
                        break
                if not terminal_observed:
                    # 旧 worker 还没把 status 写成 terminal，但 proc 已死的话风险有限
                    remote_alive = ai_session.is_remote_agent_session_alive(session_id, m)
                    if not ai_session.is_session_proc_alive(session_id, meta=m) and not remote_alive:
                        logger.warning(
                            f"[CHAT_START] sid={session_id} 20s 没等到 STATUS_ABORTED 但 running lease 已释放，"
                            f"继续 create_meta；旧 worker 后续 set_status 可能造成短暂状态错乱"
                        )
                    else:
                        logger.error(
                            f"[CHAT_START] sid={session_id} force_restart 20s 后 running lease 仍存活，拒绝覆盖旧 session"
                        )
                        return jsonify({
                            "error": "上一轮 AI 任务正在停止，请稍后再试",
                            "code": "AI_TASK_STOPPING",
                        }), 409
                ai_session.clear_abort(session_id)
            else:
                # 同一 session 双连接（前后台切换、重连）：幂等返回，让 client 去 /stream 续读
                status = existing.get("status")
                logger.info(f"[CHAT_START] sid={session_id} 已存在 status={status}，复用")
                return jsonify({
                    "session_id": session_id,
                    "status": status,
                    "queue_position": ai_session.get_queue_position(session_id) if status == ai_session.STATUS_QUEUED else None,
                    "resumed": True,
                })

        new_remaining = remaining - 1
        agent_resume_id = None
        can_resume_existing = bool(
            same_session_owner
            and existing
            and existing.get("provider") == provider_id
        )
        if (
            agent_id == "codex"
            and can_resume_existing
            and existing.get("agent") == "codex"
            and existing.get("status") == ai_session.STATUS_DONE
        ):
            agent_resume_id = existing.get("agent_thread_id") or None
        elif (
            agent_id == "claude"
            and can_resume_existing
            and existing.get("agent") == "claude"
            and ai_session.claude_cli_resume_enabled(provider_id)
        ):
            # Default is off for third-party Anthropic-compatible providers. They
            # may emit history shapes that Claude CLI cannot replay through -r.
            # When explicitly enabled, Claude Code uses the app session id as its
            # conversation id.
            agent_resume_id = session_id

        # 新一轮 job 必须清掉上一次 /abort 留下的短 TTL 标记。
        # 否则 ai-worker acquire 后会把新 job 当成旧 job 的 abort，留下 queued 幽灵状态。
        ai_session.clear_abort(session_id)
        pipeline_selection = resolve_generation_pipeline()
        generation_pipeline = pipeline_selection.id
        logger.info(
            "[CHAT_START] sid=%s generation_pipeline=%s source=%s raw=%s",
            session_id,
            generation_pipeline,
            pipeline_selection.source,
            pipeline_selection.raw_value,
        )

        # 写 meta + 提交到显式队列。只有接受入队后才扣配额。
        store.create_meta(
            session_id,
            user_id=user_id,
            provider=provider_id,
            agent=agent_id,
            quota_used=used + 1,
            quota_limit=limit,
            quota_remaining=new_remaining,
            status=ai_session.STATUS_QUEUED,
            agent_scope=agent_scope,
            generation_pipeline=generation_pipeline,
        )
        if interrupted_previous:
            store.append_event(session_id, {
                "status": "interrupted",
                "message": "已打断上一轮生成，开始处理新消息...",
            })
        accepted, queue_position = ai_session.submit_worker(
            session_id, turn_msg, provider_id,
            agent_id=agent_id,
            agent_resume_id=agent_resume_id,
            user_id=user_id,
            quota_used=used + 1,
            quota_limit=limit,
            quota_remaining=new_remaining,
            agent_scope=agent_scope,
            generation_pipeline=generation_pipeline,
        )
        if not accepted:
            store.set_status(session_id, ai_session.STATUS_FAILED, error="AI worker queue full")
            return jsonify({
                "error": "当前 AI 任务过多，请稍后再试",
                "code": "AI_QUEUE_FULL",
            }), 429

        # 扣配额（沿用老逻辑：worker 失败损 1 容忍；但队列拒绝不扣）
        increment_quota(user_id)

        logger.info(f"[CHAT_START] sid={session_id} worker 已入队 position={queue_position}")
        return jsonify({
            "session_id": session_id,
            "status": "queued",
            "queue_position": queue_position,
            "agent": agent_id,
            "agent_scope": agent_scope,
            "generation_pipeline": generation_pipeline,
            "resumed": False,
        })
    finally:
        _release_chat_start_lock(session_id, start_lock)


def _build_sse_stream(session_id: str, last_id: str):
    """生成器：从 Redis stream 读事件 + 心跳。

    每条事件输出标准 SSE 格式 `id: <entry_id>\\ndata: <json>\\n\\n`，
    entry_id 是 Redis Stream 的游标，client 重连时用 ?last_id=<entry_id> 续读。

    - 先回放 last_id 之后的所有事件
    - 然后阻塞读新事件（block 5s 内没新数据 → 心跳）
    - meta.status 进入 terminal 状态后，把剩余事件读完再发 [DONE]
    - 僵尸 session（status=running 但进程已死，常见于后端重启）→ 主动标 FAILED + needs_retry
    """
    store = ai_session.SessionStore()
    cursor = last_id
    started_at = _time.time()
    # 僵尸检测：第一次检查在 5s 后（给 worker/agent-node 注册运行态留余量），之后每 10s 检查一次
    next_zombie_check = started_at + 5
    next_queue_status = started_at

    while True:
        items = store.read_events(session_id, last_id=cursor, block_ms=5000, count=100)

        for entry_id, ev in items:
            yield f'id: {entry_id}\ndata: {json.dumps(ev, ensure_ascii=False)}\n\n'
            cursor = entry_id

        if not items:
            # 5s 没新事件 → 心跳保活 nginx / iOS 网络栈
            yield ': heartbeat\n\n'

        meta = store.get_meta(session_id)
        meta = ai_session.reconcile_stale_queued(session_id)
        status = meta.get("status", "")

        if status == ai_session.STATUS_QUEUED and _time.time() >= next_queue_status:
            next_queue_status = _time.time() + 5
            yield (
                "data: "
                + json.dumps(
                    {
                        "status": ai_session.STATUS_QUEUED,
                        "queue_position": ai_session.get_queue_position(session_id),
                        "message": ai_session.get_queue_message(session_id),
                    },
                    ensure_ascii=False,
                )
                + "\n\n"
            )

        if status in ai_session.TERMINAL_STATUSES:
            # 任务结束。再读一次（不阻塞）确保没漏事件
            tail = store.read_events(session_id, last_id=cursor, block_ms=0, count=100)
            for entry_id, ev in tail:
                yield f'id: {entry_id}\ndata: {json.dumps(ev, ensure_ascii=False)}\n\n'
                cursor = entry_id
            yield 'data: [DONE]\n\n'
            return

        # 僵尸检测：status 是 running 但本地/远端运行态都不存在。
        # 后端重启、worker OOM 或 agent-node 异常退出时，meta 可能没及时落成 terminal。
        # 客户端 idle timeout 不会触发（心跳还在），所以必须 backend 主动告诉它
        if status == ai_session.STATUS_RUNNING and _time.time() >= next_zombie_check:
            next_zombie_check = _time.time() + 10
            if not ai_session.is_session_proc_alive(session_id, meta=meta):
                if ai_session.is_remote_agent_session_alive(session_id, meta):
                    logger.debug("[CHAT_STREAM] sid=%s local lease missing but remote agent run is alive", session_id)
                    continue
                logger.warning(
                    f"[CHAT_STREAM] sid={session_id} 僵尸 session（running 但 proc 不在）"
                    f"——大概率后端重启过，标 FAILED + needs_retry"
                )
                err_evt = {
                    "error": "服务器进程异常，任务已中断",
                    "needs_retry": True,
                }
                ai_session.abort_session(session_id)
                store.append_event(session_id, err_evt)
                store.set_status(
                    session_id,
                    ai_session.STATUS_FAILED,
                    error="server process gone (zombie session)",
                )
                # 不在这里 return，让下一轮 while 循环走 TERMINAL_STATUSES 分支自然 [DONE]，
                # 顺便把刚 append 的 needs_retry 事件读出来发给 client

        # 防止单次 SSE 连接卡 10 分钟以上（即使心跳还在）
        # 客户端会自动重连续读，没数据丢失
        if _time.time() - started_at > 600:
            logger.info(f"[CHAT_STREAM] sid={session_id} 单次连接超过 10 分钟，主动关闭让 client 重连")
            return


@require_auth
def chat_stream_token(session_id):
    """给 Web EventSource 签发短期读流 token。

    EventSource 不能带 Authorization header，所以 Web 端先用正常登录态 POST
    换一个只绑定当前 session/user 的短期 token，再把它放到 stream query 里。
    """
    store = ai_session.SessionStore()
    meta = store.get_meta(session_id)
    if not meta:
        return jsonify({"error": "session 不存在或已过期"}), 404

    user_id = str(request.supabase_user.get("id", ""))
    if meta.get("user_id") != user_id:
        return jsonify({"error": "无权访问此 session"}), 403

    return jsonify({
        "stream_token": _make_stream_token(session_id, user_id),
        "expires_in": _STREAM_TOKEN_MAX_AGE,
    })


def chat_stream(session_id):
    """SSE 端点：从 Redis 读 worker 写入的事件序列。

    Query: ?last_id=<stream entry id>，重连续读用；首次连传 "0" 或省略表示从头。
    """
    store = ai_session.SessionStore()
    meta = store.get_meta(session_id)
    if not meta:
        return jsonify({"error": "session 不存在或已过期"}), 404

    # 鉴权：移动端可继续走 Authorization header；Web EventSource 走 stream_token。
    user_id = _authenticate_stream_reader(session_id)
    if user_id is None:
        return jsonify({"error": "未提供认证 token"}), 401
    if meta.get("user_id") != user_id:
        return jsonify({"error": "无权访问此 session"}), 403

    last_id = request.args.get("last_id", "0").strip() or "0"

    return Response(
        stream_with_context(_build_sse_stream(session_id, last_id)),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # nginx 不要 buffer SSE
        },
    )


@require_auth
def chat_result(session_id):
    """一次性返回最终结果（任务完成后用）。"""
    store = ai_session.SessionStore()
    meta = store.get_meta(session_id)
    if not meta:
        return jsonify({"error": "session 不存在或已过期"}), 404
    if meta.get("user_id") != request.supabase_user.get("id"):
        return jsonify({"error": "无权访问此 session"}), 403

    client_actions = []
    try:
        raw_actions = meta.get("client_actions", "[]")
        parsed_actions = json.loads(raw_actions) if raw_actions else []
        if isinstance(parsed_actions, list):
            client_actions = parsed_actions
    except Exception:
        client_actions = []

    return jsonify({
        "session_id": session_id,
        "status": meta.get("status"),
        "final_text": meta.get("final_text", ""),
        "final_thinking": meta.get("final_thinking", ""),
        "client_actions": client_actions,
        "generation_pipeline": meta.get("generation_pipeline", ""),
        "error": meta.get("error", ""),
        "started_at": meta.get("started_at"),
        "finished_at": meta.get("finished_at"),
    })


@require_auth
def chat_status_v2(session_id):
    """轻量元信息（不含 final_text，不含 events）。"""
    store = ai_session.SessionStore()
    meta = store.get_meta(session_id)
    if not meta:
        return jsonify({"error": "session 不存在或已过期"}), 404
    if meta.get("user_id") != request.supabase_user.get("id"):
        return jsonify({"error": "无权访问此 session"}), 403

    # 不返回 final_text 这种大字段；想要完整结果走 /result
    meta = ai_session.reconcile_stale_queued(session_id)
    status = meta.get("status")
    local_alive = False
    remote_alive = False
    if status not in ai_session.TERMINAL_STATUSES:
        local_alive = ai_session.is_session_proc_alive(session_id, meta=meta)
        remote_alive = ai_session.is_remote_agent_session_alive(session_id, meta)
    return jsonify({
        "session_id": session_id,
        "status": status,
        "provider": meta.get("provider", ""),
        "agent": meta.get("agent", ""),
        "generation_pipeline": meta.get("generation_pipeline", ""),
        "event_count": int(meta.get("event_count", "0") or "0"),
        "started_at": meta.get("started_at"),
        "finished_at": meta.get("finished_at"),
        "error": meta.get("error", ""),
        "queue_position": ai_session.get_queue_position(session_id) if status == ai_session.STATUS_QUEUED else None,
        "queue_message": ai_session.get_queue_message(session_id) if status == ai_session.STATUS_QUEUED else "",
        "process_alive": local_alive or remote_alive,
        "remote_agent_alive": remote_alive,
    })


@require_auth
def chat_abort(session_id):
    """请求取消任务。worker 几秒内会感知并把 status 设为 aborted。"""
    store = ai_session.SessionStore()
    meta = store.get_meta(session_id)
    if not meta:
        return jsonify({"error": "session 不存在或已过期"}), 404
    if meta.get("user_id") != request.supabase_user.get("id"):
        return jsonify({"error": "无权访问此 session"}), 403
    intent = _chat_abort_intent()
    if meta.get("status") in ai_session.TERMINAL_STATUSES:
        remote_abort_requested = False
        if intent in _CHAT_ABORT_INTENTS:
            remote_abort_requested = ai_session.abort_session(session_id)
        return jsonify({
            "ok": True,
            "already_terminal": True,
            "remote_abort_requested": remote_abort_requested,
        })

    if intent not in _CHAT_ABORT_INTENTS:
        logger.warning(
            "[CHAT_ABORT] reject abort without explicit intent sid=%s status=%s active_job=%s user=%s ua=%s",
            session_id,
            meta.get("status"),
            meta.get("active_job_id"),
            request.supabase_user.get("id"),
            request.headers.get("User-Agent", "")[:160],
        )
        return jsonify({
            "error": "abort intent required",
            "code": "AI_ABORT_INTENT_REQUIRED",
        }), 400

    logger.info(
        "[CHAT_ABORT] sid=%s intent=%s status=%s active_job=%s",
        session_id,
        intent,
        meta.get("status"),
        meta.get("active_job_id"),
    )
    remote_abort_requested = ai_session.abort_session(session_id)
    return jsonify({"ok": True, "remote_abort_requested": remote_abort_requested})
