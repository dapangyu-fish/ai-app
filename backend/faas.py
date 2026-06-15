"""FaaS control-plane routes.

The first iteration keeps invocation auth-free as requested. Management routes
can also run without auth while FAAS_REQUIRE_AUTH=0, but if a Bearer token is
present the backend always trusts the token-derived Supabase user over any
client-supplied user_id.
"""

from __future__ import annotations

import hmac
import time
from urllib.parse import quote

import requests
from flask import Response, jsonify, request, stream_with_context

try:
    from auth import verify_access_token
    from config import FAAS_DEPLOY_MODE, FAAS_OPENFAAS_GATEWAY, FAAS_REQUIRE_AUTH, FAAS_RUNTIME_TOKEN
    from faas_store import (
        FaaSError,
        FaaSValidationError,
        deploy_bundle,
        disable_service,
        ensure_local_docker_runtime_for_service,
        ensure_tables,
        get_service,
        list_services,
        load_bundle_bytes,
        openfaas_gateway_for_service,
        runtime_bundle_for_service,
        runtime_token_for_service,
    )
except ModuleNotFoundError:
    from backend.auth import verify_access_token
    from backend.config import FAAS_DEPLOY_MODE, FAAS_OPENFAAS_GATEWAY, FAAS_REQUIRE_AUTH, FAAS_RUNTIME_TOKEN
    from backend.faas_store import (
        FaaSError,
        FaaSValidationError,
        deploy_bundle,
        disable_service,
        ensure_local_docker_runtime_for_service,
        ensure_tables,
        get_service,
        list_services,
        load_bundle_bytes,
        openfaas_gateway_for_service,
        runtime_bundle_for_service,
        runtime_token_for_service,
    )


_LOCAL_DOCKER_MODES = {"local-docker", "docker", "docker-local"}


def _request_user_id() -> str | None:
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        user = verify_access_token(auth[7:])
        if user:
            return str(user.get("id") or "").strip() or None
        if FAAS_REQUIRE_AUTH:
            return None
    if FAAS_REQUIRE_AUTH:
        return None
    body = request.get_json(silent=True) if request.is_json else None
    if isinstance(body, dict):
        value = body.get("user_id") or body.get("owner_user_id")
        if value:
            return str(value).strip()
    value = request.args.get("user_id") or request.headers.get("X-MyApp-User-Id")
    return str(value).strip() if value else None


def _json_error(message: str, status: int, *, code: str = "FAAS_ERROR") -> tuple[Response, int]:
    return jsonify({"error": message, "code": code}), status


def list_user_services():
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    include_disabled = str(request.args.get("include_disabled") or request.args.get("all") or "").strip().lower() in {"1", "true", "yes", "on"}
    try:
        return jsonify({"services": list_services(user_id, include_disabled=include_disabled)})
    except Exception as exc:
        return _json_error(str(exc), 500)


def get_user_service(service_id: str):
    service = get_service(service_id)
    if not service:
        return _json_error("service not found", 404, code="FAAS_NOT_FOUND")
    user_id = _request_user_id()
    if FAAS_REQUIRE_AUTH and service.get("owner_user_id") != user_id:
        return _json_error("forbidden", 403, code="FAAS_FORBIDDEN")
    return jsonify({"service": service})


def disable_user_service(service_id: str):
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    try:
        service = disable_service(user_id, service_id)
    except FaaSValidationError as exc:
        return _json_error(str(exc), 404, code="FAAS_NOT_FOUND")
    except FaaSError as exc:
        return _json_error(str(exc), 500, code="FAAS_DISABLE_FAILED")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_DISABLE_FAILED")
    return jsonify({"ok": True, "service": service})


