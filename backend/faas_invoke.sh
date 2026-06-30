#!/bin/bash
# Agent-driven FaaS self-test. Invokes a deployed service route so the agent can
# verify the backend actually runs (status + body) before wiring/uploading the
# JSON-APP.
#
# Identity: by default the call is authenticated AS THE OWNER (the run token the
# agent-node forwards is honored by the backend), so the function's
# myapp_auth.current_user() resolves and AUTH-GATED WRITE routes return 200 —
# exactly what a logged-in user sees. Set FAAS_INVOKE_ANON=1 to invoke as an
# ANONYMOUS caller instead (current_user() is None), to verify that protected
# routes correctly reject (401/403). Test both directions for auth'd backends.
#
# Usage: faas_invoke.sh <service_id> <route> [METHOD] [json-body]
#   faas_invoke.sh svc-9249f2cdbedb /bookmarks
#   faas_invoke.sh svc-9249f2cdbedb /zones POST '{"name":"general"}'        # as owner → 200
#   FAAS_INVOKE_ANON=1 faas_invoke.sh svc-9249f2cdbedb /zones POST '{...}'  # anonymous → expect 401
#
# Env: MYAPP_FAAS_PROXY_URL (same base as faas_deploy.sh); FAAS_INVOKE_ANON (opt)
set -uo pipefail

SID="${1:-}"
ROUTE="${2:-}"
METHOD="${3:-GET}"
BODY="${4:-}"
if [ -z "$SID" ] || [ -z "$ROUTE" ]; then
  echo "usage: faas_invoke.sh <service_id> <route> [METHOD] [json-body]" >&2
  exit 1
fi

BASE="${MYAPP_FAAS_PROXY_URL:-}"
if [ -z "$BASE" ] && [ -n "${AI_APP_WORKSPACE:-}" ] && [ -f "$AI_APP_WORKSPACE/.faas_proxy_url" ]; then
  BASE="$(head -n1 "$AI_APP_WORKSPACE/.faas_proxy_url" 2>/dev/null)"
fi
if [ -z "$BASE" ]; then
  echo "MYAPP_FAAS_PROXY_URL is not set; in-run FaaS invoke is unavailable in this environment" >&2
  exit 2
fi
BASE="${BASE%/}"
ROUTE="/${ROUTE#/}"

ARGS=(-s -m 60 -w "\nhttp=%{http_code}\n" -X "$METHOD")
if [ -n "$BODY" ]; then
  ARGS+=(-H "Content-Type: application/json" -d "$BODY")
fi
# Opt into an anonymous self-test (suppress the run-token→owner identity at the
# backend) to verify protected routes reject. Default = authenticated as owner.
case "${FAAS_INVOKE_ANON:-}" in
  1|true|yes|TRUE|YES) ARGS+=(-H "X-MyApp-Faas-Anon: 1") ;;
esac
curl "${ARGS[@]}" "$BASE/invoke/${SID}${ROUTE}"
