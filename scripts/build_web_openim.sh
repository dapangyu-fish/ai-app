#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/web_openim_bridge"
LOCAL_NODE_BIN="$ROOT_DIR/.tools/node/bin"

if ! command -v npm >/dev/null 2>&1 && [[ -x "$LOCAL_NODE_BIN/npm" ]]; then
  export PATH="$LOCAL_NODE_BIN:$PATH"
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to build OpenIM Web assets." >&2
  exit 1
fi

cd "$BRIDGE_DIR"
npm ci
npm run build

required_assets=(
  "$ROOT_DIR/web/openIM.wasm"
  "$ROOT_DIR/web/sql-wasm.wasm"
  "$ROOT_DIR/web/wasm_exec.js"
  "$ROOT_DIR/web/worker.js"
  "$ROOT_DIR/web/worker-legacy.js"
  "$ROOT_DIR/web/openim_bridge.js"
)

for asset in "${required_assets[@]}"; do
  if [[ ! -s "$asset" ]]; then
    echo "Missing generated asset: $asset" >&2
    exit 1
  fi
done

echo "OpenIM Web assets are ready."
