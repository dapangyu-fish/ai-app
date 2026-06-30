#!/usr/bin/env bash
set -euo pipefail

# 向后兼容 shim。包装器已升级为「目标无关」（scripts/flutter.sh）——
# 它给所有 build/run（含 iOS/Android/桌面）注入编译 commit，不再只是 Web。
# 本文件保留是为了让既有调用方（build_cloudflare_pages.sh、README、肌肉记忆）继续可用。
# 非 Web 构建请直接用 scripts/flutter.sh（语义完全一致）。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/scripts/flutter.sh" "$@"
