#!/usr/bin/env python3
"""
JSON DSL Backend - Flask App
主入口文件

生产: gunicorn -k eventlet -w <N> -b 0.0.0.0:5566 app:app
      AI 任务由独立 ai_worker_daemon.py 消费 Redis 队列，不依赖 gunicorn 进程内存。
开发: python backend/app.py（用 socketio.run 的 werkzeug，仅本地）
"""

# eventlet monkey_patch 必须在所有其他 import 之前，否则 stdlib 已加载就来不及了。
# 只在 gunicorn eventlet worker 下生效；本地直跑 socketio.run 时也兼容（patch 是幂等的）。
import eventlet
eventlet.monkey_patch()
# psycopg2 是 C 扩展，默认不与 eventlet 协作：在 eventlet worker 下一条阻塞查询会冻结
# 整个 hub（该 worker 的所有 greenlet，含 SocketIO/SSE/FaaS data-gateway）。psycogreen
# 给 libpq 装 wait-callback，让查询在等待网络时让出 hub，使 -w N 真正并发 DB I/O。
# 必须在 monkey_patch 之后、任何 psycopg2 连接之前执行（见 RFC pgbouncer §7 P0-1）。
from psycogreen.eventlet import patch_psycopg as _patch_psycopg
_patch_psycopg()

import logging
import secrets
import os
from flask import Flask, request, jsonify
from flask_socketio import SocketIO
from config import PORT, FLASK_SECRET_KEY
import auth
# import ai_code_generator as chat  # DEPRECATED: 已废弃，使用 claude_chat 替代
import claude_chat
import ai_session
import agent_nodes
import store
import im
import im_media
import ai_summary
import faas
from bytedance_asr_routes import register_asr_routes

# 配置日志
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)


