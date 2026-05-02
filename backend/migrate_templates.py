#!/usr/bin/env python3
"""
批量发布 templates 目录下的所有模板到 Registry 服务
"""
import json
import os
import requests
from pathlib import Path

REGISTRY_URL = "https://myapp-registry.dapangyu.work"
TOKEN = "test-token"  # 使用管理员测试 token

def publish_template(file_path):
    """发布单个模板文件"""
    print(f"\n处理: {file_path.name}")

    with open(file_path, 'r', encoding='utf-8') as f:
        json_content = json.load(f)

    # 检查是否有 meta 字段
    if 'meta' not in json_content:
        print(f"  ⚠️  跳过: 没有 meta 字段")
        return False

    meta = json_content['meta']
    name = meta.get('name', file_path.stem)
    version = meta.get('version', '1.0.0')
    pkg_type = meta.get('type', 'app')

    print(f"  名称: {name}")
    print(f"  版本: {version}")
    print(f"  类型: {pkg_type}")

    # 发布到 Registry
    try:
        resp = requests.post(
            f"{REGISTRY_URL}/publish",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {TOKEN}"
            },
            json={"json_content": json_content},
            verify=False,
            timeout=30
        )

        result = resp.json()

        if resp.status_code == 200:
            print(f"  ✅ 发布成功")
            return True
        elif resp.status_code == 409:
            print(f"  ⚠️  版本已存在: {result.get('existing_versions', [])}")
            return False
        else:
            print(f"  ❌ 发布失败: {result.get('error', '未知错误')}")
            return False

    except Exception as e:
        print(f"  ❌ 异常: {e}")
        return False

def main():
    templates_dir = Path(__file__).parent.parent / "templates"

    print(f"开始迁移 templates 目录: {templates_dir}")
    print(f"Registry 服务: {REGISTRY_URL}")
    print("=" * 60)

    json_files = sorted(templates_dir.glob("*.json"))

    success_count = 0
    skip_count = 0
    fail_count = 0

    for file_path in json_files:
        result = publish_template(file_path)
        if result:
            success_count += 1
        elif result is False:
            skip_count += 1
        else:
            fail_count += 1

    print("\n" + "=" * 60)
    print(f"迁移完成:")
    print(f"  ✅ 成功: {success_count}")
    print(f"  ⚠️  跳过: {skip_count}")
    print(f"  ❌ 失败: {fail_count}")
    print(f"  📦 总计: {len(json_files)}")

if __name__ == "__main__":
    main()
