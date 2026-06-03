#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_ROOT="${MYAPP_INSTALL_ROOT:-/opt/myapp}"

install -d -m 755 /opt/myapp/bin /etc/myapp /var/lib/myapp /var/log/myapp/agent-node
install -d -m 700 /etc/myapp/secrets.d
install -m 755 "$ROOT_DIR/scripts/myapp_ctl.py" /opt/myapp/bin/myapp-ctl
ln -sf /opt/myapp/bin/myapp-ctl /usr/local/bin/myapp-ctl

install -m 644 "$ROOT_DIR/deploy/production/ctl.json" /etc/myapp/ctl.json
install -m 644 "$ROOT_DIR/deploy/production/services.json" /etc/myapp/services.json

install -d -m 755 "$INSTALL_ROOT/deploy/production"
install -m 644 "$ROOT_DIR/deploy/production/docker-compose.core.yml" "$INSTALL_ROOT/deploy/production/docker-compose.core.yml"
install -m 644 "$ROOT_DIR/backend/schema.sql" "$INSTALL_ROOT/deploy/production/schema.sql"

echo "installed myapp-ctl to /opt/myapp/bin/myapp-ctl"
echo "config: /etc/myapp/ctl.json /etc/myapp/services.json"
echo "compose: $INSTALL_ROOT/deploy/production/docker-compose.core.yml"
