#!/usr/bin/env python3
"""
聊天模块 - AI 对话和 JSON App 生成
"""

import json
import os
import re
import anthropic
from flask import request, jsonify, Response, stream_with_context
from config import (
    AI_PROVIDERS, DEFAULT_PROVIDER,
    DSL_SPEC_PATH, PROJECT_ROOT,
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


AGENT_SYSTEM = """你是 JSON-DSL 应用设计师。用户通过语音与你交流，你帮助设计和生成 JSON-APP。

## 工作模式
1. 先简要说明你的修改意图或改动点（流式发给前端）。
2. 将完整可运行的最终 JSON 必须放置在 `<app_json>` 和 `</app_json>` 标签之内（不要用 markdown）。
3. 先用工具查阅框架代码，确认内置函数和组件确实存在。
4. 参考 templates/ 目录下的已有模板 APP，学习正确的 JSON 结构和用法。
5. 对话回复极度简洁（用户在手机上看字幕），JSON 则在单独的 <app_json> 中全量输出。
6. **极其重要：在输出完 `</app_json>` 闭合标签之后，你必须再说一两句话（200字以内），明确告知用户“生成已成功”并简短介绍你生成的 APP 具备了什么功能。不然用户会以为卡住了！**

## 工具使用指引
- read_file: 读取框架源码或模板文件
- search_code: 搜索代码关键词
- list_builtin_functions: 获取所有可用 @函数列表
- list_templates: 列出所有可参考的模板 APP

## 生成 JSON-APP 的标准流程
1. 先调 list_builtin_functions 确认可用函数
2. 调 list_templates 查看有哪些模板
3. 用 read_file 读取一个相似的模板作为参考
4. 严格按照以下骨架生成 JSON-APP：
   ```json
   {
     "dsl": "3.3",
     "meta": { "name": "app_name", "version": "1.0.0", "type": "app" },
     "global": { "variables": {}, "functions": {} },
     "steps": [],
     "ui": { "screens": [ { "id": "main", "title": "...", "layout": "column", "children": [] } ] }
   }
   ```
   绝对禁止使用 `entry`、`pages` 等不属于 DSL 3.3 的顶级字段！必须把页面写在 `ui.screens` 里！

## 输出要求
- JSON 必须包含 meta（name/version/type:"app"/description/icon_url）
- 只使用工具确认存在的 @函数和组件类型
- 不要自创框架中不存在的函数或属性

## 颜色与可读性规则（极其重要！）
- **深色背景必须配浅色文字，浅色背景必须配深色文字**
- 禁止出现背景色和文字颜色亮度相近的情况（如灰底灰字、蓝底蓝字）
- 不设置文字颜色时，框架会跟随系统主题默认色（深色模式为白色，浅色模式为黑色）

## 布局与样式防暴走规则（极其重要！）
1. **Container 默认是横向排列 (layout: "row")！**如果你需要上下排列，必须显式加上 `"layout": "column"`！否则内部放入 list 会直接导致 Flutter 布局崩溃（白屏）！
2. **Container 绝对没有 `style` 字段！**其样式（`color`, `padding`, `margin`, `borderRadius` 等）直接平铺写在 Container 节点上！
3. **禁止臆造 Web CSS 属性！**框架不支持 `transform`、`transition`、`marginBottom`、`shadow` 等属性！如需间距，请使用 `margin` 或者直接插入 `{"type": "spacer", "height": 20}`。
4. **List 的高度是无限的！**如果要在一个竖直排列的地方放入 `list`，其父节点或者它所在的直接 Container 必须是 `layout: "column"`。
5. **Button 的 action 是对象不是 type！** 写法必须是 `"action": { "call": "@global.xxx", "args": {} }`，绝对不要在 action 里再套一个 `"type": "call"`！
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


@require_auth
def chat():
    """SSE 流式 AI 对话 — Claude Agent + 工具调用"""
    user_id = request.supabase_user.get("id")
    role = request.user_role

    # 配额检查
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
    agent_client = _get_agent_client(provider_id)
    agent_model = _get_agent_model(provider_id)

    # 构建 Agent 消息（过滤 system，Anthropic 用单独 system 参数）
    agent_messages = []
    for m in messages:
        if m["role"] == "system":
            continue
        content = _resolve_json_urls(m["content"])
        agent_messages.append({"role": m["role"], "content": content})

    # 系统提示
    system_prompt = AGENT_SYSTEM
    registry = _load_registry_summary()
    if registry:
        system_prompt += f"\n## 已注册的 APP 和组件\n{registry}"

    # 递增配额
    increment_quota(user_id)
    new_remaining = remaining - 1

    def generate():
        full_content = ""
        msgs = list(agent_messages)

        try:
            for iteration in range(AGENT_MAX_ITERATIONS):
                print(f"[Agent] Iteration {iteration + 1}, messages={len(msgs)}")

                response = None
                buffer = ""
                inside_json = False
                json_content = ""

                call_kwargs = {
                    "model": agent_model,
                    "max_tokens": 8192,
                    "system": system_prompt,
                    "messages": msgs,
                    "tools": AGENT_TOOLS,
                }
                if provider.get("extra_body"):
                    call_kwargs["extra_body"] = provider["extra_body"]

                try:
                    with agent_client.messages.stream(**call_kwargs) as stream:
                        for text in stream.text_stream:
                            if not inside_json:
                                buffer += text
                                if "<app_json>" in buffer:
                                    parts = buffer.split("<app_json>")
                                    if parts[0]:
                                        yield f'data: {json.dumps({"content": parts[0]}, ensure_ascii=False)}\n\n'
                                        full_content += parts[0]
                                    yield f'data: {json.dumps({"generating_json": True}, ensure_ascii=False)}\n\n'
                                    inside_json = True
                                    json_content = parts[1] if len(parts) > 1 else ""
                                    buffer = ""
                                else:
                                    # Safe yield logic to avoid splitting <app_json>
                                    if "<" in buffer:
                                        idx = buffer.rfind("<")
                                        if len(buffer) - idx < 15:
                                            safe_part = buffer[:idx]
                                            if safe_part:
                                                yield f'data: {json.dumps({"content": safe_part}, ensure_ascii=False)}\n\n'
                                                full_content += safe_part
                                            buffer = buffer[idx:]
                                        else:
                                            yield f'data: {json.dumps({"content": buffer}, ensure_ascii=False)}\n\n'
                                            full_content += buffer
                                            buffer = ""
                                    else:
                                        yield f'data: {json.dumps({"content": buffer}, ensure_ascii=False)}\n\n'
                                        full_content += buffer
                                        buffer = ""
                            else:
                                json_content += text
                                if "</app_json>" in json_content:
                                    parts = json_content.split("</app_json>")
                                    json_content = parts[0]
                                    inside_json = False
                                    
                                    # 如果模型在 </app_json> 之后还有话说，把剩下的话放回 buffer 继续跑
                                    if len(parts) > 1 and parts[1]:
                                        buffer = parts[1]
                                        # 立即发出去，防止滞留在 buffer
                                        if "<" not in buffer:
                                            yield f'data: {json.dumps({"content": buffer}, ensure_ascii=False)}\n\n'
                                            full_content += buffer
                                            buffer = ""
                                            
                        response = stream.get_final_message()
                        
                        # 循环结束后，如果有残留的安全 buffer，全刷出去
                        if buffer and not inside_json:
                            yield f'data: {json.dumps({"content": buffer}, ensure_ascii=False)}\n\n'
                            full_content += buffer
                except Exception as e:
                    print(f"[Agent] Stream failed ({e}), falling back to non-stream")
                    response = agent_client.messages.create(**call_kwargs)
                    # 非流式：手动发送文本
                    for block in response.content:
                        if block.type == 'text' and block.text:
                            full_content += block.text
                            yield f'data: {json.dumps({"content": block.text}, ensure_ascii=False)}\n\n'

                # 检查是否有工具调用
                tool_calls = [b for b in response.content if b.type == 'tool_use']
                if not tool_calls:
                    print(f"[Agent] Done after {iteration + 1} iterations")
                    break

                # 构建 assistant 消息（包含 text + tool_use blocks）
                assistant_content = []
                for block in response.content:
                    if block.type == 'text':
                        assistant_content.append({"type": "text", "text": block.text})
                    elif block.type == 'tool_use':
                        assistant_content.append({
                            "type": "tool_use",
                            "id": block.id,
                            "name": block.name,
                            "input": block.input,
                        })
                msgs.append({"role": "assistant", "content": assistant_content})

                # 执行工具
                tool_results = []
                for tc in tool_calls:
                    result = _execute_agent_tool(tc.name, tc.input)
                    print(f"[Agent] Tool {tc.name}: {len(result)} chars")
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tc.id,
                        "content": result,
                    })
                msgs.append({"role": "user", "content": tool_results})

            # JSON-APP 检测与 MinIO 上传
            json_str = ""
            if json_content and "{" in json_content:
                # 已经流式拦截了
                json_str = json_content
            else:
                # Fallback: 尝试从全量文本提取
                match = re.search(r'<app_json>\s*(\{.*?\})\s*</app_json>', full_content, re.DOTALL)
                if match:
                    json_str = match.group(1)
                else:
                    # 兼容可能输出到 Markdown 的情况
                    match = re.search(r'```(?:json|JSON)?\s*\n?\s*(\{.*?\})\s*\n?```', full_content, re.DOTALL)
                    if match:
                        json_str = match.group(1)

            print(f"[Agent] JSON detect: match={'YES' if json_str else 'NO'}, content_len={len(full_content)}")
            
            if json_str:
                # 剔除可能多余的结束标签
                if "</app_json>" in json_str:
                    json_str = json_str.split("</app_json>")[0]
                
                try:
                    fixed_app = json.loads(json_str)
                    print(f"[Agent] JSON-APP parse success, keys: {list(fixed_app.keys())}")
                    
                    # 上传到 MinIO
                    import uuid, requests
                    from store import _minio_presigned_put, _minio_presigned_get
                    
                    filename = f"gen_{uuid.uuid4().hex}.json"
                    bucket = "ai-chat-temp"
                    put_url = _minio_presigned_put(bucket, filename)
                    get_url = _minio_presigned_get(bucket, filename)
                    
                    upload_resp = requests.put(
                        put_url, 
                        data=json.dumps(fixed_app, ensure_ascii=False).encode('utf-8'),
                        headers={'Content-Type': 'application/json'}
                    )
                    
                    if upload_resp.status_code == 200:
                        yield f'data: {json.dumps({"has_json": True, "json_url": get_url}, ensure_ascii=False)}\n\n'
                        print(f"[Agent] MinIO upload success: {get_url}")
                    else:
                        yield f'data: {json.dumps({"error": f"上传 JSON 失败: HTTP {upload_resp.status_code}"}, ensure_ascii=False)}\n\n'
                except Exception as e:
                    print(f"[Agent] JSON parse or upload failed: {e}")

            # 配额
            yield f'data: {json.dumps({"quota": {"used": used + 1, "limit": limit, "remaining": new_remaining}})}\n\n'
            yield "data: [DONE]\n\n"

        except Exception as e:
            print(f"[Agent] Error: {e}")
            import traceback; traceback.print_exc()
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "Access-Control-Allow-Origin": "*"},
    )


@require_auth
def fix_app():
    """接收崩溃日志 + JSON，返回修复建议"""
    body = request.get_json(silent=True) or {}
    crash_log = body.get("crash_log", "")
    json_config = body.get("json_config", "")
    provider_id = body.get("provider")

    if not crash_log or not json_config:
        return jsonify({"error": "crash_log 和 json_config 不能为空"}), 400

    prompt = f"""以下 JSON-APP 运行时崩溃了，请修复：

## 崩溃日志
{crash_log}

## 当前 JSON
```json
{json_config if isinstance(json_config, str) else json.dumps(json_config, ensure_ascii=False, indent=2)}
```

请分析原因并输出修复后的完整 JSON（用 ```json 代码块包裹）。"""

    dsl_spec = _load_dsl_spec()
    system_prompt = f"你是 JSON-DSL 调试专家。\n\n## 规范\n{dsl_spec}"

    provider = _get_provider(provider_id)
    client = _get_agent_client(provider_id)
    model = _get_agent_model(provider_id)

    def generate():
        full_content = ""
        try:
            call_kwargs = {
                "model": model,
                "max_tokens": 8192,
                "system": system_prompt,
                "messages": [{"role": "user", "content": prompt}],
            }
            if provider.get("extra_body"):
                call_kwargs["extra_body"] = provider["extra_body"]

            with client.messages.stream(**call_kwargs) as stream:
                for text in stream.text_stream:
                    full_content += text
                    yield f'data: {json.dumps({"content": text}, ensure_ascii=False)}\n\n'

            json_match = re.search(r'```(?:json|JSON)?\s*\n?\s*(\{.*?\})\s*\n?```', full_content, re.DOTALL)
            if json_match:
                try:
                    fixed = json.loads(json_match.group(1))
                    yield f'data: {json.dumps({"has_json": True, "json_app": fixed}, ensure_ascii=False)}\n\n'
                except Exception: pass
            yield "data: [DONE]\n\n"
        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
            yield "data: [DONE]\n\n"

    return Response(stream_with_context(generate()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"})
