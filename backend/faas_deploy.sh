#!/bin/bash
# Agent-driven FaaS deploy. Runs INSIDE the generation agent (like
# upload_with_signature.sh). POSTs faas_bundle.json to the backend (via the
# per-run agent-node faas proxy, or directly), and writes the REAL deploy result
# — including the server-assigned service_id — to faas_deploy_result.json so the
# agent can wire the JSON-APP to the real id, self-test, fix, and redeploy.
#
# Usage: faas_deploy.sh <faas_bundle.json>
#
# Env (set by the agent-node when launching the runtime; direct/local fallback):
#   MYAPP_FAAS_PROXY_URL  base for faas ops:
#                           pull-agent  -> <agent-node>/faas/<run_token>
#                           local/direct-> <backend>/api/faas
#   MYAPP_FAAS_NODE_TOKEN  (direct only) shared agent-node token -> X-MyApp-Agent-Node-Token
#   MYAPP_FAAS_OWNER       (direct only) owner user id           -> X-MyApp-Owner-User-Id
set -uo pipefail

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE" ]; then
  echo "usage: faas_deploy.sh <faas_bundle.json> (file not found: $BUNDLE)" >&2
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

HDRS=(-H "Content-Type: application/json")
[ -n "${MYAPP_FAAS_NODE_TOKEN:-}" ] && HDRS+=(-H "X-MyApp-Agent-Node-Token: ${MYAPP_FAAS_NODE_TOKEN}")
[ -n "${MYAPP_FAAS_OWNER:-}" ] && HDRS+=(-H "X-MyApp-Owner-User-Id: ${MYAPP_FAAS_OWNER}")

OUT="${AI_APP_WORKSPACE:-.}/faas_deploy_result.json"
RAW="$(mktemp)"
HTTP="$(curl -s -m 150 -o "$RAW" -w "%{http_code}" -X POST "${HDRS[@]}" --data-binary @"$BUNDLE" "$BASE/services")"

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
    print(f"-> fix faas_bundle.json per the error above and re-run faas_deploy.sh")
PY
rm -f "$RAW"

# exit non-zero on failure so the agent notices
python3 -c "import json,sys; sys.exit(0 if json.load(open('$OUT')).get('ok') else 3)" 2>/dev/null
