#!/usr/bin/env python3
"""Run local AI JSON-APP generation quality experiments.

The script intentionally keeps production secrets outside the repository. It
expects a dotenv-style file such as /tmp/ai-app-prod-backend.env and only passes
the needed provider variables to the Claude CLI process.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
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
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
OUT_ROOT = Path("/tmp/ai-app-quality-lab")
DEFAULT_ENV = Path("/tmp/ai-app-backend.env")
DEFAULT_WIDTH = 402
DEFAULT_HEIGHT = 874
DEFAULT_SMALL_WIDTH = 360
DEFAULT_SMALL_HEIGHT = 780
GENERATE_PROMPT_PATH = "backend/prompts/generate_app_prompt_indexed.md"


CASES: dict[str, str] = {
    "diary": "个人日记本 APP：写日记、心情标签、搜索、编辑删除、本地持久化，风格要像 iOS/Android 原生记录工具。",
    "budget": "个人记账 APP：收入支出、分类、今日/本月统计、交易列表、编辑删除、本地持久化，移动端原生质感。",
    "habit": "习惯打卡 APP：习惯列表、每日打卡、连续天数、今日进度、编辑习惯，本地持久化。",
    "notes": "轻量笔记 APP：笔记列表、搜索、标签、编辑页、置顶/删除、本地持久化。",
    "workout": "健身训练记录 APP：训练计划、动作组数重量记录、最近记录、完成反馈，本地持久化。",
    "recipe": "菜谱收藏 APP：菜谱列表、分类筛选、详情步骤、收藏、搜索，本地持久化。",
    "meds": "服药提醒记录 APP：药品列表、服用时间、今日待办、完成记录、备注，本地持久化。",
    "contacts": "客户跟进 CRM 小工具：客户列表、状态标签、跟进记录、下一步提醒、搜索，本地持久化。",
    "reading": "读书笔记 APP：书籍列表、阅读进度、摘录笔记、评分、搜索，本地持久化。",
    "pomodoro": "番茄钟 + 任务清单 APP：25/5/15 规则、任务绑定番茄、今日统计、本地持久化。",
}


STRATEGIES: dict[str, str] = {
    "direct": (
        "直接生成 JSON-APP。先做非常简短的信息架构和视觉计划，但不要写 Flutter 代码。"
    ),
    "native_brief": (
        "在生成 JSON 前，先在思考中完成 Native Design Brief：页面层级、组件选择、"
        "空状态、列表项结构、主操作、颜色语义、402×874 手机首屏布局。然后再写 JSON。"
    ),
    "flutter_first": (
        "先把目标 APP 设计成等效 Flutter/Material3 Widget tree（只作为草稿，不保存 .dart），"
        "明确 Scaffold/AppBar/NavigationBar/Card/ListTile/Form 的结构，再把它逐项翻译为 JSON-DSL。"
        "翻译时只能使用本项目已存在的 widget/action，不能发明 Flutter 字段。"
    ),
}


def parse_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip("\"'")
    return env


def load_prompt(env: dict[str, str]) -> str:
    mode = (
        os.environ.get("AI_GENERATION_PROMPT_MODE")
        or env.get("AI_GENERATION_PROMPT_MODE")
        or "indexed"
    )
    prompt_name = (
        "generate_app_prompt.md"
        if mode.strip().lower() in {"legacy", "full"}
        else "generate_app_prompt_indexed.md"
    )
    content = (ROOT / f"backend/prompts/{prompt_name}").read_text(encoding="utf-8")
    content = content.replace(
        "https://myapp-registry.dapangyu.work",
        env.get("REGISTRY_BASE_URL", "https://myapp-registry.dapangyu.work"),
    )
    content = content.replace(
        "https://myapp-oss-endpoint.dapangyu.work",
        env.get("MINIO_PUBLIC_URL", "https://myapp-oss-endpoint.dapangyu.work"),
    )
    return content


def provider_env(env_file: Path) -> dict[str, str]:
    loaded = parse_env(env_file)
    provider_id = (
        loaded.get("AI_PROVIDER")
        or loaded.get("AI_DEFAULT_PROVIDER")
        or os.environ.get("AI_PROVIDER")
        or os.environ.get("AI_DEFAULT_PROVIDER")
        or "deepseek"
    ).strip().lower().replace("_", "-")
    prefix = "".join(ch.upper() if ch.isalnum() else "_" for ch in provider_id)

    builtin_defaults = {
        "deepseek": {
            "base_url": "https://api.deepseek.com/anthropic",
            "model": "deepseek-v4-pro[1m]",
            "auth_fallbacks": (),
        },
        "minimax": {
            "base_url": "https://api.minimaxi.com/anthropic",
            "model": "MiniMax-M3",
            "auth_fallbacks": (),
        },
    }
    defaults = builtin_defaults.get(provider_id, {"base_url": "", "model": "", "auth_fallbacks": ()})

    def value(name: str, default: str = "") -> str:
        return loaded.get(f"{prefix}_{name}") or os.environ.get(f"{prefix}_{name}") or default

    auth_token = value("ANTHROPIC_AUTH_TOKEN")
    if not auth_token:
        for fallback_name in defaults["auth_fallbacks"]:
            auth_token = loaded.get(fallback_name) or os.environ.get(fallback_name) or ""
            if auth_token:
                break

    model = value("ANTHROPIC_MODEL", defaults["model"])
    env = os.environ.copy()
    env.update(
        {
            "SERVER_PROJECT_PATH": str(ROOT),
            "AI_GENERATION_PROMPT_MODE": "indexed",
            "ANTHROPIC_BASE_URL": value("ANTHROPIC_BASE_URL", defaults["base_url"]),
            "ANTHROPIC_AUTH_TOKEN": auth_token,
            "ANTHROPIC_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": value("ANTHROPIC_DEFAULT_OPUS_MODEL", model),
            "ANTHROPIC_DEFAULT_SONNET_MODEL": value("ANTHROPIC_DEFAULT_SONNET_MODEL", model),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": value("ANTHROPIC_DEFAULT_HAIKU_MODEL", model),
            "CLAUDE_CODE_SUBAGENT_MODEL": value("CLAUDE_CODE_SUBAGENT_MODEL", model),
            "CLAUDE_CODE_EFFORT_LEVEL": value("CLAUDE_CODE_EFFORT_LEVEL", "max"),
            "API_TIMEOUT_MS": value("API_TIMEOUT_MS", "600000"),
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": value("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
            "IS_SANDBOX": "1",
        }
    )
    env.pop("ANTHROPIC_API_KEY", None)
    return env


def run_claude(
    *,
    session_id: str,
    workspace: Path,
    prompt: str,
    env: dict[str, str],
    log_path: Path,
    stderr_path: Path,
    sys_prompt: str | None = None,
    resume: bool = False,
    timeout: int = 3600,
) -> None:
    claude_bin = shutil.which("claude")
    if not claude_bin:
        raise RuntimeError("claude CLI not found in PATH")
    proc_env = env.copy()
    proc_env["AI_APP_WORKSPACE"] = str(workspace)
    proc_env["AI_APP_PROJECT_ROOT"] = str(ROOT)
    cmd = [
        claude_bin,
        "--dangerously-skip-permissions",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
        "-p",
        prompt,
    ]
    if resume:
        cmd += ["-r", session_id]
    else:
        cmd += ["--session-id", session_id]
        if sys_prompt:
            cmd += ["--append-system-prompt", sys_prompt]
    with log_path.open("wb") as out, stderr_path.open("wb") as err:
        subprocess.run(
            cmd,
            cwd=ROOT,
            env=proc_env,
            stdout=out,
            stderr=err,
            timeout=timeout,
            check=True,
        )


def result_text(log_path: Path) -> str:
    result = ""
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result" and isinstance(event.get("result"), str):
            result = event["result"]
    return result


def tool_counts(log_path: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        blocks: list[dict[str, Any]] = []
        if event.get("type") == "assistant":
            blocks = event.get("message", {}).get("content", []) or []
        for block in blocks:
            if block.get("type") == "tool_use":
                name = block.get("name") or "unknown"
                counts[name] = counts.get(name, 0) + 1
    return counts


def validate_app(app_path: Path) -> tuple[bool, str]:
    if not app_path.exists():
        return False, "app.json missing"
    output: list[str] = []
    try:
        json.loads(app_path.read_text(encoding="utf-8"))
        output.append("json syntax: OK")
    except Exception as exc:
        return False, f"json syntax: {exc}"

    commands = [
        [sys.executable, "backend/repair_json_app.py", str(app_path)],
        [sys.executable, "backend/validate_json_app.py", str(app_path)],
    ]
    for cmd in commands:
        proc = subprocess.run(
            cmd,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        output.append(proc.stdout)
        if proc.returncode != 0:
            return False, "\n".join(output)
    try:
        json.loads(app_path.read_text(encoding="utf-8"))
        output.append("json syntax after repair: OK")
    except Exception as exc:
        return False, "\n".join(output + [f"json syntax after repair: {exc}"])
    return True, "\n".join(output).strip()


def free_port() -> int:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


class JsonHelper(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/json":
            self.send_response(404)
            self.end_headers()
            return
        query = parse_qs(parsed.query)
        path = Path(unquote((query.get("path") or [""])[0]))
        if not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def serve_directory(directory: Path, port: int) -> http.server.ThreadingHTTPServer:
    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
        *args, directory=str(directory), **kwargs
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def serve_json_helper(port: int) -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), JsonHelper)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def ws_connect(ws_url: str) -> socket.socket:
    parsed = urlparse(ws_url)
    path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    sock = socket.create_connection((parsed.hostname or "127.0.0.1", parsed.port or 80))
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
    sock.settimeout(0.5)
    return sock


def ws_send(sock: socket.socket, payload: dict[str, Any]) -> None:
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
    sock.sendall(header + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(sock: socket.socket) -> dict[str, Any] | None:
    def read_exact(n: int) -> bytes:
        out = b""
        while len(out) < n:
            out += sock.recv(n - len(out))
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
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    if opcode in (8, 9):
        return None
    return json.loads(data.decode("utf-8", errors="replace"))


def capture_screenshot(app_path: Path, out_png: Path, width: int, height: int) -> str:
    if not (ROOT / "build/web/index.html").exists():
        raise RuntimeError("build/web missing; run flutter build web first")
    web_port = free_port()
    json_port = free_port()
    cdp_port = free_port()
    web_server = serve_directory(ROOT / "build/web", web_port)
    json_server = serve_json_helper(json_port)
    chrome_dir = OUT_ROOT / "chrome-profile"
    shutil.rmtree(chrome_dir, ignore_errors=True)
    url = (
        f"http://127.0.0.1:{web_port}/?local_json={quote(str(app_path), safe='')}"
        f"&local_json_server=http://127.0.0.1:{json_port}/json"
    )
    chrome = subprocess.Popen(
        [
            "google-chrome",
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--lang=zh-CN",
            "--remote-debugging-address=127.0.0.1",
            f"--remote-debugging-port={cdp_port}",
            f"--user-data-dir={chrome_dir}",
            f"--window-size={max(width, 800)},{max(height, 1000)}",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 15
        pages: list[dict[str, Any]] = []
        while time.time() < deadline:
            try:
                pages = json.load(urlopen(f"http://127.0.0.1:{cdp_port}/json/list"))
                if pages:
                    break
            except Exception:
                time.sleep(0.2)
        page = next(p for p in pages if p.get("type") == "page")
        sock = ws_connect(page["webSocketDebuggerUrl"])
        counter = 1

        def rpc(method: str, params: dict[str, Any] | None = None, timeout: float = 10) -> dict[str, Any]:
            nonlocal counter
            msg_id = counter
            counter += 1
            msg: dict[str, Any] = {"id": msg_id, "method": method}
            if params is not None:
                msg["params"] = params
            ws_send(sock, msg)
            end = time.time() + timeout
            while time.time() < end:
                try:
                    response = ws_recv(sock)
                except socket.timeout:
                    continue
                if response and response.get("id") == msg_id:
                    return response
            raise TimeoutError(method)

        rpc("Page.enable")
        rpc("Runtime.enable")
        rpc("Emulation.setLocaleOverride", {"locale": "zh-CN"})
        rpc(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": width,
                "height": height,
                "deviceScaleFactor": 1,
                "mobile": True,
            },
        )
        try:
            rpc("Page.navigate", {"url": url}, timeout=3)
        except TimeoutError:
            # Chrome may keep the navigation command open while Flutter boots;
            # the navigation has still been issued, so continue polling.
            pass
        deadline = time.time() + 45
        while time.time() < deadline:
            time.sleep(1)
            try:
                ready = rpc(
                    "Runtime.evaluate",
                    {
                        "expression": (
                            "document.querySelector('flt-glass-pane') !== null"
                            " || document.body.innerText.length > 0"
                        ),
                        "returnByValue": True,
                    },
                    timeout=2,
                )
                value = ready.get("result", {}).get("result", {}).get("value")
                if value:
                    break
            except Exception:
                pass
        # Flutter Web can report the glass pane before fallback fonts finish
        # settling; a short extra wait avoids CJK tofu/striped glyph captures.
        time.sleep(6)
        shot = rpc(
            "Page.captureScreenshot",
            {"format": "png", "captureBeyondViewport": False},
            timeout=10,
        )
        data = shot.get("result", {}).get("data")
        if not data:
            raise RuntimeError("Chrome did not return screenshot data")
        out_png.write_bytes(base64.b64decode(data))
        return url
    finally:
        chrome.terminate()
        with contextlib.suppress(Exception):
            chrome.wait(timeout=5)
        web_server.shutdown()
        json_server.shutdown()


def production_cli_prompt(last_msg: str, workspace: Path) -> str:
    workspace_note = (
        "\n\n本轮后端已为你分配独立工作目录，必须使用它隔离所有临时文件："
        f"\nAI_APP_WORKSPACE={workspace}"
        "\n生成器、下载的 manifest、app.json、校验输出都放在 AI_APP_WORKSPACE 下；"
        "不要写 /tmp/app.json 或 /tmp/generate_app.py。"
    )
    return (
        f"本轮用户的请求:\n<user_request>\n{last_msg}\n</user_request>"
        f"{workspace_note}\n请实现用户要求并严格按照系统提示词{GENERATE_PROMPT_PATH}中的信息答复用户；"
        "如果该提示词要求先分类、读取索引或按需阅读分层文档，每一轮都必须重新执行。"
        "不要遗忘工作目录、repair/validate、上传和最终标签规则。"
    )


def run_round(args: argparse.Namespace) -> int:
    case_text = CASES.get(args.case, args.case)
    strategy_text = STRATEGIES[args.strategy]
    round_dir = OUT_ROOT / args.round
    workspace = round_dir / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    session_id = str(uuid.uuid4())
    env = provider_env(args.env_file)
    sys_prompt = load_prompt(parse_env(args.env_file))
    strategy_hint = f"\n\n补充要求：{strategy_text}" if args.inject_strategy else ""
    first_msg = (
        f"{case_text}{strategy_hint}\n"
        "先和我确认方案，只需要提出你会怎么做和需要确认的问题，先不要生成 JSON。"
    )
    second_msg = f"确认按你的方案做。不要再追问，现在生成完整 APP。需求仍然是：{case_text}{strategy_hint}"
    first = production_cli_prompt(first_msg, workspace)
    second = production_cli_prompt(second_msg, workspace)
    meta = {
        "round": args.round,
        "case": args.case,
        "case_text": case_text,
        "strategy": args.strategy,
        "strategy_text": strategy_text,
        "inject_strategy": args.inject_strategy,
        "prompt_mode": "production_equivalent",
        "viewport": {"width": args.width, "height": args.height},
        "session_id": session_id,
        "workspace": str(workspace),
        "started_at": int(time.time()),
    }
    (round_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[{args.round}] discussion")
    run_claude(
        session_id=session_id,
        workspace=workspace,
        prompt=first,
        env=env,
        log_path=round_dir / "01_discuss.jsonl",
        stderr_path=round_dir / "01_discuss.stderr",
        sys_prompt=sys_prompt,
        resume=False,
        timeout=args.timeout,
    )
    print(f"[{args.round}] generate")
    run_claude(
        session_id=session_id,
        workspace=workspace,
        prompt=second,
        env=env,
        log_path=round_dir / "02_generate.jsonl",
        stderr_path=round_dir / "02_generate.stderr",
        resume=True,
        timeout=args.timeout,
    )
    app_path = workspace / "app.json"
    ok, validation = validate_app(app_path)
    screenshot = ""
    small_screenshot = ""
    render_url = ""
    if ok and not args.no_capture:
        screenshot_path = round_dir / "mobile.png"
        render_url = capture_screenshot(app_path, screenshot_path, args.width, args.height)
        screenshot = str(screenshot_path)
        if args.capture_small:
            small_screenshot_path = round_dir / "mobile-small.png"
            capture_screenshot(
                app_path,
                small_screenshot_path,
                args.small_width,
                args.small_height,
            )
            small_screenshot = str(small_screenshot_path)
    result = {
        **meta,
        "finished_at": int(time.time()),
        "app_path": str(app_path),
        "valid": ok,
        "validation": validation[-4000:],
        "screenshot": screenshot,
        "small_screenshot": small_screenshot,
        "render_url": render_url,
        "tools": tool_counts(round_dir / "02_generate.jsonl"),
        "final_text": result_text(round_dir / "02_generate.jsonl")[-2000:],
    }
    (round_dir / "result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if ok else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--round", required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument(
        "--strategy", choices=sorted(STRATEGIES), default="native_brief"
    )
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    parser.add_argument("--small-width", type=int, default=DEFAULT_SMALL_WIDTH)
    parser.add_argument("--small-height", type=int, default=DEFAULT_SMALL_HEIGHT)
    parser.add_argument("--no-capture", action="store_true")
    parser.add_argument("--capture-small", action="store_true")
    parser.add_argument(
        "--inject-strategy",
        action="store_true",
        help="Opt in to extra research guidance; default prompts match backend production injection.",
    )
    args = parser.parse_args()
    return run_round(args)


if __name__ == "__main__":
    raise SystemExit(main())
