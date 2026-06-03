import json
import os
import subprocess
import logging
import threading
from flask import current_app, request, jsonify, Response, stream_with_context
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from config import (
    AI_AGENTS,
    AI_PROVIDERS,
    DEFAULT_AGENT,
    DEFAULT_PROVIDER,
    PROJECT_ROOT,
    GENERATE_PROMPT_PATH,
    CLAUDE_BIN,
    load_generate_prompt,
)
from auth import require_auth, verify_access_token
from database import get_quota_info, increment_quota
from config import ROLE_QUOTAS

logger = logging.getLogger(__name__)
_session_procs = {}
_session_procs_lock = threading.Lock()
_STREAM_TOKEN_SALT = "ai-chat-stream-token-v1"
_STREAM_TOKEN_MAX_AGE = 120

_CLI_LOG_DIR = os.environ.get("CLAUDE_CLI_LOG_DIR", "/mnt/storage00/log")
_cli_log_lock = threading.Lock()
_cli_log_warned = False


def _append_cli_log(session_id, kind, line):
    """把 Claude CLI 的原始输出按 session 追加到 JSONL 文件，便于排查问题。

    kind: stdout / stderr / meta，原样写入。
    line: bytes 或 str；不会做任何裁剪、格式化，最大化保留原始数据。
    """
    global _cli_log_warned
    if not session_id:
        return
    try:
        if isinstance(line, bytes):
            text = line.decode("utf-8", errors="replace")
        else:
            text = str(line)
        if not text.endswith("\n"):
            text += "\n"
        with _cli_log_lock:
            os.makedirs(_CLI_LOG_DIR, exist_ok=True)
            path = os.path.join(_CLI_LOG_DIR, f"{session_id}.jsonl")
            with open(path, "a", encoding="utf-8") as f:
                if kind == "stdout":
                    f.write(text)
                else:
                    # 非 stdout（meta / stderr）包一层，便于识别
                    wrapper = json.dumps(
                        {"_log_kind": kind, "data": text.rstrip("\n")},
                        ensure_ascii=False,
                    )
                    f.write(wrapper + "\n")
    except Exception as e:
        if not _cli_log_warned:
            _cli_log_warned = True
            logger.warning(f"[CLI_LOG] 写入 CLI 日志失败（仅提示一次）: {e}")


def _register_session_proc(session_id, proc):
    with _session_procs_lock:
        _session_procs[session_id] = proc


def _clear_session_proc(session_id, proc=None):
    with _session_procs_lock:
        current = _session_procs.get(session_id)
        if proc is None or current is proc:
            _session_procs.pop(session_id, None)


def _is_session_proc_alive(session_id):
    with _session_procs_lock:
        proc = _session_procs.get(session_id)
    if proc is None:
        return False
    return proc.poll() is None


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


def _normalize_provider_id(provider_id=None):
    return (provider_id or DEFAULT_PROVIDER).strip().lower().replace("_", "-") or DEFAULT_PROVIDER


def _get_provider(provider_id=None):
    pid = _normalize_provider_id(provider_id)
    cfg = AI_PROVIDERS.get(pid)
    if not cfg:
        raise ValueError(f"未知 AI 供应商: {pid}")
    if not cfg.get("configured"):
        raise ValueError(f"AI 供应商未配置: {pid}")
    if not cfg.get("visible", True):
        raise ValueError(f"AI 供应商当前不可用: {pid}")
    return cfg


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
    if agent_id == "claude":
        return True
    if agent_id == "codex":
        return bool((provider.get("codex") or {}).get("configured"))
    return False


def list_providers():
    """获取所有可用的 AI 供应商列表"""
    providers = []
    for pid, cfg in AI_PROVIDERS.items():
        if not cfg.get("visible", True):
            continue
        supported_agents = [
            aid for aid, agent in AI_AGENTS.items()
            if agent.get("visible", True)
            and agent.get("configured", False)
            and _provider_supports_agent(cfg, aid)
        ]
        providers.append({
            "id": cfg["id"],
            "name": cfg["name"],
            "description": cfg.get("description", ""),
            "default_model": cfg["models"]["default"],
            "configured": bool(cfg.get("configured", False)),
            "supported_agents": supported_agents or ["claude"],
            "worker": cfg.get("worker", {}),
        })
    return jsonify({"providers": providers})


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


