#!/usr/bin/env python3
"""
Registry 服务测试脚本
测试所有 API 接口
"""

import json
import requests

BASE_URL = "http://localhost:3254"

def test_health():
    """测试健康检查"""
    print("\n=== 测试健康检查 ===")
    resp = requests.get(f"{BASE_URL}/health")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")


def test_resolve():
    """测试依赖解析"""
    print("\n=== 测试依赖解析 ===")

    # 测试官方包
    print("\n1. 解析官方包 common-ui ^1.0.0")
    resp = requests.get(f"{BASE_URL}/resolve?name=common-ui&version=^1.0.0")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")

    # 测试用户包（如果存在）
    print("\n2. 解析用户包 user/my-app ~1.0.0")
    resp = requests.get(f"{BASE_URL}/resolve?name=user/my-app&version=~1.0.0")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")


def test_package():
    """测试包元数据"""
    print("\n=== 测试包元数据 ===")

    print("\n1. 获取 common-ui 元数据")
    resp = requests.get(f"{BASE_URL}/package/common-ui")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")


def test_namespace_check():
    """测试命名空间检查"""
    print("\n=== 测试命名空间检查 ===")

    print("\n1. 检查已存在的命名空间")
    resp = requests.get(f"{BASE_URL}/namespace/check?name=common-ui")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")

    print("\n2. 检查不存在的命名空间")
    resp = requests.get(f"{BASE_URL}/namespace/check?name=mytest")
    print(f"Status: {resp.status_code}")
    print(f"Response: {json.dumps(resp.json(), indent=2, ensure_ascii=False)}")


def test_namespace_create():
    """测试命名空间创建（需要认证）"""
    print("\n=== 测试命名空间创建 ===")
    print("需要提供有效的 Bearer token，跳过此测试")
    print("手动测试命令:")
    print('curl -X POST http://localhost:3254/namespace/create \\')
    print('  -H "Content-Type: application/json" \\')
    print('  -H "Authorization: Bearer YOUR_TOKEN" \\')
    print('  -d \'{"namespace": "mycompany", "sub_namespace": "frontend"}\'')


def test_publish():
    """测试发布（需要认证）"""
    print("\n=== 测试发布 ===")
    print("需要提供有效的 Bearer token，跳过此测试")
    print("手动测试命令:")
    print('curl -X POST http://localhost:3254/publish \\')
    print('  -H "Content-Type: application/json" \\')
    print('  -H "Authorization: Bearer YOUR_TOKEN" \\')
    print('  -d @test_package.json')


if __name__ == '__main__':
    print("=" * 60)
    print("Registry 服务测试")
    print("=" * 60)

    try:
        test_health()
        test_resolve()
        test_package()
        test_namespace_check()
        test_namespace_create()
        test_publish()

        print("\n" + "=" * 60)
        print("测试完成！")
        print("=" * 60)

    except requests.exceptions.ConnectionError:
        print("\n错误: 无法连接到 Registry 服务")
        print("请确保服务已启动: python backend/registry_server.py")
    except Exception as e:
        print(f"\n错误: {e}")
