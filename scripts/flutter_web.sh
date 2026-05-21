#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  if [[ -x "$ROOT_DIR/../flutter/bin/flutter" ]]; then
    FLUTTER_BIN="$ROOT_DIR/../flutter/bin/flutter"
  elif [[ -x "$HOME/flutter/bin/flutter" ]]; then
    FLUTTER_BIN="$HOME/flutter/bin/flutter"
  fi
fi

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  echo "flutter is required. Set FLUTTER_BIN=/path/to/flutter if it is not on PATH." >&2
  exit 1
fi

needs_openim_assets=false
if [[ "${1:-}" == "build" && "${2:-}" == "web" ]]; then
  needs_openim_assets=true
elif [[ "${1:-}" == "run" ]]; then
  for arg in "$@"; do
    case "$arg" in
      chrome|web-server|edge)
        needs_openim_assets=true
        ;;
    esac
  done
fi

if [[ "$needs_openim_assets" == true ]]; then
  "$ROOT_DIR/scripts/build_web_openim.sh"
fi

exec "$FLUTTER_BIN" "$@"
