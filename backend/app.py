#!/usr/bin/env python3
"""
JSON DSL Backend - Flask App
主入口文件

启动: python backend/app.py
"""

import logging
from flask import Flask
from flask_socketio import SocketIO
from config import PORT
import auth
# import ai_code_generator as chat  # DEPRECATED: 已废弃，使用 claude_chat 替代
import claude_chat
import store
import im
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
    app.config['SECRET_KEY'] = 'your-secret-key'

    # 初始化 SocketIO
    socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

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
    app.add_url_rule("/chat", methods=["POST"], view_func=claude_chat.chat)
    app.add_url_rule("/api/ai/session_status", methods=["GET"], view_func=claude_chat.session_status)
    # DEPRECATED: 以下接口已废弃，使用 /chat 替代
    # app.add_url_rule("/api/ai/generate", methods=["POST"], view_func=chat.generate_app)
    # app.add_url_rule("/api/ai/fix-app", methods=["POST"], view_func=chat.fix_app)
    app.add_url_rule("/api/ai/providers", methods=["GET"], view_func=claude_chat.list_providers)
    app.add_url_rule("/api/ai/upload_url", methods=["GET"], view_func=store.get_ai_upload_url)

    # 注册 Store 路由
    app.add_url_rule("/api/store/apps", methods=["GET"], view_func=store.store_apps)
    app.add_url_rule("/api/store/components", methods=["GET"], view_func=store.store_components)
    app.add_url_rule("/api/appid/new", methods=["GET"], view_func=store.new_appid)
    app.add_url_rule("/api/store/publish", methods=["POST"], view_func=store.store_publish)
    app.add_url_rule("/api/store/delete/<app_id>", methods=["DELETE"], view_func=store.store_delete)

    # 注册 OpenIM 桥接路由
    app.add_url_rule("/api/im/token", methods=["POST"], view_func=im.get_im_token)
    app.add_url_rule("/api/im/users/lookup", methods=["GET"], view_func=im.lookup_user)

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
    logger.info("   IM:    /api/im/{token,users/lookup}")
    logger.info("   ASR:   WebSocket /socket.io (豆包语音识别)")
    logger.info("   Debug mode: ENABLED")
    socketio.run(app, host="0.0.0.0", port=PORT, debug=True, allow_unsafe_werkzeug=True)
