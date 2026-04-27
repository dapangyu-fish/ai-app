#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
字节跳动大模型流式语音识别测试
修复音频格式问题
"""

import asyncio
import websockets
import json
import struct
import gzip
import uuid
import logging
import pyaudio

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# ==================== 配置参数 ====================
APP_KEY = "5982591805"  # APP ID
ACCESS_KEY = "j5JzySkHs2ncLKrFxy6TAYZDDDmrpMEa"  # Access Token
SECRET_KEY = "RWAnUTmUEGUysStn-R0phBxqThMoe0o0"  # Secret Key（备用）
RESOURCE_ID = "volc.bigasr.sauc.duration"  # 豆包流式语音识别模型1.0 小时版
# RESOURCE_ID = "volc.seedasr.sauc.duration"  # 豆包流式语音识别模型2.0 小时版

# WebSocket 地址
WS_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"

# 音频参数
SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK_SIZE = 3200  # 200ms @ 16kHz = 3200 samples = 6400 bytes
FORMAT = pyaudio.paInt16


class ByteDanceASR:
    def __init__(self):
        self.ws = None
        self.sequence = 0
        self.audio = pyaudio.PyAudio()
        self.stream = None

    def create_header(self, message_type, message_flags, serialization, compression):
        """
        创建协议头（4字节）

        Byte 0:
          - bits 7-4: Protocol version (0b0001)
          - bits 3-0: Header size (0b0001 = 4 bytes)
        Byte 1:
          - bits 7-4: Message type
          - bits 3-0: Message type specific flags
        Byte 2:
          - bits 7-4: Serialization method
          - bits 3-0: Compression
        Byte 3:
          - Reserved (0x00)
        """
        byte0 = (0b0001 << 4) | 0b0001  # version=1, header_size=1
        byte1 = (message_type << 4) | message_flags
        byte2 = (serialization << 4) | compression
        byte3 = 0x00

        return struct.pack('BBBB', byte0, byte1, byte2, byte3)

    def create_full_client_request(self):
        """创建 full client request"""
        # 构建请求参数
        request_data = {
            "user": {
                "uid": str(uuid.uuid4())
            },
            "audio": {
                "format": "pcm",  # 使用 pcm 格式
                "codec": "raw",   # raw = pcm_s16le
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

        # 序列化为 JSON
        payload_json = json.dumps(request_data, ensure_ascii=False).encode('utf-8')
        logging.info(f"Request JSON: {json.dumps(request_data, ensure_ascii=False, indent=2)}")

        # Gzip 压缩
        payload_compressed = gzip.compress(payload_json)

        # 创建 header
        # message_type=0b0001 (full client request)
        # message_flags=0b0001 (sequence number 为正)
        # serialization=0b0001 (JSON)
        # compression=0b0001 (Gzip)
        header = self.create_header(
            message_type=0b0001,
            message_flags=0b0001,
            serialization=0b0001,
            compression=0b0001
        )

        # 序列号（4字节，大端）- 只有当 message_flags 指定时才添加
        self.sequence += 1
        sequence_bytes = struct.pack('>I', self.sequence)

        # Payload 大小（4字节，大端）
        payload_size = struct.pack('>I', len(payload_compressed))

        # 组装完整消息: header(4) + sequence(4) + payload_size(4) + payload
        message = header + sequence_bytes + payload_size + payload_compressed

        logging.info(f"Sent full client request with seq: {self.sequence}")
        return message

    def create_audio_only_request(self, audio_data, is_last=False):
        """创建 audio only request"""
        # Gzip 压缩音频数据
        payload_compressed = gzip.compress(audio_data)

        # 创建 header
        # message_type=0b0010 (audio only request)
        # message_flags: 0b0010 (最后一包，不带sequence) 或 0b0001 (正常包，带正sequence)
        if is_last:
            message_flags = 0b0010  # 最后一包，不带sequence
        else:
            message_flags = 0b0001  # 正常包，带sequence

        header = self.create_header(
            message_type=0b0010,
            message_flags=message_flags,
            serialization=0b0000,  # no serialization
            compression=0b0001     # Gzip
        )

        # Payload 大小（4字节，大端）
        payload_size = struct.pack('>I', len(payload_compressed))

        # 根据 message_flags 决定是否添加 sequence
        if message_flags == 0b0001:
            # 正常包：header(4) + sequence(4) + payload_size(4) + payload
            self.sequence += 1
            sequence_bytes = struct.pack('>I', self.sequence)
            message = header + sequence_bytes + payload_size + payload_compressed
        else:
            # 最后一包：header(4) + payload_size(4) + payload（不带sequence）
            message = header + payload_size + payload_compressed

        return message

    def parse_server_response(self, data):
        """解析服务端响应"""
        if len(data) < 12:
            logging.error("Response too short")
            return None

        # 解析 header (4 bytes)
        header = data[0:4]

        # 解析 sequence (4 bytes)
        sequence = struct.unpack('>I', data[4:8])[0]

        # 解析 payload size (4 bytes)
        payload_size = struct.unpack('>I', data[8:12])[0]

        # 解析 payload
        payload_data = data[12:12+payload_size]

        # 检查压缩方式（header byte 2 的低4位）
        compression = header[2] & 0x0F

        try:
            if compression == 0b0001:  # Gzip
                payload_json = gzip.decompress(payload_data)
            elif compression == 0b0000:  # No compression
                payload_json = payload_data
            else:
                logging.error(f"Unsupported compression: {compression}")
                return None

            result = json.loads(payload_json.decode('utf-8'))
            return result
        except Exception as e:
            logging.error(f"Failed to parse payload: {e}")
            logging.error(f"Payload data (first 100 bytes): {payload_data[:100]}")
            return None

    async def start_recognition(self):
        """开始语音识别"""
        # 连接 WebSocket
        headers = {
            "X-Api-App-Key": APP_KEY,
            "X-Api-Access-Key": ACCESS_KEY,
            "X-Api-Resource-Id": RESOURCE_ID,
            "X-Api-Connect-Id": str(uuid.uuid4())
        }

        logging.info(f"Connecting to {WS_URL}")

        async with websockets.connect(WS_URL, additional_headers=headers) as ws:
            self.ws = ws

            # 获取服务端返回的 logid
            if hasattr(ws, 'response_headers') and 'X-Tt-Logid' in ws.response_headers:
                logging.info(f"Server Logid: {ws.response_headers['X-Tt-Logid']}")

            logging.info(f"Connected to {WS_URL}")

            # 发送 full client request
            full_request = self.create_full_client_request()
            await ws.send(full_request)

            # 接收第一个响应
            response_data = await ws.recv()
            result = self.parse_server_response(response_data)
            if result:
                logging.info(f"Received response: {json.dumps(result, ensure_ascii=False)}")

            # 启动录音
            self.stream = self.audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=CHUNK_SIZE
            )

            logging.info("麦克风开始录音...")

            # 创建接收任务
            receive_task = asyncio.create_task(self.receive_responses())

            try:
                # 录音并发送（录音5秒）
                for i in range(25):  # 25 * 200ms = 5秒
                    audio_data = self.stream.read(CHUNK_SIZE, exception_on_overflow=False)

                    # 发送音频数据
                    is_last = (i == 24)
                    audio_request = self.create_audio_only_request(audio_data, is_last=is_last)
                    await ws.send(audio_request)

                    await asyncio.sleep(0.2)  # 200ms 间隔

                # 等待接收任务完成
                await asyncio.sleep(2)

            finally:
                # 停止录音
                if self.stream:
                    self.stream.stop_stream()
                    self.stream.close()
                logging.info("麦克风停止录音")

                # 取消接收任务
                receive_task.cancel()

    async def receive_responses(self):
        """接收服务端响应"""
        try:
            while True:
                response_data = await self.ws.recv()
                result = self.parse_server_response(response_data)
                if result:
                    logging.info(f"Received response: {json.dumps(result, ensure_ascii=False, indent=2)}")

                    # 显示识别结果
                    if 'result' in result and 'text' in result['result']:
                        text = result['result']['text']
                        if text:
                            print(f"\n识别结果: {text}\n")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logging.error(f"Receive error: {e}")

    def cleanup(self):
        """清理资源"""
        if self.stream:
            self.stream.stop_stream()
            self.stream.close()
        self.audio.terminate()


async def main():
    asr = ByteDanceASR()
    try:
        await asr.start_recognition()
    finally:
        asr.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