@require_auth
def session_status():
    session_id = request.args.get("session_id", "")
    if not session_id:
        return jsonify({"error": "session_id 是必需的"}), 400
    alive = _is_session_proc_alive(session_id)
    return jsonify({"session_id": session_id, "alive": alive})

def _tool_status_message(tool_name, tool_input):
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


# ────────── /tmp/ai-uploads 清理 ──────────
# AI 在每个 session 用 mktemp 在 /tmp/ai-uploads/ 生成随机路径下载 JSON 配置（见
# generate_app_prompt.md "获取当前应用配置"）。文件不会自己消失，需要清理。
# 没用 cron / systemd timer——开销极低（listdir + stat 几十微秒），每次 chat 顺手扫一次

_UPLOAD_DIR = "/tmp/ai-uploads"
_UPLOAD_RETENTION_SECONDS = 86400  # 24h


def _cleanup_old_ai_uploads() -> None:
    """删 /tmp/ai-uploads/ 里 mtime 超过 24h 的文件，幂等且吞所有 OSError"""
    import time
    if not os.path.isdir(_UPLOAD_DIR):
        return
    cutoff = time.time() - _UPLOAD_RETENTION_SECONDS
    deleted = 0
    try:
        names = os.listdir(_UPLOAD_DIR)
    except OSError:
        return
    for name in names:
        p = os.path.join(_UPLOAD_DIR, name)
        try:
            if os.path.isfile(p) and os.path.getmtime(p) < cutoff:
                os.unlink(p)
                deleted += 1
        except OSError:
            pass
    if deleted:
        logger.info(f"[chat] 清理 {_UPLOAD_DIR} 旧文件 {deleted} 个 (>24h)")


