#!/usr/bin/env python3
"""
Registry 初始化脚本
从现有数据库迁移数据到 MinIO _index.json
"""

import io
import json
import os
from datetime import datetime

import psycopg2
from psycopg2.extras import DictCursor
from minio import Minio

# ═══════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════

from config import (
    MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_SECURE,
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
)

BUCKET_COMPONENT = "json-component"
INDEX_FILE = "_index.json"

# ═══════════════════════════════════════════════════════════
# 主逻辑
# ═══════════════════════════════════════════════════════════

def main():
    print("[Registry Init] 开始初始化 Registry 索引...")

    # 连接数据库
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )

    # 连接 MinIO
    minio_client = Minio(
        MINIO_ENDPOINT,
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=MINIO_SECURE,
    )

    # 查询所有 component 类型的包
    with conn.cursor(cursor_factory=DictCursor) as cur:
        cur.execute("""
            SELECT id, name, version, type, author_id, created_at, oss_key
            FROM app_registry
            WHERE type = 'component'
            ORDER BY name, version
        """)
        rows = cur.fetchall()

    conn.close()

    # 构建索引结构
    index = {
        "version": "1.0",
        "updated_at": datetime.utcnow().isoformat() + "Z",
        "packages": {},
        "namespaces": {}
    }

    # 按包名分组
    packages_by_name = {}
    for row in rows:
        name = row['name']
        version = row['version']
        author_id = row['author_id']
        created_at = row['created_at'].isoformat() + "Z" if row['created_at'] else None

        if name not in packages_by_name:
            packages_by_name[name] = {
                "versions": [],
                "author_id": author_id,
                "created_at": created_at
            }

        packages_by_name[name]['versions'].append(version)

    # 构建 packages 索引
    for name, info in packages_by_name.items():
        # 排序版本号
        versions = info['versions']
        versions.sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
        latest = versions[0]

        # 判断类型（是否包含 /）
        slash_count = name.count('/')
        pkg_type = "official" if slash_count == 0 else "user"

        # 构造路径
        path = name

        index['packages'][name] = {
            "type": pkg_type,
            "latest": latest,
            "versions": versions,
            "path": path,
            "author_id": info['author_id'],
            "created_at": info['created_at']
        }

        print(f"  - {name}: {len(versions)} 个版本，最新 {latest}")

    # 提取命名空间（从包名中推断）
    namespaces = {}
    for name in packages_by_name.keys():
        parts = name.split('/')
        if len(parts) >= 2:
            # 一级命名空间
            ns1 = parts[0]
            if ns1 not in namespaces:
                namespaces[ns1] = {
                    "owner_id": packages_by_name[name]['author_id'],
                    "owner_email": "",
                    "created_at": packages_by_name[name]['created_at'],
                    "sub_namespaces": []
                }

            # 二级命名空间
            if len(parts) == 3:
                ns2 = f"{parts[0]}/{parts[1]}"
                if ns2 not in namespaces:
                    namespaces[ns2] = {
                        "owner_id": packages_by_name[name]['author_id'],
                        "created_at": packages_by_name[name]['created_at']
                    }
                    if parts[1] not in namespaces[ns1]['sub_namespaces']:
                        namespaces[ns1]['sub_namespaces'].append(parts[1])

    index['namespaces'] = namespaces

    print(f"\n[Registry Init] 索引统计:")
    print(f"  - 包总数: {len(index['packages'])}")
    print(f"  - 命名空间: {len(index['namespaces'])}")

    # 上传到 MinIO
    data_bytes = json.dumps(index, ensure_ascii=False, indent=2).encode('utf-8')
    minio_client.put_object(
        BUCKET_COMPONENT,
        INDEX_FILE,
        io.BytesIO(data_bytes),
        len(data_bytes),
        content_type="application/json",
    )

    print(f"\n[Registry Init] 索引文件已上传到 MinIO: {BUCKET_COMPONENT}/{INDEX_FILE}")
    print("[Registry Init] 初始化完成！")


if __name__ == '__main__':
    main()
