#!/usr/bin/env bash
# 彻底销毁本测试环境：删容器 + 删数据卷 + 删 .env / 信息文件
# 三栈分别 down -v，互不影响其他 compose project
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; N="\033[0m"

read -r -p "$(printf "${R}!! 这将删除所有容器和数据卷（不可恢复），输 yes 继续: ${N}")" ans
[[ "$ans" == "yes" ]] || { echo "已取消"; exit 0; }

[[ -f .env ]] && {
  docker compose --env-file .env          -f docker-compose.yml           down -v --remove-orphans || true
}
[[ -f openim/.env ]] && {
  docker compose --env-file openim/.env   -f openim/docker-compose.yml    down -v --remove-orphans || true
}
[[ -f supabase/.env ]] && {
  docker compose --env-file supabase/.env -f supabase/docker-compose.yml  -f supabase/docker-compose.override.yml down -v --remove-orphans || true
}

rm -f .env supabase/.env openim/.env test-env-info.txt
printf "${G}✔ 已销毁${N}\n"
