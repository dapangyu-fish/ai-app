#!/usr/bin/env python3
"""
聊天模块 - AI 对话和 JSON App 生成
"""

import json
import os
import re
import uuid
import subprocess
import anthropic
from flask import request, jsonify, Response, stream_with_context
from config import (
    AI_PROVIDERS, DEFAULT_PROVIDER,
    DSL_SPEC_PATH, PROJECT_ROOT, GENERATE_PROMPT_PATH,
    AGENT_MAX_ITERATIONS, ROLE_QUOTAS
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


AGENT_SYSTEM = """你是 JSON-DSL 应用设计师助手。用户通过语音与你交流，你负责澄清需求、确认细节。

## 工作模式
- 你只负责对话，**不负责生成 JSON**。当你充分理解用户需求后，告知用户"好的，正在为你生成..."即可，后端会自动触发代码生成。
- 对话回复极度简洁（用户在手机上看字幕）。
- 如果用户的需求不明确，主动追问（例如：主题色？核心功能？）。
- 不要在对话中输出任何 JSON 代码或代码块。
"""


AGENT_TOOLS = [
    {
        "name": "read_file",
        "description": "读取项目文件。常用: JSON-DSL.md (完整DSL规范), lib/json_ui/interpreter.dart (解释器+内置函数), lib/json_ui/widget_builder.dart (组件注册表), lib/json_ui/widgets/ (各组件实现)",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "从项目根目录的相对路径"}
            },
            "required": ["path"]
        }
    },
    {
        "name": "search_code",
        "description": "在项目代码中搜索关键词，返回匹配的行和文件路径",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "搜索关键词或正则"},
                "glob": {"type": "string", "description": "文件过滤，如 *.dart *.md"}
            },
            "required": ["pattern"]
        }
    },
    {
        "name": "list_builtin_functions",
        "description": "列出 JSON-DSL 框架所有可用的 @内置函数",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "list_templates",
        "description": "列出 templates/ 目录下所有模板 APP 文件及其简介。生成 JSON-APP 前应先查看，选一个相似的用 read_file 读取作为参考",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    }
]


def _execute_agent_tool(name, inputs):
    """执行 Agent 工具调用"""
    if name == "read_file":
        path = os.path.join(PROJECT_ROOT, inputs["path"])
        real = os.path.realpath(path)
        if not real.startswith(PROJECT_ROOT):
            return "Access denied: path outside project"
        try:
            with open(path, 'r') as f:
                content = f.read()
            if len(content) > 15000:
                content = content[:15000] + "\n\n... (truncated)"
            return content
        except FileNotFoundError:
            return f"File not found: {inputs['path']}"
        except Exception as e:
            return f"Error: {e}"

    elif name == "search_code":
        import subprocess
        pattern = inputs["pattern"]
        glob_pat = inputs.get("glob", "*.dart")
        try:
            result = subprocess.run(
                ["grep", "-rn", "--include", glob_pat, pattern, PROJECT_ROOT],
                capture_output=True, text=True, timeout=10
            )
            output = result.stdout[:8000] if result.stdout else "No matches found"
            return output
        except Exception as e:
            return f"Search error: {e}"

    elif name == "list_builtin_functions":
        path = os.path.join(PROJECT_ROOT, "lib/json_ui/interpreter.dart")
        try:
            with open(path, 'r') as f:
                content = f.read()
            funcs = sorted(set(re.findall(r"'(@\w+)'", content)))
            return "可用的内置函数:\n" + "\n".join(funcs)
        except Exception as e:
            return f"Error: {e}"

    elif name == "list_templates":
        tpl_dir = os.path.join(PROJECT_ROOT, "templates")
        try:
            files = sorted(f for f in os.listdir(tpl_dir) if f.endswith('.json'))
            result = []
            for f in files:
                path = os.path.join(tpl_dir, f)
                try:
                    with open(path, 'r', encoding='utf-8') as fh:
                        data = json.load(fh)
                    meta = data.get("meta", {})
                    name_str = meta.get("name", f)
                    desc = meta.get("description", "")
                    result.append(f"- {f}: {name_str} — {desc}")
                except Exception:
                    result.append(f"- {f}: (parse error)")
            return "可参考的模板 APP:\n" + "\n".join(result) + "\n\n用 read_file('templates/xxx.json') 读取完整内容作为参考"
        except Exception as e:
            return f"Error: {e}"

    return f"Unknown tool: {name}"


