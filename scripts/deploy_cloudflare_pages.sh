#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${1:-${CLOUDFLARE_PAGES_PROJECT:-}}"
BRANCH="${CLOUDFLARE_PAGES_BRANCH:-main}"

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <cloudflare-pages-project-name>" >&2
  echo "Or set CLOUDFLARE_PAGES_PROJECT=<project-name>." >&2
  exit 1
fi

"$ROOT_DIR/scripts/build_cloudflare_pages.sh"

if command -v wrangler >/dev/null 2>&1; then
  wrangler pages deploy "$ROOT_DIR/build/web" \
    --project-name "$PROJECT_NAME" \
    --branch "$BRANCH"
elif command -v npx >/dev/null 2>&1; then
  npx wrangler pages deploy "$ROOT_DIR/build/web" \
    --project-name "$PROJECT_NAME" \
    --branch "$BRANCH"
else
  echo "wrangler or npx is required. Install Node.js, then run: npm install -g wrangler" >&2
  exit 1
fi
