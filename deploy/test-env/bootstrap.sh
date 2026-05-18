#!/usr/bin/env bash
# 测试环境一键部署 —— 交互式，按 Enter 接受默认；只有 3 个必填：
#   - DeepSeek API Key
#   - 测试账号邮箱
#   - 测试账号密码
#
# 用法:
#   ./bootstrap.sh                       # 全交互
#   ./bootstrap.sh --yes                 # 全用默认（DeepSeek key 仍必填，从 $DEEPSEEK_API_KEY 读）
#
# 重跑安全：再次执行会基于现有 .env 起服务；要从头来跑 ./teardown.sh 后再 bootstrap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ───────── 颜色 / 排版 ─────────
B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
say()  { printf "${C}» %s${N}\n" "$*"; }
ok()   { printf "${G}✔ %s${N}\n" "$*"; }
warn() { printf "${Y}! %s${N}\n" "$*"; }
die()  { printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) NON_INTERACTIVE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数: $arg" ;;
  esac
done

ask() {
  # ask "提示语" "默认值"  → 把答案 echo 出来
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
    die "$prompt 必填（--yes 模式下需在环境变量里给出）"
  fi
  while :; do
    read -r -p "$(printf "${B}%s${N}: " "$prompt")" ans </dev/tty
    ans="${ans:-$default_from_env}"
    if [[ -n "$ans" ]]; then echo "$ans"; return; fi
    warn "必填"
  done
}

ask_secret() {
  local prompt="$1"; local default="${2:-}"
  if [[ $NON_INTERACTIVE -eq 1 ]]; then echo "$default"; return; fi
  local hint=""
  [[ -n "$default" ]] && hint=" [自动生成: ${default:0:8}…]"
  local ans
  read -r -p "$(printf "${B}%s${N}${hint}: " "$prompt")" ans </dev/tty
  echo "${ans:-$default}"
}

# ───────── 前置检查 ─────────
banner() {
cat <<'EOF'

╔══════════════════════════════════════════════════════════╗
║         AI App 测试环境一键部署 (test-env v1)            ║
║   按 Enter 接受默认；必填只有 DeepSeek key + 测试账号    ║
╚══════════════════════════════════════════════════════════╝

EOF
}
banner

say "检查依赖..."
for cmd in docker openssl python3 envsubst curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少 $cmd，请先安装"
done
docker compose version >/dev/null 2>&1 || die "docker compose 插件缺失（要 v2，不是老的 docker-compose）"
ok "依赖齐"

# ───────── 探测 IP ─────────
detect_ip() {
  # 优先取私网网卡 IP；不行用 hostname -I 第一个
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  fi
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$ip" ]] && ip="127.0.0.1"
  echo "$ip"
}
DETECTED_IP=$(detect_ip)

# ───────── 收集输入 ─────────
say "[1/4] 客户端访问 IP"
HOST_IP=$(ask "  客户端访问的 IP（局域网测试就填本机内网 IP）" "$DETECTED_IP")

echo
say "[2/4] AI 供应商（backend/config.py 实际识别这几个）"
DEEPSEEK_KEY=$(ask_required "  DeepSeek API Key（必填）" "${DEEPSEEK_KEY:-${DEEPSEEK_API_KEY:-}}")
GLM_ANTHROPIC_AUTH_TOKEN=$(ask    "  GLM (Anthropic-compatible) Auth Token（可选）" "")
GLM_ANTHROPIC_BASE_URL=$(ask      "  GLM Base URL（可选）" "")
CC_ANTHROPIC_AUTH_TOKEN=$(ask     "  Claude Code Anthropic Token（可选）" "")
CC_ANTHROPIC_BASE_URL=$(ask       "  Claude Code Base URL（可选）" "")

echo
say "[3/4] 测试账号（部署完后用来登录客户端）"
TEST_USER_EMAIL=$(ask_required    "  邮箱" "test@example.local")
TEST_USER_USERNAME=$(ask          "  用户名" "${TEST_USER_EMAIL%%@*}")
DEFAULT_PASSWORD="Test$(openssl rand -hex 4)"
TEST_USER_PASSWORD=$(ask_secret   "  密码" "$DEFAULT_PASSWORD")

