#!/usr/bin/env python3
import requests
import json
import os
import sys
import argparse

REGISTRY_URL = os.environ.get("REGISTRY_URL", "https://myapp-registry.dapangyu.work")
URL = f"{REGISTRY_URL}/publish"
TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "..", "templates")
DEFAULT_TOKEN = os.environ.get("REGISTRY_ADMIN_TOKEN", "")


def publish(filename, token=None, force=True):
    if not token:
        token = DEFAULT_TOKEN
    if not token:
        print("❌ 错误: 未提供 token (设 REGISTRY_ADMIN_TOKEN 或 --token)")
        return False
    filepath = os.path.join(TEMPLATES_DIR, filename)
    if not os.path.exists(filepath):
        print(f"❌ 错误: 文件不存在 {filepath}")
        return False
        
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = json.load(f)
    except Exception as e:
        print(f"❌ 错误: 无法解析 JSON {filename}: {e}")
        return False
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}"
    }
    
    payload = {
        "json_content": content,
        "force_update": force
    }
    
    print(f"正在发布 {filename}...")
    try:
        resp = requests.post(URL, headers=headers, json=payload, timeout=30)
        if resp.status_code == 200:
            data = resp.json()
            print(f"✅ 成功 ({resp.status_code}): {data.get('name')} v{data.get('version')} -> {data.get('download_url')}")
            return True
        else:
            print(f"❌ 失败 ({resp.status_code}): {resp.text}")
            return False
    except Exception as e:
        print(f"❌ 请求失败: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="JSON-DSL 市场发布工具")
    parser.add_argument("files", nargs="*", help="要发布的 JSON 文件名（例如 lib_user.json）。如果不填，默认发布模板目录下的所有 .json 文件。")
    parser.add_argument("--token", default=None, help="认证 token（默认读 REGISTRY_ADMIN_TOKEN 环境变量）")
    parser.add_argument("--no-force", action="store_true", help="不强制覆盖已有的同版本文件")
    
    args = parser.parse_args()
    
    files_to_publish = args.files
    if not files_to_publish:
        # 默认全部发布
        files_to_publish = [f for f in os.listdir(TEMPLATES_DIR) if f.endswith('.json')]
        print(f"未指定文件，准备发布 {len(files_to_publish)} 个组件...")
        
    success_count = 0
    for f in files_to_publish:
        if not f.endswith('.json'):
            f += '.json'
        if publish(f, args.token, not args.no_force):
            success_count += 1
            
    print(f"\n发布完成: 成功 {success_count}/{len(files_to_publish)}")
    
if __name__ == "__main__":
    main()
