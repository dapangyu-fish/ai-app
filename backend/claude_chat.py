import json
import os
import subprocess
from flask import request, jsonify, Response, stream_with_context
from config import AI_PROVIDERS, DEFAULT_PROVIDER, PROJECT_ROOT, GENERATE_PROMPT_PATH, CLAUDE_BIN
from auth import require_auth
from database import get_quota_info, increment_quota
from config import ROLE_QUOTAS

def _get_provider(provider_id=None):
    pid = provider_id or DEFAULT_PROVIDER
    return AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])

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

    used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
    if remaining <= 0:
        return jsonify({"error": "配额已用完", "quota": {"used": used, "limit": limit}}), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    session_id = body.get("session_id")
    provider_id = body.get("provider")

    if not messages or not session_id:
        return jsonify({"error": "messages 和 session_id 是必需的"}), 400

    # 提取最后一条用户消息
    last_msg = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_msg = m.get("content", "")
            break
            
    if not last_msg:
        return jsonify({"error": "未找到用户消息"}), 400

    provider = _get_provider(provider_id)
    cli_env = provider.get("cli_env", {})
    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"

    increment_quota(user_id)
    new_remaining = remaining - 1

    def run_cli(is_resume=True):
        cmd = [
            CLAUDE_BIN,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--verbose",
            "-p", last_msg
        ]
        
        if is_resume:
            cmd.extend(["-r", session_id])
        else:
            cmd.extend(["--session-id", session_id])
            try:
                with open(GENERATE_PROMPT_PATH, "r", encoding="utf-8") as f:
                    sys_prompt = f.read()
                if sys_prompt:
                    # 将系统提示词作为一个长参数传递（需要 CLI 支持 --append-system-prompt）
                    cmd.extend(["--append-system-prompt", sys_prompt])
            except Exception:
                pass

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
        proc = run_cli(is_resume=True)
        
        initial_lines = []
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            initial_lines.append(line)
            line_str = line.decode("utf-8", errors="replace").strip()
            if line_str:
                break
                
        # 此时可能进程已经退出（如发生错误），给它 0.1s 彻底清理以获取准确的 returncode
        try:
            proc.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            pass
            
        if proc.returncode is not None and proc.returncode != 0:
            stderr_text = proc.stderr.read().decode("utf-8", errors="replace")
            stdout_text = b"".join(initial_lines).decode("utf-8", errors="replace") + proc.stdout.read().decode("utf-8", errors="replace")
            full_err = stderr_text + "\n" + stdout_text
            
            if "No conversation found" in full_err or "requires a valid session ID" in full_err:
                # fallback: 创建新会话
                proc = run_cli(is_resume=False)
                initial_lines = []
            else:
                yield f'data: {json.dumps({"error": f"Claude CLI 启动失败 (code {proc.returncode}): {stderr_text}"}, ensure_ascii=False)}\n\n'
                yield "data: [DONE]\n\n"
                return

        def process_stream(process, buffered_lines):
            for line in buffered_lines:
                yield from _parse_line(line)
            
            lines_iter = iter(process.stdout.readline, b'')
            for line in lines_iter:
                yield from _parse_line(line)
            
            process.wait()
            if process.returncode != 0:
                err = process.stderr.read().decode("utf-8", errors="replace")
                if err:
                    yield f'data: {json.dumps({"error": f"Claude CLI 异常退出: {err}"}, ensure_ascii=False)}\n\n'
                    
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        def _parse_line(raw_line):
            line_str = raw_line.decode("utf-8", errors="replace").strip()
            if not line_str:
                return
            try:
                event = json.loads(line_str)
                evt_type = event.get("type")
                
                if evt_type == "system":
                    yield f'data: {json.dumps({"status": "init", "message": "AI 引擎已启动"}, ensure_ascii=False)}\n\n'
                    
                elif evt_type == "assistant":
                    msg = event.get("message", {})
                    for block in msg.get("content", []):
                        btype = block.get("type")
                        if btype == "thinking" and block.get("thinking"):
                            yield f'data: {json.dumps({"thinking": block["thinking"]}, ensure_ascii=False)}\n\n'
                            yield f'data: {json.dumps({"status": "thinking", "message": "正在思考..."}, ensure_ascii=False)}\n\n'
                        elif btype == "text" and block.get("text"):
                            yield f'data: {json.dumps({"content": block["text"]}, ensure_ascii=False)}\n\n'
                        elif btype == "tool_use":
                            tool_name = block.get("name", "")
                            tool_input = block.get("input", {})
                            status_msg = _tool_status_message(tool_name, tool_input)
                            yield f'data: {json.dumps({"status": tool_name.lower(), "message": status_msg}, ensure_ascii=False)}\n\n'
                            
                elif evt_type == "result":
                    res = event.get("result", "")
                    if res:
                        yield f'data: {json.dumps({"content": res}, ensure_ascii=False)}\n\n'
                    if event.get("is_error"):
                        yield f'data: {json.dumps({"error": f"生成中断: {res}"}, ensure_ascii=False)}\n\n'
            except json.JSONDecodeError:
                pass

        yield from process_stream(proc, initial_lines)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "Access-Control-Allow-Origin": "*"}
    )
