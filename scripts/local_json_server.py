#!/usr/bin/env python3
"""Serve local JSON-APP files to Flutter Web during debug runs.

Flutter Web cannot read arbitrary absolute filesystem paths from the browser.
This localhost-only helper lets the app use:

    http://localhost:PORT/?local_json=/abs/path/app.json

The Flutter app then fetches:

    http://127.0.0.1:8765/json?path=/abs/path/app.json
"""

from __future__ import annotations

import argparse
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


LOCAL_ORIGINS = {
    "localhost",
    "127.0.0.1",
    "::1",
    "[::1]",
}

DEFAULT_ALLOWED_ORIGINS = {
    "https://myapp-web.dapangyu.work",
}


def _origin_host(origin: str) -> str:
    if not origin:
        return ""
    try:
        return urlparse(origin).hostname or ""
    except ValueError:
        return ""


def _origin_allowed(origin: str, allowed_origins: set[str]) -> bool:
    if not origin:
        return True
    if origin in allowed_origins:
        return True
    return _origin_host(origin) in LOCAL_ORIGINS


class LocalJsonHandler(BaseHTTPRequestHandler):
    server_version = "LocalJsonDebug/1.0"

    def end_headers(self) -> None:
        origin = self.headers.get("Origin", "")
        allowed_origins = getattr(self.server, "allowed_origins", set())
        if _origin_allowed(origin, allowed_origins):
            self.send_header("Access-Control-Allow-Origin", origin or "*")
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Private-Network", "true")
        super().end_headers()

    def do_OPTIONS(self) -> None:
        origin = self.headers.get("Origin", "")
        allowed_origins = getattr(self.server, "allowed_origins", set())
        if not _origin_allowed(origin, allowed_origins):
            self.send_response(HTTPStatus.FORBIDDEN)
        else:
            self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        origin = self.headers.get("Origin", "")
        allowed_origins = getattr(self.server, "allowed_origins", set())
        if not _origin_allowed(origin, allowed_origins):
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "Origin not allowed"})
            return

        single_file = getattr(self.server, "single_file", "")
        if single_file and parsed.path in {"/app.json", "/json"}:
            file_path = single_file
        elif parsed.path == "/json":
            params = parse_qs(parsed.query)
            file_path = (params.get("path") or [""])[0]
        else:
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {"error": "Use /json?path=/abs/app.json or --file with /app.json"},
            )
            return

        if not file_path:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Missing path"})
            return
        if not os.path.isabs(file_path):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Path must be absolute"})
            return
        if not file_path.lower().endswith(".json"):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Only .json files are served"})
            return
        if not os.path.isfile(file_path):
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "File not found"})
            return

        try:
            with open(file_path, "rb") as f:
                data = f.read()
            json.loads(data.decode("utf-8"))
        except Exception as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Invalid JSON: {exc}"})
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, status: HTTPStatus, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Serve absolute local JSON app paths to Flutter Web debug builds."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--file",
        default="",
        help="Serve one JSON file directly at /app.json for hosted Web preview.",
    )
    parser.add_argument(
        "--allow-origin",
        action="append",
        default=[],
        help="Additional allowed CORS origin. Can be repeated.",
    )
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), LocalJsonHandler)
    server.single_file = os.path.abspath(args.file) if args.file else ""
    server.allowed_origins = DEFAULT_ALLOWED_ORIGINS | set(args.allow_origin)
    print(f"Serving local JSON debug helper on http://{args.host}:{args.port}/json")
    if server.single_file:
        print(f"Serving {server.single_file} on http://{args.host}:{args.port}/app.json")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
