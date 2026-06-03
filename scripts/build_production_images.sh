#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-agent-control-plane}"
PUSH="${PUSH:-0}"

cd "$ROOT_DIR"

docker build -f deploy/production/Dockerfile.agent-runtime -t "dapangyufish/myapp-agent-runtime:${TAG}" .
docker build -f deploy/production/Dockerfile.agent-node -t "dapangyufish/myapp-agent-node:${TAG}" .
docker build -f deploy/production/Dockerfile.backend -t "dapangyufish/myapp-backend:${TAG}" .

if [[ "$PUSH" == "1" ]]; then
  docker push "dapangyufish/myapp-agent-runtime:${TAG}"
  docker push "dapangyufish/myapp-agent-node:${TAG}"
  docker push "dapangyufish/myapp-backend:${TAG}"
fi