def _resolve_json_urls(content):
    """将消息中的 [json_app_url]...[/json_app_url] 标签替换为实际 JSON 内容。
    客户端会先将大 JSON 上传到 MinIO，消息里只放下载链接。
    后端在发给 AI 之前把链接解析成真正的 JSON 文本。
    """
    if not isinstance(content, str) or "[json_app_url]" not in content:
        return content

    import requests as _req

    def _fetch_and_replace(match):
        url = match.group(1).strip()
        try:
            resp = _req.get(url, timeout=15)
            if resp.status_code == 200:
                # 验证是合法 JSON
                json.loads(resp.text)
                print(f"[Agent] Resolved JSON URL: {len(resp.text)} chars")
                return f"```json\n{resp.text}\n```"
            else:
                print(f"[Agent] JSON URL fetch failed: HTTP {resp.status_code}")
                return f"(JSON 下载失败: HTTP {resp.status_code})"
        except Exception as e:
            print(f"[Agent] JSON URL fetch error: {e}")
            return f"(JSON 下载异常: {e})"

    return re.sub(
        r'\[json_app_url\](.*?)\[/json_app_url\]',
        _fetch_and_replace,
        content,
        flags=re.DOTALL,
    )


def _get_provider(provider_id=None):
    pid = provider_id or DEFAULT_PROVIDER
    return AI_PROVIDERS.get(pid, AI_PROVIDERS[DEFAULT_PROVIDER])


def _get_agent_client(provider_id=None):
    provider = _get_provider(provider_id)
    api_key = provider.get("api_key", "")
    masked_key = f"{api_key[:4]}***{api_key[-4:]}" if len(api_key) > 8 else "***"
    print(f"\n[AI_SERVER] Initiating Agent Client:")
    print(f"  - Provider ID: {provider.get('id')}")
    print(f"  - Base URL: {provider.get('base_url')}")
    print(f"  - API Key: {masked_key}")
    print(f"  - Agent Model: {provider.get('agent_model', provider.get('models', {}).get('default'))}\n")

    # 强制清理环境变量中的残留 token，防止 anthropic SDK 错误地发送 Authorization: Bearer 头
    if "ANTHROPIC_AUTH_TOKEN" in os.environ:
        os.environ.pop("ANTHROPIC_AUTH_TOKEN", None)

    return anthropic.Anthropic(
        base_url=provider["base_url"],
        api_key=provider["api_key"],
    )


def _get_agent_model(provider_id=None):
    provider = _get_provider(provider_id)
    return provider.get("agent_model", provider["models"]["default"])


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


def _build_user_prompt(user_prompt, current_app, crash_log, output_path):
    """构建用户提示词，拼接当前 APP、崩溃日志和用户需求"""
    parts = []
    if current_app:
        app_str = current_app if isinstance(current_app, str) else json.dumps(current_app, ensure_ascii=False, indent=2)
        parts.append(f"## 当前正在运行的 JSON-APP\n```json\n{app_str}\n```")
    if crash_log:
        parts.append(f"## 崩溃日志\n{crash_log}")
    if user_prompt:
        parts.append(f"## 用户需求\n{user_prompt}")
    parts.append(f"\n请将最终生成的完整 JSON-APP 保存到文件: {output_path}")
    return "\n\n".join(parts)


