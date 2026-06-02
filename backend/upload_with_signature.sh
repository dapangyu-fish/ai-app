#!/bin/bash
# 上传文件到 MinIO 并返回带签名的 URL
# 参数: $1 = 文件路径, $2 = 有效期（小时，默认 24）
# 默认与 backend/store.py 的 TEMP_JSON_EXPIRY_HOURS 保持一致

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <file_path> [expiry_hours]" >&2
    exit 1
fi

FILE_PATH="$1"
EXPIRY_HOURS="${2:-24}"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 强制校验 JSON-APP。提示词会要求 AI 先本地跑一遍，但上传脚本是最后一道闸：
# 只要 validate_json_app.py 报 ERROR，就不能把坏配置发给客户端。
python3 "$SCRIPT_DIR/repair_json_app.py" "$FILE_PATH" >&2
python3 "$SCRIPT_DIR/validate_json_app.py" "$FILE_PATH" >&2

# 加载环境变量
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# MinIO 配置
MINIO_URL="${MINIO_PUBLIC_URL:-https://myapp-oss-endpoint.dapangyu.work}"
MINIO_ENDPOINT="${MINIO_URL#https://}"
MINIO_ENDPOINT="${MINIO_ENDPOINT#http://}"
BUCKET="ai-chat-temp"
OBJECT_NAME="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-').json"

# 使用 mc (MinIO Client) 上传文件并生成预签名 URL
# 如果没有 mc，使用 Python 脚本
if command -v mc &> /dev/null; then
    # 配置 mc alias（如果还没配置）
    mc alias set myminio "${MINIO_URL}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" &> /dev/null || true

    # 上传文件
    mc cp "$FILE_PATH" "myminio/${BUCKET}/${OBJECT_NAME}" &> /dev/null

    # 生成预签名 URL
    SIGNED_URL="$(mc share download --expire="${EXPIRY_HOURS}h" "myminio/${BUCKET}/${OBJECT_NAME}" 2>/dev/null | grep -o 'https://[^[:space:]]*' | head -n 1)"
else
    # 使用 Python 生成预签名 URL
    SIGNED_URL="$(python3 - "$FILE_PATH" "$BUCKET" "$OBJECT_NAME" "$EXPIRY_HOURS" <<'PYTHON'
import sys
import os
from datetime import timedelta
from minio import Minio
import io

file_path = sys.argv[1]
bucket = sys.argv[2]
object_name = sys.argv[3]
expiry_hours = int(sys.argv[4])

# 读取文件内容
with open(file_path, 'rb') as f:
    data = f.read()

# MinIO 配置
public_url = os.environ.get('MINIO_PUBLIC_URL', 'https://myapp-oss-endpoint.dapangyu.work')
endpoint = public_url.split('://')[-1]
secure = public_url.startswith('https://')
access_key = os.environ.get('MINIO_ACCESS_KEY', '')
secret_key = os.environ.get('MINIO_SECRET_KEY', '')

# 创建 MinIO 客户端
client = Minio(
    endpoint,
    access_key=access_key,
    secret_key=secret_key,
    secure=secure,
)

# 确保 bucket 存在
if not client.bucket_exists(bucket):
    client.make_bucket(bucket)

# 上传文件
client.put_object(
    bucket,
    object_name,
    io.BytesIO(data),
    len(data),
    content_type='application/json',
)

# 生成预签名 URL
url = client.presigned_get_object(bucket, object_name, expires=timedelta(hours=expiry_hours))
print(url)
PYTHON
)"
fi

if [ -z "${SIGNED_URL:-}" ]; then
    echo "Error: failed to create signed URL" >&2
    exit 1
fi

echo "$SIGNED_URL"

# 新结构化客户端动作协议：Agent 原文不负责驱动客户端按钮。
# 如果本脚本运行在 AI_APP_WORKSPACE 内，上传成功后自动写入动作文件；
# 后端 worker 会在本轮结束后读取、校验，并追加 client_action SSE。
if [ -n "${AI_APP_WORKSPACE:-}" ] && [ -d "$AI_APP_WORKSPACE" ]; then
    python3 - "$AI_APP_WORKSPACE/client_actions.json" "$SIGNED_URL" <<'PYTHON'
import json
import os
import sys

path = sys.argv[1]
url = sys.argv[2]
payload = {"client_actions": []}

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict) and isinstance(loaded.get("client_actions"), list):
            payload = loaded
        elif isinstance(loaded, list):
            payload = {"client_actions": loaded}
    except Exception:
        payload = {"client_actions": []}

action = {"type": "json_app_ready", "url": url}
payload["client_actions"] = [
    item for item in payload["client_actions"]
    if not (isinstance(item, dict) and item.get("type") == "json_app_ready")
]
payload["client_actions"].append(action)

with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYTHON
fi
