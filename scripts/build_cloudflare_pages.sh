#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/web"
WASM_FILE="$BUILD_DIR/openIM.wasm"
WASM_GZ_FILE="$BUILD_DIR/openIM.wasm.gz"

"$ROOT_DIR/scripts/flutter_web.sh" build web --release "$@"

if [[ -s "$WASM_FILE" ]]; then
  gzip -f -k -9 "$WASM_FILE"
  rm -f "$WASM_FILE"
fi

if [[ ! -s "$WASM_GZ_FILE" ]]; then
  echo "Missing compressed OpenIM wasm asset: $WASM_GZ_FILE" >&2
  exit 1
fi

cat > "$BUILD_DIR/_headers" <<'EOF'
/openIM.wasm
  Content-Type: application/wasm
  Content-Encoding: gzip
  Cache-Control: public, max-age=31536000, immutable

/openIM.wasm.gz
  Content-Type: application/wasm
  Content-Encoding: gzip
  Cache-Control: public, max-age=31536000, immutable

/sql-wasm.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=31536000, immutable

/openim_bridge.js
  Cache-Control: public, max-age=31536000, immutable

/worker.js
  Cache-Control: public, max-age=31536000, immutable

/worker-legacy.js
  Cache-Control: public, max-age=31536000, immutable
EOF

cat > "$BUILD_DIR/_redirects" <<'EOF'
/openIM.wasm /openIM.wasm.gz 200
/* /index.html 200
EOF

echo "Cloudflare Pages build is ready: $BUILD_DIR"
echo "Deploy with: wrangler pages deploy build/web --project-name <project-name>"
