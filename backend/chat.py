#!/usr/bin/env python3
"""
聊天模块 - AI 对话和 JSON App 生成
"""

import json
import os
import re
import anthropic
import requests
from flask import request, jsonify, Response, stream_with_context
from config import (
    DEEPSEEK_URL, DEEPSEEK_KEY, DEEPSEEK_MODEL,
    DSL_SPEC_PATH, PROJECT_ROOT, AGENT_MODEL,
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
1. 先理解用户需求
2. 生成 JSON-APP 前，必须用工具查阅框架代码，确认内置函数和组件确实存在
3. 参考 templates/ 目录下的已有模板 APP，学习正确的 JSON 结构和用法
4. 用 ```json ... ``` 代码块包裹完整可运行的 JSON-APP
5. 回复简洁（用户在手机上看字幕）

## 工具使用指引
- read_file: 读取框架源码或模板文件
- search_code: 搜索代码关键词
- list_builtin_functions: 获取所有可用 @函数列表
- list_templates: 列出所有可参考的模板 APP

## 生成 JSON-APP 的标准流程
1. 先调 list_builtin_functions 确认可用函数
2. 调 list_templates 查看有哪些模板
3. 用 read_file 读取一个相似的模板作为参考
4. 基于模板结构和真实函数生成 JSON-APP

## 输出要求
- JSON 必须包含 meta（name/version/type:"app"/description/icon_url）
- 只使用工具确认存在的 @函数和组件类型
- 不要自创框架中不存在的函数或属性
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


# 初始化 Agent 客户端
_agent_client = anthropic.Anthropic(
    base_url="https://api.deepseek.com/anthropic",
    api_key=DEEPSEEK_KEY,
)


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

    # 构建 Agent 消息（过滤 system，Anthropic 用单独 system 参数）
    agent_messages = []
    for m in messages:
        if m["role"] == "system":
            continue
        agent_messages.append({"role": m["role"], "content": m["content"]})

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

                # 流式调用 — 文本实时推送给客户端，工具调用在结束后处理
                response = None
                try:
                    with _agent_client.messages.stream(
                        model=AGENT_MODEL,
                        max_tokens=8192,
                        system=system_prompt,
                        messages=msgs,
                        tools=AGENT_TOOLS,
                    ) as stream:
                        for text in stream.text_stream:
                            full_content += text
                            yield f'data: {json.dumps({"content": text}, ensure_ascii=False)}\n\n'
                        response = stream.get_final_message()
                except Exception as e:
                    # 流式不支持时 fallback 到非流式
                    print(f"[Agent] Stream failed ({e}), falling back to non-stream")
                    response = _agent_client.messages.create(
                        model=AGENT_MODEL,
                        max_tokens=8192,
                        system=system_prompt,
                        messages=msgs,
                        tools=AGENT_TOOLS,
                    )
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

            # JSON-APP 检测
            json_match = re.search(r'```(?:json|JSON)?\s*\n?\s*(\{.*?\})\s*\n?```', full_content, re.DOTALL)
            if not json_match:
                json_match = re.search(r'(\{[\s\S]*"screens"[\s\S]*\})\s*$', full_content)
            print(f"[Agent] JSON detect: match={'YES' if json_match else 'NO'}, content_len={len(full_content)}")
            if json_match:
                try:
                    json_app = json.loads(json_match.group(1))
                    yield f'data: {json.dumps({"has_json": True, "json_app": json_app}, ensure_ascii=False)}\n\n'
                    print(f"[Agent] JSON-APP sent, keys: {list(json_app.keys())}")
                except json.JSONDecodeError as e:
                    print(f"[Agent] JSON parse failed: {e}")

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

    if not crash_log or not json_config:
        return jsonify({"error": "crash_log 和 json_config 不能为空"}), 400

    # 不额外消耗配额，但需要登录
    prompt = f"""以下 JSON-APP 运行时崩溃了，请修复：

## 崩溃日志
{crash_log}

## 当前 JSON
```json
{json_config if isinstance(json_config, str) else json.dumps(json_config, ensure_ascii=False, indent=2)}
```

请分析原因并输出修复后的完整 JSON（用 ```json 代码块包裹）。"""

    dsl_spec = _load_dsl_spec()
    messages = [
        {"role": "system", "content": f"你是 JSON-DSL 调试专家。\n\n## 规范\n{dsl_spec}"},
        {"role": "user", "content": prompt},
    ]

    def generate():
        full_content = ""
        try:
            resp = requests.post(
                DEEPSEEK_URL,
                headers={"Content-Type": "application/json",
                         "Authorization": f"Bearer {DEEPSEEK_KEY}"},
                json={"model": DEEPSEEK_MODEL, "messages": messages, "stream": True},
                stream=True, timeout=120,
            )
            for line in resp.iter_lines(decode_unicode=True):
                if not line: continue
                if line.startswith("data:"):
                    data_str = line[5:].strip()
                    if data_str == "[DONE]": break
                    try:
                        chunk = json.loads(data_str)
                        content = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                        if content:
                            full_content += content
                            yield f'data: {json.dumps({"content": content}, ensure_ascii=False)}\n\n'
                    except Exception: pass

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