echo
say "[4/4] 端口偏移（同机并行多 env 时用，默认 0）"
PORT_OFFSET=$(ask "  端口偏移" "0")
[[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || die "端口偏移必须是数字"

# ───────── 计算端口 ─────────
add() { echo $(( $1 + PORT_OFFSET )); }

BACKEND_PORT=$(add 5566)
REGISTRY_PORT=$(add 3254)
CONFIG_CENTER_PORT=$(add 5567)
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
OPENIM_CHAT_PORT=$(add 10008)
OPENIM_MYSQL_PORT=$(add 13306)
OPENIM_MONGO_PORT=$(add 37017)
OPENIM_REDIS_PORT=$(add 16379)
OPENIM_MINIO_PORT=$(add 10005)
OPENIM_MINIO_CONSOLE_PORT=$(add 10006)

# ───────── 生成 secrets ─────────
say "生成密钥..."
rand_hex()  { openssl rand -hex "$1"; }
rand_b64()  { openssl rand -base64 "$1" | tr -d '=+/' | cut -c1-"$2"; }

JWT_SECRET=$(rand_hex 32)
JSONAPP_DB_PASSWORD=$(rand_b64 30 24)
SUPABASE_DB_PASSWORD=$(rand_b64 30 24)
SUPABASE_DASHBOARD_PASSWORD=$(rand_b64 30 16)
SUPABASE_SECRET_KEY_BASE=$(rand_hex 32)
SUPABASE_VAULT_ENC_KEY=$(rand_hex 16)             # 32 字符 hex = 16 字节
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

BYTEDANCE_ASR_APP_KEY=""
BYTEDANCE_ASR_ACCESS_KEY=""
BYTEDANCE_ASR_RESOURCE_ID="volc.bigasr.sauc.duration"
ok "密钥生成完毕"

# ───────── 算 Supabase JWT keys ─────────
say "签发 Supabase ANON_KEY / SERVICE_ROLE_KEY..."
SUPABASE_ANON_KEY=$(python3 "$SCRIPT_DIR/lib/mint-jwt.py" "$JWT_SECRET" anon)
SUPABASE_SERVICE_ROLE_KEY=$(python3 "$SCRIPT_DIR/lib/mint-jwt.py" "$JWT_SECRET" service_role)
ok "Supabase keys 已签发"

# ───────── 写 .env 们 ─────────
say "渲染 .env 文件..."
export HOST_IP PORT_OFFSET
export TEST_USER_EMAIL TEST_USER_PASSWORD TEST_USER_USERNAME
export DEEPSEEK_KEY GLM_ANTHROPIC_AUTH_TOKEN GLM_ANTHROPIC_BASE_URL CC_ANTHROPIC_AUTH_TOKEN CC_ANTHROPIC_BASE_URL
export BYTEDANCE_ASR_APP_KEY BYTEDANCE_ASR_ACCESS_KEY BYTEDANCE_ASR_RESOURCE_ID
export JSONAPP_DB_PASSWORD JSONAPP_DB_PORT
export BACKEND_REDIS_PASSWORD
export APP_MINIO_ROOT_USER APP_MINIO_ROOT_PASSWORD APP_MINIO_ACCESS_KEY APP_MINIO_SECRET_KEY APP_MINIO_PORT APP_MINIO_CONSOLE_PORT
export KONG_HTTP_PORT KONG_HTTPS_PORT JWT_SECRET SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY
export SUPABASE_DB_PASSWORD SUPABASE_DB_PORT SUPABASE_DASHBOARD_PASSWORD SUPABASE_SECRET_KEY_BASE SUPABASE_VAULT_ENC_KEY SUPABASE_PG_META_CRYPTO_KEY SUPABASE_LOGFLARE_PUBLIC SUPABASE_LOGFLARE_PRIVATE SUPABASE_POOLER_TENANT_ID SUPABASE_POOLER_PORT
export OPENIM_SECRET OPENIM_WEBHOOK_SECRET OPENIM_WS_PORT OPENIM_API_PORT OPENIM_ADMIN_PORT OPENIM_CHAT_PORT
export OPENIM_MYSQL_ROOT_PASSWORD OPENIM_MYSQL_PASSWORD OPENIM_MONGO_PASSWORD OPENIM_REDIS_PASSWORD OPENIM_MINIO_ACCESS_KEY OPENIM_MINIO_SECRET_KEY
export OPENIM_MYSQL_PORT OPENIM_MONGO_PORT OPENIM_REDIS_PORT OPENIM_MINIO_PORT OPENIM_MINIO_CONSOLE_PORT
export FLASK_SECRET_KEY REGISTRY_ADMIN_TOKEN BACKEND_PORT REGISTRY_PORT CONFIG_CENTER_PORT
export CONFIG_CENTER_ADMIN_PASSWORD CONFIG_CENTER_SESSION_SECRET

envsubst < .env.template          > .env
envsubst < supabase/.env.template > supabase/.env
envsubst < openim/.env.template   > openim/.env
ok ".env 已渲染（3 份）"

# ───────── 拉镜像 ─────────
say "拉镜像（首次比较慢）..."
docker compose --env-file supabase/.env -f supabase/docker-compose.yml -f supabase/docker-compose.override.yml pull --quiet
docker compose --env-file openim/.env   -f openim/docker-compose.yml   pull --quiet
docker compose --env-file .env          -f docker-compose.yml          pull --quiet
ok "镜像 ready"

# ───────── 启动 Supabase ─────────
say "启动 Supabase（13 服务，首次起约 1-2 分钟）..."
docker compose --env-file supabase/.env -f supabase/docker-compose.yml -f supabase/docker-compose.override.yml up -d
say "等 Supabase auth 服务就绪..."
for i in {1..60}; do
  # Kong 的 /auth/v1/* 路由有 keyauth 插件保护，必须带 apikey；
  # 带 apikey 后：auth 健康返回 200；auth 挂了 Kong 返 502/503
  code=$(curl -sS -o /dev/null -m 2 -w '%{http_code}' \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    "http://${HOST_IP}:${KONG_HTTP_PORT}/auth/v1/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    ok "Supabase auth ready (${i}s)"; break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "Supabase auth 等 120s 还没起来 (last HTTP $code)，docker logs supabase-auth"
done

# ───────── 启动 OpenIM ─────────
say "启动 OpenIM（8 服务，首次起约 1-2 分钟）..."
docker compose --env-file openim/.env -f openim/docker-compose.yml up -d
say "等 OpenIM server 就绪..."
for i in {1..60}; do
  # OpenIM 根路径会返 404（没注册）；用 -o /dev/null 拿 status code，**不**用 -f
  # 否则 curl 4xx 即 exit 22，永远拿不到 status，循环等死
  code=$(curl -sS -o /dev/null -m 2 -w '%{http_code}' "http://${HOST_IP}:${OPENIM_API_PORT}/" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|400|401|403|404)$ ]]; then
    ok "OpenIM API ready (${i}s, HTTP $code)"; break
  fi
  sleep 2
  [[ $i -eq 60 ]] && warn "OpenIM 等 120s 没就绪，继续；docker compose --env-file openim/.env -f openim/docker-compose.yml logs openim-server"
done

# ───────── 启动 app 自有服务 ─────────
say "构建 + 启动 app 自有服务（backend / registry / config-center / jsonapp-postgres / app-minio）..."
docker compose --env-file .env -f docker-compose.yml up -d --build
say "等 backend 健康检查..."
for i in {1..40}; do
  if curl -fsS "http://${HOST_IP}:${BACKEND_PORT}/api/ai/providers" >/dev/null 2>&1; then
    ok "backend ready (${i}s)"; break
  fi
  sleep 2
  [[ $i -eq 40 ]] && warn "backend 健康检查 80s 没过，继续；docker compose logs -f backend 看看"
done

# ───────── 初始化 MinIO buckets ─────────
say "初始化 app-minio buckets..."
bash "$SCRIPT_DIR/lib/init-buckets.sh"

# ───────── Seed 测试账号 ─────────
say "在 Supabase 上创建测试账号..."
SUPABASE_URL="http://${HOST_IP}:${KONG_HTTP_PORT}" \
SERVICE_ROLE_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
TEST_USER_EMAIL="$TEST_USER_EMAIL" \
TEST_USER_PASSWORD="$TEST_USER_PASSWORD" \
TEST_USER_USERNAME="$TEST_USER_USERNAME" \
python3 "$SCRIPT_DIR/lib/seed-test-user.py"

# ───────── 写信息文件 + 摘要 ─────────
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

【测试账号】
  邮箱:    ${TEST_USER_EMAIL}
  用户名:  ${TEST_USER_USERNAME}
  密码:    ${TEST_USER_PASSWORD}

【运维 UI / 调试入口】
  Supabase Studio (DB / Auth GUI):
     http://${HOST_IP}:${KONG_HTTP_PORT}
     账号: admin / ${SUPABASE_DASHBOARD_PASSWORD}
  MinIO Console:
     http://${HOST_IP}:${APP_MINIO_CONSOLE_PORT}
     账号: ${APP_MINIO_ROOT_USER} / ${APP_MINIO_ROOT_PASSWORD}
  jsonapp Postgres:
     psql postgresql://${JSONAPP_DB_USER}:${JSONAPP_DB_PASSWORD}@${HOST_IP}:${JSONAPP_DB_PORT}/jsonapp
  Config Center 后台:
     http://${HOST_IP}:${CONFIG_CENTER_PORT}/login
     账号: admin / ${CONFIG_CENTER_ADMIN_PASSWORD}
  Registry admin token: ${REGISTRY_ADMIN_TOKEN}

【常用命令】
  ./reset-data.sh    清空所有数据卷但保留容器配置
  ./teardown.sh      彻底销毁本环境（删容器 + 数据卷 + .env）
  docker compose --env-file .env logs -f backend          实时看 backend 日志
  docker compose --env-file supabase/.env -f supabase/docker-compose.yml logs -f auth

【已禁用】
  - APNs / FCM / 极光 / 任何 push 通道（测试环境用不到）
  - OpenIM beforeOfflinePush / afterSendSingleMsg webhook
  → 用户杀后台收不到消息，重新打开 app 会拿到积压消息（OpenIM 离线消息保留）

EOF
chmod 600 test-env-info.txt

echo
printf "${G}╔════════════════════════════════════════════════════════════╗${N}\n"
printf "${G}║                  ✔ 部署完成！                              ║${N}\n"
printf "${G}╚════════════════════════════════════════════════════════════╝${N}\n"
cat test-env-info.txt
echo
ok "全部信息也保存到 ./test-env-info.txt（mode 600）"
