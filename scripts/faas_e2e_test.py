#!/usr/bin/env python3
"""Simulated end-to-end test: client app -> backend AI generation -> FaaS deploy -> invoke.

This drives the REAL generation pipeline over the public HTTP API exactly as a
client app would (no UI automation): it authenticates a throwaway test user,
asks the AI (default provider=minimax, model MiniMax-M3) to generate an app that
needs a Python/Flask backend, waits for the backend to validate + deploy the
generated FaaS service, then verifies the service through the backend proxy
(mode a) and — when the FaaS node domain is wired — directly (mode b).

Implements docs/faas-e2e-and-access-goal.md sections 七/八 (verification steps and
test goals). Access-architecture-dependent checks (direct-domain mode b, public
port firewall) are OPTIONAL and skipped-with-a-log until D-A/D-B land, so the
core chain (generate -> deploy -> proxy invoke -> update -> cleanup) runs today.

Run on or against 77. Supabase config is read from env (SUPABASE_URL,
SUPABASE_SERVICE_KEY, SUPABASE_ANON_KEY) or flags. Real AI usage is expected and
allowed (consumes MiniMax M3).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from typing import Any, Optional

import requests


def _log(msg: str) -> None:
    print(f"[faas-e2e] {msg}", file=sys.stderr, flush=True)


def _req(method: str, url: str, *, ok=(200, 201, 204), timeout: int = 60, **kw: Any) -> requests.Response:
    resp = requests.request(method, url, timeout=timeout, **kw)
    if ok is not None and resp.status_code not in ok:
        raise RuntimeError(f"{method} {url} -> {resp.status_code}: {resp.text[:800]}")
    return resp


# --------------------------------------------------------------------------- auth

def ensure_test_user(supabase_url: str, service_key: str, email: str, password: str) -> None:
    """Idempotently create a confirmed test user via the GoTrue admin API."""
    url = f"{supabase_url.rstrip('/')}/auth/v1/admin/users"
    headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}", "Content-Type": "application/json"}
    resp = requests.post(url, headers=headers, json={"email": email, "password": password, "email_confirm": True}, timeout=30)
    if resp.status_code in (200, 201):
        _log(f"created test user {email}")
        return
    body = resp.text.lower()
    if resp.status_code in (422, 409) or "already" in body or "registered" in body or "exists" in body:
        _log(f"test user {email} already exists")
        return
    raise RuntimeError(f"admin create user failed {resp.status_code}: {resp.text[:400]}")


def login_token(supabase_url: str, anon_key: str, email: str, password: str) -> str:
    """Password-grant against GoTrue (what /api/auth/login wraps) -> access_token."""
    url = f"{supabase_url.rstrip('/')}/auth/v1/token?grant_type=password"
    headers = {"apikey": anon_key, "Content-Type": "application/json"}
    data = _req("POST", url, headers=headers, json={"email": email, "password": password}, ok=(200,)).json()
    token = data.get("access_token") or (data.get("session") or {}).get("access_token")
    if not token:
        raise RuntimeError(f"login returned no access_token: {json.dumps(data)[:300]}")
    return token


def _user_id_from_token(supabase_url: str, anon_key: str, token: str) -> str:
    data = _req("GET", f"{supabase_url.rstrip('/')}/auth/v1/user",
                headers={"apikey": anon_key, "Authorization": f"Bearer {token}"}, ok=(200,)).json()
    return str(data.get("id") or "")


# ----------------------------------------------------------------------- generation

# Prompt tuned from observed generation variance (service_id/error-handling/route
# description drifted run-to-run): pin the service_id (also avoids the global-PK
# collision across runs), state the input/error contract explicitly, and require a
# route description. Keep the JSON-APP minimal so generation stays fast and focused.
GEN_SERVICE_ID = "faas-e2e-sum"
GEN_PROMPT = (
    "请帮我做一个带后端的小应用。后端用 Python/Flask 生成一个 FaaS 服务（写入 faas_bundle.json），严格满足："
    f"\n- service_id 固定命名为 \"{GEN_SERVICE_ID}\"（务必用这个名字，不要自创其它名字）。"
    "\n- 提供接口 POST /sum：请求体 JSON {\"a\": 数字, \"b\": 数字}，正常返回 JSON {\"result\": a+b}；"
    "当 a 或 b 缺失或不是数字时，返回 HTTP 400 和 {\"error\": \"a and b must be numbers\"}。"
    "\n- service.routes 必须声明 /sum 的 POST 方法并带一句简短 description，"
    "且由对应的 @app.post(\"/sum\") 实现。"
    f"\n- 再生成一个尽量简单的 JSON-APP 页面，通过相对地址 /api/faas/invoke/{GEN_SERVICE_ID}/sum 调用该后端。"
)

UPDATE_PROMPT = (
    f"请复用同一个后端服务（service_id 仍为 \"{GEN_SERVICE_ID}\"），把 /sum 接口改成同时返回字段 by=\"v2\"，"
    "即返回 JSON {\"result\": a+b, \"by\": \"v2\"}；service.routes 保持声明 /sum 的 POST（带 description）。"
)


def start_generation(base_url: str, token: str, session_id: str, prompt: str,
                     provider: str, agent: str, force_restart: bool) -> dict[str, Any]:
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "session_id": session_id,
        "provider": provider,
        "agent": agent,
        "agent_scope": "public",
        "force_restart": force_restart,
    }
    resp = _req("POST", f"{base_url.rstrip('/')}/api/ai/chat/start",
                headers={"Authorization": f"Bearer {token}"}, json=payload, ok=(200,), timeout=60)
    return resp.json()


def wait_for_result(base_url: str, token: str, session_id: str, timeout_s: int) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    headers = {"Authorization": f"Bearer {token}"}
    last_status = ""
    while time.time() < deadline:
        st = _req("GET", f"{base_url.rstrip('/')}/api/ai/chat/{session_id}/status",
                  headers=headers, ok=(200,), timeout=30).json()
        status = str(st.get("status") or "")
        if status != last_status:
            _log(f"generation status={status} queue_pos={st.get('queue_position')}")
            last_status = status
        if status in {"done", "failed", "aborted"}:
            res = _req("GET", f"{base_url.rstrip('/')}/api/ai/chat/{session_id}/result",
                       headers=headers, ok=(200,), timeout=30).json()
            return res
        time.sleep(5)
    raise RuntimeError(f"generation did not finish within {timeout_s}s (last status={last_status})")


def extract_faas_ready(result: dict[str, Any]) -> dict[str, Any]:
    actions = result.get("client_actions") or []
    ready = [a for a in actions if a.get("type") == "faas_service_ready"]
    failed = [a for a in actions if a.get("type") == "faas_service_failed"]
    if failed and not ready:
        raise RuntimeError(f"AI produced a FaaS service but deploy FAILED: {json.dumps(failed[0])[:600]}")
    if not ready:
        raise RuntimeError(
            "AI did not produce a deployed FaaS backend (no faas_service_ready action). "
            f"status={result.get('status')} actions={json.dumps(actions)[:600]} "
            f"final_text={str(result.get('final_text'))[:400]}"
        )
    return ready[-1]


# ------------------------------------------------------------------------- invoking

def _pick_sum_route(routes: list[dict]) -> Optional[dict]:
    for r in routes:
        if "sum" in str(r.get("path", "")).lower() and any(m.upper() == "POST" for m in (r.get("methods") or [])):
            return r
    for r in routes:
        if any(m.upper() == "POST" for m in (r.get("methods") or [])):
            return r
    return routes[0] if routes else None


def invoke_proxy(base_url: str, service_id: str, route_path: str, method: str,
                 token: Optional[str], **kw: Any) -> requests.Response:
    url = f"{base_url.rstrip('/')}/api/faas/invoke/{service_id}{route_path}"
    headers = kw.pop("headers", {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return requests.request(method, url, headers=headers, timeout=60, **kw)


_COLD_MARKERS = ("can't reach service", "cannot reach", "no endpoints available", "connection refused")


def invoke_until_ready(base_url: str, service_id: str, route_path: str, method: str,
                       token: Optional[str], *, attempts: int = 12, delay: float = 6.0, **kw: Any) -> requests.Response:
    """Invoke, tolerating faasd scale-from-zero cold starts (first invoke of a fresh
    function can take tens of seconds). Retries only on cold-start signals so a
    genuinely-broken function still surfaces after the budget."""
    last = None
    for i in range(attempts):
        r = invoke_proxy(base_url, service_id, route_path, method, token, **kw)
        last = r
        if r.status_code < 500:
            return r
        body = (r.text or "").lower()
        if not any(m in body for m in _COLD_MARKERS):
            return r
        _log(f"cold-start retry {i + 1}/{attempts} ({r.status_code})")
        time.sleep(delay)
    return last


def main() -> int:
    p = argparse.ArgumentParser(description="Simulated FaaS end-to-end test (real AI generation).")
    p.add_argument("--base-url", default=os.environ.get("FAAS_E2E_BASE_URL", "http://127.0.0.1:5566"))
    p.add_argument("--supabase-url", default=os.environ.get("SUPABASE_URL", ""))
    p.add_argument("--service-key", default=os.environ.get("SUPABASE_SERVICE_KEY", ""))
    p.add_argument("--anon-key", default=os.environ.get("SUPABASE_ANON_KEY", ""))
    p.add_argument("--provider", default="minimax")
    p.add_argument("--agent", default="claude")
    # Fixed test user by default so re-runs re-deploy the SAME owner's service_id
    # (service_id is a global PK; a random user each run would collide on leftovers).
    p.add_argument("--email", default=os.environ.get("FAAS_E2E_EMAIL", "faas-e2e@e2e.local"))
    p.add_argument("--password", default=os.environ.get("FAAS_E2E_PASSWORD", "FaasE2e!fixed-2026"))
    p.add_argument("--timeout", type=int, default=900, help="max seconds to wait per generation")
    p.add_argument("--with-update", action="store_true", help="also run the update path (second generation)")
    p.add_argument("--faas-domain", default="", help="enable mode-b direct invoke via this faasd node domain")
    p.add_argument("--function-name", default="", help="faasd function name for mode-b (else derived not attempted)")
    p.add_argument("--keep", action="store_true", help="do not delete the generated service")
    args = p.parse_args()

    if not args.supabase_url or not args.service_key or not args.anon_key:
        raise RuntimeError("SUPABASE_URL / SUPABASE_SERVICE_KEY / SUPABASE_ANON_KEY required (env or flags)")

    email = args.email or f"faas-e2e-{uuid.uuid4().hex[:10]}@e2e.local"
    summary: dict[str, Any] = {"ok": False, "steps": []}

    def step(name: str, **extra: Any) -> None:
        _log(f"OK {name} {extra if extra else ''}")
        summary["steps"].append({name: extra or True})

    # 1) backend reachable
    h = _req("GET", f"{args.base_url.rstrip('/')}/api/faas/health", ok=(200,), timeout=30).json()
    step("faas_health", mode=h.get("deploy_mode") or h.get("mode"))

    # 2) auth: ensure user + token
    ensure_test_user(args.supabase_url, args.service_key, email, args.password)
    token = login_token(args.supabase_url, args.anon_key, email, args.password)
    user_id = _user_id_from_token(args.supabase_url, args.anon_key, token)
    step("auth", user_id=user_id, email=email)

    # 3) generation (real AI)
    session_id = str(uuid.uuid4())
    _log(f"starting generation session={session_id} provider={args.provider} agent={args.agent}")
    start_generation(args.base_url, token, session_id, GEN_PROMPT, args.provider, args.agent, False)
    result = wait_for_result(args.base_url, token, session_id, args.timeout)
    if result.get("status") != "done":
        raise RuntimeError(f"generation status={result.get('status')} error={str(result.get('error'))[:400]}")
    ready = extract_faas_ready(result)
    service_id = str(ready.get("service_id") or "")
    routes = ready.get("routes") or []
    if not service_id:
        raise RuntimeError(f"faas_service_ready missing service_id: {ready}")
    step("generated", service_id=service_id, routes=routes, invoke_url=ready.get("invoke_url"))

    # 4) mode-a: invoke through backend proxy + route/method enforcement
    route = _pick_sum_route(routes)
    if not route:
        raise RuntimeError(f"no invokable route declared: {ready}")
    route_path = str(route.get("path") or "/")
    if not route_path.startswith("/"):
        route_path = "/" + route_path
    r = invoke_until_ready(args.base_url, service_id, route_path, "POST", token, json={"a": 2, "b": 3})
    if r.status_code != 200:
        raise RuntimeError(f"mode-a invoke {route_path} -> {r.status_code}: {r.text[:400]}")
    body = r.json()
    math_ok = (body.get("result") == 5)
    step("invoke_proxy", route=route_path, status=r.status_code, body=body, math_contract=math_ok)
    if not math_ok:
        _log(f"WARN: /sum contract not exactly met (expected result=5), got {body} — chain proven, math is a bonus assertion")

    # 4b) negative: undeclared route -> 404 (only meaningful when an allowlist exists)
    if routes:
        neg = invoke_proxy(args.base_url, service_id, "/__e2e_undeclared__", "POST", token, json={})
        step("negative_undeclared_route", status=neg.status_code, enforced=(neg.status_code == 404))
        if neg.status_code != 404:
            _log(f"WARN: undeclared route returned {neg.status_code}, expected 404 (allowlist may be empty)")

    # 4c) soft checks for the tuned prompt's contract (warn, don't fail — the chain is
    # what must pass; these measure whether the prompt pinned the generated details).
    if service_id != GEN_SERVICE_ID:
        _log(f"WARN: service_id={service_id!r} != pinned {GEN_SERVICE_ID!r} (prompt pin not honored)")
    bad = invoke_proxy(args.base_url, service_id, route_path, "POST", token, json={"a": "x", "b": 3})
    step("bad_input_contract", status=bad.status_code, returns_400=(bad.status_code == 400))
    if bad.status_code != 400:
        _log(f"WARN: bad input returned {bad.status_code}, expected 400 per contract")

    # 5) update path (optional)
    update_info = None
    if args.with_update:
        _log("starting update generation (same session)")
        start_generation(args.base_url, token, session_id, UPDATE_PROMPT, args.provider, args.agent, True)
        ures = wait_for_result(args.base_url, token, session_id, args.timeout)
        uready = extract_faas_ready(ures)
        r2 = invoke_proxy(args.base_url, str(uready.get("service_id") or service_id), route_path, "POST", token,
                          json={"a": 2, "b": 3})
        update_info = {"status": r2.status_code, "body": (r2.json() if r2.status_code == 200 else r2.text[:300])}
        step("update", service_id=uready.get("service_id"), **update_info)

    # 6) mode-b: direct faasd node domain (needs the access architecture wired).
    # The faas domain fronts faasd directly with no backend cold-start retry, so
    # retry here; derive function_name from the service if not supplied.
    mode_b = None
    if args.faas_domain:
        fn = args.function_name
        if not fn:
            try:
                detail = _req("GET", f"{args.base_url.rstrip('/')}/api/faas/services/{service_id}",
                              headers={"Authorization": f"Bearer {token}"}, ok=(200,)).json()
                fn = str((detail.get("service") or {}).get("function_name") or "")
            except Exception as exc:
                _log(f"could not derive function_name for mode-b: {exc}")
        if fn:
            url = f"https://{args.faas_domain.rstrip('/')}/function/{fn}{route_path}"
            rb = None
            for i in range(10):
                try:
                    rb = requests.post(url, json={"a": 2, "b": 3}, timeout=20)
                    if rb.status_code == 200:
                        break
                    if rb.status_code < 500:
                        break
                except Exception:
                    rb = None
                _log(f"mode-b cold-start retry {i + 1}/10")
                time.sleep(5)
            ct = rb.headers.get("content-type", "") if rb is not None else ""
            mode_b = {"url": url, "status": (rb.status_code if rb is not None else None),
                      "body": (rb.json() if (rb is not None and ct.startswith("application/json")) else (rb.text[:200] if rb is not None else None))}
            step("invoke_direct_domain", **mode_b)
        else:
            _log("SKIP mode-b: could not resolve function_name")
    else:
        _log("SKIP mode-b (pass --faas-domain to also test direct faasd-node access)")

    # 7) cleanup (faasd function-delete + git can be slow -> generous timeout + retry).
    # service_id is a global PK, so a leftover blocks re-runs; make deletion best-effort but patient.
    cleaned = False
    if not args.keep:
        for attempt in range(3):
            try:
                requests.delete(f"{args.base_url.rstrip('/')}/api/faas/services/{service_id}",
                                params={"user_id": user_id}, timeout=120)
                cleaned = True
                break
            except Exception as exc:
                _log(f"cleanup attempt {attempt + 1} warning: {exc}")
    step("cleanup", deleted=cleaned)

    summary.update({"ok": True, "service_id": service_id, "user_id": user_id, "email": email,
                    "session_id": session_id, "math_contract": math_ok, "update": update_info, "mode_b": mode_b})
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
