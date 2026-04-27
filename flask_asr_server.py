#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Flask WebSocket 服务器 - 字节跳动语音识别代理
客户端 <-> Flask <-> 字节跳动 ASR
"""

import json
import base64
import struct
import gzip
import uuid
import logging
import threading
import queue
from flask import Flask, request
from flask_socketio import SocketIO, emit
import websocket

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

app = Flask(__name__)
app.config['SECRET_KEY'] = 'your-secret-key'
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

# 字节跳动 ASR 配置
APP_KEY = "5982591805"
ACCESS_KEY = "j5JzySkHs2ncLKrFxy6TAYZDDDmrpMEa"
SECRET_KEY = "RWAnUTmUEGUysStn-R0phBxqThMoe0o0"
RESOURCE_ID = "volc.bigasr.sauc.duration"
WS_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"

# 音频参数
SAMPLE_RATE = 16000
CHANNELS = 1


class ByteDanceASRProxy:
    """字节跳动 ASR 代理（使用 websocket-client 库）"""

    def __init__(self, client_sid):
        self.client_sid = client_sid
        self.ws = None
        self.sequence = 0
        self.audio_queue = queue.Queue()
        self.running = False
        self.receive_thread = None

    def create_header(self, message_type, message_flags, serialization, compression):
        """创建协议头（4字节）"""
        byte0 = (0b0001 << 4) | 0b0001
        byte1 = (message_type << 4) | message_flags
        byte2 = (serialization << 4) | compression
        byte3 = 0x00
        return struct.pack('BBBB', byte0, byte1, byte2, byte3)

    def create_full_client_request(self):
        """创建 full client request"""
        request_data = {
            "user": {"uid": str(uuid.uuid4())},
            "audio": {
                "format": "pcm",
                "codec": "raw",
                "rate": SAMPLE_RATE,
                "bits": 16,
                "channel": CHANNELS
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
                "enable_ddc": False,
                "result_type": "full"
            }
        }

        payload_json = json.dumps(request_data, ensure_ascii=False).encode('utf-8')
        payload_compressed = gzip.compress(payload_json)

        header = self.create_header(
            message_type=0b0001,
            message_flags=0b0001,
            serialization=0b0001,
            compression=0b0001
        )

        self.sequence += 1
        sequence_bytes = struct.pack('>I', self.sequence)
        payload_size = struct.pack('>I', len(payload_compressed))

        message = header + sequence_bytes + payload_size + payload_compressed
        logging.info(f"[Client {self.client_sid}] Sent full client request")
        return message

    def create_audio_only_request(self, audio_data, is_last=False):
        """创建 audio only request"""
        payload_compressed = gzip.compress(audio_data)

        if is_last:
            message_flags = 0b0010
        else:
            message_flags = 0b0001

        header = self.create_header(
            message_type=0b0010,
            message_flags=message_flags,
            serialization=0b0000,
            compression=0b0001
        )

        payload_size = struct.pack('>I', len(payload_compressed))

        if message_flags == 0b0001:
            self.sequence += 1
            sequence_bytes = struct.pack('>I', self.sequence)
            message = header + sequence_bytes + payload_size + payload_compressed
        else:
            message = header + payload_size + payload_compressed

        return message

    def parse_server_response(self, data):
        """解析服务端响应"""
        if len(data) < 12:
            return None

        header = data[0:4]
        sequence = struct.unpack('>I', data[4:8])[0]
        payload_size = struct.unpack('>I', data[8:12])[0]
        payload_data = data[12:12+payload_size]

        compression = header[2] & 0x0F

        try:
            if compression == 0b0001:
                payload_json = gzip.decompress(payload_data)
            elif compression == 0b0000:
                payload_json = payload_data
            else:
                logging.error(f"Unsupported compression: {compression}")
                return None

            result = json.loads(payload_json.decode('utf-8'))
            return result
        except Exception as e:
            logging.error(f"Failed to parse payload: {e}")
            return None

    def on_message(self, ws, message):
        """WebSocket 消息回调"""
        result = self.parse_server_response(message)
        if result:
            # 发送识别结果给客户端
            if 'result' in result and 'text' in result['result']:
                text = result['result']['text']
                if text:
                    logging.info(f"[Client {self.client_sid}] Result: {text}")

                socketio.emit('result', {
                    'type': 'result',
                    'text': text,
                    'is_final': False
                }, room=self.client_sid)

    def on_error(self, ws, error):
        """WebSocket 错误回调"""
        logging.error(f"[Client {self.client_sid}] WebSocket error: {error}")
        socketio.emit('error', {
            'type': 'error',
            'message': str(error)
        }, room=self.client_sid)

    def on_close(self, ws, close_status_code, close_msg):
        """WebSocket 关闭回调"""
        logging.info(f"[Client {self.client_sid}] WebSocket closed")
        self.running = False

    def on_open(self, ws):
        """WebSocket 打开回调"""
        logging.info(f"[Client {self.client_sid}] WebSocket opened")

        # 发送 full client request
        full_request = self.create_full_client_request()
        ws.send(full_request, opcode=websocket.ABNF.OPCODE_BINARY)

    def connect(self):
        """连接到字节跳动 ASR 服务"""
        try:
            headers = {
                "X-Api-App-Key": APP_KEY,
                "X-Api-Access-Key": ACCESS_KEY,
                "X-Api-Resource-Id": RESOURCE_ID,
                "X-Api-Connect-Id": str(uuid.uuid4())
            }

            self.ws = websocket.WebSocketApp(
                WS_URL,
                header=headers,
                on_open=self.on_open,
                on_message=self.on_message,
                on_error=self.on_error,
                on_close=self.on_close
            )

            self.running = True

            # 在新线程中运行 WebSocket
            self.receive_thread = threading.Thread(target=self.ws.run_forever)
            self.receive_thread.daemon = True
            self.receive_thread.start()

            logging.info(f"[Client {self.client_sid}] Connected to ByteDance ASR")
            return True
        except Exception as e:
            logging.error(f"[Client {self.client_sid}] Connect error: {e}")
            return False

    def send_audio(self, audio_data, is_last=False):
        """发送音频数据"""
        if not self.ws or not self.running:
            return False

        try:
            audio_request = self.create_audio_only_request(audio_data, is_last=is_last)
            self.ws.send(audio_request, opcode=websocket.ABNF.OPCODE_BINARY)
            return True
        except Exception as e:
            logging.error(f"[Client {self.client_sid}] Send audio error: {e}")
            return False

    def close(self):
        """关闭连接"""
        self.running = False
        if self.ws:
            self.ws.close()
            logging.info(f"[Client {self.client_sid}] Connection closed")


# 存储每个客户端的 ASR 代理
asr_proxies = {}


@socketio.on('connect')
def handle_connect():
    """客户端连接"""
    client_sid = request.sid
    logging.info(f"[Client {client_sid}] Connected")
    emit('connected', {'status': 'ok'})


@socketio.on('disconnect')
def handle_disconnect():
    """客户端断开"""
    client_sid = request.sid
    logging.info(f"[Client {client_sid}] Disconnected")

    # 清理 ASR 代理
    if client_sid in asr_proxies:
        proxy = asr_proxies[client_sid]
        proxy.close()
        del asr_proxies[client_sid]


@socketio.on('start')
def handle_start(data):
    """开始识别"""
    client_sid = request.sid
    logging.info(f"[Client {client_sid}] Start recognition")

    # 创建 ASR 代理
    proxy = ByteDanceASRProxy(client_sid)
    asr_proxies[client_sid] = proxy

    # 连接到字节跳动 ASR
    success = proxy.connect()

    if success:
        emit('started', {'status': 'ok'})
    else:
        emit('error', {
            'type': 'error',
            'message': 'Failed to connect to ASR service'
        })


@socketio.on('audio')
def handle_audio(data):
    """接收音频数据"""
    client_sid = request.sid

    if client_sid not in asr_proxies:
        emit('error', {
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
            logging.info(f"[Client {client_sid}] Last audio packet sent")
    except Exception as e:
        logging.error(f"[Client {client_sid}] Handle audio error: {e}")
        emit('error', {
            'type': 'error',
            'message': str(e)
        })


if __name__ == '__main__':
    logging.info("Starting Flask ASR Server on http://0.0.0.0:5001")
    socketio.run(app, host='0.0.0.0', port=5001, debug=False, allow_unsafe_werkzeug=True)
