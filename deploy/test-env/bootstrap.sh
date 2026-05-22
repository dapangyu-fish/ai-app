#!/usr/bin/env bash
# Test-env one-click deploy / 测试环境一键部署 —— interactive.
# First prompt picks UI language (1=English default, 2=中文). All messages are i18n'd.
#
# Usage:
#   ./bootstrap.sh                       # interactive
#   ./bootstrap.sh --yes                 # all defaults (DeepSeek key still required, from $DEEPSEEK_API_KEY)
#   ./bootstrap.sh --lang en|zh          # preset language, skip the picker
#
# Re-run safe: running again brings services up from existing .env. To start fresh run ./teardown.sh first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ───────── colors ─────────
B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; C="\033[36m"; N="\033[0m"

# ───────── i18n catalog ─────────
declare -A T_en T_zh
UI_LANG="en"

# t <key> [printf args...] —— emit localized string (falls back en → key)
t() {
  local key="$1"; shift || true
  local fmt
  if [[ "$UI_LANG" == "zh" ]]; then
    fmt="${T_zh[$key]:-${T_en[$key]:-$key}}"
  else
    fmt="${T_en[$key]:-$key}"
  fi
  # shellcheck disable=SC2059
  printf "$fmt" "$@"
}

T_en[deps_check]="Checking dependencies..."
T_zh[deps_check]="检查依赖..."
T_en[dep_missing]="Missing %s — please install it first"
T_zh[dep_missing]="缺少 %s，请先安装"
T_en[compose_missing]="docker compose plugin missing (need v2, not the old docker-compose)"
T_zh[compose_missing]="docker compose 插件缺失（要 v2，不是老的 docker-compose）"
T_en[install_deps]="Installing missing system packages: %s"
T_zh[install_deps]="安装缺失系统包: %s"
T_en[install_docker]="Docker is missing; installing Docker Engine via get.docker.com..."
T_zh[install_docker]="缺少 Docker；通过 get.docker.com 安装 Docker Engine..."
T_en[install_docker_pkg]="Docker is missing; installing Docker packages..."
T_zh[install_docker_pkg]="缺少 Docker；通过系统包管理器安装 Docker..."
T_en[install_docker_hint]="Docker is required. Install Docker Desktop / OrbStack / Colima on macOS, or Docker Engine + compose plugin on Linux."
T_zh[install_docker_hint]="需要 Docker。macOS 请安装 Docker Desktop / OrbStack / Colima；Linux 请安装 Docker Engine 和 compose plugin。"
T_en[install_hint]="Missing dependencies: %s. No supported package manager found (apt, dnf, yum, brew, apk, pacman, zypper)."
T_zh[install_hint]="缺少依赖: %s。未找到支持的包管理器（apt, dnf, yum, brew, apk, pacman, zypper）。"
T_en[pkg_manager]="Using package manager: %s"
T_zh[pkg_manager]="使用包管理器: %s"
T_en[docker_unusable]="Docker is installed but not usable. Start the Docker daemon/Desktop, or rerun as root / add this user to the docker group and re-login."
T_zh[docker_unusable]="Docker 已安装但当前不可用。请启动 Docker daemon/Desktop，或用 root 运行 / 把当前用户加入 docker 组后重新登录。"
T_en[deps_ok]="Dependencies OK"
T_zh[deps_ok]="依赖齐"
T_en[unknown_arg]="Unknown argument: %s"
T_zh[unknown_arg]="未知参数: %s"
T_en[required_yes]="%s is required (must be provided via env in --yes mode)"
T_zh[required_yes]="%s 必填（--yes 模式下需在环境变量里给出）"
T_en[required]="required"
T_zh[required]="必填"
T_en[banner_title]="AI App test-env one-click deploy (test-env v1)"
T_zh[banner_title]="AI App 测试环境一键部署 (test-env v1)"
T_en[banner_sub]="Press Enter for defaults; only DeepSeek key + test account are required"
T_zh[banner_sub]="按 Enter 接受默认；必填只有 DeepSeek key + 测试账号"
T_en[sec_ip]="[1/5] Client access IP"
T_zh[sec_ip]="[1/5] 客户端访问 IP"
T_en[ask_ip]="  IP the client uses (LAN testing: your machine's intranet IP)"
T_zh[ask_ip]="  客户端访问的 IP（局域网测试就填本机内网 IP）"
T_en[sec_ai]="[2/5] AI providers (backend/config.py recognizes these)"
T_zh[sec_ai]="[2/5] AI 供应商（backend/config.py 实际识别这几个）"
T_en[ask_deepseek]="  DeepSeek API Key (required)"
T_zh[ask_deepseek]="  DeepSeek API Key（必填）"
T_en[ask_glm_token]="  GLM (Anthropic-compatible) Auth Token (optional)"
T_zh[ask_glm_token]="  GLM (Anthropic-compatible) Auth Token（可选）"
T_en[ask_glm_url]="  GLM Base URL (optional)"
T_zh[ask_glm_url]="  GLM Base URL（可选）"
T_en[ask_cc_token]="  Claude Code Anthropic Token (optional)"
T_zh[ask_cc_token]="  Claude Code Anthropic Token（可选）"
T_en[ask_cc_url]="  Claude Code Base URL (optional)"
T_zh[ask_cc_url]="  Claude Code Base URL（可选）"
T_en[sec_account]="[3/5] Test account (used to log into the client after deploy)"
T_zh[sec_account]="[3/5] 测试账号（部署完后用来登录客户端）"
T_en[ask_email]="  Email"
T_zh[ask_email]="  邮箱"
T_en[ask_username]="  Username"
T_zh[ask_username]="  用户名"
T_en[ask_password]="  Password"
T_zh[ask_password]="  密码"
T_en[sec_mirror]="[4/5] Registry mirror (optional)"
T_zh[sec_mirror]="[4/5] Registry mirror（可选）"
T_en[mirror_desc1]="  This instance can mirror another Registry's public package index, syncing every N seconds."
T_zh[mirror_desc1]="  本实例可以镜像另一个 Registry 的公开包索引，每 N 秒同步一次。"
T_en[mirror_desc2]="  Leave upstream URL empty = no mirror, run standalone."
T_zh[mirror_desc2]="  上游 URL 留空 = 不开 mirror，本实例独立运行。"
T_en[ask_upstream]="  Upstream Registry URL (e.g. https://myapp-registry.dapangyu.work)"
T_zh[ask_upstream]="  上游 Registry URL（如 https://myapp-registry.dapangyu.work）"
T_en[ask_interval]="  Sync interval (seconds, <=0 = sync once at startup only)"
T_zh[ask_interval]="  同步间隔（秒，<=0 = 只首启一次）"
T_en[sec_port]="[5/5] Port offset (for running multiple envs on one host, default 0)"
T_zh[sec_port]="[5/5] 端口偏移（同机并行多 env 时用，默认 0）"
T_en[ask_offset]="  Port offset"
T_zh[ask_offset]="  端口偏移"
T_en[offset_num]="Port offset must be a number"
T_zh[offset_num]="端口偏移必须是数字"
T_en[gen_secrets]="Generating secrets..."
T_zh[gen_secrets]="生成密钥..."
T_en[secrets_done]="Secrets generated"
T_zh[secrets_done]="密钥生成完毕"
T_en[mint_keys]="Minting Supabase ANON_KEY / SERVICE_ROLE_KEY..."
T_zh[mint_keys]="签发 Supabase ANON_KEY / SERVICE_ROLE_KEY..."
T_en[keys_done]="Supabase keys minted"
T_zh[keys_done]="Supabase keys 已签发"
T_en[render_env]="Rendering .env files..."
T_zh[render_env]="渲染 .env 文件..."
T_en[env_done]=".env rendered (3 files)"
T_zh[env_done]=".env 已渲染（3 份）"
T_en[pull_images]="Pulling images (slow the first time)..."
T_zh[pull_images]="拉镜像（首次比较慢）..."
T_en[images_ready]="Images ready"
T_zh[images_ready]="镜像 ready"
T_en[start_supabase]="Starting Supabase (13 services, ~1-2 min first time)..."
T_zh[start_supabase]="启动 Supabase（13 服务，首次起约 1-2 分钟）..."
T_en[wait_supabase]="Waiting for Supabase auth..."
T_zh[wait_supabase]="等 Supabase auth 服务就绪..."
T_en[supabase_ready]="Supabase auth ready (%ss)"
T_zh[supabase_ready]="Supabase auth ready (%ss)"
T_en[supabase_timeout]="Supabase auth not up after 120s (last HTTP %s), docker logs supabase-auth"
T_zh[supabase_timeout]="Supabase auth 等 120s 还没起来 (last HTTP %s)，docker logs supabase-auth"
T_en[openim_cfg]="Extracting + patching default config from OpenIM image..."
T_zh[openim_cfg]="从 OpenIM 镜像提取默认 config 并打补丁..."
T_en[openim_cfg_done]="OpenIM config rendered (mongodb/redis/kafka/etcd/minio/share)"
T_zh[openim_cfg_done]="OpenIM config 渲染完毕（mongodb/redis/kafka/etcd/minio/share）"
T_en[start_openim]="Starting OpenIM (8 services, ~1-2 min first time)..."
T_zh[start_openim]="启动 OpenIM（8 服务，首次起约 1-2 分钟）..."
T_en[wait_openim]="Waiting for OpenIM server..."
T_zh[wait_openim]="等 OpenIM server 就绪..."
T_en[openim_ready]="OpenIM API ready (%ss, HTTP %s)"
T_zh[openim_ready]="OpenIM API ready (%ss, HTTP %s)"
T_en[openim_timeout]="OpenIM not ready after 120s, continuing; logs: docker compose --env-file openim/.env -f openim/docker-compose.yml logs openim-server"
T_zh[openim_timeout]="OpenIM 等 120s 没就绪，继续；docker compose --env-file openim/.env -f openim/docker-compose.yml logs openim-server"
T_en[start_app]="Building + starting app services (backend / registry / config-center / user-center / jsonapp-postgres / app-minio)..."
T_zh[start_app]="构建 + 启动 app 自有服务（backend / registry / config-center / user-center / jsonapp-postgres / app-minio）..."
T_en[wait_backend]="Waiting for backend health check..."
T_zh[wait_backend]="等 backend 健康检查..."
T_en[backend_ready]="backend ready (%ss)"
T_zh[backend_ready]="backend ready (%ss)"
T_en[backend_timeout]="backend health check failed after 80s, continuing; docker compose logs -f backend"
T_zh[backend_timeout]="backend 健康检查 80s 没过，继续；docker compose logs -f backend 看看"
T_en[init_minio]="Initializing app-minio buckets..."
T_zh[init_minio]="初始化 app-minio buckets..."
T_en[seed_user]="Creating test account on Supabase..."
T_zh[seed_user]="在 Supabase 上创建测试账号..."
T_en[deploy_done]="Deploy complete!"
T_zh[deploy_done]="部署完成！"
T_en[info_saved]="All info also saved to ./test-env-info.txt (mode 600)"
T_zh[info_saved]="全部信息也保存到 ./test-env-info.txt（mode 600）"
T_en[env_qr_saved]="Client environment QR saved to ./test-env-environment.png and ./test-env-environment.json"
T_zh[env_qr_saved]="客户端环境二维码已保存到 ./test-env-environment.png 和 ./test-env-environment.json"
T_en[env_qr_title]="Scan this QR in the client Service Environment page"
T_zh[env_qr_title]="在客户端“服务环境”页扫码导入"

