#!/usr/bin/env bash
# 只清数据卷，保留容器配置 + .env —— 适合"清库重测一遍"
# 完事后用同样的密钥重新 docker compose up（schema 会重建）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

B="\033[1m"; G="\033[32m"; R="\033[31m"; N="\033[0m"

[[ -f .env ]] || { echo "找不到 .env。bootstrap.sh 已移除；新环境请使用 myapp-ctl deploy --build/--pull"; exit 1; }

read -r -p "$(printf "${R}!! 这将清空所有数据库 / OSS / IM 数据，输 yes 继续: ${N}")" ans
[[ "$ans" == "yes" ]] || { echo "已取消"; exit 0; }

# 停服务、删 volume、再起
docker compose --env-file .env          -f docker-compose.yml           down -v
docker compose --env-file openim/.env   -f openim/docker-compose.yml    down -v
docker compose --env-file supabase/.env -f supabase/docker-compose.yml  -f supabase/docker-compose.override.yml down -v
# Supabase 的 db PGDATA 是 bind mount，down -v 不动它，必须手动 rm
rm -rf supabase/volumes/db/data

printf "${G}✔ 数据卷已清空。新部署入口是 myapp-ctl deploy --build/--pull；要保留旧 compose 可直接 'docker compose up -d' 起回来。${N}\n"
