#!/usr/bin/env python3
"""Render a JSON-APP in the hosted Flutter Web client and capture review artifacts.

The tool is designed for agent-runtime use. It hides the mechanical work from
the Agent: start a loopback JSON server, open hosted Web with remote_file,
drive headless Chrome through CDP, capture mobile screenshots, and write
report.md/report.json under AI_APP_WORKSPACE.

It deliberately does not call any vision API. If the selected Agent/model can
understand images, the Agent should read the generated screenshots itself and
revise app.json before final upload.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import http.server
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse
from urllib.request import urlopen


DEFAULT_WEB_BASE = "https://myapp-web.dapangyu.work"
DEFAULT_PRIMARY_VIEWPORT = "402x874"
DEFAULT_SMALL_VIEWPORT = "360x780"
DEFAULT_TIMEOUT_SECONDS = 120
DEFAULT_MAX_CLICKS = 4
DEFAULT_STABILIZE_SECONDS = 5.0


def _env_flag(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
        "enabled",
    }


def _parse_viewport(value: str, *, label: str = "") -> tuple[int, int, str]:
    raw = (value or "").strip().lower().replace("*", "x")
    if "x" not in raw:
        raise ValueError(f"invalid viewport: {value}")
    left, right = raw.split("x", 1)
    width = int(left)
    height = int(right)
    if width < 240 or height < 320:
        raise ValueError(f"viewport too small: {value}")
    return width, height, label or f"{width}x{height}"


def _free_port() -> int:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _json_load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("JSON-APP root must be an object")
    return data


class _OneFileJsonHandler(http.server.BaseHTTPRequestHandler):
    server_version = "MyAppVisualJson/1.0"

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        if urlparse(self.path).path not in {"/app.json", "/json"}:
            self._send_json(404, {"error": "Use /app.json"})
            return
        path = Path(getattr(self.server, "json_path"))
        try:
            data = path.read_bytes()
            json.loads(data.decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": f"Invalid JSON: {exc}"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args: object) -> None:
        if _env_flag("AI_APP_VISUAL_REVIEW_SERVER_LOG"):
            print("[json-server] " + fmt % args, file=sys.stderr)


class _JsonServer:
    def __init__(self, app_path: Path, *, allowed_origin: str) -> None:
        self.app_path = app_path
        self.allowed_origin = allowed_origin
        self.port = _free_port()
        self.server: http.server.ThreadingHTTPServer | None = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/app.json"

    def __enter__(self) -> "_JsonServer":
        server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), _OneFileJsonHandler)
        server.json_path = str(self.app_path)
        server.allowed_origin = self.allowed_origin
        self.server = server
        threading.Thread(target=server.serve_forever, name="visual-json-server", daemon=True).start()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self.server:
            self.server.shutdown()
            self.server.server_close()


def _chrome_binary() -> str:
    configured = os.environ.get("AI_APP_VISUAL_REVIEW_CHROME_BIN", "").strip()
    candidates = [
        configured,
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
    ]
    for candidate in candidates:
        if not candidate:
            continue
        found = shutil.which(candidate)
        if found:
            return found
        if Path(candidate).is_file():
            return candidate
    raise RuntimeError("Chrome/Chromium binary not found")


def _ws_connect(ws_url: str) -> socket.socket:
    parsed = urlparse(ws_url)
    path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    sock = socket.create_connection((parsed.hostname or "127.0.0.1", parsed.port or 80), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parsed.hostname}:{parsed.port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    data = b""
    while b"\r\n\r\n" not in data:
        data += sock.recv(4096)
    if b" 101 " not in data.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"CDP websocket upgrade failed: {data[:200]!r}")
    sock.settimeout(0.5)
    return sock


def _ws_send(sock: socket.socket, payload: dict[str, Any]) -> None:
    data = json.dumps(payload).encode("utf-8")
    header = bytearray([0x81])
    size = len(data)
    if size < 126:
        header.append(0x80 | size)
    elif size < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", size))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", size))
    mask = os.urandom(4)
    header.extend(mask)
    sock.sendall(header + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))


def _ws_recv(sock: socket.socket) -> dict[str, Any] | None:
    def read_exact(n: int) -> bytes:
        out = b""
        while len(out) < n:
            chunk = sock.recv(n - len(out))
            if not chunk:
                raise EOFError("websocket closed")
            out += chunk
        return out

    first = read_exact(2)
    opcode = first[0] & 0x0F
    size = first[1] & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(8))[0]
    mask = read_exact(4) if first[1] & 0x80 else b""
    data = read_exact(size) if size else b""
    if mask:
        data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
    if opcode in {8, 9, 10}:
        return None
    return json.loads(data.decode("utf-8", errors="replace"))


class _CdpClient:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.counter = 1

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 10) -> dict[str, Any]:
        msg_id = self.counter
        self.counter += 1
        msg: dict[str, Any] = {"id": msg_id, "method": method}
        if params is not None:
            msg["params"] = params
        _ws_send(self.sock, msg)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                response = _ws_recv(self.sock)
            except socket.timeout:
                continue
            if response and response.get("id") == msg_id:
                if "error" in response:
                    raise RuntimeError(f"{method} failed: {response['error']}")
                return response
        raise TimeoutError(method)

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self.sock.close()


class _ChromeSession:
    def __init__(self, profile_dir: Path) -> None:
        self.profile_dir = profile_dir
        self.proc: subprocess.Popen | None = None
        self.client: _CdpClient | None = None
        self.port = _free_port()

    def __enter__(self) -> "_CdpClient":
        chrome = _chrome_binary()
        self.profile_dir.mkdir(parents=True, exist_ok=True)
        cmd = [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--allow-running-insecure-content",
            "--disable-web-security",
            "--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults",
            "--disable-background-networking",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-popup-blocking",
            "--disable-sync",
            "--hide-scrollbars",
            "--lang=zh-CN",
            "--remote-debugging-address=127.0.0.1",
            f"--remote-debugging-port={self.port}",
            f"--user-data-dir={self.profile_dir}",
            "--window-size=900,1100",
            "about:blank",
        ]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 15
        pages: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"Chrome exited early with code {self.proc.returncode}")
            try:
                with urlopen(f"http://127.0.0.1:{self.port}/json/list", timeout=1) as response:
                    pages = json.loads(response.read().decode("utf-8"))
                if pages:
                    break
            except Exception:
                time.sleep(0.2)
        page = next((item for item in pages if item.get("type") == "page"), None)
        if not page:
            raise RuntimeError("Chrome did not expose a page target")
        self.client = _CdpClient(_ws_connect(page["webSocketDebuggerUrl"]))
        self.client.call("Page.enable")
        self.client.call("Runtime.enable")
        with contextlib.suppress(Exception):
            self.client.call("Emulation.setLocaleOverride", {"locale": "zh-CN"})
        return self.client

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self.client:
            self.client.close()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            with contextlib.suppress(Exception):
                self.proc.wait(timeout=5)
        if self.proc and self.proc.poll() is None:
            with contextlib.suppress(Exception):
                self.proc.kill()
                self.proc.wait(timeout=3)


@dataclass
class Screenshot:
    id: str
    path: Path
    viewport: tuple[int, int, str]
    action: dict[str, Any] | None
    sha256: str
    changed_from_previous: bool


def _render_url(web_base: str, remote_param: str, json_url: str) -> str:
    base = web_base.strip()
    if "?" not in base:
        base = base.rstrip("/") + "/"
    sep = "&" if "?" in base else "?"
    return f"{base}{sep}{quote(remote_param)}={quote(json_url, safe='')}"


def _set_viewport(cdp: _CdpClient, width: int, height: int) -> None:
    cdp.call(
        "Emulation.setDeviceMetricsOverride",
        {
            "width": width,
            "height": height,
            "deviceScaleFactor": 1,
            "mobile": True,
        },
    )


def _wait_for_flutter(cdp: _CdpClient, timeout_seconds: int) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_value: Any = None
    while time.monotonic() < deadline:
        time.sleep(0.5)
        try:
            result = cdp.call(
                "Runtime.evaluate",
                {
                    "expression": (
                        "(() => ({"
                        "glass: !!document.querySelector('flt-glass-pane'),"
                        "debug: globalThis.MyAppLocalJsonDebug || null,"
                        "text: document.body ? document.body.innerText.slice(0, 1000) : '',"
                        "title: document.title || '',"
                        "ready: document.readyState"
                        "}))()"
                    ),
                    "returnByValue": True,
                },
                timeout=2,
            )
            value = result.get("result", {}).get("result", {}).get("value")
            last_value = value
            if isinstance(value, dict) and (value.get("glass") or value.get("text")):
                return value
        except Exception:
            pass
    return {"timeout": True, "last": last_value}


def _render_failure_message(ready_state: dict[str, Any]) -> str:
    debug = ready_state.get("debug")
    if isinstance(debug, dict) and str(debug.get("status") or "").strip().lower() == "error":
        error = str(debug.get("error") or "").strip()
        source = str(debug.get("source") or "").strip()
        return f"Local JSON debug loader failed: {error} source={source}".strip()[:1000]
    text = str(ready_state.get("text") or "")
    lowered = text.lower()
    markers = (
        "failed to load local json",
        "clientexception",
        "xmlhttprequest error",
        "format exception",
        "json parse",
        "invalid json",
    )
    if any(marker in lowered for marker in markers):
        return text.strip().replace("\n", " ")[:1000] or "Flutter Web reported a JSON load failure"
    return ""


def _capture(cdp: _CdpClient, out_path: Path, *, stabilize_seconds: float) -> str:
    time.sleep(max(0.0, stabilize_seconds))
    result = cdp.call(
        "Page.captureScreenshot",
        {"format": "png", "captureBeyondViewport": False},
        timeout=15,
    )
    encoded = result.get("result", {}).get("data")
    if not encoded:
        raise RuntimeError("Chrome did not return screenshot data")
    data = base64.b64decode(encoded)
    out_path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def _tap(cdp: _CdpClient, x: int, y: int) -> None:
    params = {"x": x, "y": y, "button": "left", "clickCount": 1}
    cdp.call("Input.dispatchMouseEvent", {"type": "mousePressed", **params}, timeout=3)
    cdp.call("Input.dispatchMouseEvent", {"type": "mouseReleased", **params}, timeout=3)


def _default_taps(width: int, height: int, max_clicks: int) -> list[dict[str, Any]]:
    candidates = [
        {"type": "tap", "x": round(width * 0.50), "y": max(48, height - 54), "reason": "bottom navigation center"},
        {"type": "tap", "x": round(width * 0.25), "y": max(48, height - 54), "reason": "bottom navigation left"},
        {"type": "tap", "x": round(width * 0.75), "y": max(48, height - 54), "reason": "bottom navigation right"},
        {"type": "tap", "x": max(24, width - 48), "y": 72, "reason": "top-right action"},
        {"type": "tap", "x": round(width * 0.50), "y": round(height * 0.62), "reason": "primary visible content"},
    ]
    seen: set[tuple[int, int]] = set()
    out: list[dict[str, Any]] = []
    for item in candidates:
        xy = (int(item["x"]), int(item["y"]))
        if xy in seen:
            continue
        seen.add(xy)
        out.append({**item, "dangerous": False, "source": "deterministic"})
        if len(out) >= max(0, max_clicks):
            break
    return out


def _heuristic_review(screenshots: list[Screenshot], render_error: str = "") -> dict[str, Any]:
    issues: list[dict[str, str]] = []
    hard_fail = bool(render_error)
    if render_error:
        issues.append(
            {
                "severity": "critical",
                "screen": "render",
                "category": "render",
                "message": render_error,
                "suggestion": "Fix the JSON/runtime issue, rerun validate_json_app.py, then rerun myapp-visual-review.",
            }
        )
    if not screenshots:
        hard_fail = True
        issues.append(
            {
                "severity": "critical",
                "screen": "capture",
                "category": "render",
                "message": "No screenshots were captured.",
                "suggestion": "Check Chrome, remote_file loading, and JSON server availability.",
            }
        )
    unchanged = [shot for shot in screenshots if shot.action and not shot.changed_from_previous]
    if unchanged and len(unchanged) == len([shot for shot in screenshots if shot.action]):
        issues.append(
            {
                "severity": "minor",
                "screen": "interaction",
                "category": "interaction",
                "message": "Deterministic tap exploration did not visibly change the screenshots.",
                "suggestion": "If the app has multiple screens, ensure visible tabs/buttons are wired to real navigation.",
            }
        )
    return {
        "pass": not hard_fail,
        "score": 0 if hard_fail else 70,
        "hard_fail": hard_fail,
        "issues": issues,
        "recommended_next_steps": [
            (
                (
                    "Inspect the screenshot PNG files listed in report.md, then fix app.json per the real frames before upload."
                    if _supports_vision()
                    else "This run's model has no image input: rely on this text report as visual evidence; do NOT read the screenshot PNGs (reading an image fails the run with a 400)."
                )
                if not hard_fail
                else "Fix render/capture failure before final upload."
            )
        ],
    }


def _supports_vision() -> bool:
    """Whether the run's model accepts image input. The launcher sets
    AI_APP_MODEL_SUPPORTS_VISION per the selected provider. Default (unset) = NO
    vision, because a text-only model that tries to Read a screenshot PNG fails the
    whole run with a 400. When False, the report must not embed/invite image reads."""
    return os.environ.get("AI_APP_MODEL_SUPPORTS_VISION", "").strip().lower() in {"1", "true", "yes", "on"}


def _write_reports(
    out_dir: Path,
    *,
    app_path: Path,
    web_url: str,
    renderer: str,
    ready_state: dict[str, Any],
    screenshots: list[Screenshot],
    review: dict[str, Any],
    started_at: int,
) -> dict[str, Any]:
    payload = {
        "schema": "myapp.visual_review.v1",
        "app_path": str(app_path),
        "renderer": renderer,
        "web_url": web_url,
        "web_base": os.environ.get("AI_APP_VISUAL_REVIEW_WEB_BASE", DEFAULT_WEB_BASE),
        "agent_runtime_commit": os.environ.get("MYAPP_BUILD_COMMIT", "unknown"),
        "started_at": started_at,
        "finished_at": int(time.time()),
        "ready_state": ready_state,
        "agent_visual_review": {
            "tool_calls_vision_api": False,
            "model_supports_vision": _supports_vision(),
            "agent_should_inspect_images_if_supported": True,
            "note": "Screenshots are artifacts for the running Agent/model. This tool does not call a separate visual model.",
        },
        "screenshots": [
            {
                "id": shot.id,
                "path": str(shot.path.relative_to(out_dir)),
                "viewport": {"width": shot.viewport[0], "height": shot.viewport[1], "label": shot.viewport[2]},
                "action": shot.action,
                "sha256": shot.sha256,
                "changed_from_previous": shot.changed_from_previous,
            }
            for shot in screenshots
        ],
        "summary": {
            "pass": bool(review.get("pass")),
            "score": review.get("score", 0),
            "hard_fail": bool(review.get("hard_fail")),
        },
        "issues": review.get("issues") if isinstance(review.get("issues"), list) else [],
        "recommended_next_steps": review.get("recommended_next_steps")
        if isinstance(review.get("recommended_next_steps"), list)
        else [],
        "raw_review": review,
    }
    (out_dir / "report.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Visual Review Report",
        "",
        f"- App: `{app_path}`",
        f"- Renderer: `{renderer}`",
        f"- Score: `{payload['summary']['score']}`",
        f"- Pass: `{payload['summary']['pass']}`",
        f"- Hard fail: `{payload['summary']['hard_fail']}`",
    ]
    if _supports_vision():
        lines.extend(
            [
                "",
                "## Agent Instruction",
                "",
                "Your model supports image input. Inspect the PNG files below before final upload, then fix app.json per the real frames.",
                "",
                "## Screenshots",
            ]
        )
        for item in payload["screenshots"]:
            action = item["action"]
            action_text = "initial" if not action else f"{action.get('type')} at ({action.get('x')},{action.get('y')})"
            lines.append(f"- `{item['id']}`: `{item['path']}`; {action_text}; changed={item['changed_from_previous']}")
            lines.append(f"  ![{item['id']}]({item['path']})")
    else:
        lines.extend(
            [
                "",
                "## Agent Instruction",
                "",
                "This run's model has NO image input. DO NOT read or open any screenshot PNG — "
                "reading an image will fail the whole run with a 400 error. Use this text report "
                "(render success, capture, interaction changes, and issues below) as your sole "
                "visual evidence; do not claim pixel-level visual inspection.",
                "",
                f"## Screenshots ({len(payload['screenshots'])} captured as build artifacts; not shown to a text-only model)",
            ]
        )
        for item in payload["screenshots"]:
            action = item["action"]
            action_text = "initial" if not action else f"{action.get('type')} at ({action.get('x')},{action.get('y')})"
            lines.append(
                f"- `{item['id']}`: {action_text}; changed={item['changed_from_previous']} (PNG saved under screenshots/, not for reading)"
            )
    lines.extend(["", "## Issues"])
    issues = payload["issues"]
    if not issues:
        lines.append("- No hard issues detected by the automated reviewer.")
    for issue in issues:
        if not isinstance(issue, dict):
            continue
        lines.append(
            f"- [{issue.get('severity', 'unknown')}] {issue.get('category', 'general')} "
            f"on `{issue.get('screen', '')}`: {issue.get('message', '')} "
            f"Suggestion: {issue.get('suggestion', '')}"
        )
    lines.extend(["", "## Recommended Next Steps"])
    steps = payload["recommended_next_steps"]
    if not steps:
        lines.append("- If visual quality is important, inspect screenshots and revise app.json before upload.")
    for step in steps:
        lines.append(f"- {step}")
    (out_dir / "report.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return payload


def run_review(args: argparse.Namespace) -> int:
    app_path = Path(args.app_json).resolve()
    if not app_path.is_file():
        raise FileNotFoundError(app_path)
    _json_load(app_path)

    workspace = Path(os.environ.get("AI_APP_WORKSPACE") or app_path.parent)
    out_dir = Path(args.out_dir or workspace / "visual_review").resolve()
    screenshot_dir = out_dir / "screenshots"
    screenshot_dir.mkdir(parents=True, exist_ok=True)
    profile_dir = out_dir / ".chrome-profile"
    shutil.rmtree(profile_dir, ignore_errors=True)

    viewports = [_parse_viewport(args.viewport, label="primary")]
    if args.small_viewport:
        viewports.append(_parse_viewport(args.small_viewport, label="small"))

    started_at = int(time.time())
    screenshots: list[Screenshot] = []
    render_error = ""
    ready_state: dict[str, Any] = {}
    web_base = args.web_base.rstrip("/")
    remote_param = args.remote_param

    with _JsonServer(app_path, allowed_origin=web_base) as json_server:
        web_url = _render_url(web_base, remote_param, json_server.url)
        try:
            with _ChromeSession(profile_dir) as cdp:
                for viewport_index, (width, height, label) in enumerate(viewports):
                    _set_viewport(cdp, width, height)
                    try:
                        cdp.call("Page.navigate", {"url": web_url}, timeout=5)
                    except TimeoutError:
                        pass
                    ready_state = _wait_for_flutter(cdp, args.timeout)
                    state_error = _render_failure_message(ready_state)
                    prev_hash = ""
                    shot_id = f"{label}-initial"
                    path = screenshot_dir / f"{shot_id}.png"
                    sha = _capture(cdp, path, stabilize_seconds=args.stabilize_seconds)
                    screenshots.append(
                        Screenshot(
                            id=shot_id,
                            path=path,
                            viewport=(width, height, label),
                            action=None,
                            sha256=sha,
                            changed_from_previous=True,
                        )
                    )
                    prev_hash = sha
                    if state_error:
                        render_error = state_error
                        break
                    if viewport_index == 0 and args.max_clicks > 0:
                        for i, action in enumerate(_default_taps(width, height, args.max_clicks), start=1):
                            x = int(action.get("x", 0))
                            y = int(action.get("y", 0))
                            if x < 0 or y < 0 or x > width or y > height:
                                continue
                            _tap(cdp, x, y)
                            shot_id = f"{label}-tap-{i}"
                            path = screenshot_dir / f"{shot_id}.png"
                            sha = _capture(cdp, path, stabilize_seconds=max(1.0, args.stabilize_seconds / 2))
                            screenshots.append(
                                Screenshot(
                                    id=shot_id,
                                    path=path,
                                    viewport=(width, height, label),
                                    action=action,
                                    sha256=sha,
                                    changed_from_previous=sha != prev_hash,
                                )
                            )
                            prev_hash = sha
        except Exception as exc:
            render_error = str(exc)

    shutil.rmtree(profile_dir, ignore_errors=True)
    review = _heuristic_review(screenshots, render_error)
    payload = _write_reports(
        out_dir,
        app_path=app_path,
        web_url=web_url,
        renderer="hosted-loopback-url",
        ready_state=ready_state,
        screenshots=screenshots,
        review=review,
        started_at=started_at,
    )
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(f"visual review report: {out_dir / 'report.md'}")
        print(f"screenshots: {screenshot_dir}")
        if render_error:
            print(f"render error: {render_error}", file=sys.stderr)
    return 2 if render_error else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render and visually review a JSON-APP.")
    parser.add_argument("app_json", help="Path to app.json")
    parser.add_argument("--out-dir", default="")
    parser.add_argument(
        "--web-base",
        default=os.environ.get("AI_APP_VISUAL_REVIEW_WEB_BASE", DEFAULT_WEB_BASE),
    )
    parser.add_argument(
        "--remote-param",
        default=os.environ.get("AI_APP_VISUAL_REVIEW_REMOTE_PARAM", "remote_file"),
    )
    parser.add_argument(
        "--viewport",
        default=os.environ.get("AI_APP_VISUAL_REVIEW_PRIMARY_VIEWPORT", DEFAULT_PRIMARY_VIEWPORT),
    )
    parser.add_argument(
        "--small-viewport",
        default=os.environ.get("AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT", ""),
    )
    parser.add_argument("--capture-small", action="store_true")
    parser.add_argument("--max-clicks", type=int, default=int(os.environ.get("AI_APP_VISUAL_REVIEW_MAX_CLICKS", str(DEFAULT_MAX_CLICKS))))
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("AI_APP_VISUAL_REVIEW_TIMEOUT", str(DEFAULT_TIMEOUT_SECONDS))))
    parser.add_argument(
        "--stabilize-seconds",
        type=float,
        default=float(os.environ.get("AI_APP_VISUAL_REVIEW_STABILIZE_SECONDS", str(DEFAULT_STABILIZE_SECONDS))),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.capture_small and not args.small_viewport:
        args.small_viewport = DEFAULT_SMALL_VIEWPORT
    return run_review(args)


if __name__ == "__main__":
    raise SystemExit(main())
