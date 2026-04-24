#!/usr/bin/env python3
"""
聊天模块 - AI 对话和 JSON App 生成
统一使用 Claude CLI 处理所有对话和代码生成请求。
"""

import json
import os
import re
import uuid
import subprocess
from flask import request, jsonify, Response, stream_with_context
from config import (
    AI_PROVIDERS, DEFAULT_PROVIDER,
    DSL_SPEC_PATH, PROJECT_ROOT, GENERATE_PROMPT_PATH,
    ROLE_QUOTAS, CLAUDE_BIN
)
from database import db_query, get_quota_info, increment_quota
from auth import require_auth


def _load_dsl_spec():
    """加载 JSON-DSL.md 规范"""
    try:
        with open(DSL_SPEC_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def _load_registry_summary():
    """从 app_registry 加载已有 app/component 摘要"""
    try:
        rows = db_query(
            "SELECT type, name, version, description, dsl_spec FROM app_registry WHERE is_public = true ORDER BY type, name",
            fetch_all=True
        )
        if not rows:
            return ""
        lines = []
        for row in rows:
            lines.append(f"- [{row['type']}] {row['name']} v{row['version']}: {row['description']}")
            if row.get("dsl_spec"):
                lines.append(f"  规格: {row['dsl_spec']}")
        return "\n".join(lines)
    except Exception:
        return ""


# ---------------------------------------------------------------------------
#  用于判断用户是否需要上传当前 APP 的关键词
# ---------------------------------------------------------------------------

_MODIFY_KEYWORDS = [
    "修改", "修复", "修一下", "改一下", "改改", "调整", "优化",
    "加一个", "添加", "增加", "删除", "删掉", "去掉", "移除",
    "换成", "改成", "变成", "替换", "更新", "升级",
    "bug", "崩溃", "白屏", "报错", "出错", "不工作", "不显示",
    "当前", "这个app", "这个应用", "现在的",
    "fix", "modify", "change", "update", "remove", "add",
]


def _needs_current_app(messages):
    """判断用户的最新消息是否暗示要修改当前 APP。
    只检查最后一条 user 消息。"""
    last_user_msg = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_user_msg = m.get("content", "").lower()
            break
    if not last_user_msg:
        return False
    return any(kw in last_user_msg for kw in _MODIFY_KEYWORDS)


def _get_provider(provider_id=None):
    pid = provider_id or DEFAULT_PROVIDER
    return AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])


def list_providers():
    providers = []
    for pid, cfg in AI_PROVIDERS.items():
        providers.append({
            "id": cfg["id"],
            "name": cfg["name"],
            "description": cfg.get("description", ""),
            "default_model": cfg["models"]["default"],
        })
    return jsonify({"providers": providers})


# ---------------------------------------------------------------------------
#  Claude CLI 代码生成（generate_app / fix_app 共用）
# ---------------------------------------------------------------------------