@require_auth
def chat():
    """纯粹的 AI 聊天接口，完全交由 Claude 自主处理（前端负责解析动作或 JSON）。"""
    _cleanup_old_ai_uploads()
    user_id = request.supabase_user.get("id")
    role = request.user_role

    logger.info(f"[CHAT] 收到聊天请求 - user_id: {user_id}, role: {role}")

    used, limit, remaining = get_quota_info(
        user_id, role, ROLE_QUOTAS,
        app_metadata=request.supabase_user.get("app_metadata"),
    )
    logger.debug(f"[CHAT] 配额信息 - used: {used}, limit: {limit}, remaining: {remaining}")

    if remaining <= 0:
        logger.warning(f"[CHAT] 配额已用完 - user_id: {user_id}")
        return jsonify({"error": "配额已用完", "quota": {"used": used, "limit": limit}}), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    session_id = body.get("session_id")
    provider_id = body.get("provider")

    logger.info(f"[CHAT] session_id: {session_id}, provider: {provider_id}, messages count: {len(messages)}")

    if not messages or not session_id:
        logger.error(f"[CHAT] 缺少必需参数 - messages: {bool(messages)}, session_id: {bool(session_id)}")
        return jsonify({"error": "messages 和 session_id 是必需的"}), 400

    # 提取最后一条用户消息
    last_msg = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_msg = m.get("content", "")
            break

    logger.debug(f"[CHAT] 用户消息: {last_msg[:100]}..." if len(last_msg) > 100 else f"[CHAT] 用户消息: {last_msg}")

    if not last_msg:
        logger.error(f"[CHAT] 未找到用户消息")
        return jsonify({"error": "未找到用户消息"}), 400

    try:
        provider = _get_provider(provider_id)
    except ValueError as e:
        logger.warning(f"[CHAT] provider rejected: {e}")
        return jsonify({"error": str(e), "code": "AI_PROVIDER_UNAVAILABLE"}), 400
    logger.info(f"[CHAT] 使用 AI 供应商: {provider.get('name', provider_id)}")

    cli_env = provider.get("cli_env", {})
    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"
    try:
        workspace = ai_session._prepare_worker_workspace(session_id, "legacy")
        env["AI_APP_WORKSPACE"] = workspace
        env["AI_APP_PROJECT_ROOT"] = PROJECT_ROOT
    except Exception as e:
        workspace = None
        logger.warning(f"[CHAT] legacy workspace 初始化失败，将走 prompt fallback: {e}")

    logger.debug(f"[CHAT] CLI 环境变量: {list(cli_env.keys())}")

    increment_quota(user_id)
    # 新一轮被接受前清掉旧 abort 标记；如果旧 running lease 仍存活，上面已经直接返回。
    ai_session.clear_abort(session_id)
    new_remaining = remaining - 1
    logger.info(f"[CHAT] 配额已扣除，剩余: {new_remaining}")

    def run_cli(is_resume=True):
        # 走 config.load_generate_prompt() 而不是直接 open() —— 它会把硬编码的
        # 生产 URL（myapp-registry / myapp-oss-endpoint）替换成当前环境的 URL，
        # 否则测试环境跑出来的 JSON-APP 会嵌入生产域名
        sys_prompt = load_generate_prompt()
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
                    
        cmd = [
            CLAUDE_BIN,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "-p", (
                f"本轮用户的请求:\n<user_request>\n{last_msg}\n</user_request>\n"
                + (
                    "本轮后端已为你分配独立工作目录，必须使用它隔离所有临时文件："
                    f"\nAI_APP_WORKSPACE={workspace}\n"
                    "生成器、下载的 manifest、app.json、校验输出都放在 AI_APP_WORKSPACE 下；"
                    "不要写 /tmp/app.json 或 /tmp/generate_app.py。\n"
                    if workspace else ""
                )
                + f"请实现用户要求并严格按照系统提示词{GENERATE_PROMPT_PATH}中的信息答复用户；"
                "如果该提示词要求先分类、读取索引或按需阅读分层文档，每一轮都必须重新执行。"
                "不要遗忘工作目录、repair/validate、上传和 client_actions 结构化动作规则。"
                + final_protocol_note
            )
        ]

        if is_resume:
            cmd.extend(["-r", session_id])
            logger.info(f"[CLI] 恢复已有会话: {session_id}")
        else:
            cmd.extend(["--session-id", session_id])
            logger.info(f"[CLI] 创建新会话: {session_id}")
            if sys_prompt:
                # 将系统提示词作为一个长参数传递（需要 CLI 支持 --append-system-prompt）
                cmd.extend(["--append-system-prompt", sys_prompt])
                logger.debug(f"[CLI] 已添加系统提示词，长度: {len(sys_prompt)}")

        logger.info(f"[CLI] 执行命令: {' '.join(cmd[:6])}... (共 {len(cmd)} 个参数)")
        logger.debug(f"[CLI] 工作目录: {PROJECT_ROOT}")
        logger.debug(f"[CLI] 环境变量: IS_SANDBOX=1, ANTHROPIC_BASE_URL={env.get('ANTHROPIC_BASE_URL', 'N/A')}")

        _append_cli_log(session_id, "meta", json.dumps({
            "event": "cli_start",
            "is_resume": is_resume,
            "session_id": session_id,
            "provider": provider.get("id"),
            "cmd_preview": cmd[:6],
            "cmd_arg_count": len(cmd),
        }, ensure_ascii=False))

        return subprocess.Popen(
            cmd,
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            env=env,
            bufsize=1
        )

    def generate():
        # 先尝试作为老会话恢复
        logger.info(f"[STREAM] 开始生成流式响应")
        proc = run_cli(is_resume=True)
        _register_session_proc(session_id, proc)
        logger.debug(f"[STREAM] CLI 进程已启动，PID: {proc.pid}")

        initial_lines = []
        logger.debug(f"[STREAM] 等待 CLI 首行输出...")
        while True:
            line = proc.stdout.readline()
            if not line:
                logger.debug(f"[STREAM] 读取到空行，退出等待")
                break
            initial_lines.append(line)
            _append_cli_log(session_id, "stdout", line)
            line_str = line.decode("utf-8", errors="replace").strip()
            if line_str:
                logger.debug(f"[STREAM] 收到首行输出: {line_str[:100]}...")
                break

        # 此时可能进程已经退出（如发生错误），给它 0.1s 彻底清理以获取准确的 returncode
        try:
            proc.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            logger.debug(f"[STREAM] CLI 进程仍在运行")
            pass

        if proc.returncode is not None and proc.returncode != 0:
            stderr_text = proc.stderr.read().decode("utf-8", errors="replace")
            stdout_text = b"".join(initial_lines).decode("utf-8", errors="replace") + proc.stdout.read().decode("utf-8", errors="replace")
            full_err = stderr_text + "\n" + stdout_text

            logger.warning(f"[STREAM] CLI 进程异常退出，returncode: {proc.returncode}")
            logger.debug(f"[STREAM] stderr: {stderr_text[:500]}...")
            logger.debug(f"[STREAM] stdout: {stdout_text[:500]}...")

            _append_cli_log(session_id, "stderr", stderr_text)
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "cli_exit_nonzero",
                "returncode": proc.returncode,
            }, ensure_ascii=False))

            if "No conversation found" in full_err or "requires a valid session ID" in full_err:
                # fallback: 创建新会话
                logger.info(f"[STREAM] 会话不存在，fallback 到创建新会话")
                proc = run_cli(is_resume=False)
                _register_session_proc(session_id, proc)
                logger.debug(f"[STREAM] 新 CLI 进程已启动，PID: {proc.pid}")
                initial_lines = []
            else:
                logger.error(f"[STREAM] CLI 启动失败: {stderr_text}")
                yield f'data: {json.dumps({"error": f"Claude CLI 启动失败 (code {proc.returncode}): {stderr_text}"}, ensure_ascii=False)}\n\n'
                yield "data: [DONE]\n\n"
                return

        def process_stream(process, buffered_lines):
            import time
            import threading
            from queue import Queue, Empty

            logger.info(f"[STREAM] 开始处理流式输出，缓冲行数: {len(buffered_lines)}")
            line_count = 0
            last_data_time = time.time()

            for line in buffered_lines:
                line_count += 1
                yield from _parse_line(line, line_count)
                last_data_time = time.time()

            logger.debug(f"[STREAM] 缓冲行处理完毕，开始实时读取...")

            # 使用队列 + 线程实现非阻塞读取（跨平台兼容）
            line_queue = Queue()

            def reader_thread():
                try:
                    for line in iter(process.stdout.readline, b''):
                        if line:
                            _append_cli_log(session_id, "stdout", line)
                            line_queue.put(('data', line))
                    line_queue.put(('eof', None))
                except Exception as e:
                    line_queue.put(('error', str(e)))

            reader = threading.Thread(target=reader_thread, daemon=True)
            reader.start()

            # 主循环：读取数据或发送心跳
            while True:
                try:
                    # 尝试从队列获取数据，超时 10 秒
                    msg_type, data = line_queue.get(timeout=10.0)

                    if msg_type == 'eof':
                        logger.debug(f"[STREAM] 读取线程结束")
                        break
                    elif msg_type == 'error':
                        logger.error(f"[STREAM] 读取线程异常: {data}")
                        break
                    elif msg_type == 'data':
                        line_count += 1
                        yield from _parse_line(data, line_count)
                        last_data_time = time.time()

                except Empty:
                    # 超时，发送心跳
                    current_time = time.time()
                    logger.debug(f"[STREAM] 发送心跳 (已 {int(current_time - last_data_time)}s 无数据)")
                    yield ': heartbeat\n\n'  # SSE 注释格式的心跳

            logger.info(f"[STREAM] CLI 输出结束，共处理 {line_count} 行")
            process.wait()
            logger.debug(f"[STREAM] CLI 进程退出，returncode: {process.returncode}")

            if process.returncode != 0:
                err = process.stderr.read().decode("utf-8", errors="replace")
                if err:
                    logger.error(f"[STREAM] CLI 异常退出: {err}")
                    _append_cli_log(session_id, "stderr", err)
                    yield f'data: {json.dumps({"error": f"Claude CLI 异常退出: {err}"}, ensure_ascii=False)}\n\n'

            try:
                for action in ai_session._load_client_actions(workspace, session_id):
                    yield f'data: {json.dumps({"client_action": action}, ensure_ascii=False)}\n\n'
            except Exception as e:
                logger.warning(f"[STREAM] 读取 client_actions 失败: {e}")

            logger.info(f"[STREAM] 发送配额信息和结束标记")
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"
            _append_cli_log(session_id, "meta", json.dumps({
                "event": "stream_done",
                "returncode": process.returncode,
                "lines": line_count,
            }, ensure_ascii=False))
            _clear_session_proc(session_id, process)


        def _parse_line(raw_line, line_num=0):
            line_str = raw_line.decode("utf-8", errors="replace").strip()
            if not line_str:
                return
            try:
                event = json.loads(line_str)
                evt_type = event.get("type")

                if evt_type == "system":
                    logger.debug(f"[EVENT #{line_num}] system 事件")
                    yield f'data: {json.dumps({"status": "init", "message": "AI 引擎已启动"}, ensure_ascii=False)}\n\n'

                elif evt_type == "stream_event":
                    # 处理实时的 delta 增量流
                    ev = event.get("event", {})
                    ev_type = ev.get("type")

                    # 消息开始事件
                    if ev_type == "message_start":
                        logger.debug(f"[EVENT #{line_num}] message_start")
                        yield f'data: {json.dumps({"event": "message_start"}, ensure_ascii=False)}\n\n'

                    # 消息结束事件
                    elif ev_type == "message_stop":
                        logger.debug(f"[EVENT #{line_num}] message_stop")
                        yield f'data: {json.dumps({"event": "message_stop"}, ensure_ascii=False)}\n\n'

                    # 内容块开始事件（可能包含工具调用信息）
                    elif ev_type == "content_block_start":
                        content_block = ev.get("content_block", {})
                        block_type = content_block.get("type")
                        logger.debug(f"[EVENT #{line_num}] content_block_start: {block_type}")

                        # 如果是工具调用开始，发送状态消息
                        if block_type == "tool_use":
                            tool_name = content_block.get("name", "")
                            tool_input = content_block.get("input", {})
                            if tool_name:
                                logger.info(f"[EVENT #{line_num}] 工具调用开始: {tool_name}")
                                status_msg = _tool_status_message(tool_name, tool_input)
                                yield f'data: {json.dumps({"status": tool_name.lower(), "message": status_msg}, ensure_ascii=False)}\n\n'
                        # 思考块开始 → 显式告诉客户端"AI 正在思考..."，避免 thinking_delta
                        # 静默刷屏期间用户以为卡住。客户端 status handler 会亮起转圈+文案。
                        elif block_type == "thinking":
                            logger.debug(f"[EVENT #{line_num}] thinking 块开始")
                            yield f'data: {json.dumps({"status": "thinking", "message": "AI 正在思考..."}, ensure_ascii=False)}\n\n'

                    # 内容块增量事件
                    elif ev_type == "content_block_delta":
                        delta = ev.get("delta", {})
                        delta_type = delta.get("type")

                        if delta_type == "text_delta":
                            text_chunk = delta.get("text", "")
                            if text_chunk:
                                logger.debug(f"[EVENT #{line_num}] text_delta: {text_chunk[:50]}...")
                                yield f'data: {json.dumps({"content": text_chunk}, ensure_ascii=False)}\n\n'

                        elif delta_type == "thinking_delta":
                            think_chunk = delta.get("thinking", "")
                            if think_chunk:
                                logger.debug(f"[EVENT #{line_num}] thinking_delta: {think_chunk[:50]}...")
                                yield f'data: {json.dumps({"thinking": think_chunk}, ensure_ascii=False)}\n\n'

                        elif delta_type == "input_json_delta":
                            # 工具输入参数的增量构造 — 发送状态提示让客户端知道 AI 正在准备工具调用
                            logger.debug(f"[EVENT #{line_num}] input_json_delta")
                            yield f'data: {json.dumps({"status": "tool_preparing", "message": "AI 正在构造工具参数..."}, ensure_ascii=False)}\n\n'

                    # 内容块结束事件
                    elif ev_type == "content_block_stop":
                        logger.debug(f"[EVENT #{line_num}] content_block_stop")

                    # 消息增量事件（元数据更新，如 stop_reason）
                    elif ev_type == "message_delta":
                        delta = ev.get("delta", {})
                        stop_reason = delta.get("stop_reason")
                        if stop_reason:
                            logger.debug(f"[EVENT #{line_num}] message_delta: stop_reason={stop_reason}")

                    else:
                        logger.debug(f"[EVENT #{line_num}] 未处理的 stream_event 类型: {ev_type}")

                elif evt_type == "assistant":
                    # 处理整体状态、工具调用，以及 resume 模式下可能整块下发的文本
                    msg = event.get("message", {})
                    logger.debug(f"[EVENT #{line_num}] assistant 事件，content blocks: {len(msg.get('content', []))}")
                    for block in msg.get("content", []):
                        btype = block.get("type")
                        if btype == "tool_use":
                            tool_name = block.get("name", "")
                            tool_input = block.get("input", {})
                            logger.info(f"[EVENT #{line_num}] 工具调用: {tool_name}")
                            status_msg = _tool_status_message(tool_name, tool_input)
                            yield f'data: {json.dumps({"status": tool_name.lower(), "message": status_msg}, ensure_ascii=False)}\n\n'
                        elif btype == "text":
                            # resume 流里有时不发 stream_event 的 text_delta，而是直接整块 text 放在 assistant 事件
                            text_value = block.get("text", "")
                            if text_value:
                                logger.info(f"[EVENT #{line_num}] assistant 文本块下发，长度: {len(text_value)}")
                                yield f'data: {json.dumps({"assistant_content": text_value}, ensure_ascii=False)}\n\n'
                        elif btype == "thinking":
                            think_value = block.get("thinking", "")
                            if think_value:
                                logger.info(f"[EVENT #{line_num}] assistant 思考块下发，长度: {len(think_value)}")
                                yield f'data: {json.dumps({"assistant_thinking": think_value}, ensure_ascii=False)}\n\n'

                elif evt_type == "result":
                    logger.debug(f"[EVENT #{line_num}] result 事件，is_error: {event.get('is_error')}")
                    if event.get("is_error"):
                        # 错误情况
                        res = event.get("result", "")
                        logger.error(f"[EVENT #{line_num}] 生成中断: {res[:200]}...")
                        yield f'data: {json.dumps({"error": f"生成中断: {res}"}, ensure_ascii=False)}\n\n'
                    else:
                        # 正常结束，发送完整的最终文本（用于替换之前的增量累积）
                        msg = event.get("message", {})
                        for block in msg.get("content", []):
                            if block.get("type") == "text":
                                final_text = block.get("text", "")
                                if final_text:
                                    logger.info(f"[EVENT #{line_num}] 发送最终完整文本，长度: {len(final_text)}")
                                    yield f'data: {json.dumps({"final_content": final_text}, ensure_ascii=False)}\n\n'
                            elif block.get("type") == "thinking":
                                final_thinking = block.get("thinking", "")
                                if final_thinking:
                                    logger.info(f"[EVENT #{line_num}] 发送最终完整思考，长度: {len(final_thinking)}")
                                    yield f'data: {json.dumps({"final_thinking": final_thinking}, ensure_ascii=False)}\n\n'
                else:
                    logger.debug(f"[EVENT #{line_num}] 未处理的事件类型: {evt_type}")
            except json.JSONDecodeError as e:
                logger.warning(f"[EVENT #{line_num}] JSON 解析失败: {e}, line: {line_str[:100]}...")

        yield from process_stream(proc, initial_lines)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"}
    )


