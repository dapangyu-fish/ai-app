#!/usr/bin/env python3
"""
本地流媒体视频服务器
=====================
模拟类似 B站 的视频流媒体服务，支持 HTTP Range 请求（断点续传 / 拖拽进度条）。

用法:
    python3 video_server.py                          # 默认在 8080 端口提供 videos/ 目录下的视频
    python3 video_server.py --port 9090              # 指定端口
    python3 video_server.py --dir /path/to/videos    # 指定视频目录
    python3 video_server.py --file sample.mp4        # 直接指定单个视频文件

测试:
    1. 放一个 .mp4 文件到 videos/ 目录（或用 --file 指定）
    2. 运行此脚本
    3. 在 JSON DSL 的 video 控件中使用:
       { "type": "video", "url": "http://localhost:8080/sample.mp4" }

特性:
    - 支持 HTTP Range 请求（视频拖拽进度条）
    - 自动识别 Content-Type (mp4/webm/mov/avi)
    - CORS 头支持（Flutter Web 可直接访问）
    - 视频文件列表页
"""

import os
import sys
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import unquote

MIME_TYPES = {
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
    '.mov': 'video/quicktime',
    '.avi': 'video/x-msvideo',
    '.mkv': 'video/x-matroska',
    '.m3u8': 'application/vnd.apple.mpegurl',
    '.ts': 'video/mp2t',
    '.flv': 'video/x-flv',
}


class VideoStreamHandler(BaseHTTPRequestHandler):
    video_dir = './videos'

    def do_GET(self):
        path = unquote(self.path).lstrip('/')

        # JSON API：返回视频列表
        if path == 'api/list':
            self._serve_api_list()
            return

        # 根路径：列出可用视频（HTML）
        if not path:
            self._serve_index()
            return

        file_path = os.path.join(self.video_dir, path)

        if not os.path.isfile(file_path):
            self.send_error(404, f'文件不存在: {path}')
            return

        self._serve_video(file_path)

    def _serve_api_list(self):
        """JSON API: 返回视频文件列表"""
        import json as json_mod
        port = self.server.server_port
        videos = []
        for f in sorted(os.listdir(self.video_dir)):
            ext = os.path.splitext(f)[1].lower()
            if ext in MIME_TYPES:
                full_path = os.path.join(self.video_dir, f)
                size_bytes = os.path.getsize(full_path)
                size_mb = round(size_bytes / 1024 / 1024, 1)
                videos.append({
                    'name': f,
                    'url': f'http://localhost:{port}/{f}',
                    'size': f'{size_mb} MB',
                    'size_bytes': size_bytes,
                })

        body = json_mod.dumps(videos, ensure_ascii=False).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def _serve_index(self):
        """列出视频目录中的所有文件"""
        files = []
        for f in sorted(os.listdir(self.video_dir)):
            ext = os.path.splitext(f)[1].lower()
            if ext in MIME_TYPES:
                size = os.path.getsize(os.path.join(self.video_dir, f))
                size_mb = f'{size / 1024 / 1024:.1f} MB'
                files.append((f, size_mb))

        html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
        html += '<title>Video Stream Server</title>'
        html += '<style>body{font-family:system-ui;max-width:600px;margin:40px auto;padding:0 20px}'
        html += 'a{display:block;padding:12px;margin:8px 0;background:#f0f0f0;border-radius:8px;'
        html += 'text-decoration:none;color:#333}a:hover{background:#e0e0f0}'
        html += '.size{color:#888;font-size:13px}</style></head><body>'
        html += '<h2>🎬 视频流媒体服务器</h2>'
        html += f'<p style="color:#666">目录: {os.path.abspath(self.video_dir)}</p>'

        if not files:
            html += '<p style="color:#999">暂无视频文件，请将 .mp4 等文件放入 videos/ 目录</p>'
        else:
            html += f'<p>共 {len(files)} 个视频：</p>'
            for name, size in files:
                url = f'http://localhost:{self.server.server_port}/{name}'
                html += f'<a href="/{name}">🎞 {name} <span class="size">({size})</span>'
                html += f'<br><code style="font-size:11px;color:#888">{url}</code></a>'

        html += '<hr><p style="font-size:12px;color:#aaa">'
        html += 'JSON DSL 用法: { "type": "video", "url": "http://localhost:'
        html += f'{self.server.server_port}/文件名.mp4" }}</p>'
        html += '</body></html>'

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))

    def _serve_video(self, file_path):
        """支持 Range 请求的视频流"""
        file_size = os.path.getsize(file_path)
        ext = os.path.splitext(file_path)[1].lower()
        content_type = MIME_TYPES.get(ext, 'application/octet-stream')

        # 解析 Range 头
        range_header = self.headers.get('Range')
        if range_header:
            # Range: bytes=start-end
            range_str = range_header.replace('bytes=', '')
            parts = range_str.split('-')
            start = int(parts[0]) if parts[0] else 0
            end = int(parts[1]) if parts[1] else file_size - 1
            end = min(end, file_size - 1)
            length = end - start + 1

            self.send_response(206)  # Partial Content
            self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
            self.send_header('Content-Length', str(length))
        else:
            start = 0
            length = file_size
            self.send_response(200)
            self.send_header('Content-Length', str(file_size))

        self.send_header('Content-Type', content_type)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Range')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()

        # 分块发送（避免大文件占满内存）
        chunk_size = 64 * 1024  # 64KB
        with open(file_path, 'rb') as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(chunk_size, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
                remaining -= len(chunk)

    def do_OPTIONS(self):
        """CORS preflight"""
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Range')
        self.end_headers()

    def log_message(self, format, *args):
        """美化日志输出"""
        msg = format % args
        if '206' in msg:
            print(f'  📦 {msg}')  # Range 请求（拖拽进度条）
        elif '200' in msg:
            print(f'  ▶️  {msg}')  # 完整请求
        elif '404' in msg:
            print(f'  ❌ {msg}')
        else:
            print(f'  ℹ️  {msg}')


def main():
    parser = argparse.ArgumentParser(description='本地流媒体视频服务器（支持 Range 请求）')
    parser.add_argument('--port', type=int, default=8080, help='服务端口 (默认 8080)')
    parser.add_argument('--dir', type=str, default='./videos', help='视频目录 (默认 ./videos)')
    parser.add_argument('--file', type=str, help='直接指定单个视频文件')
    args = parser.parse_args()

    if args.file:
        # 单文件模式：创建临时目录软链接
        if not os.path.isfile(args.file):
            print(f'❌ 文件不存在: {args.file}')
            sys.exit(1)
        video_dir = os.path.dirname(os.path.abspath(args.file)) or '.'
        VideoStreamHandler.video_dir = video_dir
        print(f'📁 单文件模式: {os.path.abspath(args.file)}')
    else:
        video_dir = args.dir
        os.makedirs(video_dir, exist_ok=True)
        VideoStreamHandler.video_dir = video_dir
        print(f'📁 视频目录: {os.path.abspath(video_dir)}')

    server = HTTPServer(('0.0.0.0', args.port), VideoStreamHandler)
    print(f'🚀 视频流媒体服务器已启动: http://localhost:{args.port}')
    print(f'   打开浏览器查看视频列表')
    print()
    print(f'   JSON DSL 用法:')
    print(f'   {{ "type": "video", "url": "http://localhost:{args.port}/文件名.mp4" }}')
    print()
    print('按 Ctrl+C 停止服务器')
    print('─' * 50)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n🛑 服务器已停止')
        server.server_close()


if __name__ == '__main__':
    main()