say()  { printf "${C}» %s${N}\n" "$*"; }
ok()   { printf "${G}✔ %s${N}\n" "$*"; }
warn() { printf "${Y}! %s${N}\n" "$*"; }
die()  { printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

NON_INTERACTIVE=0
LANG_PRESET=""
_args=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) NON_INTERACTIVE=1 ;;
    --lang) LANG_PRESET="__next__" ;;
    --lang=*) LANG_PRESET="${arg#*=}" ;;
    en|zh) [[ "$LANG_PRESET" == "__next__" ]] && LANG_PRESET="$arg" || _args+=("$arg") ;;
    -h|--help) sed -n '2,12p' "$SCRIPT_DIR/bootstrap.sh"; exit 0 ;;
    *) die "$(t unknown_arg "$arg")" ;;
  esac
done

# ───────── language selection (number-based, default English) ─────────
if [[ -n "$LANG_PRESET" && "$LANG_PRESET" != "__next__" ]]; then
  UI_LANG="$LANG_PRESET"
elif [[ $NON_INTERACTIVE -eq 1 ]]; then
  UI_LANG="en"
else
  printf "${B}Select language / 选择语言:${N}\n"
  printf "  1) English (default)\n"
  printf "  2) 中文\n"
  read -r -p "$(printf "${B}> ${N}")" _lang </dev/tty
  case "${_lang:-1}" in
    2) UI_LANG="zh" ;;
    *) UI_LANG="en" ;;
  esac