# ════════════════════════════════════════════════════════════════════════════
# 新流（feat/ai-background-push）：worker 与 HTTP 连接解耦
#
# 老 /chat 端点保持不变（client 切走 = 任务断），新流：
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


@require_auth
def chat_start():
    """提交 AI 任务到 worker，立即返回 session_id。

    Body: {messages, session_id, provider?, agent?}
    Resp: {session_id, status: "running"}
    """
    _cleanup_old_ai_uploads()
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
    # force_restart=true：用户输入新消息时用，先杀掉同 session 还在跑的 worker 再起新的
    # 默认 false：双击 send / 重连等场景幂等返回 resumed:true
    force_restart = bool(body.get("force_restart", False))

    if not messages or not session_id:
        return jsonify({"error": "messages 和 session_id 是必需的"}), 400

    last_msg = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_msg = m.get("content", "")
            break
    if not last_msg:
        return jsonify({"error": "未找到用户消息"}), 400

    try:
        provider = _get_provider(provider_id)
    except ValueError as e:
        logger.warning(f"[CHAT_START] provider rejected: {e}")
        return jsonify({"error": str(e), "code": "AI_PROVIDER_UNAVAILABLE"}), 400
    provider_id = provider["id"]

    try:
        agent = _get_agent(agent_id)
    except ValueError as e:
        logger.warning(f"[CHAT_START] agent rejected: {e}")
        return jsonify({"error": str(e), "code": "AI_AGENT_UNAVAILABLE"}), 400
    agent_id = agent["id"]
    if not _provider_supports_agent(provider, agent_id):
        return jsonify({
            "error": f"供应商 {provider_id} 不支持 Agent {agent_id}",
            "code": "AI_AGENT_PROVIDER_UNAVAILABLE",
        }), 400

    store = ai_session.SessionStore()
    existing = store.get_meta(session_id)

    if existing and existing.get("status") in (ai_session.STATUS_RUNNING, ai_session.STATUS_QUEUED):
        if force_restart:
            # 用户发了新消息：杀掉旧 worker，等它真的结束再起新的
            # 关键不变量：必须确认旧 worker 已经写完 STATUS_ABORTED 才能 create_meta，
            # 否则旧 worker 后写的 set_status 会覆盖新 worker 的 fresh meta，
            # 导致客户端 /status 看到 status=aborted → 又触发重试 → 死循环
            logger.info(f"[CHAT_START] sid={session_id} force_restart：先 abort 旧 worker/queued job")
            ai_session.abort_session(session_id)  # 内部 _kill_proc 阻塞最多 2s 等 proc 死
            # abort_session 返回时 proc 已死，worker 线程通常 1-10ms 内 set_status(ABORTED) 完成
            # 5s 是给 Redis 抖动 / GIL 争抢的余量
            terminal_observed = False
            for _ in range(50):  # 5s
                _time.sleep(0.1)
                m = store.get_meta(session_id)
                if not m or m.get("status") in ai_session.TERMINAL_STATUSES:
                    terminal_observed = True
                    break
            if not terminal_observed:
                # 旧 worker 还没把 status 写成 terminal，但 proc 已死的话风险有限
                if not ai_session.is_session_proc_alive(session_id):
                    logger.warning(
                        f"[CHAT_START] sid={session_id} 5s 没等到 STATUS_ABORTED 但 proc 已死，"
                        f"继续 create_meta；旧 worker 后续 set_status 可能造成短暂状态错乱"
                    )
                else:
                    logger.error(
                        f"[CHAT_START] sid={session_id} 5s 后 running lease 仍存活，拒绝覆盖旧 session"
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
    if (
        agent_id == "codex"
        and existing
        and existing.get("agent") == "codex"
        and existing.get("provider") == provider_id
    ):
        agent_resume_id = existing.get("agent_thread_id") or None
    elif (
        agent_id == "claude"
        and existing
        and existing.get("agent") == "claude"
        and existing.get("provider") == provider_id
    ):
        # Claude Code uses the session id as its conversation id. First turns
        # create a new CLI session; later turns resume the same id.
        agent_resume_id = session_id

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
    )
    accepted, queue_position = ai_session.submit_worker(
        session_id, last_msg, provider_id,
        agent_id=agent_id,
        agent_resume_id=agent_resume_id,
        user_id=user_id,
        quota_used=used + 1,
        quota_limit=limit,
        quota_remaining=new_remaining,
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
        "resumed": False,
    })


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
    # 僵尸检测：第一次检查在 5s 后（给 worker 注册 _session_procs 留余量），之后每 10s 检查一次
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

        # 僵尸检测：status 是 running 但进程不在 _session_procs（dict 在内存里，
        # 后端重启就丢了；worker 线程也可能因 OOM / 异常没写完 status 就崩了）
        # 客户端 idle timeout 不会触发（心跳还在），所以必须 backend 主动告诉它
        if status == ai_session.STATUS_RUNNING and _time.time() >= next_zombie_check:
            next_zombie_check = _time.time() + 10
            if not ai_session.is_session_proc_alive(session_id):
                logger.warning(
                    f"[CHAT_STREAM] sid={session_id} 僵尸 session（running 但 proc 不在）"
                    f"——大概率后端重启过，标 FAILED + needs_retry"
                )
                err_evt = {
                    "error": "服务器进程异常，任务已中断",
                    "needs_retry": True,
                }
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
    status = meta.get("status")
    return jsonify({
        "session_id": session_id,
        "status": status,
        "provider": meta.get("provider", ""),
        "agent": meta.get("agent", ""),
        "event_count": int(meta.get("event_count", "0") or "0"),
        "started_at": meta.get("started_at"),
        "finished_at": meta.get("finished_at"),
        "error": meta.get("error", ""),
        "queue_position": ai_session.get_queue_position(session_id) if status == ai_session.STATUS_QUEUED else None,
        "queue_message": ai_session.get_queue_message(session_id) if status == ai_session.STATUS_QUEUED else "",
        "process_alive": ai_session.is_session_proc_alive(session_id),
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
    if meta.get("status") in ai_session.TERMINAL_STATUSES:
        return jsonify({"ok": True, "already_terminal": True})

    ai_session.abort_session(session_id)
    return jsonify({"ok": True})
