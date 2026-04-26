#!/bin/bash
# 上传文件到 MinIO 并返回带签名的 URL
# 参数: $1 = 文件路径, $2 = 有效期（小时，默认1）

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <file_path> [expiry_hours]" >&2
    exit 1
fi

FILE_PATH="$1"
EXPIRY_HOURS="${2:-1}"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File not found: $FILE_PATH" >&2
    exit 1
fi

# 加载环境变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# MinIO 配置
MINIO_ENDPOINT="${MINIO_PUBLIC_URL#https://}"
MINIO_ENDPOINT="${MINIO_ENDPOINT#http://}"
BUCKET="ai-chat-temp"
OBJECT_NAME="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-').json"

# 使用 mc (MinIO Client) 上传文件并生成预签名 URL
# 如果没有 mc，使用 Python 脚本
if command -v mc &> /dev/null; then
    # 配置 mc alias（如果还没配置）
    mc alias set myminio "https://${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" &> /dev/null || true

    # 上传文件
    mc cp "$FILE_PATH" "myminio/${BUCKET}/${OBJECT_NAME}" &> /dev/null

    # 生成预签名 URL
    mc share download --expire="${EXPIRY_HOURS}h" "myminio/${BUCKET}/${OBJECT_NAME}" 2>/dev/null | grep -o 'https://[^[:space:]]*'
else
    # 使用 Python 生成预签名 URL
    python3 - "$FILE_PATH" "$BUCKET" "$OBJECT_NAME" "$EXPIRY_HOURS" <<'PYTHON'
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
endpoint = os.environ.get('MINIO_PUBLIC_URL', 'https://app-oss-endpoint.dapangyu.work').split('://')[-1]
access_key = os.environ.get('MINIO_ACCESS_KEY', '')
secret_key = os.environ.get('MINIO_SECRET_KEY', '')

# 创建 MinIO 客户端
client = Minio(
    endpoint,
    access_key=access_key,
    secret_key=secret_key,
    secure=True,
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
fi
