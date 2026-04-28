import json
import os
import subprocess
import logging
import threading
from flask import request, jsonify, Response, stream_with_context
from config import AI_PROVIDERS, DEFAULT_PROVIDER, PROJECT_ROOT, GENERATE_PROMPT_PATH, CLAUDE_BIN
from auth import require_auth
from database import get_quota_info, increment_quota
from config import ROLE_QUOTAS

logger = logging.getLogger(__name__)
_session_procs = {}
_session_procs_lock = threading.Lock()

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

def _get_provider(provider_id=None):
    pid = provider_id or DEFAULT_PROVIDER
    return AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])

def list_providers():
    """获取所有可用的 AI 供应商列表"""
    providers = []
    for pid, cfg in AI_PROVIDERS.items():
        providers.append({
            "id": cfg["id"],
            "name": cfg["name"],
            "description": cfg.get("description", ""),
            "default_model": cfg["models"]["default"],
        })
    return jsonify({"providers": providers})


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
    return f"正在使用工具 {tool_name}..."

@require_auth
def chat():
    """纯粹的 AI 聊天接口，完全交由 Claude 自主处理（前端负责解析动作或 JSON）。"""
    user_id = request.supabase_user.get("id")
    role = request.user_role

    logger.info(f"[CHAT] 收到聊天请求 - user_id: {user_id}, role: {role}")

    used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
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

    provider = _get_provider(provider_id)
    logger.info(f"[CHAT] 使用 AI 供应商: {provider.get('name', provider_id)}")

    cli_env = provider.get("cli_env", {})
    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"

    logger.debug(f"[CHAT] CLI 环境变量: {list(cli_env.keys())}")

    increment_quota(user_id)
    new_remaining = remaining - 1
    logger.info(f"[CHAT] 配额已扣除，剩余: {new_remaining}")

    def run_cli(is_resume=True):
        sys_prompt = ""
        with open(GENERATE_PROMPT_PATH, "r", encoding="utf-8") as f:
            sys_prompt = f.read()
                    
        cmd = [
            CLAUDE_BIN,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "-p", f"本轮用户的请求: ‘’‘{last_msg}’‘’，请实现用户要求并严格按照系统提示词{GENERATE_PROMPT_PATH}中的信息答复用户"
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
                            # 工具输入的增量更新（通常不需要发给客户端）
                            logger.debug(f"[EVENT #{line_num}] input_json_delta")

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
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "Access-Control-Allow-Origin": "*"}
    )
