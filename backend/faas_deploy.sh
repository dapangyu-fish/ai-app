#!/bin/bash
# Agent-driven FaaS deploy. Runs INSIDE the generation agent (like
# upload_with_signature.sh). Accepts EITHER:
#   - a faas_bundle.json  (inline {service, files} bundle), uploaded as JSON; or
#   - a service FOLDER    (multi-file): zipped root-relative and uploaded as
#                         application/zip — the backend unzips, validates, updates
#                         git, then deploys (the rest of the pipeline is unchanged).
# Writes the REAL deploy result — including the server-assigned service_id — to
# faas_deploy_result.json so the agent can wire the JSON-APP to the real id,
# self-test, fix, and redeploy.
#
# Usage: faas_deploy.sh <faas_bundle.json | service_folder>
#
# Env (set by the agent-node when launching the runtime; direct/local fallback):
#   MYAPP_FAAS_PROXY_URL  base for faas ops:
#                           pull-agent  -> <agent-node>/faas/<run_token>
#                           local/direct-> <backend>/api/faas
#   MYAPP_FAAS_NODE_TOKEN  (direct only) shared agent-node token -> X-MyApp-Agent-Node-Token
#   MYAPP_FAAS_OWNER       (direct only) owner user id           -> X-MyApp-Owner-User-Id
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || { [ ! -f "$TARGET" ] && [ ! -d "$TARGET" ]; }; then
  echo "usage: faas_deploy.sh <faas_bundle.json | service_folder> (not found: $TARGET)" >&2
  exit 1
fi

BASE="${MYAPP_FAAS_PROXY_URL:-}"
# Fallback: the agent-node also writes the proxy URL to the workspace, so this
# works even if the env var was lost (e.g. the script ran in a stripped-env shell).
if [ -z "$BASE" ] && [ -n "${AI_APP_WORKSPACE:-}" ] && [ -f "$AI_APP_WORKSPACE/.faas_proxy_url" ]; then
  BASE="$(head -n1 "$AI_APP_WORKSPACE/.faas_proxy_url" 2>/dev/null)"
fi
if [ -z "$BASE" ]; then
  echo "MYAPP_FAAS_PROXY_URL is not set; in-run FaaS deploy is unavailable in this environment" >&2
  exit 2
fi
BASE="${BASE%/}"

OUT="${AI_APP_WORKSPACE:-.}/faas_deploy_result.json"
RAW="$(mktemp)"
CLEAN_ZIP=""

if [ -d "$TARGET" ]; then
  # Zip the folder contents root-relative (app.py must be at the zip root).
  UPLOAD="$(mktemp /tmp/faas-bundle.XXXXXX.zip)"
  CLEAN_ZIP="$UPLOAD"
  if ! python3 - "$TARGET" "$UPLOAD" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
skip_dirs = {"__pycache__", ".git"}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith(".")]
        for name in files:
            if name.startswith("."):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            zf.write(full, rel)
PY
  then
    echo "failed to zip service folder: $TARGET" >&2
    rm -f "$RAW" "$CLEAN_ZIP"
    exit 1
  fi
  CT="application/zip"
else
  UPLOAD="$TARGET"
  CT="application/json"
fi

CURL_ARGS=(-s -m 150 -o "$RAW" -w "%{http_code}" -X POST -H "Content-Type: $CT")
[ -n "${MYAPP_FAAS_NODE_TOKEN:-}" ] && CURL_ARGS+=(-H "X-MyApp-Agent-Node-Token: ${MYAPP_FAAS_NODE_TOKEN}")
[ -n "${MYAPP_FAAS_OWNER:-}" ] && CURL_ARGS+=(-H "X-MyApp-Owner-User-Id: ${MYAPP_FAAS_OWNER}")
CURL_ARGS+=(--data-binary @"$UPLOAD" "$BASE/services")
HTTP="$(curl "${CURL_ARGS[@]}")"
[ -n "$CLEAN_ZIP" ] && rm -f "$CLEAN_ZIP"

python3 - "$RAW" "$HTTP" "$OUT" <<'PY'
import json, sys
raw, code, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(raw, encoding="utf-8"))
except Exception:
    d = {"error": open(raw, encoding="utf-8", errors="replace").read()[:500] or "empty response"}
svc = d.get("service") or {}
res = {"ok": bool(d.get("ok") and svc.get("service_id")), "http": int(code)}
if res["ok"]:
    res["service_id"] = svc.get("service_id")
    res["status"] = svc.get("status")
    res["routes"] = svc.get("routes") or []
else:
    res["error"] = d.get("error") or d.get("code") or f"deploy failed (http {code})"
with open(out, "w", encoding="utf-8") as f:
    json.dump(res, f, ensure_ascii=False, indent=2)
if res["ok"]:
    print(f"DEPLOY OK  service_id={res['service_id']}  status={res['status']}")
    for r in res["routes"]:
        print(f"  route {r.get('path')} {r.get('methods')}")
    print(f"-> wrote {out}; now wire the JSON-APP invoke ids to '{res['service_id']}' and self-test with faas_invoke.sh")
else:
    print(f"DEPLOY FAILED (http {code}): {res['error']}")
    print(f"-> fix the bundle/folder per the error above and re-run faas_deploy.sh")
PY
rm -f "$RAW"

# exit non-zero on failure so the agent notices
python3 -c "import json,sys; sys.exit(0 if json.load(open('$OUT')).get('ok') else 3)" 2>/dev/null
