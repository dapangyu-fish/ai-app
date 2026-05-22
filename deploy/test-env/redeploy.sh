#!/usr/bin/env bash
# 只更新后端代码：git pull + 重建 backend / ai-worker / registry / config-center 镜像
# 数据卷（Postgres / Redis / MinIO）一律不动 —— 它们挂在其他容器上
#
# === git 和容器的边界（看脚本前先理清楚）===
# 1) git pull 跑在 *宿主机* 的 /root/ai-app（bootstrap.sh 时已经 clone 过），
#    用宿主机的 ssh key 拉私有仓库，容器里没有 git、也不需要 git 凭据
# 2) rebuild 时 Dockerfile 用 `context: ../../`，docker daemon 把 *宿主机*
#    刚 pull 下来的 backend/ 目录 COPY 进新镜像
# 3) 新容器从新镜像启，代码就是最新的；整个过程容器都不联网拉代码
#
# 用法:
#   ./redeploy.sh                     # 共用 Dockerfile.backend 的服务都重建
#   ./redeploy.sh backend             # 只重建 backend
#   ./redeploy.sh backend registry    # 指定多个
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
REPO_ROOT="$(cd ../.. && pwd)"

# 先解析 --force，再把剩下的位置参数当服务名（否则 --force 会被当成服务名喂给 docker compose）
FORCE=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--force" ]]; then
    FORCE=1
  else
    ARGS+=("$arg")
  fi
done

# 默认重建全部四个吃同一份 Dockerfile.backend 的服务，免得改 config.py / database.py 这种共用模块时漏掉
SERVICES=("backend" "ai-worker" "registry" "config-center" "user-center")
[[ ${#ARGS[@]} -gt 0 ]] && SERVICES=("${ARGS[@]}")

B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; N="\033[0m"

echo -e "${B}== 1. git pull ==${N}"
cd "$REPO_ROOT"
OLD_HEAD=$(git rev-parse HEAD)
git pull --ff-only
NEW_HEAD=$(git rev-parse HEAD)
if [[ "$OLD_HEAD" == "$NEW_HEAD" ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    echo -e "${Y}没有新提交。如果就想 rebuild 现有代码，加 --force：${N}"
    echo -e "${Y}  ./redeploy.sh --force [service...]${N}"
    exit 0
  fi
  echo -e "${Y}没有新提交，--force 强制 rebuild${N}"
else
  echo -e "${G}更新: $OLD_HEAD → $NEW_HEAD${N}"
  git log --oneline "$OLD_HEAD..$NEW_HEAD"
fi
echo

cd "$SCRIPT_DIR"
echo -e "${B}== 2. rebuild + recreate: ${SERVICES[*]} ==${N}"
docker compose --env-file .env -f docker-compose.yml up -d --build "${SERVICES[@]}"

echo
echo -e "${B}== 3. healthcheck（等 15s 让 healthcheck 跑一轮）==${N}"
sleep 15
for s in "${SERVICES[@]}"; do
  cname="testenv-$s"
  status=$(docker inspect -f '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "no-healthcheck")
  case "$status" in
    healthy)        echo -e "  ${G}✔${N} $cname: $status" ;;
    starting)       echo -e "  ${Y}…${N} $cname: $status（还在启动）" ;;
    unhealthy)      echo -e "  ${R}✘${N} $cname: $status —— docker logs $cname 看看" ;;
    no-healthcheck) echo -e "  ${Y}·${N} $cname: 无 healthcheck，仅检查存活" ;;
    *)              echo -e "  $cname: $status" ;;
  esac
done
echo
echo -e "${G}✔ 完成。要看日志：${N}docker compose --env-file .env -f docker-compose.yml logs -f ${SERVICES[*]}"
