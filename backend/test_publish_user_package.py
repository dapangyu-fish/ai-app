#!/usr/bin/env python3
"""
用户包发布示例脚本
演示如何创建命名空间并发布用户包
"""

import os
import requests
import json
import urllib3

# 禁用 SSL 警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

REGISTRY_URL = os.environ.get("REGISTRY_URL", "https://myapp-registry.dapangyu.work")

_TOKEN = os.environ.get("REGISTRY_ADMIN_TOKEN")
if not _TOKEN:
    raise SystemExit("请设置 REGISTRY_ADMIN_TOKEN 环境变量（在 backend/.env 里），不要硬编码")
HEADERS = {
    "Authorization": f"Bearer {_TOKEN}"
}

def test_namespace_creation():
    """测试命名空间创建"""
    print("=== 测试命名空间创建 ===\n")

    # 1. 检查命名空间是否可用
    namespace = "mycompany"
    print(f"1. 检查命名空间 '{namespace}' 是否可用...")
    resp = requests.get(f"{REGISTRY_URL}/namespace/check", params={"name": namespace}, verify=False)
    print(f"   响应: {resp.json()}\n")

    # 2. 创建命名空间
    if resp.json().get("available"):
        print(f"2. 创建命名空间 '{namespace}'...")
        resp = requests.post(f"{REGISTRY_URL}/namespace/create", json={
            "namespace": namespace
        }, headers=HEADERS, verify=False)
        print(f"   响应: {resp.json()}\n")
    else:
        print(f"2. 命名空间 '{namespace}' 已存在，跳过创建\n")

def test_user_package_publish():
    """测试用户包发布"""
    print("=== 测试用户包发布 ===\n")

    # 创建一个示例用户包
    package_name = "mycompany/ui-kit"
    version = "1.0.0"

    package_content = {
        "meta": {
            "name": package_name,
            "version": version,
            "type": "library",
            "description": "My Company UI Kit"
        },
        "components": {
            "CustomButton": {
                "type": "Container",
                "props": {
                    "padding": {"all": 16},
                    "decoration": {
                        "color": "#007AFF",
                        "borderRadius": {"all": 8}
                    }
                },
                "children": [
                    {
                        "type": "Text",
                        "props": {
                            "data": "Custom Button",
                            "style": {
                                "color": "#FFFFFF",
                                "fontSize": 16,
                                "fontWeight": "bold"
                            }
                        }
                    }
                ]
            },
            "CustomCard": {
                "type": "Card",
                "props": {
                    "elevation": 4,
                    "margin": {"all": 8}
                },
                "children": [
                    {
                        "type": "Padding",
                        "props": {"padding": {"all": 16}},
                        "children": [
                            {
                                "type": "Text",
                                "props": {
                                    "data": "Custom Card",
                                    "style": {"fontSize": 18}
                                }
                            }
                        ]
                    }
                ]
            }
        }
    }

    print(f"1. 发布用户包 '{package_name}' v{version}...")
    resp = requests.post(f"{REGISTRY_URL}/publish", json={
        "json_content": package_content
    }, headers=HEADERS, verify=False)

    result = resp.json()
    print(f"   响应: {json.dumps(result, indent=2)}\n")

    if result.get("message") == "发布成功":
        print(f"✅ 发布成功！")
        print(f"   下载地址: {result.get('download_url')}\n")
        return True
    else:
        print(f"❌ 发布失败: {result.get('error')}\n")
        return False

def test_user_package_resolve():
    """测试用户包依赖解析"""
    print("=== 测试用户包依赖解析 ===\n")

    package_name = "mycompany/ui-kit"
    version = "^1.0.0"

    print(f"1. 解析依赖 '{package_name}' {version}...")
    resp = requests.get(f"{REGISTRY_URL}/resolve", params={
        "name": package_name,
        "version": version
    }, verify=False)

    result = resp.json()
    print(f"   响应: {json.dumps(result, indent=2)}\n")

    if result.get("download_url"):
        print(f"✅ 解析成功！")
        print(f"   包名: {result.get('name')}")
        print(f"   版本: {result.get('version')}")
        print(f"   类型: {result.get('type')}")
        print(f"   下载地址: {result.get('download_url')}\n")
        return True
    else:
        print(f"❌ 解析失败: {result.get('error')}\n")
        return False

def test_nested_namespace():
    """测试嵌套命名空间（2级）"""
    print("=== 测试嵌套命名空间 ===\n")

    # 1. 创建嵌套命名空间
    namespace = "mycompany/frontend"
    print(f"1. 检查嵌套命名空间 '{namespace}' 是否可用...")
    resp = requests.get(f"{REGISTRY_URL}/namespace/check", params={"name": namespace}, verify=False)
    print(f"   响应: {resp.json()}\n")

    if resp.json().get("available"):
        print(f"2. 创建嵌套命名空间 '{namespace}'...")
        resp = requests.post(f"{REGISTRY_URL}/namespace/create", json={
            "namespace": "mycompany",
            "sub_namespace": "frontend"
        }, headers=HEADERS, verify=False)
        print(f"   响应: {resp.json()}\n")

    # 2. 发布嵌套命名空间的包
    package_name = "mycompany/frontend/form-kit"
    version = "1.0.0"

    package_content = {
        "meta": {
            "name": package_name,
            "version": version,
            "type": "library",
            "description": "Form Components Kit"
        },
        "components": {
            "FormInput": {
                "type": "TextField",
                "props": {
                    "decoration": {
                        "border": "outline",
                        "labelText": "Input Field"
                    }
                }
            }
        }
    }

    print(f"3. 发布嵌套包 '{package_name}' v{version}...")
    resp = requests.post(f"{REGISTRY_URL}/publish", json={
        "json_content": package_content
    }, headers=HEADERS, verify=False)

    result = resp.json()
    print(f"   响应: {json.dumps(result, indent=2)}\n")

    if result.get("success"):
        print(f"✅ 嵌套包发布成功！\n")

        # 4. 解析嵌套包
        print(f"4. 解析嵌套包依赖...")
        resp = requests.get(f"{REGISTRY_URL}/resolve", params={
            "name": package_name,
            "version": "^1.0.0"
        }, verify=False)
        print(f"   响应: {json.dumps(resp.json(), indent=2)}\n")

def main():
    print("=" * 60)
    print("Registry 用户包发布完整测试")
    print("=" * 60)
    print()

    try:
        # 1. 测试命名空间创建
        test_namespace_creation()

        # 2. 测试用户包发布
        if test_user_package_publish():
            # 3. 测试用户包解析
            test_user_package_resolve()

        # 4. 测试嵌套命名空间
        test_nested_namespace()

        print("=" * 60)
        print("✅ 所有测试完成！")
        print("=" * 60)

    except Exception as e:
        print(f"\n❌ 测试失败: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
