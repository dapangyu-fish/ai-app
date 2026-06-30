#!/usr/bin/env bash
set -euo pipefail

# 通用 Flutter 包装器：给「每一个 build / run」注入版本号 + 编译 commit
#   --dart-define=APP_VERSION=<pubspec version>      （单一真相源 = pubspec.yaml）
#   --dart-define=APP_GIT_COMMIT=<git 短 sha>
# 这样 App 落地页底部的「版本号 + commit」标签在「所有端」都正确显示 —— 不只是 Web，
# iOS / Android / macOS / Linux / Windows 一视同仁（显示代码本就是同一份 main.dart，
# 之前只有 Web 构建注入了 commit 的 --dart-define，所以只有 Web 看得到 commit）。
#
# 同时：仅当目标是 Web（build web / run chrome|web-server|edge）时才预备 OpenIM wasm/js 资源。
# 其他 flutter 子命令（pub get / analyze / test ...）原样透传，不做任何注入。
#
# 用法与 `flutter` 完全一致，例如：
#   ./scripts/flutter.sh build apk --release
#   ./scripts/flutter.sh build ios --release
#   ./scripts/flutter.sh run -d <device>
#   ./scripts/flutter.sh build web --release
# CI / 显式覆盖：APP_VERSION=<v> APP_GIT_COMMIT=<sha> ./scripts/flutter.sh build apk
# 直接走 IDE（Xcode / Android Studio）构建不经过本包装器，需在其 run 配置里自行加
#   --dart-define=APP_VERSION=<v> --dart-define=APP_GIT_COMMIT=<sha>，否则只显示兜底
#   版本号、commit 行留空（与直接裸 `flutter build` 相同）。

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

# 是否已显式传入某个 --dart-define=<KEY>=...（传了就不覆盖用户的值）
_has_define() {
  local key="$1"; shift
  local a
  for a in "$@"; do
    case "$a" in
      --dart-define="$key"=*) return 0 ;;
    esac
  done
  return 1
}

cmd="${1:-}"

# --- OpenIM Web 资源：仅 web build / web run 需要 ---
needs_openim_assets=false
if [[ "$cmd" == "build" && "${2:-}" == "web" ]]; then
  needs_openim_assets=true
elif [[ "$cmd" == "run" ]]; then
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

# --- 版本号 + commit 注入：任何 build / run 目标都注入（Web + 原生 + 桌面一视同仁）---
inject_meta=false
case "$cmd" in
  build|run) inject_meta=true ;;
esac

if [[ "$inject_meta" == true ]]; then
  extra_defines=()

  # commit：默认取 git 短 sha（12 位，与 Web 一致）；可被环境变量 APP_GIT_COMMIT
  # 或显式 --dart-define 覆盖。取不到 git 时静默跳过（落地页 commit 行留空）。
  if ! _has_define APP_GIT_COMMIT "$@"; then
    git_commit="${APP_GIT_COMMIT:-}"
    if [[ -z "$git_commit" ]] && command -v git >/dev/null 2>&1; then
      git_commit="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || true)"
    fi
    [[ -n "$git_commit" ]] && extra_defines+=("--dart-define=APP_GIT_COMMIT=$git_commit")
  fi

  # 版本号：单一真相源是 pubspec.yaml 的 version: 字段；可被环境变量 APP_VERSION
  # 或显式 --dart-define 覆盖。解析失败时静默跳过（回落 AppConfig 的兜底常量）。
  if ! _has_define APP_VERSION "$@"; then
    app_version="${APP_VERSION:-}"
    if [[ -z "$app_version" ]]; then
      app_version="$(awk '/^version:/{print $2; exit}' "$ROOT_DIR/pubspec.yaml" 2>/dev/null || true)"
    fi
    [[ -n "$app_version" ]] && extra_defines+=("--dart-define=APP_VERSION=$app_version")
  fi

  if [[ ${#extra_defines[@]} -gt 0 ]]; then
    exec "$FLUTTER_BIN" "$@" "${extra_defines[@]}"
  fi
fi

exec "$FLUTTER_BIN" "$@"