def _run_claude_cli(system_prompt, user_prompt, provider, output_path, tag="CLI"):
    """运行 Claude CLI 并 yield SSE 事件字符串。

    通过 stdin 传递 user_prompt（避免超长 CLI 参数），
    实时解析 stream-json 输出，最后将生成的 JSON 文件上传到 MinIO。
    """
    cli_env = provider.get("cli_env", {})
    cli_model = provider.get("cli_model", provider["models"]["default"])

    env = os.environ.copy()
    for k, v in cli_env.items():
        env[k] = v
    env.pop("ANTHROPIC_API_KEY", None)

    cmd = [
        "claude", "-p",
        "--model", cli_model,
        "--output-format", "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        "--no-session-persistence",
    ]
    if system_prompt:
        cmd.extend(["--system-prompt", system_prompt])

    auth_token = cli_env.get("ANTHROPIC_AUTH_TOKEN", "")
    masked = f"{auth_token[:4]}***{auth_token[-4:]}" if len(auth_token) > 8 else "***"
    print(f"\n[{tag}] Starting Claude CLI:")
    print(f"  - Provider: {provider['name']}")
    print(f"  - Model: {cli_model}")
    print(f"  - Base URL: {cli_env.get('ANTHROPIC_BASE_URL')}")
    print(f"  - Auth Token: {masked}")
    print(f"  - CWD: {PROJECT_ROOT}")
    print(f"  - Output: {output_path}\n")

    proc = subprocess.Popen(
        cmd,
        cwd=PROJECT_ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        bufsize=1,
    )

    # 通过 stdin 传递用户提示词（避免超长 CLI 参数）
    if user_prompt:
        proc.stdin.write(user_prompt.encode("utf-8"))
    proc.stdin.close()

    # 实时读取 stdout，逐行解析 stream-json 格式并推送 SSE
    for raw_line in iter(proc.stdout.readline, b''):
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            if event.get("type") == "assistant":
                msg = event.get("message", {})
                for block in msg.get("content", []):
                    if block.get("type") == "text" and block.get("text"):
                        yield f'data: {json.dumps({"content": block["text"]}, ensure_ascii=False)}\n\n'
        except json.JSONDecodeError:
            if line:
                yield f'data: {json.dumps({"content": line}, ensure_ascii=False)}\n\n'

    proc.wait()
    stderr_output = proc.stderr.read().decode("utf-8", errors="replace")
    if proc.returncode != 0:
        print(f"[{tag}] CLI exited with code {proc.returncode}")
        if stderr_output:
            print(f"[{tag}] stderr: {stderr_output[:500]}")

    # 检查输出文件并上传到 MinIO
    output_filename = os.path.basename(output_path)
    if os.path.exists(output_path):
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
        finally:
            try:
                os.remove(output_path)
            except Exception:
                pass
    else:
        print(f"[{tag}] Output file not found: {output_path}")
        yield f'data: {json.dumps({"content": "\n\n⚠️ Claude 未生成 JSON 文件，请检查提示词或重试。"}, ensure_ascii=False)}\n\n'


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
    full_prompt = _build_user_prompt(user_prompt, current_app, crash_log, output_path)

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
#  意图检测 — 判断最后一条用户消息是否要求生成/修复 JSON-APP
# ---------------------------------------------------------------------------

_GENERATE_KEYWORDS = [
    "生成", "创建", "做一个", "做个", "帮我做", "帮我写", "开发",
    "generate", "create", "build", "make",
]
_FIX_KEYWORDS = [
    "修复", "修改", "改一下", "改成", "更新", "优化", "加上", "删掉", "去掉",
    "fix", "update", "modify", "change", "remove", "add",
]


def _detect_generate_intent(messages):
    """从最后一条用户消息检测是否有生成/修复 APP 的意图。
    返回 (is_generate: bool, last_user_text: str)
    """
    last_user_text = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            content = m.get("content", "")
            if isinstance(content, str):
                last_user_text = content
            break

    if not last_user_text:
        return False, ""

    lower = last_user_text.lower()
    for kw in _GENERATE_KEYWORDS + _FIX_KEYWORDS:
        if kw in lower:
            return True, last_user_text

    return False, last_user_text


# ---------------------------------------------------------------------------
#  Chat — 对话澄清需求，生成/修复由 Claude CLI 完成
# ---------------------------------------------------------------------------

