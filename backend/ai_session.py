"""AI session 状态管理 + Worker 解耦层 (Phase 1: ai-background-push)

设计目标：把 claude CLI 的运行从 HTTP 连接生命周期里抽出来。
- worker 跑在独立线程（eventlet monkey_patch 后实为 greenlet），把 claude CLI
  输出实时写到 Redis Stream
- HTTP 端点 /api/ai/chat/<id>/stream 只是从 Redis 读流，可以随时断重连

Redis 数据：
    ai:session:<id>:meta    Hash    元信息（status / 起止时间 / 配额 / final_text）
    ai:session:<id>:stream  Stream  SSE 事件序列；entry id 即"位置"
    ai:session:<id>:abort   String  存在 = 已请求取消（SETEX 300s 自动失效）

详见 backend/ARCHITECTURE.md §3。
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import List, Optional, Tuple

import redis

from config import (
    AI_PROVIDERS,
    AI_SESSION_REDIS_HOST,
    AI_SESSION_REDIS_PASSWORD,
    AI_SESSION_REDIS_PORT,
    AI_SESSION_REDIS_TTL_SECONDS,
    AI_WORKER_MAX_CONCURRENCY,
    CLAUDE_BIN,
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


# ────────────────────────────── 状态枚举 ──────────────────────────────

STATUS_RUNNING = "running"
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
                    quota_used: int, quota_limit: int, quota_remaining: int) -> None:
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
            "status": STATUS_RUNNING,
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

    def get_meta(self, session_id: str) -> dict:
        raw = self.r.hgetall(_meta_key(session_id))
        if not raw:
            return {}
        return {k.decode(): v.decode() for k, v in raw.items()}

    def set_status(self, session_id: str, status: str, *,
                   final_text: Optional[str] = None,
                   final_thinking: Optional[str] = None,
                   error: Optional[str] = None) -> None:
        update = {
            "status": status,
            "finished_at": str(int(time.time() * 1000)),
        }
        if final_text is not None:
            update["final_text"] = final_text
        if final_thinking is not None:
            update["final_thinking"] = final_thinking
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


# ────────────────────────────── Worker 池 ──────────────────────────────

# eventlet monkey_patch 后 threading.Thread 实为 greenlet，开销低。
# 这里限制的是同时跑的 claude CLI 进程数（每个进程独立占 RAM）。
_executor = ThreadPoolExecutor(
    max_workers=AI_WORKER_MAX_CONCURRENCY,
    thread_name_prefix="ai-worker",
)

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
    with _session_procs_lock:
        proc = _session_procs.get(session_id)
    if proc is None:
        return False
    return proc.poll() is None


def _build_cli_cmd(session_id: str, last_msg: str, sys_prompt: str,
                   is_resume: bool) -> list:
    cmd = [
        CLAUDE_BIN,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p", f"本轮用户的请求:\n<user_request>\n{last_msg}\n</user_request>\n请实现用户要求并严格按照系统提示词{GENERATE_PROMPT_PATH}中的信息答复用户",
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
    pid = provider_id or DEFAULT_PROVIDER
    provider = AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])
    cli_env = provider.get("cli_env", {})
    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"
    return provider, env


def _worker_main(session_id: str, last_msg: str, provider_id: Optional[str],
                 quota_used: int, quota_limit: int, quota_remaining: int) -> None:
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

        _append_cli_log(session_id, "meta", json.dumps({
            "event": "worker_start",
            "provider": provider.get("id"),
            "user_msg_len": len(last_msg),
            "ts": int(time.time() * 1000),
        }, ensure_ascii=False))

        # 先尝试 resume
        cmd = _build_cli_cmd(session_id, last_msg, sys_prompt, is_resume=True)
        logger.info(f"[WORKER] sid={session_id} 起 CLI (resume): {cmd[0]}...")

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
                store.set_status(session_id, STATUS_ABORTED)
                return

            stderr_text = proc.stderr.read().decode("utf-8", errors="replace")
            stdout_text = b"".join(first_lines).decode("utf-8", errors="replace") + \
                          proc.stdout.read().decode("utf-8", errors="replace")
            full_err = stderr_text + "\n" + stdout_text

            if "No conversation found" in full_err or "requires a valid session ID" in full_err:
                logger.info(f"[WORKER] sid={session_id} resume 失败，fallback 新会话")
                _unregister_proc(session_id, proc)
                cmd = _build_cli_cmd(session_id, last_msg, sys_prompt, is_resume=False)
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
                store.append_event(session_id, err_evt)
                store.set_status(session_id, STATUS_FAILED, error=err_msg)
                return

        # ─── 4. 主循环：读 CLI 输出 → 解析 → 写 Redis ───
        line_count = 0
        for buffered in first_lines:
            _append_cli_log(session_id, "stdout", buffered)
            line_str = buffered.decode("utf-8", errors="replace")
            for ev in parse_cli_line(line_str):
                store.append_event(session_id, ev)
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
                store.set_status(session_id, STATUS_ABORTED)
                return

            line = proc.stdout.readline()
            if not line:
                # CLI 结束
                break

            _append_cli_log(session_id, "stdout", line)
            line_str = line.decode("utf-8", errors="replace")
            for ev in parse_cli_line(line_str):
                store.append_event(session_id, ev)
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
            store.set_status(session_id, STATUS_ABORTED)
            return

        # ─── 5. 退出码 != 0 → 失败（含外部 kill） ───
        if proc.returncode != 0:
            killed_externally = proc.returncode in (-15, -9)
            err_text = proc.stderr.read().decode("utf-8", errors="replace")
            err_msg = (
                f"Claude CLI 被外部信号 {proc.returncode} 终止"
                if killed_externally
                else f"Claude CLI 异常退出 (code {proc.returncode}): {err_text}"
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
            store.append_event(session_id, err_evt)
            store.set_status(session_id, STATUS_FAILED, error=err_msg)
            return

        # ─── 6. 正常完成 ───
        # 配额事件 + DONE 标记保留发到 stream（给老客户端兼容；新客户端从 meta 读）
        store.append_event(session_id, {"quota": {
            "used": quota_used, "limit": quota_limit, "remaining": quota_remaining,
        }})

        final_text, final_thinking = extract_final_texts(all_events)
        store.set_status(
            session_id, STATUS_DONE,
            final_text=final_text or "",
            final_thinking=final_thinking or "",
        )
        _append_cli_log(session_id, "meta", json.dumps({
            "event": "worker_done",
            "lines": line_count,
            "final_text_len": len(final_text or ""),
            "final_thinking_len": len(final_thinking or ""),
        }, ensure_ascii=False))
        logger.info(
            f"[WORKER] sid={session_id} 完成 lines={line_count} "
            f"final_text_len={len(final_text or '')}"
        )

    except Exception as e:
        logger.exception(f"[WORKER] sid={session_id} 异常: {e}")
        try:
            store.append_event(session_id, {"error": f"worker 异常: {e}"})
            store.set_status(session_id, STATUS_FAILED, error=str(e))
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
                  *, user_id: str, quota_used: int, quota_limit: int,
                  quota_remaining: int) -> None:
    """提交 worker 到线程池。立刻返回，不等任务完成。

    调用前应先 SessionStore.create_meta；这里只负责起 worker。
    """
    _executor.submit(
        _worker_main, session_id, last_msg, provider_id,
        quota_used, quota_limit, quota_remaining,
    )


def abort_session(session_id: str) -> None:
    """请求 abort：写 abort 标记 + 主动 kill 进程（双保险）。
    worker 主循环里下一次 readline 唤醒后会检测到 abort 标记并把 status 设为 aborted。
    """
    SessionStore().request_abort(session_id)
    _kill_proc(session_id)


def clear_abort(session_id: str) -> None:
    """擦掉 abort 标记。force_restart 重启 worker 时用。"""
    SessionStore().clear_abort(session_id)
