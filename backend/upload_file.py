#!/usr/bin/env python3
import sys
import uuid
import os

# 将 backend 目录加入路径以方便导入 store
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from store import _minio_upload

def main():
    if len(sys.argv) < 2:
        print("Usage: python upload_file.py <file_path>")
        sys.exit(1)

    file_path = sys.argv[1]
    if not os.path.exists(file_path):
        print(f"Error: File {file_path} not found.")
        sys.exit(1)

    with open(file_path, "r", encoding="utf-8") as f:
        data = f.read()

    bucket = "ai-chat-temp"
    key = f"{uuid.uuid4().hex}.json"

    url = _minio_upload(bucket, key, data)
    # 输出 URL，使用 <<URL>> 标记包裹，避免 shell 截断
    print(f"<<URL>>{url}<</URL>>")

if __name__ == "__main__":
    main()
