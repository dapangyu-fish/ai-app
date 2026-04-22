#!/usr/bin/env python3
"""
JSON DSL Backend - Flask App
主入口文件

启动: python backend/app.py
"""

from flask import Flask
from flask_sock import Sock
from config import PORT
import auth
import ai_code_generator as chat
import store


def create_app():
    """创建 Flask 应用"""
    app = Flask(__name__)
    sock = Sock(app)

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
    app.add_url_rule("/chat", methods=["POST"], view_func=chat.chat)
    app.add_url_rule("/api/ai/fix-app", methods=["POST"], view_func=chat.fix_app)
    app.add_url_rule("/api/ai/providers", methods=["GET"], view_func=chat.list_providers)

    # 注册 Store 路由
    app.add_url_rule("/api/store/apps", methods=["GET"], view_func=store.store_apps)
    app.add_url_rule("/api/store/components", methods=["GET"], view_func=store.store_components)
    app.add_url_rule("/api/appid/new", methods=["GET"], view_func=store.new_appid)
    app.add_url_rule("/api/store/publish", methods=["POST"], view_func=store.store_publish)
    app.add_url_rule("/api/store/delete/<app_id>", methods=["DELETE"], view_func=store.store_delete)

    return app


app = create_app()


if __name__ == "__main__":
    print(f"🚀 JSON DSL Backend on http://0.0.0.0:{PORT}")
    print("   Auth:  /api/auth/{register,login,verify,refresh,logout,user,avatar,quota}")
    print("   Chat:  POST /chat (SSE, quota-limited, DSL-aware)")
    print("   Fix:   POST /api/ai/fix-app (crash repair)")
    print("   Store: /api/store/{apps,components,publish,delete}")
    app.run(host="0.0.0.0", port=PORT, debug=False)
