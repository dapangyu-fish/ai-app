#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
豆包ASR WebSocket路由
"""

import base64
import logging
from flask import request
from flask_socketio import emit
from auth import require_auth_socketio
from database import get_quota_info, increment_quota
from config import ROLE_QUOTAS
from bytedance_asr_service import ByteDanceASRProxy

logger = logging.getLogger(__name__)

# 存储每个客户端的 ASR 代理
asr_proxies = {}


def register_asr_routes(socketio):
    """注册豆包ASR WebSocket路由"""

    @socketio.on('asr_connect')
    @require_auth_socketio
    def handle_asr_connect():
        """客户端连接"""
        client_sid = request.sid
        user_id = request.supabase_user.get("id")
        role = request.user_role

        logger.info(f"[ASR] Client connected - sid: {client_sid}, user: {user_id}, role: {role}")
        emit('asr_connected', {'status': 'ok'})

    @socketio.on('asr_disconnect')
    def handle_asr_disconnect():
        """客户端断开"""
        client_sid = request.sid
        logger.info(f"[ASR] Client disconnected - sid: {client_sid}")

        # 清理 ASR 代理
        if client_sid in asr_proxies:
            proxy = asr_proxies[client_sid]
            proxy.close()
            del asr_proxies[client_sid]

    @socketio.on('asr_start')
    @require_auth_socketio
    def handle_asr_start(data):
        """开始识别 - 需要鉴权和配额检查"""
        client_sid = request.sid
        user_id = request.supabase_user.get("id")
        role = request.user_role

        logger.info(f"[ASR] Start recognition - user: {user_id}, role: {role}")

        # 检查配额
        used, limit, remaining = get_quota_info(user_id, role, ROLE_QUOTAS)
        logger.info(f"[ASR] Quota - used: {used}, limit: {limit}, remaining: {remaining}")

        if remaining <= 0:
            logger.warning(f"[ASR] Quota exceeded - user: {user_id}")
            emit('asr_error', {
                'type': 'error',
                'message': '今日配额已用完',
                'quota': {'used': used, 'limit': limit, 'remaining': 0}
            })
            return

        # 扣除配额
        increment_quota(user_id)
        new_remaining = remaining - 1
        logger.info(f"[ASR] Quota deducted, remaining: {new_remaining}")

        # 创建 ASR 代理
        proxy = ByteDanceASRProxy(client_sid, socketio)
        asr_proxies[client_sid] = proxy

        # 连接到字节跳动 ASR
        success = proxy.connect()

        if success:
            emit('asr_started', {
                'status': 'ok',
                'quota': {'used': used + 1, 'limit': limit, 'remaining': new_remaining}
            })
        else:
            emit('asr_error', {
                'type': 'error',
                'message': 'Failed to connect to ASR service'
            })

    @socketio.on('asr_audio')
    def handle_asr_audio(data):
        """接收音频数据"""
        client_sid = request.sid

        if client_sid not in asr_proxies:
            emit('asr_error', {
                'type': 'error',
                'message': 'ASR proxy not initialized'
            })
            return

        proxy = asr_proxies[client_sid]

        try:
            # 解码 base64 音频数据
            audio_base64 = data.get('data', '')
            is_last = data.get('is_last', False)

            if audio_base64:
                audio_bytes = base64.b64decode(audio_base64)
                # 发送到字节跳动 ASR
                proxy.send_audio(audio_bytes, is_last=is_last)

            if is_last:
                logger.info(f"[ASR] Last audio packet - sid: {client_sid}")
        except Exception as e:
            logger.error(f"[ASR] Handle audio error: {e}")
            emit('asr_error', {
                'type': 'error',
                'message': str(e)
            })
