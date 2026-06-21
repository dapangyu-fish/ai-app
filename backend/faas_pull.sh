#!/bin/bash
# Pull an existing FaaS service's WHOLE folder so the agent can edit it as a
# multi-file project. Downloads the service archive (zip) and unzips it to
# $AI_APP_WORKSPACE/faas_pull/<service_id>/. Edit/add any files there, then
# redeploy the folder with: bash backend/faas_deploy.sh <that folder>.
#
# Usage: faas_pull.sh <service_id>
#
# Env (same as faas_deploy.sh): MYAPP_FAAS_PROXY_URL [, MYAPP_FAAS_NODE_TOKEN,
# MYAPP_FAAS_OWNER for the direct/local path].
set -uo pipefail

SERVICE_ID="${1:-}"
if [ -z "$SERVICE_ID" ]; then
  echo "usage: faas_pull.sh <service_id>" >&2
  exit 1
fi

BASE="${MYAPP_FAAS_PROXY_URL:-}"
if [ -z "$BASE" ] && [ -n "${AI_APP_WORKSPACE:-}" ] && [ -f "$AI_APP_WORKSPACE/.faas_proxy_url" ]; then
  BASE="$(head -n1 "$AI_APP_WORKSPACE/.faas_proxy_url" 2>/dev/null)"
fi
if [ -z "$BASE" ]; then
  echo "MYAPP_FAAS_PROXY_URL is not set; in-run FaaS pull is unavailable in this environment" >&2
  exit 2
fi
BASE="${BASE%/}"

DEST_ROOT="${AI_APP_WORKSPACE:-.}/faas_pull"
DEST="$DEST_ROOT/$SERVICE_ID"
ZIP="$(mktemp /tmp/faas-pull.XXXXXX.zip)"

CURL_ARGS=(-s -m 120 -o "$ZIP" -w "%{http_code}")
[ -n "${MYAPP_FAAS_NODE_TOKEN:-}" ] && CURL_ARGS+=(-H "X-MyApp-Agent-Node-Token: ${MYAPP_FAAS_NODE_TOKEN}")
[ -n "${MYAPP_FAAS_OWNER:-}" ] && CURL_ARGS+=(-H "X-MyApp-Owner-User-Id: ${MYAPP_FAAS_OWNER}")
CURL_ARGS+=("$BASE/services/$SERVICE_ID/archive")
HTTP="$(curl "${CURL_ARGS[@]}")"

if [ "$HTTP" != "200" ]; then
  echo "PULL FAILED (http $HTTP): $(head -c 400 "$ZIP" 2>/dev/null)" >&2
  rm -f "$ZIP"
  exit 3
fi

rm -rf "$DEST"
mkdir -p "$DEST"
if ! python3 - "$ZIP" "$DEST" <<'PY'
import sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zf:
    zf.extractall(dest)
PY
then
  echo "failed to unzip service archive for $SERVICE_ID" >&2
  rm -f "$ZIP"
  exit 4
fi
rm -f "$ZIP"

echo "PULL OK  service_id=$SERVICE_ID -> $DEST"
echo "files:"
( cd "$DEST" && find . -type f | sed 's|^\./|  |' | sort )
echo "-> edit/add files under $DEST, then: bash backend/faas_deploy.sh $DEST"
