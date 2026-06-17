#!/bin/bash
# Agent-driven FaaS self-test. Invokes a deployed service route so the agent can
# verify the backend actually runs (status + body) before wiring/uploading the
# JSON-APP. Invocation is intentionally auth-free (same as the client path).
#
# Usage: faas_invoke.sh <service_id> <route> [METHOD] [json-body]
#   faas_invoke.sh svc-9249f2cdbedb /bookmarks
#   faas_invoke.sh svc-9249f2cdbedb /bookmarks POST '{"title":"x","url":"https://x"}'
#
# Env: MYAPP_FAAS_PROXY_URL (same base as faas_deploy.sh)
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
curl "${ARGS[@]}" "$BASE/invoke/${SID}${ROUTE}"
