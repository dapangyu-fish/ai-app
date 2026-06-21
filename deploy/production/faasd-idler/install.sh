#!/usr/bin/env bash
# Install the faasd idle-to-zero reaper as a systemd service on a faasd host.
#
# Community faasd has no autoscaler/idler, so functions deployed with
# com.openfaas.scale.zero never actually scale down. This reaper stops idle
# function tasks; the faasd gateway's scale_from_zero wakes them on demand.
#
# Usage (run as root on the faasd host):
#   deploy/production/faasd-idler/install.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR=/opt/faasd-idler
UNIT=/etc/systemd/system/faasd-idler.service

if [[ "${EUID}" -ne 0 ]]; then
  echo "must run as root (needs ctr/containerd access)" >&2
  exit 1
fi

if [[ ! -S /run/faasd.containerd.sock && ! -d /var/lib/faasd ]]; then
  echo "this host does not look like a faasd host (/var/lib/faasd missing)" >&2
  exit 1
fi

install -d -m 0755 "${DEST_DIR}"
install -m 0755 "${SRC_DIR}/faasd_idler.py" "${DEST_DIR}/faasd_idler.py"
install -m 0644 "${SRC_DIR}/faasd-idler.service" "${UNIT}"

systemctl daemon-reload
systemctl enable --now faasd-idler.service

echo "installed faasd-idler. status:"
systemctl --no-pager status faasd-idler.service | head -8 || true
echo
echo "inspect:   python3 ${DEST_DIR}/faasd_idler.py --status"
echo "logs:      journalctl -u faasd-idler -f"