fi

ask() {
  local prompt="$1"; local default="${2:-}"
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    echo "$default"; return
  fi
  local hint=""
  [[ -n "$default" ]] && hint=" [${default}]"
  local ans
  read -r -p "$(printf "${B}%s${N}${hint}: " "$prompt")" ans </dev/tty
  echo "${ans:-$default}"
}

ask_required() {
  local prompt="$1"; local default_from_env="${2:-}"
  local ans
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    [[ -n "$default_from_env" ]] && { echo "$default_from_env"; return; }
    die "$(t required_yes "$prompt")"
  fi
  while :; do
    read -r -p "$(printf "${B}%s${N}: " "$prompt")" ans </dev/tty
    ans="${ans:-$default_from_env}"
    if [[ -n "$ans" ]]; then echo "$ans"; return; fi
    warn "$(t required)"
  done
}

ask_secret() {
  local prompt="$1"; local default="${2:-}"
  if [[ $NON_INTERACTIVE -eq 1 ]]; then echo "$default"; return; fi
  local hint=""
  [[ -n "$default" ]] && hint=" [auto: ${default:0:8}…]"
  local ans
  read -r -p "$(printf "${B}%s${N}${hint}: " "$prompt")" ans </dev/tty
  echo "${ans:-$default}"
}

# ───────── banner ─────────
printf "\n${B}╔══════════════════════════════════════════════════════════╗${N}\n"
printf "${B}║  %-56s║${N}\n" "$(t banner_title)"
printf "${B}║  %-56s║${N}\n" "$(t banner_sub)"
printf "${B}╚══════════════════════════════════════════════════════════╝${N}\n\n"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

os_name() { uname -s 2>/dev/null || true; }
is_macos() { [[ "$(os_name)" == "Darwin" ]]; }
is_linux() { [[ "$(os_name)" == "Linux" ]]; }

detect_pkg_manager() {
  if have_cmd apt-get; then echo apt; return; fi
  if have_cmd dnf; then echo dnf; return; fi
  if have_cmd yum; then echo yum; return; fi
  if have_cmd brew; then echo brew; return; fi
  if have_cmd apk; then echo apk; return; fi
  if have_cmd pacman; then echo pacman; return; fi
  if have_cmd zypper; then echo zypper; return; fi
  echo none
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    die "Need root privileges. Re-run as root or install sudo."
  fi
}

