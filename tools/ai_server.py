#!/usr/bin/env python3
"""
AI Chat + JSON App Marketplace Server — 端口 5566

功能：
  POST /chat              — SSE 流式 AI 对话（DeepSeek）
  GET  /app-list          — 列出市场中所有公开的 JSON App
  GET  /component-list    — 列出市场中所有公开的 JSON 组件/库
  GET  /download/<name>   — 下载指定 JSON 文件

启动: python3 tools/ai_server.py
"""

import json
import os
import http.server
import urllib.request
import urllib.parse
import ssl

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_KEY = "sk-63a3f89ae09440f2b05e21f56410eb68"
DEEPSEEK_MODEL = "deepseek-chat"
PORT = 5566

# JSON 模板目录
TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates")


# ══════════════════════════════════════════════════════════
# 市场：扫描 templates/ 目录，按 meta.type 分类
# ══════════════════════════════════════════════════════════

def _scan_market():
    """扫描 templates/ 下所有 .json，返回 (apps, components) 两个列表。"""
    apps = []
    components = []

    if not os.path.isdir(TEMPLATES_DIR):
        return apps, components

    for fname in sorted(os.listdir(TEMPLATES_DIR)):
        if not fname.endswith(".json"):
            continue
        fpath = os.path.join(TEMPLATES_DIR, fname)
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue

        meta = data.get("meta", {})
        entry = {
            "file": fname,
            "name": meta.get("name", fname.replace(".json", "")),
            "version": meta.get("version", data.get("version", "unknown")),
            "description": meta.get("description", ""),
            "author": meta.get("author", ""),
            "download": f"/download/{urllib.parse.quote(fname)}",
        }

        meta_type = meta.get("type", "")
        if meta_type == "library":
            entry["exports"] = meta.get("exports", [])
            components.append(entry)
        else:
            # 有 ui 字段的视为 app，否则也归为 component
            if "ui" in data:
                apps.append(entry)
            else:
                entry["exports"] = meta.get("exports", [])
                components.append(entry)

    return apps, components


class MarketHandler(http.server.BaseHTTPRequestHandler):

    # ── OPTIONS (CORS) ──────────────────────────────────

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    # ── GET ──────────────────────────────────────────────

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/app-list":
            apps, _ = _scan_market()
            self._json_response(200, {"apps": apps})

        elif path == "/component-list":
            _, components = _scan_market()
            self._json_response(200, {"components": components})

        elif path.startswith("/download/"):
            fname = urllib.parse.unquote(path[len("/download/"):])
            self._serve_file(fname)

        else:
            self.send_error(404)

    # ── POST /chat (SSE) ────────────────────────────────

    def do_POST(self):
        if self.path != "/chat":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}
        messages = body.get("messages", [])

        if not messages:
            self._json_response(400, {"error": "messages is required"})
            return

        payload = json.dumps({
            "model": DEEPSEEK_MODEL,
            "messages": messages,
            "stream": True,
        }).encode()

        req = urllib.request.Request(
            DEEPSEEK_URL,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {DEEPSEEK_KEY}",
            },
        )

        try:
            ctx = ssl.create_default_context()
            resp = urllib.request.urlopen(req, context=ctx, timeout=60)

            self.send_response(200)
            self._cors_headers()
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            for raw_line in resp:
                line = raw_line.decode("utf-8").strip()
                if not line:
                    continue
                if line.startswith("data:"):
                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        self.wfile.write(b"data: [DONE]\n\n")
                        self.wfile.flush()
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            event = json.dumps({"content": content}, ensure_ascii=False)
                            self.wfile.write(f"data: {event}\n\n".encode())
                            self.wfile.flush()
                    except (json.JSONDecodeError, IndexError, KeyError):
                        pass

            resp.close()

        except Exception as e:
            try:
                error_event = json.dumps({"error": str(e)}, ensure_ascii=False)
                self.wfile.write(f"data: {error_event}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except Exception:
                self._json_response(502, {"error": str(e)})

    # ── 文件下载 ────────────────────────────────────────

    def _serve_file(self, fname):
        # 防止路径穿越
        if "/" in fname or "\\" in fname or ".." in fname:
            self.send_error(403, "Invalid filename")
            return

        fpath = os.path.join(TEMPLATES_DIR, fname)
        if not os.path.isfile(fpath):
            self.send_error(404, f"File not found: {fname}")
            return

        with open(fpath, "rb") as f:
            data = f.read()

        self.send_response(200)
        self._cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
        self.end_headers()
        self.wfile.write(data)

    # ── 工具方法 ────────────────────────────────────────

    def _json_response(self, code, data):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode()
        self.send_response(code)
        self._cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, fmt, *args):
        print(f"[Server] {args[0]}")


def main():
    server = http.server.HTTPServer(("0.0.0.0", PORT), MarketHandler)
    print(f"🚀 AI Chat + Marketplace Server on http://0.0.0.0:{PORT}")
    print(f"   POST /chat           — AI 对话 (SSE)")
    print(f"   GET  /app-list       — App 列表")
    print(f"   GET  /component-list — 组件列表")
    print(f"   GET  /download/<file>— 下载 JSON")
    print(f"   Templates dir: {os.path.abspath(TEMPLATES_DIR)}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n🛑 Server stopped.")
        server.server_close()


if __name__ == "__main__":
    main()