@require_auth
def chat():
    """SSE 流式 AI 对话。
    - 纯聊天：轻量 SDK Agent 澄清需求。
    - 检测到生成/修复意图：直接拼提示词，调 Claude CLI 完成 JSON 生成。
    """
    user_id = request.supabase_user.get("id")
    role = request.user_role

    used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
    if remaining <= 0:
        return jsonify({
            "error": f"今日对话次数已用完（{used}/{limit}）",
            "quota": {"used": used, "limit": limit, "remaining": 0},
        }), 429

    body = request.get_json(silent=True) or {}
    messages = body.get("messages", [])
    if not messages:
        return jsonify({"error": "messages is required"}), 400

    provider_id = body.get("provider")
    provider = _get_provider(provider_id)
    current_app = body.get("current_app")  # 客户端传来的当前 JSON（用于修改场景）

    increment_quota(user_id)
    new_remaining = remaining - 1

    is_generate, last_user_text = _detect_generate_intent(messages)

    # ── 路径 A：生成/修复 — 直接调 Claude CLI ──
    if is_generate and provider.get("cli_env", {}).get("ANTHROPIC_AUTH_TOKEN"):
        output_path = os.path.join("/tmp", f"ai-chat-gen-{uuid.uuid4().hex}.json")
        # 构建一体化提示词：基础提示词 + 当前 APP + 用户需求 + 保存路径
        system_prompt = _load_generate_prompt()
        full_prompt = _build_user_prompt(last_user_text, current_app, None, output_path)

        def generate_via_cli():
            try:
                yield f'data: {json.dumps({"generating_json": True}, ensure_ascii=False)}\n\n'
                yield from _run_claude_cli(system_prompt, full_prompt, provider, output_path, tag="Chat-CLI")
                yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
                yield "data: [DONE]\n\n"
            except Exception as e:
                print(f"[Chat-CLI] Error: {e}")
                import traceback; traceback.print_exc()
                yield f'data: {json.dumps({"error": str(e)})}\n\n'
                yield "data: [DONE]\n\n"

        return Response(
            stream_with_context(generate_via_cli()),
            mimetype="text/event-stream",
            headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                     "Access-Control-Allow-Origin": "*"},
        )

    # ── 路径 B：纯对话 — 轻量 SDK Agent ──
    agent_client = _get_agent_client(provider_id)
    agent_model = _get_agent_model(provider_id)

    agent_messages = []
    for m in messages:
        if m["role"] == "system":
            continue
        content = _resolve_json_urls(m["content"])
        agent_messages.append({"role": m["role"], "content": content})

    system_prompt = AGENT_SYSTEM
    registry = _load_registry_summary()
    if registry:
        system_prompt += f"\n## 已注册的 APP 和组件\n{registry}"

    def generate_via_sdk():
        msgs = list(agent_messages)
        try:
            for iteration in range(AGENT_MAX_ITERATIONS):
                print(f"[Agent] Iteration {iteration + 1}, messages={len(msgs)}")
                call_kwargs = {
                    "model": agent_model,
                    "max_tokens": 2048,
                    "system": system_prompt,
                    "messages": msgs,
                    "tools": AGENT_TOOLS,
                }
                if provider.get("extra_body"):
                    call_kwargs["extra_body"] = provider["extra_body"]

                response = None
                try:
                    with agent_client.messages.stream(**call_kwargs) as stream:
                        for text in stream.text_stream:
                            yield f'data: {json.dumps({"content": text}, ensure_ascii=False)}\n\n'
                        response = stream.get_final_message()
                except Exception as e:
                    print(f"[Agent] Stream failed ({e}), falling back to non-stream")
                    response = agent_client.messages.create(**call_kwargs)
                    for block in response.content:
                        if block.type == 'text' and block.text:
                            yield f'data: {json.dumps({"content": block.text}, ensure_ascii=False)}\n\n'

                tool_calls = [b for b in response.content if b.type == 'tool_use']
                if not tool_calls:
                    print(f"[Agent] Done after {iteration + 1} iterations")
                    break

                assistant_content = []
                for block in response.content:
                    if block.type == 'text':
                        assistant_content.append({"type": "text", "text": block.text})
                    elif block.type == 'tool_use':
                        assistant_content.append({
                            "type": "tool_use", "id": block.id,
                            "name": block.name, "input": block.input,
                        })
                msgs.append({"role": "assistant", "content": assistant_content})

                tool_results = []
                for tc in tool_calls:
                    result = _execute_agent_tool(tc.name, tc.input)
                    print(f"[Agent] Tool {tc.name}: {len(result)} chars")
                    tool_results.append({
                        "type": "tool_result", "tool_use_id": tc.id, "content": result,
                    })
                msgs.append({"role": "user", "content": tool_results})

            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        except Exception as e:
            print(f"[Agent] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate_via_sdk()),
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
        output_path,
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
