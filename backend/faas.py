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
    from config import AGENT_NODE_TOKEN, FAAS_DEPLOY_MODE, FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER, FAAS_REQUIRE_AUTH, FAAS_RUNTIME_TOKEN
    from faas_store import (
        FaaSError,
        FaaSValidationError,
        build_service_archive,
        deploy_bundle,
        disable_service,
        delete_service,
        running_replica_counts,
        ensure_local_docker_runtime_for_service,
        ensure_tables,
        get_service,
        list_services,
        load_bundle_bytes,
        load_bundle_zip,
        runtime_bundle_for_service,
        service_deploy_mode,
        scale_service,
        runtime_token_for_service,
    )
except ModuleNotFoundError:
    from backend.auth import verify_access_token
    from backend.config import AGENT_NODE_TOKEN, FAAS_DEPLOY_MODE, FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER, FAAS_REQUIRE_AUTH, FAAS_RUNTIME_TOKEN
    from backend.faas_store import (
        FaaSError,
        FaaSValidationError,
        deploy_bundle,
        disable_service,
        delete_service,
        running_replica_counts,
        ensure_local_docker_runtime_for_service,
        ensure_tables,
        get_service,
        list_services,
        load_bundle_bytes,
        load_bundle_zip,
        runtime_bundle_for_service,
        service_deploy_mode,
        scale_service,
        runtime_token_for_service,
    )


_LOCAL_DOCKER_MODES = {"local-docker", "docker", "docker-local"}


def _request_user_id(*, trusted_only: bool = False) -> str | None:
    # Trusted internal call: the agent-node faas proxy (and co-located local
    # agents) authenticate with the shared AGENT_NODE_TOKEN and pass the run's
    # owner explicitly, so an in-run deploy is scoped to the right owner without
    # ever handing the agent a user access token. Owner is a header so it works
    # even when the body is the octet-stream bundle.
    node_token = request.headers.get("X-MyApp-Agent-Node-Token", "")
    if node_token and AGENT_NODE_TOKEN and hmac.compare_digest(node_token, AGENT_NODE_TOKEN):
        owner = str(request.headers.get("X-MyApp-Owner-User-Id", "") or "").strip()
        if owner:
            return owner
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        user = verify_access_token(auth[7:])
        if user:
            return str(user.get("id") or "").strip() or None
        if FAAS_REQUIRE_AUTH:
            return None
    if FAAS_REQUIRE_AUTH:
        return None
    if trusted_only:
        # Mutations (deploy) must not trust a client-supplied identity even when
        # auth is disabled — otherwise a caller could rotate user_id to mint a
        # fresh per-user quota. Only the agent-node token / Bearer paths above
        # count as a trusted owner.
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


def _annotate_running(services: list) -> list:
    """Attach the REAL running-container count per service (0 = scaled to zero) so
    callers (dashboard, CLI) never infer instances from status. One docker query."""
    try:
        counts = running_replica_counts()
    except Exception:
        counts = {}
    for s in services:
        if isinstance(s, dict):
            s["running_replicas"] = int(counts.get(s.get("function_name") or "", 0))
    return services


def list_user_services():
    include_disabled = str(request.args.get("include_disabled") or request.args.get("all") or "").strip().lower() in {"1", "true", "yes", "on"}
    all_users = str(request.args.get("all_users") or "").strip().lower() in {"1", "true", "yes", "on"}
    if all_users:
        # B0-G1 (R14): operator-only, FAIL-CLOSED. An anonymous ?all_users=1 was an
        # enumeration oracle (every service_id + owner, feeding R12 container-name
        # derivation). Require the trusted agent-node operator token regardless of
        # FAAS_REQUIRE_AUTH — the operator CLI and dashboard both send this header.
        node_token = request.headers.get("X-MyApp-Agent-Node-Token", "")
        is_operator = bool(node_token and AGENT_NODE_TOKEN and hmac.compare_digest(node_token, AGENT_NODE_TOKEN))
        if not is_operator:
            return _json_error("all_users listing requires the agent-node operator token", 403, code="FAAS_FORBIDDEN")
        try:
            return jsonify({"services": _annotate_running(list_services("", include_disabled=include_disabled, all_services=True))})
        except Exception as exc:
            return _json_error(str(exc), 500)
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    try:
        return jsonify({"services": _annotate_running(list_services(user_id, include_disabled=include_disabled))})
    except Exception as exc:
        return _json_error(str(exc), 500)


def get_user_service(service_id: str):
    service = get_service(service_id)
    if not service:
        return _json_error("service not found", 404, code="FAAS_NOT_FOUND")
    user_id = _request_user_id()
    if FAAS_REQUIRE_AUTH and service.get("owner_user_id") != user_id:
        return _json_error("forbidden", 403, code="FAAS_FORBIDDEN")
    _annotate_running([service])
    return jsonify({"service": service})


