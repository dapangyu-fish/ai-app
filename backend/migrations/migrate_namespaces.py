#!/usr/bin/env python3
"""
数据迁移脚本：从 MinIO _index.json 迁移命名空间数据到 PostgreSQL

使用方法：
    python backend/migrations/migrate_namespaces.py

注意：
    - 迁移前请先执行 001_create_namespace_tables.sql 创建表
    - 迁移完成后会清空 _index.json 中的 namespaces 字段
    - 建议先备份 _index.json
"""

import sys
import os
import json
from datetime import datetime

# 添加父目录到 Python 路径
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from minio import Minio
from config import MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_SECURE
from database import create_namespace, add_namespace_member, get_namespace_by_name

BUCKET_COMPONENT = "json-component"
INDEX_FILE = "_index.json"

# MinIO 客户端
minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=MINIO_SECURE,
)


def load_index():
    """从 MinIO 加载索引文件"""
    try:
        response = minio_client.get_object(BUCKET_COMPONENT, INDEX_FILE)
        data = json.loads(response.read().decode('utf-8'))
        return data
    except Exception as e:
        print(f"[Migration] Error loading index: {e}")
        return None


def save_index(index_data):
    """保存索引文件到 MinIO"""
    import io
    data_bytes = json.dumps(index_data, ensure_ascii=False, indent=2).encode('utf-8')
    minio_client.put_object(
        BUCKET_COMPONENT,
        INDEX_FILE,
        io.BytesIO(data_bytes),
        len(data_bytes),
        content_type="application/json",
    )


def migrate_namespaces():
    """迁移命名空间数据"""
    print("[Migration] 开始迁移命名空间数据...")

    # 1. 加载 _index.json
    index = load_index()
    if not index:
        print("[Migration] 无法加载索引文件")
        return False

    namespaces = index.get('namespaces', {})
    if not namespaces:
        print("[Migration] 没有需要迁移的命名空间")
        return True

    print(f"[Migration] 找到 {len(namespaces)} 个命名空间")

    # 2. 迁移每个命名空间
    migrated_count = 0
    skipped_count = 0

    for ns_name, ns_info in namespaces.items():
        # 跳过子命名空间（包含 / 的）
        if '/' in ns_name:
            print(f"[Migration] 跳过子命名空间: {ns_name}")
            skipped_count += 1
            continue

        owner_id = ns_info.get('owner_id')
        if not owner_id:
            print(f"[Migration] 跳过无 owner_id 的命名空间: {ns_name}")
            skipped_count += 1
            continue

        # 检查是否已存在
        existing = get_namespace_by_name(ns_name)
        if existing:
            print(f"[Migration] 命名空间已存在，跳过: {ns_name}")
            skipped_count += 1
            continue

        try:
            # 创建命名空间
            description = f"Migrated from _index.json"
            namespace_id = create_namespace(ns_name, description, owner_id)

            if namespace_id:
                # 添加 owner 成员
                add_namespace_member(namespace_id, owner_id, 'owner', owner_id)
                print(f"[Migration] ✓ 迁移成功: {ns_name} (owner: {owner_id})")
                migrated_count += 1
            else:
                print(f"[Migration] ✗ 创建失败: {ns_name}")
        except Exception as e:
            print(f"[Migration] ✗ 迁移失败: {ns_name}, 错误: {e}")

    print(f"\n[Migration] 迁移完成:")
    print(f"  - 成功: {migrated_count}")
    print(f"  - 跳过: {skipped_count}")

    # 3. 清空 _index.json 中的 namespaces 字段
    if migrated_count > 0:
        print("\n[Migration] 清空 _index.json 中的 namespaces 字段...")
        index['namespaces'] = {}
        save_index(index)
        print("[Migration] ✓ 已清空 namespaces 字段")

    return True


if __name__ == '__main__':
    print("=" * 60)
    print("命名空间数据迁移脚本")
    print("=" * 60)
    print()

    # 确认操作
    confirm = input("确认开始迁移？(yes/no): ")
    if confirm.lower() != 'yes':
        print("已取消迁移")
        sys.exit(0)

    # 执行迁移
    success = migrate_namespaces()

    if success:
        print("\n[Migration] 迁移完成！")
        sys.exit(0)
    else:
        print("\n[Migration] 迁移失败！")
        sys.exit(1)