def create_app():
    """创建 Flask 应用"""
    app = Flask(__name__)
    if FLASK_SECRET_KEY:
        app.config['SECRET_KEY'] = FLASK_SECRET_KEY
    else:
        # 本地开发兜底：进程级随机值，重启后失效。生产必须在 .env 里给真值。
        app.config['SECRET_KEY'] = secrets.token_hex(32)
        logging.getLogger(__name__).warning(
            "FLASK_SECRET_KEY 未配置，已生成临时随机值（仅适合本地开发；生产请在 backend.env 里配置）"
        )

    # 初始化 SocketIO
    # async_mode='eventlet' 配合上面 monkey_patch + gunicorn eventlet worker，是 Flask-SocketIO
    # 官方推荐的生产组合（裸 WebSocket 客户端 → 必须协程 worker，gthread 撑不起）
    socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

    # ── CORS（Web 端跨域）──────────────────────────────────────────
    # Web 客户端从自己的源请求后端，浏览器强制 CORS。后端（REST）此前没补 CORS 头，
    # 导致 Flutter Web 切到本后端时预检/请求被浏览器拦下（移动端不受影响）。
    # 给所有响应（含 Flask 自动处理的 OPTIONS 预检）补 Access-Control-* 头。
    # CORS_ALLOWED_ORIGINS：逗号分隔的源白名单；为空或含 "*" → 反射任意 Origin（pre-de/demo 用）。
    _cors_allow = [o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "*").split(",") if o.strip()]

    @app.before_request
    def _cors_preflight():
        # 跨域预检（带 Origin 的 OPTIONS）一律直接 204 放行，CORS 头由 after_request 补。
        # 否则像 /api/faas/invoke/<svc>/<route> 这种只声明了 POST 的代理路由，预检会被当成
        # 「未声明方法」返回 405 → 浏览器判定预检失败 → 报 CORS。这里在路由/鉴权之前短路掉。
        if request.method == "OPTIONS" and request.headers.get("Origin"):
            return ("", 204)
        return None

    @app.after_request
    def _add_cors_headers(resp):
        origin = request.headers.get("Origin")
        if origin and ("*" in _cors_allow or origin in _cors_allow):
            # 反射具体 Origin（而非 "*"），这样 Allow-Credentials 才生效、且支持带 token 的请求
            resp.headers["Access-Control-Allow-Origin"] = origin
            resp.headers.setdefault("Vary", "Origin")
            resp.headers["Access-Control-Allow-Credentials"] = "true"
            resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
            resp.headers["Access-Control-Allow-Headers"] = (
                request.headers.get("Access-Control-Request-Headers")
                or "Content-Type, Authorization, X-Requested-With"
            )
            resp.headers["Access-Control-Max-Age"] = "86400"
        return resp

    # ── 版本/构建溯源端点（公开，无鉴权）─────────────────────────
    # 见 docs/planning/version-management.md §3.8：运行实例自报平台版本/构建。
    _build_commit = (os.environ.get("MYAPP_BUILD_COMMIT") or "unknown").strip()[:128] or "unknown"
    _build_version = (os.environ.get("MYAPP_BUILD_VERSION") or _build_commit).strip()[:128] or _build_commit
    _app_version = (os.environ.get("MYAPP_VERSION") or "unknown").strip()[:64] or "unknown"
    logging.getLogger(__name__).info(
        "myapp backend version=%s build_commit=%s", _app_version, _build_commit
    )

    def _version_handler():
        return jsonify({
            "service": "myapp-backend",
            "version": _app_version,
            "build_commit": _build_commit,
            "build_version": _build_version,
            "dsl_supported": "3.3",
        })

    app.add_url_rule("/version", methods=["GET"], view_func=_version_handler)

    # 注册 Auth 路由
    app.add_url_rule("/api/auth/register", methods=["POST"], view_func=auth.register)
    app.add_url_rule("/api/auth/verify", methods=["POST"], view_func=auth.verify_otp)
    app.add_url_rule("/api/auth/resend", methods=["POST"], view_func=auth.resend_verification)
    app.add_url_rule("/api/auth/login", methods=["POST"], view_func=auth.login)
    app.add_url_rule("/api/auth/demo", methods=["POST"], view_func=auth.demo_login)
    app.add_url_rule("/api/auth/refresh", methods=["POST"], view_func=auth.refresh_token)
    app.add_url_rule("/api/auth/logout", methods=["POST"], view_func=auth.logout)
    app.add_url_rule("/api/auth/user", methods=["GET"], view_func=auth.get_user)
    app.add_url_rule("/api/auth/user", methods=["PUT"], view_func=auth.update_user)
    app.add_url_rule("/api/auth/avatar", methods=["POST"], view_func=auth.upload_avatar)
    app.add_url_rule("/api/auth/quota", methods=["GET"], view_func=auth.get_quota)

    # 注册 Chat 路由
    # 新路径（feat/ai-background-push）：worker 与 HTTP 解耦，支持后台续跑 + SSE 重连
    # 详见 backend/ARCHITECTURE.md §3
    app.add_url_rule("/api/ai/chat/start", methods=["POST"], view_func=claude_chat.chat_start)
    app.add_url_rule("/api/ai/chat/<session_id>/stream_token", methods=["POST"], view_func=claude_chat.chat_stream_token)
    app.add_url_rule("/api/ai/chat/<session_id>/stream", methods=["GET"], view_func=claude_chat.chat_stream)
    app.add_url_rule("/api/ai/chat/<session_id>/result", methods=["GET"], view_func=claude_chat.chat_result)
    app.add_url_rule("/api/ai/chat/<session_id>/status", methods=["GET"], view_func=claude_chat.chat_status_v2)
    app.add_url_rule("/api/ai/chat/<session_id>/abort", methods=["POST"], view_func=claude_chat.chat_abort)
    app.add_url_rule("/api/ai/providers", methods=["GET"], view_func=claude_chat.list_providers)
    app.add_url_rule("/api/ai/agents", methods=["GET"], view_func=claude_chat.list_agents)
    app.add_url_rule("/api/ai/agent_nodes", methods=["GET"], view_func=agent_nodes.list_agent_nodes)
    app.add_url_rule("/api/ai/agent_nodes/<node_id>", methods=["GET"], view_func=agent_nodes.get_agent_node)
    app.add_url_rule("/api/ai/agent_nodes/<node_id>/pause", methods=["POST"], view_func=agent_nodes.pause_agent_node)
    app.add_url_rule("/api/ai/agent_nodes/<node_id>/resume", methods=["POST"], view_func=agent_nodes.resume_agent_node)
    app.add_url_rule("/api/ai/agent_nodes/<node_id>", methods=["DELETE"], view_func=agent_nodes.delete_agent_node)
    app.add_url_rule("/api/ai/agent_nodes/register", methods=["POST"], view_func=agent_nodes.register_agent_node)
    app.add_url_rule("/api/ai/private_agent/nodes", methods=["GET"], view_func=agent_nodes.list_private_agent_nodes)
    app.add_url_rule("/api/ai/private_agent/nodes/self", methods=["GET"], view_func=agent_nodes.get_private_agent_node_self)
    app.add_url_rule("/api/ai/private_agent/join_token", methods=["POST"], view_func=agent_nodes.create_private_agent_join_token)
    app.add_url_rule("/api/ai/private_agent/nodes", methods=["POST"], view_func=agent_nodes.create_private_agent_node)
    app.add_url_rule("/api/ai/private_agent/nodes/<node_id>", methods=["DELETE"], view_func=agent_nodes.delete_private_agent_node)
    app.add_url_rule("/api/ai/private_agent/nodes/<node_id>/pause", methods=["POST"], view_func=agent_nodes.pause_private_agent_node)
    app.add_url_rule("/api/ai/private_agent/nodes/<node_id>/resume", methods=["POST"], view_func=agent_nodes.resume_private_agent_node)
    app.add_url_rule("/api/ai/private_agent/nodes/<node_id>/limits", methods=["POST"], view_func=agent_nodes.set_private_agent_node_limits)
    app.add_url_rule("/api/ai/agent_pull/acquire", methods=["POST"], view_func=ai_session.agent_pull_acquire)
    app.add_url_rule("/api/ai/agent_pull/jobs/<run_id>/events", methods=["POST"], view_func=ai_session.agent_pull_job_events)
    app.add_url_rule("/api/ai/agent_pull/jobs/<run_id>/artifact", methods=["POST"], view_func=ai_session.agent_pull_job_artifact)
    app.add_url_rule("/api/ai/upload_url", methods=["GET"], view_func=store.get_ai_upload_url)
    # Registry 富化用的单次结构化摘要（内部接口，registry enrich worker 调，REGISTRY_ADMIN_TOKEN 鉴权）
    app.add_url_rule("/api/ai/summarize", methods=["POST"], view_func=ai_summary.summarize_endpoint)

    # 用户生成后端服务：FaaS 控制面。当前 FaaS invoke 暂不强制鉴权；
    # 管理接口在 FAAS_REQUIRE_AUTH=0 时也允许测试用 user_id 参数，后续可收紧。
    app.add_url_rule("/api/faas/health", methods=["GET"], view_func=faas.health)
    # B3-G1: backend-mediated data-access gateway for FaaS functions (myapp_data).
    app.add_url_rule("/api/faas/data", methods=["POST"], view_func=faas.faas_data_gateway)
    # B3-G8: owner-scoped Application management API (consumed by the client UI).
    app.add_url_rule("/api/faas/apps", methods=["GET"], view_func=faas.list_my_applications)
    app.add_url_rule("/api/faas/apps/<app_id>", methods=["GET"], view_func=faas.get_my_application)
    app.add_url_rule("/api/faas/apps/<app_id>", methods=["DELETE"], view_func=faas.delete_my_application)
    app.add_url_rule("/api/faas/apps/<app_id>/policy", methods=["POST"], view_func=faas.set_my_application_policy)
    app.add_url_rule("/api/faas/apps/<app_id>/maintainers", methods=["POST"], view_func=faas.add_my_maintainer)
    app.add_url_rule("/api/faas/apps/<app_id>/maintainers/<user_id>", methods=["DELETE"], view_func=faas.remove_my_maintainer)
    app.add_url_rule("/api/faas/apps/<app_id>/grants", methods=["POST"], view_func=faas.grant_my_consumer)
    app.add_url_rule("/api/faas/apps/<app_id>/grants/<user_id>", methods=["DELETE"], view_func=faas.revoke_my_consumer)
    app.add_url_rule("/api/faas/audit", methods=["GET"], view_func=faas.list_my_audit)
    app.add_url_rule("/api/faas/services", methods=["GET"], view_func=faas.list_user_services)
    app.add_url_rule("/api/faas/services", methods=["POST"], view_func=faas.deploy_service)
    app.add_url_rule("/api/faas/services/<service_id>", methods=["GET"], view_func=faas.get_user_service)
    app.add_url_rule("/api/faas/services/<service_id>", methods=["DELETE"], view_func=faas.disable_user_service)
    app.add_url_rule(
        "/api/faas/services/<service_id>/archive",
        methods=["GET"],
        view_func=faas.download_service_archive,
    )
    app.add_url_rule(
        "/api/faas/services/<service_id>/scale",
        methods=["POST"],
        view_func=faas.scale_user_service,
    )
    app.add_url_rule(
        "/api/faas/runtime_bundle/<service_id>",
        methods=["GET"],
        view_func=faas.runtime_bundle,
    )
    app.add_url_rule(
        "/api/faas/invoke/<service_id>",
        defaults={"route_path": ""},
        methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        view_func=faas.invoke_service,
    )
    app.add_url_rule(
        "/api/faas/invoke/<service_id>/<path:route_path>",
        methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        view_func=faas.invoke_service,
    )

    # 注册 Store 路由
    app.add_url_rule("/api/store/apps", methods=["GET"], view_func=store.store_apps)
    app.add_url_rule("/api/store/components", methods=["GET"], view_func=store.store_components)
    app.add_url_rule("/api/appid/new", methods=["GET"], view_func=store.new_appid)
    app.add_url_rule("/api/store/publish", methods=["POST"], view_func=store.store_publish)
    app.add_url_rule("/api/store/delete/<app_id>", methods=["DELETE"], view_func=store.store_delete)

    # 注册 OpenIM 桥接路由
    app.add_url_rule("/api/im/token", methods=["POST"], view_func=im.get_im_token)
    app.add_url_rule("/api/im/friends", methods=["GET"], view_func=im.list_friends)
    app.add_url_rule("/api/im/users/lookup", methods=["GET"], view_func=im.lookup_user)
    app.add_url_rule("/api/im/users/search", methods=["GET"], view_func=im.search_users)
    app.add_url_rule("/api/im/users/profiles", methods=["GET"], view_func=im.user_profiles)
    app.add_url_rule("/api/im/push_token", methods=["POST"], view_func=im.upload_push_token)
    app.add_url_rule("/api/im/push_token", methods=["DELETE"], view_func=im.remove_push_token)
    # IM 富媒体上传：客户端拿预签名 PUT 直传 MinIO，避免大文件经 Flask
    app.add_url_rule("/api/im/media/upload-url", methods=["POST"], view_func=im_media.upload_url)
    # 当前在用：afterSendSingleMsg webhook → 后端按平台分发（详见 PUSH_ARCHITECTURE.md）
    app.add_url_rule(
        "/api/im/after_send_msg",
        methods=["POST"],
        view_func=im.after_send_msg,
    )
    # 旧入口保留：以前接 beforeOfflinePush，OpenIM v3.8 实测不会触发，改用 after_send_msg
    # 不主动用，但保留路由以便切回时无需改代码
    app.add_url_rule(
        "/api/im/offline_push_hook",
        methods=["POST"],
        view_func=im.offline_push_hook,
    )

    # 注册豆包ASR WebSocket路由
    register_asr_routes(socketio)

    return app, socketio