def deploy_service():
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    try:
        if request.mimetype == "application/octet-stream":
            bundle = load_bundle_bytes(request.get_data())
        else:
            bundle = request.get_json(silent=True) or {}
        result = deploy_bundle(user_id, bundle, source="api")
    except FaaSValidationError as exc:
        return _json_error(str(exc), 400, code="FAAS_VALIDATION_FAILED")
    except FaaSError as exc:
        return _json_error(str(exc), 500, code="FAAS_DEPLOY_FAILED")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_DEPLOY_FAILED")
    return jsonify({
        "ok": True,
        "service": {
            "service_id": result.service_id,
            "function_name": result.function_name,
            "status": result.status,
            "commit_sha": result.commit_sha,
            "code_path": result.code_path,
            "public_base_url": result.public_base_url,
            "routes": result.routes,
            "deployment_id": result.deployment_id,
        },
    })


def health():
    try:
        ensure_tables()
        tables = True
    except Exception:
        tables = False
    gateway = FAAS_OPENFAAS_GATEWAY
    gateway_ok: bool | None = None
    if gateway:
        try:
            resp = requests.get(f"{gateway.rstrip('/')}/healthz", timeout=1.5)
            gateway_ok = 200 <= resp.status_code < 500
        except requests.RequestException:
            gateway_ok = False
    return jsonify({
        "ok": tables,
        "tables": tables,
        "deploy_mode": FAAS_DEPLOY_MODE,
        "openfaas_gateway": gateway,
        "openfaas_gateway_ok": gateway_ok,
        "auth_required": FAAS_REQUIRE_AUTH,
    })


def runtime_bundle(service_id: str):
    if not FAAS_RUNTIME_TOKEN:
        return _json_error("FaaS runtime token is not configured", 503, code="FAAS_RUNTIME_TOKEN_MISSING")
    token = request.headers.get("X-MyApp-FaaS-Runtime-Token", "")
    expected = runtime_token_for_service(service_id)
    if not expected or not hmac.compare_digest(token, expected):
        return _json_error("forbidden", 403, code="FAAS_RUNTIME_FORBIDDEN")
    try:
        return jsonify(runtime_bundle_for_service(service_id))
    except FaaSValidationError as exc:
        return _json_error(str(exc), 404, code="FAAS_NOT_FOUND")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_RUNTIME_BUNDLE_FAILED")


def _proxy_headers(upstream: requests.Response) -> list[tuple[str, str]]:
    excluded = {
        "connection",
        "content-encoding",
        "content-length",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }
    return [(key, value) for key, value in upstream.headers.items() if key.lower() not in excluded]


def _safe_route_suffix(route_path: str) -> str:
    subpath = route_path.strip("/")
    if not subpath:
        return ""
    if "://" in subpath or subpath.startswith(("/", "\\")) or "\\" in subpath:
        raise ValueError("invalid FaaS route path")
    parts = [part for part in subpath.split("/") if part not in {"", ".", ".."}]
    if len(parts) != len([part for part in subpath.split("/") if part]):
        raise ValueError("invalid FaaS route path")
    encoded = "/".join(quote(part, safe="") for part in parts)
    return "/" + encoded


def _append_safe_route_path(upstream: str, route_path: str) -> str:
    suffix = _safe_route_suffix(route_path)
    return upstream.rstrip("/") + suffix if suffix else upstream


def _route_segments(path: str) -> list[str]:
    value = str(path or "").strip()
    if not value.startswith("/"):
        value = "/" + value
    return [part for part in value.strip("/").split("/") if part]


def _route_pattern_matches(pattern: str, actual: str) -> bool:
    pattern_parts = _route_segments(pattern)
    actual_parts = _route_segments(actual)
    i = 0
    j = 0
    while i < len(pattern_parts) and j < len(actual_parts):
        part = pattern_parts[i]
        if part.startswith("<") and part.endswith(">"):
            inner = part[1:-1]
            if inner.startswith("path:"):
                return j < len(actual_parts)
            i += 1
            j += 1
            continue
        if part != actual_parts[j]:
            return False
        i += 1
        j += 1
    return i == len(pattern_parts) and j == len(actual_parts)


