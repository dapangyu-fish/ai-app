#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-agent-control-plane}"
PUSH="${PUSH:-0}"
BUILD_BASE="${BUILD_BASE:-0}"
PUSH_BASE="${PUSH_BASE:-$BUILD_BASE}"

cd "$ROOT_DIR"

BUILD_COMMIT="${MYAPP_BUILD_COMMIT:-$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)}"
BUILD_VERSION="${MYAPP_BUILD_VERSION:-$BUILD_COMMIT}"
BUILD_ARGS=(--build-arg "MYAPP_BUILD_COMMIT=${BUILD_COMMIT}" --build-arg "MYAPP_BUILD_VERSION=${BUILD_VERSION}")

if [[ "$BUILD_BASE" == "1" ]]; then
  docker build -f deploy/production/Dockerfile.agent-runtime-base -t "dapangyu/myapp-agent-runtime-base:${TAG}" .
  docker build -f deploy/production/Dockerfile.agent-node-base -t "dapangyu/myapp-agent-node-base:${TAG}" .
  docker build -f deploy/production/Dockerfile.backend-base -t "dapangyu/myapp-backend-base:${TAG}" .
fi

docker build "${BUILD_ARGS[@]}" --build-arg "BASE_IMAGE=dapangyu/myapp-agent-runtime-base:${TAG}" -f deploy/production/Dockerfile.agent-runtime -t "dapangyu/myapp-agent-runtime:${TAG}" .
docker build "${BUILD_ARGS[@]}" --build-arg "BASE_IMAGE=dapangyu/myapp-agent-node-base:${TAG}" -f deploy/production/Dockerfile.agent-node -t "dapangyu/myapp-agent-node:${TAG}" .
docker build "${BUILD_ARGS[@]}" --build-arg "BASE_IMAGE=dapangyu/myapp-backend-base:${TAG}" -f deploy/production/Dockerfile.backend -t "dapangyu/myapp-backend:${TAG}" .

if [[ "$PUSH" == "1" ]]; then
  if [[ "$PUSH_BASE" == "1" ]]; then
    docker push "dapangyu/myapp-agent-runtime-base:${TAG}"
    docker push "dapangyu/myapp-agent-node-base:${TAG}"
    docker push "dapangyu/myapp-backend-base:${TAG}"
  fi
  docker push "dapangyu/myapp-agent-runtime:${TAG}"
  docker push "dapangyu/myapp-agent-node:${TAG}"
  docker push "dapangyu/myapp-backend:${TAG}"
fi
