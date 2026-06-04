#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_ROOT="${MYAPP_INSTALL_ROOT:-/opt/myapp}"
LANGUAGE_FILE="/etc/myapp/ctl-language"
EXISTING_LANGUAGE=""
if [ -f "$LANGUAGE_FILE" ]; then
  EXISTING_LANGUAGE="$(tr -d '[:space:]' < "$LANGUAGE_FILE" || true)"
elif [ -f /etc/myapp/ctl.json ]; then
  EXISTING_LANGUAGE="$(python3 - <<'PY' 2>/dev/null || true
import json
from pathlib import Path

try:
    data = json.loads(Path("/etc/myapp/ctl.json").read_text(encoding="utf-8"))
except Exception:
    data = {}
lang = str(data.get("language") or data.get("lang") or "").strip().lower()
print(lang if lang in {"zh", "en", "de", "es"} else "")
PY
)"
fi

install -d -m 755 /opt/myapp/bin /etc/myapp /var/lib/myapp /var/log/myapp/agent-node
install -d -m 700 /etc/myapp/secrets.d /etc/myapp/secrets.d/files /etc/myapp/secrets.d/files/apns /etc/myapp/secrets.d/files/fcm
install -m 755 "$ROOT_DIR/scripts/myapp_ctl.py" /opt/myapp/bin/myapp-ctl
ln -sf /opt/myapp/bin/myapp-ctl /usr/local/bin/myapp-ctl

install -m 644 "$ROOT_DIR/deploy/production/ctl.json" /etc/myapp/ctl.json
install -m 644 "$ROOT_DIR/deploy/production/services.json" /etc/myapp/services.json
if [[ "$EXISTING_LANGUAGE" =~ ^(zh|en|de|es)$ ]]; then
  printf '%s\n' "$EXISTING_LANGUAGE" > "$LANGUAGE_FILE"
  chmod 644 "$LANGUAGE_FILE"
  python3 - "$EXISTING_LANGUAGE" <<'PY'
import json
import sys
from pathlib import Path

path = Path("/etc/myapp/ctl.json")
data = json.loads(path.read_text(encoding="utf-8"))
data["language"] = sys.argv[1]
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
fi

install -d -m 755 "$INSTALL_ROOT/deploy/production"
install -m 644 "$ROOT_DIR/deploy/production/docker-compose.core.yml" "$INSTALL_ROOT/deploy/production/docker-compose.core.yml"
install -m 644 "$ROOT_DIR/backend/schema.sql" "$INSTALL_ROOT/deploy/production/schema.sql"

SUPABASE_INSTALL="$INSTALL_ROOT/deploy/production/supabase"
OPENIM_INSTALL="$INSTALL_ROOT/deploy/production/openim"

if [ -d "$SUPABASE_INSTALL" ]; then
  # Keep runtime data mounted by the self-hosted Supabase compose file.
  # Reinstalling myapp-ctl must never remove Postgres PGDATA or file storage.
  find "$SUPABASE_INSTALL" -mindepth 1 -maxdepth 1 ! -name volumes -exec rm -rf {} +
  mkdir -p "$SUPABASE_INSTALL/volumes/db" "$SUPABASE_INSTALL/volumes/storage"
  find "$SUPABASE_INSTALL/volumes" -mindepth 1 -maxdepth 1 ! -name db ! -name storage -exec rm -rf {} +
  find "$SUPABASE_INSTALL/volumes/db" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
else
  mkdir -p "$SUPABASE_INSTALL"
fi

rm -rf "$OPENIM_INSTALL"
mkdir -p "$OPENIM_INSTALL"
cp -a "$ROOT_DIR/deploy/production/supabase/." "$SUPABASE_INSTALL/"
cp -a "$ROOT_DIR/deploy/production/openim/." "$OPENIM_INSTALL/"

echo "installed myapp-ctl to /opt/myapp/bin/myapp-ctl"
echo "config: /etc/myapp/ctl.json /etc/myapp/services.json"
echo "compose: $INSTALL_ROOT/deploy/production/docker-compose.core.yml"
echo "compose: $INSTALL_ROOT/deploy/production/supabase/docker-compose.yml"
echo "compose: $INSTALL_ROOT/deploy/production/openim/docker-compose.yml"
