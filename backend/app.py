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

import logging
import secrets
from flask import Flask
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

    # 注册 Auth 路由
    app.add_url_rule("/api/auth/register", methods=["POST"], view_func=auth.register)
    app.add_url_rule("/api/auth/verify", methods=["POST"], view_func=auth.verify_otp)
    app.add_url_rule("/api/auth/resend", methods=["POST"], view_func=auth.resend_verification)
    app.add_url_rule("/api/auth/login", methods=["POST"], view_func=auth.login)
    app.add_url_rule("/api/auth/refresh", methods=["POST"], view_func=auth.refresh_token)
    app.add_url_rule("/api/auth/logout", methods=["POST"], view_func=auth.logout)
    app.add_url_rule("/api/auth/user", methods=["GET"], view_func=auth.get_user)
    app.add_url_rule("/api/auth/user", methods=["PUT"], view_func=auth.update_user)
    app.add_url_rule("/api/auth/avatar", methods=["POST"], view_func=auth.upload_avatar)
    app.add_url_rule("/api/auth/quota", methods=["GET"], view_func=auth.get_quota)

    # 注册 Chat 路由
    app.add_url_rule("/api/ai/session_status", methods=["GET"], view_func=claude_chat.session_status)
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

    # 注册 Store 路由
    app.add_url_rule("/api/store/apps", methods=["GET"], view_func=store.store_apps)
    app.add_url_rule("/api/store/components", methods=["GET"], view_func=store.store_components)
    app.add_url_rule("/api/appid/new", methods=["GET"], view_func=store.new_appid)
    app.add_url_rule("/api/store/publish", methods=["POST"], view_func=store.store_publish)
    app.add_url_rule("/api/store/delete/<app_id>", methods=["DELETE"], view_func=store.store_delete)

    # 注册 OpenIM 桥接路由
    app.add_url_rule("/api/im/token", methods=["POST"], view_func=im.get_im_token)
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


if __name__ == "__main__":
    logger = logging.getLogger(__name__)
    logger.info(f"🚀 JSON DSL Backend on http://0.0.0.0:{PORT}")
    logger.info("   Auth:  /api/auth/{register,login,verify,refresh,logout,user,avatar,quota}")
    logger.info("   Chat:  POST /chat (SSE, quota-limited, DSL-aware)")
    logger.info("   Store: /api/store/{apps,components,publish,delete}")
    logger.info("   IM:    /api/im/{token,users/lookup,users/search,push_token,media/upload-url,after_send_msg,offline_push_hook}")
    logger.info("   ASR:   WebSocket /socket.io (豆包语音识别)")
    logger.info("   ⚠️  本地开发模式（werkzeug）；生产用 gunicorn -k eventlet -w <N> app:app + ai_worker_daemon.py")
    socketio.run(app, host="0.0.0.0", port=PORT, allow_unsafe_werkzeug=True)