def download_service_archive(service_id: str):
    service = get_service(service_id)
    if not service:
        return _json_error("service not found", 404, code="FAAS_NOT_FOUND")
    user_id = _request_user_id()
    if FAAS_REQUIRE_AUTH and service.get("owner_user_id") != user_id:
        return _json_error("forbidden", 403, code="FAAS_FORBIDDEN")
    # Even without enforced auth, scope to the owner whenever an owner is known
    # (the trusted agent-node/Bearer path supplies it) so one user's agent can
    # never pull another user's service code.
    if not FAAS_REQUIRE_AUTH and user_id and service.get("owner_user_id") != user_id:
        return _json_error("forbidden", 403, code="FAAS_FORBIDDEN")
    try:
        data = build_service_archive(service_id)
    except FaaSValidationError as exc:
        return _json_error(str(exc), 404, code="FAAS_NOT_FOUND")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_ARCHIVE_FAILED")
    slug = str(service.get("service_slug") or service_id)
    return Response(
        data,
        status=200,
        headers={
            "Content-Type": "application/zip",
            "Content-Disposition": f'attachment; filename="{slug}.zip"',
            "Content-Length": str(len(data)),
        },
    )


def scale_user_service(service_id: str):
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    body = request.get_json(silent=True) or {}
    try:
        replicas = int(body.get("replicas"))
    except (TypeError, ValueError):
        return _json_error("replicas must be an integer", 400, code="FAAS_SCALE_INVALID")
    try:
        result = scale_service(user_id, service_id, replicas)
    except FaaSValidationError as exc:
        return _json_error(str(exc), 404, code="FAAS_NOT_FOUND")
    except FaaSError as exc:
        return _json_error(str(exc), 500, code="FAAS_SCALE_FAILED")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_SCALE_FAILED")
    return jsonify({"ok": True, **result})


def disable_user_service(service_id: str):
    # DELETE /api/faas/services/<id>            -> disable (stop containers, keep record)
    # DELETE /api/faas/services/<id>?purge=1    -> HARD delete (drop record + code),
    #                                              also works on already-disabled services.
    user_id = _request_user_id()
    if not user_id:
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    purge = str(request.args.get("purge") or request.args.get("hard") or "").strip().lower() in {"1", "true", "yes", "on"}
    try:
        if purge:
            result = delete_service(user_id, service_id)
            return jsonify({"ok": True, **result})
        service = disable_service(user_id, service_id)
    except FaaSValidationError as exc:
        return _json_error(str(exc), 404, code="FAAS_NOT_FOUND")
    except FaaSError as exc:
        return _json_error(str(exc), 500, code="FAAS_DELETE_FAILED" if purge else "FAAS_DISABLE_FAILED")
    except Exception as exc:
        return _json_error(str(exc), 500, code="FAAS_DELETE_FAILED" if purge else "FAAS_DISABLE_FAILED")
    return jsonify({"ok": True, "service": service})


def deploy_service():
    user_id = _request_user_id(trusted_only=FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER)
    if not user_id:
        if FAAS_DEPLOY_REQUIRE_TRUSTED_OWNER and not FAAS_REQUIRE_AUTH:
            return _json_error(
                "deploy requires a trusted owner (agent-node token or Bearer auth)",
                401,
                code="FAAS_UNTRUSTED_OWNER",
            )
        return _json_error("user_id is required", 401 if FAAS_REQUIRE_AUTH else 400, code="FAAS_USER_REQUIRED")
    try:
        mimetype = (request.mimetype or "").lower()
        if mimetype in {"application/zip", "application/x-zip-compressed", "application/x-zip"}:
            # Multi-file archive upload: a zip of the whole svc folder.
            bundle = load_bundle_zip(request.get_data())
        elif mimetype == "application/octet-stream":
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
    return jsonify({
        "ok": tables,
        "tables": tables,
        "deploy_mode": FAAS_DEPLOY_MODE,
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

    mode = service_deploy_mode(service)
    if mode not in _LOCAL_DOCKER_MODES:
        return _json_error(
            f"service deploy mode '{mode}' is not invocable; only the self-managed Docker runtime is supported",
            503,
            code="FAAS_RUNTIME_UNCONFIGURED",
        )
    try:
        upstream = ensure_local_docker_runtime_for_service(service)
    except FaaSError as exc:
        return _json_error(str(exc), 502, code="FAAS_INVOKE_FAILED")
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
    # Tolerate scale-from-zero cold starts: a just-started container may not be
    # listening yet, so the first proxy can fail with a connection-level 5xx. The
    # request never reached the generated app, so retrying is safe for any method.
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