def _route_allowed(service: dict, route_path: str, method: str) -> tuple[bool, int, str]:
    routes = service.get("routes") or []
    if not routes:
        return True, 200, ""
    path = "/" + route_path.strip("/") if route_path.strip("/") else "/"
    requested_method = str(method or "GET").upper()
    path_seen = False
    for item in routes:
        if not isinstance(item, dict):
            continue
        pattern = str(item.get("path") or "/")
        if not _route_pattern_matches(pattern, path):
            continue
        path_seen = True
        methods = {str(value).strip().upper() for value in (item.get("methods") or ["GET"])}
        if requested_method in methods or (requested_method == "HEAD" and "GET" in methods):
            return True, 200, ""
    if path_seen:
        return False, 405, "method is not allowed for this FaaS route"
    return False, 404, "route is not declared by this FaaS service"


def invoke_service(service_id: str, route_path: str = ""):
    service = get_service(service_id)
    if not service:
        return _json_error("service not found", 404, code="FAAS_NOT_FOUND")
    if service.get("status") != "ready":
        return _json_error(
            f"service is not ready: {service.get('status') or 'unknown'}",
            409,
            code="FAAS_NOT_READY",
        )
    try:
        safe_route_suffix = _safe_route_suffix(route_path)
    except ValueError as exc:
        return _json_error(str(exc), 400, code="FAAS_ROUTE_INVALID")
    allowed, status, message = _route_allowed(service, route_path, request.method)
    if not allowed:
        return _json_error(message, status, code="FAAS_ROUTE_NOT_ALLOWED")

    mode = FAAS_DEPLOY_MODE
    if mode in _LOCAL_DOCKER_MODES:
        try:
            upstream = ensure_local_docker_runtime_for_service(service)
        except FaaSError as exc:
            return _json_error(str(exc), 502, code="FAAS_INVOKE_FAILED")
    else:
        gateway = (
            openfaas_gateway_for_service(service)
            if mode == "openfaas"
            else FAAS_OPENFAAS_GATEWAY.rstrip("/")
        )
        if not gateway:
            return _json_error(
                "FaaS gateway is not configured and local runtime mode is disabled",
                503,
                code="FAAS_GATEWAY_UNCONFIGURED",
            )
        function_name = str(service.get("function_name") or "").strip()
        if not function_name:
            return _json_error("service function name is missing", 500, code="FAAS_MISCONFIGURED")
        upstream = f"{gateway}/function/{quote(function_name)}"
    if safe_route_suffix:
        upstream = upstream.rstrip("/") + safe_route_suffix
    if request.query_string:
        upstream = f"{upstream}?{request.query_string.decode('utf-8', errors='replace')}"

    sensitive_request_headers = {
        "host",
        "content-length",
        "connection",
        "authorization",
        "cookie",
        "x-myapp-faas-runtime-token",
        "x-myapp-user-id",
    }
    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in sensitive_request_headers
    }
    request_body = request.get_data()
    # Tolerate faasd/OpenFaaS scale-from-zero cold starts: faasd reports a
    # function "ready" as soon as its container task runs, before the runtime is
    # listening, so the first proxy can fail with a gateway-level 5xx
    # ("Can't reach service" / connection refused). The request never reached the
    # generated app, so retrying is safe for any HTTP method.
    _cold_markers = ("can't reach service", "cannot reach", "no endpoints available", "connection refused")
    max_attempts = 5
    resp = None
    for attempt in range(max_attempts):
        try:
            resp = requests.request(
                request.method,
                upstream,
                headers=headers,
                data=request_body,
                stream=True,
                timeout=(5, 65),
            )
        except requests.RequestException as exc:
            if attempt < max_attempts - 1:
                time.sleep(1.2)
                continue
            return _json_error(str(exc), 502, code="FAAS_INVOKE_FAILED")
        if resp.status_code >= 500 and attempt < max_attempts - 1:
            peek = resp.content
            resp.close()
            if any(marker in peek.decode("utf-8", "replace").lower() for marker in _cold_markers):
                time.sleep(1.2)
                continue
            return Response(peek, status=resp.status_code, headers=_proxy_headers(resp))
        break

    def generate():
        try:
            for chunk in resp.iter_content(chunk_size=65536):
                if chunk:
                    yield chunk
        finally:
            resp.close()

    return Response(
        stream_with_context(generate()),
        status=resp.status_code,
        headers=_proxy_headers(resp),
    )