def _load_generate_prompt():
    """加载 Claude CLI 代码生成提示词"""
    try:
        with open(GENERATE_PROMPT_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        print(f"[CLI] Failed to load prompt: {e}")
        return ""


def _build_user_prompt(user_prompt, current_app=None, crash_log=None):
    """构建用户提示词，拼接当前 APP、崩溃日志和用户需求"""
    parts = []
    if current_app:
        app_str = current_app if isinstance(current_app, str) else json.dumps(current_app, ensure_ascii=False, indent=2)
        parts.append(f"## 当前正在运行的 JSON-APP\n```json\n{app_str}\n```")
    if crash_log:
        parts.append(f"## 崩溃日志\n{crash_log}")
    if user_prompt:
        parts.append(f"## 用户需求\n{user_prompt}")
    return "\n\n".join(parts)


def _tool_status_message(tool_name, tool_input):
    """将 Claude CLI 的工具调用映射为人类可读的状态描述。"""
    if tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        short = os.path.basename(file_path) if file_path else "文件"
        return f"正在阅读 {short}..."
    elif tool_name == "Write":
        file_path = tool_input.get("file_path", "")
        short = os.path.basename(file_path) if file_path else "文件"
        return f"正在写入 {short}..."
    elif tool_name in ("Grep", "Glob"):
        pattern = tool_input.get("pattern", tool_input.get("regex", ""))
        return f"正在搜索代码 {pattern[:30]}..." if pattern else "正在搜索代码..."
    elif tool_name == "Bash":
        cmd = tool_input.get("command", "")
        return f"正在执行命令..." if cmd else "正在运行脚本..."
    elif tool_name == "Edit":
        file_path = tool_input.get("file_path", "")
        short = os.path.basename(file_path) if file_path else "文件"
        return f"正在编辑 {short}..."
    elif tool_name == "WebFetch":
        return "正在获取网页内容..."
    elif tool_name == "WebSearch":
        return "正在搜索网络..."
    elif tool_name in ("Task", "TodoWrite"):
        return "正在规划任务..."
    else:
        return f"正在使用工具 {tool_name}..."


def _run_claude_cli(system_prompt, user_prompt, provider, output_path, tag="CLI"):
    """运行 Claude CLI 并 yield SSE 事件字符串。

    通过 stdin 传递 user_prompt（避免超长 CLI 参数），
    system_prompt 写入临时文件避免 ARG_MAX 限制。
    实时解析 stream-json 输出，最后将生成的 JSON 文件上传到 MinIO。
    """
    cli_env = provider.get("cli_env", {})
    cli_model = provider.get("cli_model", provider["models"]["default"])

    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)
    env["IS_SANDBOX"] = "1"  # 允许 root 下使用 --dangerously-skip-permissions

    # 将 system_prompt 写到临时文件，避免超长命令行参数
    sys_prompt_file = None
    if system_prompt:
        sys_prompt_file = os.path.join("/tmp", f"ai-sys-{uuid.uuid4().hex}.txt")
        with open(sys_prompt_file, "w", encoding="utf-8") as f:
            f.write(system_prompt)

    # 拼接完整提示词：基础提示词(从文件读) + 用户需求 + 输出路径
    # 格式: claude -p "$(cat /tmp/sys.txt) 用户需求... json文件放在/tmp/xxx.json"
    prompt_parts = []
    if sys_prompt_file:
        prompt_parts.append(f"$(cat {sys_prompt_file})")
    if user_prompt:
        prompt_parts.append(user_prompt)
    prompt_parts.append(f"\n请将最终生成的完整 JSON-APP 保存到文件: {output_path}")
    full_prompt = "\n\n".join(prompt_parts)

    cmd_str = (
        f'{CLAUDE_BIN}'
        f' --dangerously-skip-permissions'
        f' --no-session-persistence'
        f' --output-format stream-json'
        f' --verbose'
        f' -p "{full_prompt}"'
    )

    auth_token = cli_env.get("ANTHROPIC_AUTH_TOKEN", "")
    masked = f"{auth_token[:4]}***{auth_token[-4:]}" if len(auth_token) > 8 else "***"
    print(f"\n[{tag}] Starting Claude CLI:")
    print(f"  - Provider: {provider['name']}")
    print(f"  - Model: {cli_model}")
    print(f"  - Base URL: {cli_env.get('ANTHROPIC_BASE_URL')}")
    print(f"  - Auth Token: {masked}")
    print(f"  - CWD: {PROJECT_ROOT}")
    print(f"  - Output: {output_path}")
    print(f"  - User prompt preview: {user_prompt[:300] if user_prompt else '(empty)'}...")
    print(f"  - Cmd: {cmd_str[:200]}...\n")

    try:
        proc = subprocess.Popen(
            cmd_str,
            shell=True,
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=1,
        )
    except Exception as e:
        print(f"[{tag}] Failed to start Claude CLI: {e}")
        yield f'data: {json.dumps({"error": f"无法启动 Claude CLI: {e}"}, ensure_ascii=False)}\n\n'
        yield f'data: {json.dumps({"generating_json": False}, ensure_ascii=False)}\n\n'
        if sys_prompt_file:
            try: os.remove(sys_prompt_file)
            except: pass
        return

    # 实时读取 stdout，逐行解析 stream-json 格式并推送 SSE
    for raw_line in iter(proc.stdout.readline, b''):
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            evt_type = event.get("type")

            if evt_type == "system":
                # CLI 初始化完成
                yield f'data: {json.dumps({"status": "init", "message": "AI 引擎启动完毕"}, ensure_ascii=False)}\n\n'

            elif evt_type == "assistant":
                msg = event.get("message", {})
                for block in msg.get("content", []):
                    block_type = block.get("type")
                    if block_type == "thinking" and block.get("thinking"):
                        # 思考过程 → 推给前端显示
                        yield f'data: {json.dumps({"thinking": block["thinking"]}, ensure_ascii=False)}\n\n'
                        yield f'data: {json.dumps({"status": "thinking", "message": "正在思考..."}, ensure_ascii=False)}\n\n'
                    elif block_type == "text" and block.get("text"):
                        # 正式文本 → 推给前端
                        yield f'data: {json.dumps({"content": block["text"]}, ensure_ascii=False)}\n\n'
                    elif block_type == "tool_use":
                        # 工具调用 → 推送状态描述
                        tool_name = block.get("name", "")
                        tool_input = block.get("input", {})
                        status_msg = _tool_status_message(tool_name, tool_input)
                        if status_msg:
                            yield f'data: {json.dumps({"status": tool_name.lower(), "message": status_msg}, ensure_ascii=False)}\n\n'

            elif evt_type == "result":
                # 最终结果
                result_text = event.get("result", "")
                if result_text:
                    yield f'data: {json.dumps({"content": result_text}, ensure_ascii=False)}\n\n'
                duration = event.get("duration_ms", 0)
                num_turns = event.get("num_turns", 0)
                is_error = event.get("is_error", False)
                print(f"[{tag}] Result: turns={num_turns}, duration={duration}ms, error={is_error}")
                if is_error:
                    yield f'data: {json.dumps({"error": f"Claude CLI 执行出错: {result_text[:200]}"}, ensure_ascii=False)}\n\n'
                    yield f'data: {json.dumps({"generating_json": False}, ensure_ascii=False)}\n\n'

        except json.JSONDecodeError:
            pass

    proc.wait()
    stderr_output = proc.stderr.read().decode("utf-8", errors="replace")

    if proc.returncode != 0:
        print(f"[{tag}] CLI exited with code {proc.returncode}")
        if stderr_output:
            print(f"[{tag}] stderr: {stderr_output[:2000]}")
        # 把 stderr 关键信息推给前端，方便诊断
        err_msg = f"Claude CLI 异常退出 (code {proc.returncode})"
        if stderr_output:
            # 取 stderr 最后几行作为错误信息
            err_lines = [l.strip() for l in stderr_output.strip().splitlines() if l.strip()]
            if err_lines:
                err_msg += f": {err_lines[-1][:200]}"
        yield f'data: {json.dumps({"error": err_msg}, ensure_ascii=False)}\n\n'
        yield f'data: {json.dumps({"generating_json": False}, ensure_ascii=False)}\n\n'
        return

    # 检查输出文件并上传到 MinIO
    output_filename = os.path.basename(output_path)
    if os.path.exists(output_path):
        yield f'data: {json.dumps({"status": "uploading", "message": "正在上传生成结果..."}, ensure_ascii=False)}\n\n'
        try:
            with open(output_path, "r", encoding="utf-8") as f:
                app_json = json.load(f)
            print(f"[{tag}] JSON file found, keys: {list(app_json.keys())}")

            import requests as _req
            from store import _minio_presigned_put, _minio_presigned_get

            bucket = "ai-chat-temp"
            put_url = _minio_presigned_put(bucket, output_filename)
            get_url = _minio_presigned_get(bucket, output_filename)

            upload_resp = _req.put(
                put_url,
                data=json.dumps(app_json, ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )

            if upload_resp.status_code == 200:
                yield f'data: {json.dumps({"has_json": True, "json_url": get_url}, ensure_ascii=False)}\n\n'
                print(f"[{tag}] MinIO upload success: {get_url}")
            else:
                yield f'data: {json.dumps({"has_json": True, "json_app": app_json}, ensure_ascii=False)}\n\n'
        except Exception as e:
            print(f"[{tag}] JSON read/upload failed: {e}")
            yield f'data: {json.dumps({"error": f"JSON 处理失败: {e}"}, ensure_ascii=False)}\n\n'
            yield f'data: {json.dumps({"generating_json": False}, ensure_ascii=False)}\n\n'
        finally:
            try:
                os.remove(output_path)
            except Exception:
                pass
    else:
        print(f"[{tag}] Output file not found: {output_path}")
        if stderr_output:
            print(f"[{tag}] stderr: {stderr_output[:2000]}")
        err_detail = ""
        if stderr_output:
            err_lines = [l.strip() for l in stderr_output.strip().splitlines() if l.strip()]
            if err_lines:
                err_detail = f" ({err_lines[-1][:200]})"
        yield f'data: {json.dumps({"error": f"Claude 未生成 JSON 文件，请重试{err_detail}"}, ensure_ascii=False)}\n\n'
        yield f'data: {json.dumps({"generating_json": False}, ensure_ascii=False)}\n\n'

    # 清理 system prompt 临时文件
    if sys_prompt_file:
        try:
            os.remove(sys_prompt_file)
        except Exception:
            pass


@require_auth
def generate_app():
    """使用 Claude CLI 生成/修改/修复 JSON-APP"""
    user_id = request.supabase_user.get("id")
    role = request.user_role

    used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
    if remaining <= 0:
        return jsonify({
            "error": f"今日对话次数已用完（{used}/{limit}）",
            "quota": {"used": used, "limit": limit, "remaining": 0},
        }), 429

    body = request.get_json(silent=True) or {}
    user_prompt = body.get("prompt", "")
    current_app = body.get("current_app")
    crash_log = body.get("crash_log")
    provider_id = body.get("provider")

    if not user_prompt and not crash_log:
        return jsonify({"error": "prompt 或 crash_log 不能为空"}), 400

    provider = _get_provider(provider_id)
    if not provider.get("cli_env", {}).get("ANTHROPIC_AUTH_TOKEN"):
        return jsonify({"error": f"供应商 {provider['name']} 未配置 CLI 环境变量"}), 500

    output_path = os.path.join("/tmp", f"ai-gen-{uuid.uuid4().hex}.json")
    system_prompt = _load_generate_prompt()
    full_prompt = _build_user_prompt(user_prompt, current_app, crash_log)

    increment_quota(user_id)
    new_remaining = remaining - 1

    def generate():
        try:
            yield from _run_claude_cli(system_prompt, full_prompt, provider, output_path, tag="GenerateApp")
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"
        except Exception as e:
            print(f"[GenerateApp] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )


# ---------------------------------------------------------------------------
#  崩溃报告检测
# ---------------------------------------------------------------------------

_CRASH_INDICATORS = [
    "exception was thrown", "stack trace", "崩溃日志",
    "renderobject", "renderflex", "type cast",
    "is not a subtype of type", "error_", "I/flutter",
    "another exception", "dart:core", "package:flutter",
]


def _is_crash_report(messages):
    """判断最后一条 user 消息是否是崩溃报告/日志（而非修改请求）。"""
    last_user_msg = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_user_msg = m.get("content", "").lower()
            break
    if not last_user_msg:
        return False
    # 崩溃报告通常包含多行堆栈或框架日志特征
    return sum(1 for ind in _CRASH_INDICATORS if ind in last_user_msg) >= 2


# ---------------------------------------------------------------------------
#  Chat — 统一 Claude CLI 对话
# ---------------------------------------------------------------------------

@require_auth
def chat():
    """SSE 流式 AI 对话。
    所有用户消息通过 Claude CLI 处理。
    第一轮对话：只输出方案摘要，不生成代码。
    后续对话（含确认）：正常执行代码生成。
    崩溃报告：跳过上传检查，直接修复。
    """
    user_id = request.supabase_user.get("id")
    role = request.user_role

    used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
    if remaining <= 0:
        return jsonify({
            "error": f"今日对话次数已用完（{used}/{limit})",
            "quota": {"used": used, "limit": limit, "remaining": 0},
        }), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    if not messages:
        return jsonify({"error": "messages is required"}), 400

    provider_id = body.get("provider")
    provider = _get_provider(provider_id)
    current_app = body.get("current_app")  # 客户端传来的当前 JSON

    if not provider.get("cli_env", {}).get("ANTHROPIC_AUTH_TOKEN"):
        return jsonify({"error": f"供应商 {provider['name']} 未配置 CLI 环境变量"}), 500

    # 过滤掉 system 消息，只保留 user/assistant
    user_messages = []
    for m in messages:
        if m["role"] == "system":
            continue
        user_messages.append({"role": m["role"], "content": m["content"]})

    # 前置检查：如果用户想修改当前 APP 但没有传 current_app，先要求上传
    # ★ 崩溃报告跳过此检查（崩溃修复场景下客户端不会提示上传）
    if not current_app and _needs_current_app(user_messages) and not _is_crash_report(user_messages):
        # 检查对话历史中是否已经包含了 APP 配置（用户之前已上传过）
        has_app_in_history = any(
            "json_app_url" in m.get("content", "") or "当前正在运行的 JSON-APP" in m.get("content", "")
            for m in user_messages
        )
        if not has_app_in_history:
            def request_upload():
                yield f'data: {json.dumps({"content": "好的，请先上传当前应用配置，我来帮你处理。"}, ensure_ascii=False)}\n\n'
                yield f'data: {json.dumps({"request_action": "upload_current_app"}, ensure_ascii=False)}\n\n'
                yield "data: [DONE]\n\n"
            return Response(
                stream_with_context(request_upload()),
                mimetype="text/event-stream",
                headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                         "Access-Control-Allow-Origin": "*"},
            )

    # 构建完整的用户提示词（包含对话历史）
    history_parts = []
    for m in user_messages[:-1]:
        role_label = "用户" if m["role"] == "user" else "助手"
        history_parts.append(f"[{role_label}] {m['content']}")

    last_msg = user_messages[-1]["content"] if user_messages else ""

    if history_parts:
        combined_prompt = f"## 之前的对话历史\n" + "\n\n".join(history_parts) + f"\n\n## 用户的最新需求\n{last_msg}"
    else:
        combined_prompt = last_msg

    # ★ 判断是否为首轮对话（无历史 = 用户第一句话）
    is_first_turn = len(history_parts) == 0 and not _is_crash_report(user_messages)
    # 如果有 current_app，说明是修改/修复场景，不需要讨论
    if current_app:
        is_first_turn = False

    increment_quota(user_id)
    new_remaining = remaining - 1

    def generate():
        try:
            output_path = os.path.join("/tmp", f"ai-chat-gen-{uuid.uuid4().hex}.json")
            cli_system = _load_generate_prompt()
            cli_prompt = _build_user_prompt(combined_prompt, current_app)

            if is_first_turn:
                # ★ 首轮对话：追加指令，强制 CLI 只输出方案、不写文件
                cli_prompt += (
                    "\n\n---\n"
                    "【系统指令】这是用户发来的第一条消息，你还没有和用户确认过方案。\n"
                    "请严格遵守「先讨论，后动手」规则：\n"
                    "1. 用 200 字以内简洁描述你的理解和方案（功能、页面数、交互要点）\n"
                    "2. 结尾询问用户是否确认\n"
                    "3. 绝对不要阅读源码、不要生成 JSON、不要写入任何文件！\n"
                )
                # 首轮不发 generating_json，前端不显示生成状态
                yield f'data: {json.dumps({"status": "thinking", "message": "正在分析需求..."}, ensure_ascii=False)}\n\n'
            else:
                # 非首轮：通知前端进入生成模式
                yield f'data: {json.dumps({"generating_json": True}, ensure_ascii=False)}\n\n'

            yield from _run_claude_cli(cli_system, cli_prompt, provider, output_path, tag="Chat-CLI")

            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        except Exception as e:
            print(f"[Chat] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )



# ---------------------------------------------------------------------------
#  Fix App — 使用 Claude CLI 修复崩溃的 JSON-APP
# ---------------------------------------------------------------------------

@require_auth
def fix_app():
    """接收崩溃日志 + JSON，使用 Claude CLI 返回修复版 JSON"""
    body = request.get_json(silent=True) or {}
    crash_log = body.get("crash_log", "")
    json_config = body.get("json_config", "")
    provider_id = body.get("provider")

    if not crash_log or not json_config:
        return jsonify({"error": "crash_log 和 json_config 不能为空"}), 400

    provider = _get_provider(provider_id)
    if not provider.get("cli_env", {}).get("ANTHROPIC_AUTH_TOKEN"):
        return jsonify({"error": f"供应商 {provider['name']} 未配置 CLI 环境变量"}), 500

    output_path = os.path.join("/tmp", f"ai-fix-{uuid.uuid4().hex}.json")
    system_prompt = _load_generate_prompt()
    full_prompt = _build_user_prompt(
        "请修复这个崩溃的 JSON-APP，确保修复后可以正常运行。",
        json_config,
        crash_log,
    )

    def generate():
        try:
            yield from _run_claude_cli(system_prompt, full_prompt, provider, output_path, tag="FixApp")
            yield "data: [DONE]\n\n"
        except Exception as e:
            print(f"[FixApp] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )
