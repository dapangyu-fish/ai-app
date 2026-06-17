"""HTTPS 连通性测试后端（FaaS 参考样板 / e2e 测试床）。

这是配套 JSON-APP「HTTPS 测试台」(templates/https_test_lab.json) 的 FaaS 后端。
每个路由对应客户端里的一个测试用例，覆盖 GET / POST / PUT / DELETE / SSE /
带 token 的真实 Supabase 鉴权 / 任意状态码。响应全部是内存里 mock 的，不连数据库
（faasd CE 的函数无持久卷、无 DB），只有 /auth/verify 会真实出网调用 Supabase。

约束（见 backend/faas_store.py 校验器）：
- 顶层只允许 imports、`app = Flask(__name__)`、字面量常量、（路由及辅助）函数、
  可选 `__main__` guard；顶层不得有任何函数调用 / IO / 循环。
- 允许的 import 根：__future__ base64 collections dateutil datetime decimal flask
  functools hashlib hmac itertools json math pydantic random re statistics string
  time typing urllib uuid。（urllib 是为本样板的真实 Supabase 调用新加的。）
- 方法装饰器只有 @app.get/post/put/patch/delete；其它方法用 @app.route(methods=[...])。
- /__myapp_faas_health 由运行时自动提供，不要自己写。
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from datetime import datetime, timezone

from flask import Flask, Response, jsonify, request

app = Flask(__name__)

SERVICE_NAME = "https-test-lab"

# Supabase (GoTrue) 鉴权端点 + 公开 anon key。anon key 是设计上可公开的客户端密钥，
# 可以安全地写进 app.py。真正敏感的 service_role / JWT secret 绝不在这里出现。
SUPABASE_URL = "https://myapp-pre-de-auth.dapangyu.work"
SUPABASE_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzgxMTU5MjgzLCJleHAiOjE5Mzg4MzkyODN9."
    "rIOJUpfSYV9p6h2LrklvfHdXcUZUUKdGY-yhClkOvhA"
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _verify_supabase_token(token: str):
    """真实调用 Supabase GoTrue 的 GET /auth/v1/user 校验用户 JWT。

    返回 (http_status, user_dict_or_None)。status==0 表示根本没连上 Supabase。
    """
    req = urllib.request.Request(
        SUPABASE_URL + "/auth/v1/user",
        headers={
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as exc:
        # token 无效时 GoTrue 返回 401/403 —— 这是「真实鉴权」的预期失败路径
        return exc.code, None
    except Exception:
        return 0, None


@app.get("/ping")
def ping():
    """最基础的 GET 存活探针。"""
    return jsonify(
        ok=True,
        service=SERVICE_NAME,
        method="GET",
        time=_now_iso(),
        message="pong",
    )


@app.get("/echo")
def echo_get():
    """回显 query 参数，验证 GET + 查询字符串透传。"""
    return jsonify(
        ok=True,
        method="GET",
        query={key: value for key, value in request.args.items()},
        time=_now_iso(),
    )


@app.post("/echo")
def echo_post():
    """回显 JSON body，验证 POST + 请求体透传。"""
    body = request.get_json(silent=True)
    if body is None:
        body = {}
    keys = list(body.keys()) if isinstance(body, dict) else []
    return jsonify(
        ok=True,
        method="POST",
        received=body,
        field_count=len(keys),
        time=_now_iso(),
    ), 201


@app.put("/items/<item_id>")
def update_item(item_id):
    """按 id 更新一条 mock 资源，验证 PUT + 动态路径段。"""
    body = request.get_json(silent=True) or {}
    return jsonify(
        ok=True,
        method="PUT",
        id=item_id,
        updated_fields=list(body.keys()) if isinstance(body, dict) else [],
        item={"id": item_id, **(body if isinstance(body, dict) else {})},
        time=_now_iso(),
    )


@app.delete("/items/<item_id>")
def delete_item(item_id):
    """按 id 删除一条 mock 资源，验证 DELETE + 动态路径段。"""
    return jsonify(ok=True, method="DELETE", id=item_id, deleted=True, time=_now_iso())


@app.get("/headers")
def show_headers():
    """回显函数实际收到的请求头。

    用来直观看到 invoke 代理会剥掉哪些头：客户端发的 Authorization / Cookie
    到不了这里（被代理过滤），而自定义头（如 X-User-Token）能透传过来。
    """
    received = {key: value for key, value in request.headers.items()}
    return jsonify(
        ok=True,
        method="GET",
        received_headers=received,
        has_authorization="Authorization" in received,
        has_x_user_token="X-User-Token" in received,
        note="Authorization/Cookie 会被 invoke 代理剥离；自定义头可透传",
        time=_now_iso(),
    )


@app.get("/stream")
def stream():
    """SSE 流式响应，验证 text/event-stream 透传与客户端逐帧解析。

    连续推送 5 个 tick 事件再发一个 done。不 sleep（避免冷启动叠加超时），
    重点是验证 content-type 与 data: 帧能否一路传到客户端。
    """

    def generate():
        for index in range(1, 6):
            payload = json.dumps({"tick": index, "service": SERVICE_NAME})
            yield "event: tick\n"
            yield "data: " + payload + "\n\n"
        yield "event: done\n"
        yield "data: " + json.dumps({"ok": True, "total": 5}) + "\n\n"

    return Response(generate(), mimetype="text/event-stream")


@app.post("/auth/verify")
def auth_verify():
    """带 token 的真实鉴权用例。

    客户端用 JSON 层的 @get_auth_token 拿到用户 token，放进自定义头 X-User-Token
    （Authorization 会被代理剥掉，所以必须用自定义头或 body）。本函数把它转成
    Bearer，真实调用 Supabase /auth/v1/user 验证，并回传裁决结果。
    """
    token = (request.headers.get("X-User-Token") or "").strip()
    if not token:
        body = request.get_json(silent=True) or {}
        token = str(body.get("token") or "").strip()
    if not token:
        return jsonify(
            ok=False,
            authenticated=False,
            reason="缺少用户 token（请用 X-User-Token 头或 body.token 传入）",
            time=_now_iso(),
        ), 400

    status, user = _verify_supabase_token(token)
    if status == 200 and isinstance(user, dict):
        return jsonify(
            ok=True,
            authenticated=True,
            supabase_status=status,
            user={
                "id": user.get("id"),
                "email": user.get("email"),
                "role": user.get("role"),
            },
            time=_now_iso(),
        )
    if status == 0:
        return jsonify(
            ok=False,
            authenticated=False,
            supabase_status=0,
            reason="无法连接 Supabase",
            time=_now_iso(),
        ), 502
    return jsonify(
        ok=True,
        authenticated=False,
        supabase_status=status,
        reason="Supabase 拒绝了该 token",
        time=_now_iso(),
    )


@app.get("/status/<int:code>")
def force_status(code):
    """按需返回任意状态码，验证客户端的错误/非 2xx 处理路径。"""
    safe_code = code if 200 <= code <= 599 else 400
    return jsonify(ok=safe_code < 400, requested_status=safe_code, time=_now_iso()), safe_code


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
