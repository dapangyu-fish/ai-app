#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-agent-control-plane}"
PUSH="${PUSH:-0}"

cd "$ROOT_DIR"

BUILD_COMMIT="${MYAPP_BUILD_COMMIT:-$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)}"
BUILD_VERSION="${MYAPP_BUILD_VERSION:-$BUILD_COMMIT}"
BUILD_ARGS=(--build-arg "MYAPP_BUILD_COMMIT=${BUILD_COMMIT}" --build-arg "MYAPP_BUILD_VERSION=${BUILD_VERSION}")

docker build "${BUILD_ARGS[@]}" -f deploy/production/Dockerfile.agent-runtime -t "dapangyufish/myapp-agent-runtime:${TAG}" .
docker build "${BUILD_ARGS[@]}" -f deploy/production/Dockerfile.agent-node -t "dapangyufish/myapp-agent-node:${TAG}" .
docker build "${BUILD_ARGS[@]}" -f deploy/production/Dockerfile.backend -t "dapangyufish/myapp-backend:${TAG}" .

if [[ "$PUSH" == "1" ]]; then
  docker push "dapangyufish/myapp-agent-runtime:${TAG}"
  docker push "dapangyufish/myapp-agent-node:${TAG}"
  docker push "dapangyufish/myapp-backend:${TAG}"
fi