app, socketio = create_app()

# Self-managed Docker FaaS: start the scale-to-zero reaper (flock-guarded so only
# one worker reaps). Only in docker deploy mode; the invoke proxy cold-wakes.
try:
    from config import FAAS_DEPLOY_MODE as _FAAS_DEPLOY_MODE
    if str(_FAAS_DEPLOY_MODE or "").strip().lower() in {"local-docker", "docker", "docker-local"}:
        import threading as _threading
        from faas_docker_reaper import run_loop as _faas_reaper_loop
        _threading.Thread(target=_faas_reaper_loop, name="faas-docker-reaper", daemon=True).start()
except Exception:
    pass


if __name__ == "__main__":
    logger = logging.getLogger(__name__)
    logger.info(f"🚀 JSON DSL Backend on http://0.0.0.0:{PORT}")
    logger.info("   Auth:  /api/auth/{register,login,verify,refresh,logout,user,avatar,quota}")
    logger.info("   Chat:  /api/ai/chat/{start,stream,result,status,abort}")
    logger.info("   Store: /api/store/{apps,components,publish,delete}")
    logger.info("   IM:    /api/im/{token,friends,users/lookup,users/search,push_token,media/upload-url,after_send_msg,offline_push_hook}")
    logger.info("   ASR:   WebSocket /socket.io (豆包语音识别)")
    logger.info("   ⚠️  本地开发模式（werkzeug）；生产用 gunicorn -k eventlet -w <N> app:app + ai_worker_daemon.py")
    socketio.run(app, host="0.0.0.0", port=PORT, allow_unsafe_werkzeug=True)