install_packages() {
  local manager="$1"; shift
  local packages=("$@")
  [[ ${#packages[@]} -eq 0 ]] && return
  say "$(t pkg_manager "$manager")"
  say "$(t install_deps "${packages[*]}")"
  case "$manager" in
    apt)
      run_as_root apt-get update
      run_as_root apt-get install -y "${packages[@]}"
      ;;
    dnf)
      run_as_root dnf install -y "${packages[@]}"
      ;;
    yum)
      run_as_root yum install -y "${packages[@]}"
      ;;
    brew)
      brew install "${packages[@]}"
      ;;
    apk)
      run_as_root apk add --no-cache "${packages[@]}"
      ;;
    pacman)
      run_as_root pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    zypper)
      run_as_root zypper --non-interactive install "${packages[@]}"
      ;;
    *)
      die "$(t install_hint "${packages[*]}")"
      ;;
  esac
}

package_for_cmd() {
  local manager="$1"
  local cmd="$2"
  case "$cmd" in
    curl) echo curl ;;
    wget) echo wget ;;
    openssl)
      case "$manager" in
        brew) echo openssl@3 ;;
        *) echo openssl ;;
      esac
      ;;
    python3)
      case "$manager" in
        brew) echo python ;;
        *) echo python3 ;;
      esac
      ;;
    envsubst)
      case "$manager" in
        apt) echo gettext-base ;;
        apk|pacman|zypper|brew) echo gettext ;;
        dnf|yum) echo gettext ;;
        *) echo gettext ;;
      esac
      ;;
    qrencode) echo qrencode ;;
  esac
}

compose_package() {
  local manager="$1"
  case "$manager" in
    apt|dnf|yum) echo docker-compose-plugin ;;
    apk) echo docker-cli-compose ;;
    pacman|zypper|brew) echo docker-compose ;;
    *) echo "" ;;
  esac
}

docker_packages() {
  local manager="$1"
  case "$manager" in
    apk) echo docker docker-cli-compose ;;
    pacman) echo docker docker-compose ;;
    zypper) echo docker docker-compose ;;
    brew) echo "" ;;
    *) echo "" ;;
  esac
}

ensure_docker() {
  if have_cmd docker; then
    return
  fi

  local manager="$1"
  if is_macos; then
    if [[ "$manager" == "brew" ]]; then
      say "$(t install_docker)"
      brew install --cask docker
      return
    fi
    die "$(t install_docker_hint)"
  fi

  if ! is_linux; then
    die "$(t install_docker_hint)"
  fi

  local docker_pkgs
  docker_pkgs="$(docker_packages "$manager")"
  if [[ -n "$docker_pkgs" ]]; then
    say "$(t install_docker_pkg)"
    # shellcheck disable=SC2086
    install_packages "$manager" $docker_pkgs
    return
  fi

  case "$manager" in
    apt|dnf|yum)
      if ! have_cmd curl; then
        local curl_pkg
        curl_pkg="$(package_for_cmd "$manager" curl)"
        install_packages "$manager" "$curl_pkg"
      fi
      if [[ "$manager" == "apt" ]]; then
        install_packages "$manager" ca-certificates
      fi
      say "$(t install_docker)"
      curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
      run_as_root sh /tmp/get-docker.sh
      rm -f /tmp/get-docker.sh
      ;;
    *)
      die "$(t install_docker_hint)"
      ;;
  esac
}

ensure_dependencies() {
  local manager
  manager="$(detect_pkg_manager)"
  local missing_pkgs=()
  local missing_names=()

  for cmd in curl wget openssl python3 envsubst qrencode; do
    if ! have_cmd "$cmd"; then
      missing_pkgs+=("$(package_for_cmd "$manager" "$cmd")")
      missing_names+=("$cmd")
    fi
  done

  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    if [[ "$manager" == "none" ]]; then
      die "$(t install_hint "${missing_names[*]}")"
    fi
    install_packages "$manager" "${missing_pkgs[@]}"
  fi

  ensure_docker "$manager"

  if ! docker compose version >/dev/null 2>&1; then
    local compose_pkg
    compose_pkg="$(compose_package "$manager")"
    if [[ -n "$compose_pkg" ]]; then
      install_packages "$manager" "$compose_pkg"
    fi
  fi
  docker compose version >/dev/null 2>&1 || die "$(t compose_missing)"
  docker info >/dev/null 2>&1 || die "$(t docker_unusable)"
}

say "$(t deps_check)"
ensure_dependencies
ok "$(t deps_ok)"

# ───────── detect IP ─────────
detect_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  fi
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$ip" ]] && ip="127.0.0.1"
  echo "$ip"
}
DETECTED_IP=$(detect_ip)

# ───────── collect input ─────────
say "$(t sec_ip)"
HOST_IP=$(ask "$(t ask_ip)" "$DETECTED_IP")

echo
say "$(t sec_ai)"
DEEPSEEK_KEY=$(ask_required "$(t ask_deepseek)" "${DEEPSEEK_KEY:-${DEEPSEEK_API_KEY:-}}")
GLM_ANTHROPIC_AUTH_TOKEN=$(ask    "$(t ask_glm_token)" "")
GLM_ANTHROPIC_BASE_URL=$(ask      "$(t ask_glm_url)" "")
CC_ANTHROPIC_AUTH_TOKEN=$(ask     "$(t ask_cc_token)" "")
CC_ANTHROPIC_BASE_URL=$(ask       "$(t ask_cc_url)" "")

