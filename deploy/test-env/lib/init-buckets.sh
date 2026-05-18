#!/usr/bin/env bash
# 在 app-minio 上创建 4 个 bucket，与生产一致：json-app / json-component / models / ai-chat-temp
# 用 minio/mc 镜像跑一次性容器，比起 alpine + 装 mc 简单
set -euo pipefail

: "${HOST_IP:?HOST_IP required}"
: "${APP_MINIO_PORT:?APP_MINIO_PORT required}"
: "${APP_MINIO_ROOT_USER:?APP_MINIO_ROOT_USER required}"
: "${APP_MINIO_ROOT_PASSWORD:?APP_MINIO_ROOT_PASSWORD required}"
: "${APP_MINIO_ACCESS_KEY:?APP_MINIO_ACCESS_KEY required}"
: "${APP_MINIO_SECRET_KEY:?APP_MINIO_SECRET_KEY required}"

# mc 通过容器走内部 docker 网络访问 minio（避免依赖 HOST_IP 路由）
docker run --rm \
  --network testenv-app_default \
  -e MC_HOST_app="http://${APP_MINIO_ROOT_USER}:${APP_MINIO_ROOT_PASSWORD}@app-minio:9000" \
  minio/mc:latest \
  sh -c '
    set -e
    until mc alias list app >/dev/null 2>&1; do sleep 1; done
    for b in json-app json-component models ai-chat-temp; do
      mc mb -p app/$b 2>/dev/null || echo "  bucket $b 已存在"
    done
    # json-app 和 json-component 设公读（客户端直接 GET）
    mc anonymous set download app/json-app
    mc anonymous set download app/json-component
    mc anonymous set download app/models
    # ai-chat-temp 私有，通过 presigned URL 访问
    # 应用 access key（次级账号）
    mc admin user add app "'"${APP_MINIO_ACCESS_KEY}"'" "'"${APP_MINIO_SECRET_KEY}"'" || true
    mc admin policy attach app readwrite --user "'"${APP_MINIO_ACCESS_KEY}"'" || true
    echo "✔ MinIO buckets + access key ready"
  '