echo
say "$(t sec_account)"
TEST_USER_EMAIL=$(ask_required    "$(t ask_email)" "test@example.local")
TEST_USER_USERNAME=$(ask          "$(t ask_username)" "${TEST_USER_EMAIL%%@*}")
DEFAULT_PASSWORD="Test$(openssl rand -hex 4)"
TEST_USER_PASSWORD=$(ask_secret   "$(t ask_password)" "$DEFAULT_PASSWORD")

echo
say "$(t sec_mirror)"
echo "$(t mirror_desc1)"
echo "$(t mirror_desc2)"
REGISTRY_UPSTREAM=$(ask "$(t ask_upstream)" "")
if [[ -n "$REGISTRY_UPSTREAM" ]]; then
  REGISTRY_MIRROR_SYNC_INTERVAL_SEC=$(ask "$(t ask_interval)" "600")
else
  REGISTRY_MIRROR_SYNC_INTERVAL_SEC="0"
fi

echo
say "$(t sec_port)"
PORT_OFFSET=$(ask "$(t ask_offset)" "0")
[[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || die "$(t offset_num)"

# ───────── compute ports ─────────
add() { echo $(( $1 + PORT_OFFSET )); }

BACKEND_PORT=$(add 5566)
REGISTRY_PORT=$(add 3254)
CONFIG_CENTER_PORT=$(add 5567)
USER_CENTER_PORT=$(add 5568)
KONG_HTTP_PORT=$(add 18000)
KONG_HTTPS_PORT=$(add 18443)
SUPABASE_DB_PORT=$(add 15432)
SUPABASE_POOLER_PORT=$(add 6543)
JSONAPP_DB_PORT=$(add 15433)
APP_MINIO_PORT=$(add 19000)
APP_MINIO_CONSOLE_PORT=$(add 19001)
OPENIM_WS_PORT=$(add 10001)
OPENIM_API_PORT=$(add 10002)
OPENIM_ADMIN_PORT=$(add 10009)
OPENIM_MYSQL_PORT=$(add 13306)
OPENIM_MONGO_PORT=$(add 37017)
OPENIM_REDIS_PORT=$(add 16379)
OPENIM_MINIO_PORT=$(add 10005)
OPENIM_MINIO_CONSOLE_PORT=$(add 10006)

# ───────── generate secrets ─────────
say "$(t gen_secrets)"
rand_hex()  { openssl rand -hex "$1"; }
rand_b64()  { openssl rand -base64 "$1" | tr -d '=+/' | cut -c1-"$2"; }

JWT_SECRET=$(rand_hex 32)
JSONAPP_DB_PASSWORD=$(rand_b64 30 24)
SUPABASE_DB_PASSWORD=$(rand_b64 30 24)
SUPABASE_DASHBOARD_PASSWORD=$(rand_b64 30 16)
SUPABASE_SECRET_KEY_BASE=$(rand_hex 32)
SUPABASE_VAULT_ENC_KEY=$(rand_hex 16)
SUPABASE_PG_META_CRYPTO_KEY=$(rand_hex 32)
SUPABASE_LOGFLARE_PUBLIC=$(rand_hex 24)
SUPABASE_LOGFLARE_PRIVATE=$(rand_hex 24)
SUPABASE_POOLER_TENANT_ID="testenv$(rand_hex 4)"

APP_MINIO_ROOT_USER="admin$(rand_hex 4)"
APP_MINIO_ROOT_PASSWORD=$(rand_b64 30 24)
APP_MINIO_ACCESS_KEY="app$(rand_hex 8)"
APP_MINIO_SECRET_KEY=$(rand_b64 30 32)

OPENIM_MYSQL_ROOT_PASSWORD=$(rand_b64 30 24)
OPENIM_MYSQL_PASSWORD=$(rand_b64 30 24)
OPENIM_MONGO_PASSWORD=$(rand_b64 30 24)
OPENIM_REDIS_PASSWORD=$(rand_b64 30 24)
OPENIM_MINIO_ACCESS_KEY="openim$(rand_hex 4)"
OPENIM_MINIO_SECRET_KEY=$(rand_b64 30 24)
OPENIM_SECRET=$(rand_hex 32)
OPENIM_WEBHOOK_SECRET=$(rand_hex 32)

FLASK_SECRET_KEY=$(rand_hex 32)
REGISTRY_ADMIN_TOKEN=$(rand_hex 32)
BACKEND_REDIS_PASSWORD=$(rand_b64 30 24)
CONFIG_CENTER_ADMIN_PASSWORD=$(rand_b64 30 16)
CONFIG_CENTER_SESSION_SECRET=$(rand_hex 32)
USER_CENTER_ADMIN_PASSWORD=$(rand_b64 30 16)
USER_CENTER_SESSION_SECRET=$(rand_hex 32)

BYTEDANCE_ASR_APP_KEY=""
BYTEDANCE_ASR_ACCESS_KEY=""
BYTEDANCE_ASR_RESOURCE_ID="volc.bigasr.sauc.duration"
ok "$(t secrets_done)"

# ───────── mint Supabase JWT keys ─────────
say "$(t mint_keys)"
SUPABASE_ANON_KEY=$(python3 "$SCRIPT_DIR/lib/mint-jwt.py" "$JWT_SECRET" anon)
SUPABASE_SERVICE_ROLE_KEY=$(python3 "$SCRIPT_DIR/lib/mint-jwt.py" "$JWT_SECRET" service_role)
ok "$(t keys_done)"

# ───────── render .env files ─────────
say "$(t render_env)"
export HOST_IP PORT_OFFSET
export TEST_USER_EMAIL TEST_USER_PASSWORD TEST_USER_USERNAME
export DEEPSEEK_KEY GLM_ANTHROPIC_AUTH_TOKEN GLM_ANTHROPIC_BASE_URL CC_ANTHROPIC_AUTH_TOKEN CC_ANTHROPIC_BASE_URL
export BYTEDANCE_ASR_APP_KEY BYTEDANCE_ASR_ACCESS_KEY BYTEDANCE_ASR_RESOURCE_ID
export JSONAPP_DB_PASSWORD JSONAPP_DB_PORT
export BACKEND_REDIS_PASSWORD
export APP_MINIO_ROOT_USER APP_MINIO_ROOT_PASSWORD APP_MINIO_ACCESS_KEY APP_MINIO_SECRET_KEY APP_MINIO_PORT APP_MINIO_CONSOLE_PORT
export KONG_HTTP_PORT KONG_HTTPS_PORT JWT_SECRET SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY
export SUPABASE_DB_PASSWORD SUPABASE_DB_PORT SUPABASE_DASHBOARD_PASSWORD SUPABASE_SECRET_KEY_BASE SUPABASE_VAULT_ENC_KEY SUPABASE_PG_META_CRYPTO_KEY SUPABASE_LOGFLARE_PUBLIC SUPABASE_LOGFLARE_PRIVATE SUPABASE_POOLER_TENANT_ID SUPABASE_POOLER_PORT
export OPENIM_SECRET OPENIM_WEBHOOK_SECRET OPENIM_WS_PORT OPENIM_API_PORT OPENIM_ADMIN_PORT
export OPENIM_MYSQL_ROOT_PASSWORD OPENIM_MYSQL_PASSWORD OPENIM_MONGO_PASSWORD OPENIM_REDIS_PASSWORD OPENIM_MINIO_ACCESS_KEY OPENIM_MINIO_SECRET_KEY
export OPENIM_MYSQL_PORT OPENIM_MONGO_PORT OPENIM_REDIS_PORT OPENIM_MINIO_PORT OPENIM_MINIO_CONSOLE_PORT
export FLASK_SECRET_KEY REGISTRY_ADMIN_TOKEN BACKEND_PORT REGISTRY_PORT CONFIG_CENTER_PORT
export CONFIG_CENTER_ADMIN_PASSWORD CONFIG_CENTER_SESSION_SECRET
export USER_CENTER_PORT USER_CENTER_ADMIN_PASSWORD USER_CENTER_SESSION_SECRET
export REGISTRY_UPSTREAM REGISTRY_MIRROR_SYNC_INTERVAL_SEC

envsubst < .env.template          > .env
envsubst < supabase/.env.template > supabase/.env
envsubst < openim/.env.template   > openim/.env
ok "$(t env_done)"

# ───────── pull images ─────────
say "$(t pull_images)"
docker compose --env-file supabase/.env -f supabase/docker-compose.yml -f supabase/docker-compose.override.yml pull --quiet
docker compose --env-file openim/.env   -f openim/docker-compose.yml   pull --quiet
docker compose --env-file .env          -f docker-compose.yml          pull --quiet
ok "$(t images_ready)"

# ───────── start Supabase ─────────
say "$(t start_supabase)"
docker compose --env-file supabase/.env -f supabase/docker-compose.yml -f supabase/docker-compose.override.yml up -d
say "$(t wait_supabase)"
for i in {1..60}; do
  code=$(curl -sS -o /dev/null -m 2 -w '%{http_code}' \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    "http://${HOST_IP}:${KONG_HTTP_PORT}/auth/v1/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "$(t supabase_ready "$i")"; break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "$(t supabase_timeout "$code")"
done

# ───────── render OpenIM config (v3.8 image ignores env, only reads /openim-server/config/*.yml) ─────────
say "$(t openim_cfg)"
OPENIM_CFG_DIR="$SCRIPT_DIR/openim/config-rendered"
rm -rf "$OPENIM_CFG_DIR" && mkdir -p "$OPENIM_CFG_DIR"
docker run --rm --entrypoint sh -v "$OPENIM_CFG_DIR":/host \
  openim/openim-server:v3.8.3-patch.12 \
  -c "cp -a /openim-server/config/. /host/ && chmod -R a+r /host/"

cd "$OPENIM_CFG_DIR"
sed -i "s|localhost:37017|mongodb:27017|g; s|^username: openIM$|username: openim|; s|^password: openIM123$|password: ${OPENIM_MONGO_PASSWORD}|; s|^authSource: openim_v3$|authSource: admin|" mongodb.yml
sed -i "s|localhost:16379|redis:6379|g; s|^password: openIM123$|password: ${OPENIM_REDIS_PASSWORD}|" redis.yml
sed -i "s|localhost:19094|kafka:9092|g" kafka.yml
sed -i "s|localhost:12379|etcd:2379|g" discovery.yml
sed -i "s|^accessKeyID: root$|accessKeyID: ${OPENIM_MINIO_ACCESS_KEY}|; s|^secretAccessKey: openIM123$|secretAccessKey: ${OPENIM_MINIO_SECRET_KEY}|; s|localhost:10005|minio:9000|g; s|http://external_ip:10005|http://${HOST_IP}:${OPENIM_MINIO_PORT}|g" minio.yml
sed -i "s|^secret: openIM123$|secret: ${OPENIM_SECRET}|" share.yml
cd "$SCRIPT_DIR"
ok "$(t openim_cfg_done)"

# ───────── start OpenIM ─────────
say "$(t start_openim)"
docker compose --env-file openim/.env -f openim/docker-compose.yml up -d
say "$(t wait_openim)"
for i in {1..60}; do
  code=$(curl -sS -o /dev/null -m 2 -w '%{http_code}' "http://${HOST_IP}:${OPENIM_API_PORT}/" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|400|401|403|404)$ ]]; then
    ok "$(t openim_ready "$i" "$code")"; break
  fi
  sleep 2
  [[ $i -eq 60 ]] && warn "$(t openim_timeout)"
done

# ───────── start app services ─────────
say "$(t start_app)"
docker compose --env-file .env -f docker-compose.yml up -d --build
say "$(t wait_backend)"
for i in {1..40}; do
  if curl -fsS "http://${HOST_IP}:${BACKEND_PORT}/api/ai/providers" >/dev/null 2>&1; then
    ok "$(t backend_ready "$i")"; break
  fi
  sleep 2
  [[ $i -eq 40 ]] && warn "$(t backend_timeout)"
done

# ───────── init MinIO buckets ─────────
say "$(t init_minio)"
bash "$SCRIPT_DIR/lib/init-buckets.sh"

# ───────── seed test account ─────────
say "$(t seed_user)"
SUPABASE_URL="http://${HOST_IP}:${KONG_HTTP_PORT}" \
SERVICE_ROLE_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
TEST_USER_EMAIL="$TEST_USER_EMAIL" \
TEST_USER_PASSWORD="$TEST_USER_PASSWORD" \
TEST_USER_USERNAME="$TEST_USER_USERNAME" \
python3 "$SCRIPT_DIR/lib/seed-test-user.py"

# ───────── client environment import QR ─────────
ENV_IMPORT_JSON="test-env-environment.json"
ENV_IMPORT_QR="test-env-environment.png"
ENV_NAME="Test Env ${HOST_IP}"
if [[ "$PORT_OFFSET" != "0" ]]; then
  ENV_NAME="Test Env ${HOST_IP} +${PORT_OFFSET}"
fi

ENV_NAME="$ENV_NAME" \
BACKEND_URL="http://${HOST_IP}:${BACKEND_PORT}" \
SUPABASE_URL="http://${HOST_IP}:${KONG_HTTP_PORT}" \
MINIO_URL="http://${HOST_IP}:${APP_MINIO_PORT}" \
REGISTRY_URL="http://${HOST_IP}:${REGISTRY_PORT}" \
IM_API_URL="http://${HOST_IP}:${OPENIM_API_PORT}" \
IM_WS_URL="ws://${HOST_IP}:${OPENIM_WS_PORT}" \
CONFIG_CENTER_URL="http://${HOST_IP}:${CONFIG_CENTER_PORT}" \
python3 - <<'PY' > "$ENV_IMPORT_JSON"
import json
import os

payload = {
    "type": "myapp.environment",
    "version": 1,
    "name": os.environ["ENV_NAME"],
    "backendUrl": os.environ["BACKEND_URL"],
    "supabaseUrl": os.environ["SUPABASE_URL"],
    "minioUrl": os.environ["MINIO_URL"],
    "registryUrl": os.environ["REGISTRY_URL"],
    "imApiUrl": os.environ["IM_API_URL"],
    "imWsUrl": os.environ["IM_WS_URL"],
    "configCenterUrl": os.environ["CONFIG_CENTER_URL"],
}
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
chmod 644 "$ENV_IMPORT_JSON"
qrencode -o "$ENV_IMPORT_QR" < "$ENV_IMPORT_JSON"

# ───────── write info file + summary ─────────
if [[ "$UI_LANG" == "zh" ]]; then
cat > test-env-info.txt <<EOF
========================================
  AI App 测试环境部署信息
  生成时间: $(date)
========================================

客户端访问 IP: ${HOST_IP}

【客户端"服务环境"页填入下列 URL】
  Backend       http://${HOST_IP}:${BACKEND_PORT}
  Supabase      http://${HOST_IP}:${KONG_HTTP_PORT}
  MinIO         http://${HOST_IP}:${APP_MINIO_PORT}
  Registry      http://${HOST_IP}:${REGISTRY_PORT}
  OpenIM HTTP   http://${HOST_IP}:${OPENIM_API_PORT}
  OpenIM WS     ws://${HOST_IP}:${OPENIM_WS_PORT}
  Config Center http://${HOST_IP}:${CONFIG_CENTER_PORT}

【客户端扫码导入】
  二维码 PNG:  ./test-env-environment.png
  二维码 JSON: ./test-env-environment.json

【测试账号】
  邮箱:    ${TEST_USER_EMAIL}
  用户名:  ${TEST_USER_USERNAME}
  密码:    ${TEST_USER_PASSWORD}

【运维 UI / 调试入口】
  Supabase Studio: http://${HOST_IP}:${KONG_HTTP_PORT}   账号: admin / ${SUPABASE_DASHBOARD_PASSWORD}
  MinIO Console:   http://${HOST_IP}:${APP_MINIO_CONSOLE_PORT}   账号: ${APP_MINIO_ROOT_USER} / ${APP_MINIO_ROOT_PASSWORD}
  jsonapp Postgres: psql postgresql://jsonapp:${JSONAPP_DB_PASSWORD}@${HOST_IP}:${JSONAPP_DB_PORT}/jsonapp
  Config Center:   http://${HOST_IP}:${CONFIG_CENTER_PORT}/login   账号: admin / ${CONFIG_CENTER_ADMIN_PASSWORD}
  User Center:     http://${HOST_IP}:${USER_CENTER_PORT}/login   账号: admin / ${USER_CENTER_ADMIN_PASSWORD}
  Registry admin token: ${REGISTRY_ADMIN_TOKEN}

【Registry Mirror】
  Upstream: ${REGISTRY_UPSTREAM:-（未配置，本实例独立运行）}
  同步间隔: ${REGISTRY_MIRROR_SYNC_INTERVAL_SEC}s（0 = 仅首启同步一次）

【常用命令】
  ./redeploy.sh      只更新后端代码（git pull + rebuild，不动数据）
  ./reset-data.sh    清空所有数据卷但保留容器配置
  ./teardown.sh      彻底销毁本环境（删容器 + 数据卷 + .env）
EOF
else
cat > test-env-info.txt <<EOF
========================================
  AI App Test Environment Info
  Generated: $(date)
========================================

Client access IP: ${HOST_IP}

[Fill these URLs in the client "Service Environment" page]
  Backend       http://${HOST_IP}:${BACKEND_PORT}
  Supabase      http://${HOST_IP}:${KONG_HTTP_PORT}
  MinIO         http://${HOST_IP}:${APP_MINIO_PORT}
  Registry      http://${HOST_IP}:${REGISTRY_PORT}
  OpenIM HTTP   http://${HOST_IP}:${OPENIM_API_PORT}
  OpenIM WS     ws://${HOST_IP}:${OPENIM_WS_PORT}
  Config Center http://${HOST_IP}:${CONFIG_CENTER_PORT}

[Client QR import]
  QR PNG:  ./test-env-environment.png
  QR JSON: ./test-env-environment.json

[Test account]
  Email:    ${TEST_USER_EMAIL}
  Username: ${TEST_USER_USERNAME}
  Password: ${TEST_USER_PASSWORD}

[Ops UI / debug entries]
  Supabase Studio: http://${HOST_IP}:${KONG_HTTP_PORT}   login: admin / ${SUPABASE_DASHBOARD_PASSWORD}
  MinIO Console:   http://${HOST_IP}:${APP_MINIO_CONSOLE_PORT}   login: ${APP_MINIO_ROOT_USER} / ${APP_MINIO_ROOT_PASSWORD}
  jsonapp Postgres: psql postgresql://jsonapp:${JSONAPP_DB_PASSWORD}@${HOST_IP}:${JSONAPP_DB_PORT}/jsonapp
  Config Center:   http://${HOST_IP}:${CONFIG_CENTER_PORT}/login   login: admin / ${CONFIG_CENTER_ADMIN_PASSWORD}
  User Center:     http://${HOST_IP}:${USER_CENTER_PORT}/login   login: admin / ${USER_CENTER_ADMIN_PASSWORD}
  Registry admin token: ${REGISTRY_ADMIN_TOKEN}

[Registry Mirror]
  Upstream: ${REGISTRY_UPSTREAM:-(not set, standalone)}
  Sync interval: ${REGISTRY_MIRROR_SYNC_INTERVAL_SEC}s (0 = sync once at startup)

[Common commands]
  ./redeploy.sh      update backend code only (git pull + rebuild, data preserved)
  ./reset-data.sh    wipe all data volumes, keep container config
  ./teardown.sh      destroy this env (containers + volumes + .env)
EOF
fi
chmod 600 test-env-info.txt

echo
printf "${G}╔════════════════════════════════════════════════════════════╗${N}\n"
printf "${G}║  ✔ %-56s║${N}\n" "$(t deploy_done)"
printf "${G}╚════════════════════════════════════════════════════════════╝${N}\n"
cat test-env-info.txt
echo
ok "$(t info_saved)"
ok "$(t env_qr_saved)"
echo
printf "${B}%s:${N}\n" "$(t env_qr_title)"
qrencode -t ANSIUTF8 < "$ENV_IMPORT_JSON"
