#!/usr/bin/env python3
"""
JSON-DSL Registry Server
独立的包注册中心服务，负责依赖解析和命名空间管理

启动: python backend/registry_server.py
端口: 3254
域名: https://registry.dapangyu.work
"""

import io
import json
import os
import re
from datetime import datetime
from functools import wraps

import requests
from flask import Flask, request, jsonify
from minio import Minio

# ═══════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════

SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://127.0.0.1:8000")
SUPABASE_ANON_KEY = (
    "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9"
    ".eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3NzYzNjU0NjIsICJleHAiOiAyMDkxNzI1NDYyfQ"
    ".yDol0HCrVCJ_XlWTAb3k89aAwb-KzMlSMw-EHEIpB2k"
)

MINIO_ENDPOINT = "127.0.0.1:9000"
MINIO_ACCESS_KEY = "m3wZkIA5EgmEwkctueZM"
MINIO_SECRET_KEY = "m9M7M70F6SpsQxTZZ6roLklq33AUMV8mzAm1RJGk"
MINIO_PUBLIC_URL = "https://app-oss-endpoint.dapangyu.work"

BUCKET_APP = "json-app"
BUCKET_COMPONENT = "json-component"
INDEX_FILE = "_index.json"

PORT = 3254

app = Flask(__name__)

# MinIO 客户端
minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=False,
)

# ═══════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════

def _supabase_headers(token=None):
    h = {"apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _get_user_role(user):
    """从 app_metadata 获取角色，默认 user"""
    return user.get("app_metadata", {}).get("role", "user")


def require_auth(f):
    """认证装饰器"""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "未提供认证 token"}), 401
        token = auth[7:]

        # 测试模式：允许使用 test-token
        if token == "test-token":
            request.supabase_user = {
                "id": "test-user-id",
                "email": "test@example.com"
            }
            request.supabase_token = token
            request.user_role = "admin"
            return f(*args, **kwargs)

        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=10,
        )
        if resp.status_code != 200:
            return jsonify({"error": "token 无效或已过期"}), 401
        request.supabase_user = resp.json()
        request.supabase_token = token
        request.user_role = _get_user_role(request.supabase_user)
        return f(*args, **kwargs)
    return decorated


def _load_index():
    """从 MinIO 加载全局索引文件"""
    try:
        response = minio_client.get_object(BUCKET_COMPONENT, INDEX_FILE)
        data = response.read()
        return json.loads(data.decode('utf-8'))
    except Exception as e:
        # 索引文件不存在，返回空结构
        print(f"[Registry] 索引文件不存在或加载失败: {e}")
        return {
            "version": "1.0",
            "updated_at": datetime.utcnow().isoformat() + "Z",
            "packages": {},
            "namespaces": {}
        }


def _save_index(index_data):
    """保存全局索引文件到 MinIO"""
    index_data["updated_at"] = datetime.utcnow().isoformat() + "Z"
    data_bytes = json.dumps(index_data, ensure_ascii=False, indent=2).encode('utf-8')

    minio_client.put_object(
        BUCKET_COMPONENT,
        INDEX_FILE,
        io.BytesIO(data_bytes),
        len(data_bytes),
        content_type="application/json",
    )


def _validate_package_name(name):
    """
    验证包名格式
    - 官方包: common-ui, data-utils (无 /)
    - 用户包: mycompany/app-name (一级 /)
    - 用户包: mycompany/frontend/ui-kit (二级 /)
    """
    if not name:
        return False, "包名不能为空"

    # 检查斜杠数量
    slash_count = name.count('/')
    if slash_count > 2:
        return False, "包名最多支持两级命名空间（如 org/team/app）"

    # 检查每个部分的格式
    parts = name.split('/')
    pattern = re.compile(r'^[a-z0-9][a-z0-9-_]*$')
    for part in parts:
        if not pattern.match(part):
            return False, f"包名部分 '{part}' 格式不正确（只能包含小写字母、数字、- 和 _，且必须以字母或数字开头）"

    return True, ""


def _validate_version(version):
    """验证版本号格式（semver）"""
    pattern = re.compile(r'^\d+\.\d+\.\d+$')
    return pattern.match(version) is not None


def _parse_version_constraint(constraint):
    """解析版本约束（简化版 semver）"""
    constraint = constraint.strip()

    # ^1.2.3 → >=1.2.3 <2.0.0
    if constraint.startswith('^'):
        version = constraint[1:]
        parts = version.split('.')
        if len(parts) == 3:
            major = int(parts[0])
            return f">={version} <{major + 1}.0.0"

    # ~1.2.3 → >=1.2.3 <1.3.0
    elif constraint.startswith('~'):
        version = constraint[1:]
        parts = version.split('.')
        if len(parts) == 3:
            major, minor = int(parts[0]), int(parts[1])
            return f">={version} <{major}.{minor + 1}.0"

    # >=1.0.0, >=1.0.0 <2.0.0
    elif constraint.startswith('>=') or '<' in constraint:
        return constraint

    # 1.2.3 → ==1.2.3
    elif _validate_version(constraint):
        return f"=={constraint}"

    # * → 任意版本
    elif constraint == '*':
        return ">=0.0.0"

    return None


def _match_version(version, constraint_str):
    """检查版本是否满足约束"""
    if constraint_str == ">=0.0.0":  # * 匹配任意版本
        return True

    def parse_version(v):
        parts = v.split('.')
        return tuple(int(p) for p in parts)

    v = parse_version(version)

    # 解析约束
    if constraint_str.startswith('=='):
        target = parse_version(constraint_str[2:])
        return v == target

    # >=1.2.3 <2.0.0
    if '>=' in constraint_str and '<' in constraint_str:
        parts = constraint_str.split()
        min_v = parse_version(parts[0][2:])
        max_v = parse_version(parts[1][1:])
        return min_v <= v < max_v

    # >=1.2.3
    if constraint_str.startswith('>='):
        min_v = parse_version(constraint_str[2:])
        return v >= min_v

    return False


def _select_best_version(versions, constraint):
    """从版本列表中选择最佳匹配版本"""
    constraint_str = _parse_version_constraint(constraint)
    if not constraint_str:
        return None

    # 过滤满足约束的版本
    matched = [v for v in versions if _match_version(v, constraint_str)]
    if not matched:
        return None

    # 返回最新版本（按 semver 排序）
    def parse_version(v):
        parts = v.split('.')
        return tuple(int(p) for p in parts)

    matched.sort(key=parse_version, reverse=True)
    return matched[0]


# ═══════════════════════════════════════════════════════════
# API 路由
# ═══════════════════════════════════════════════════════════

@app.route('/health', methods=['GET'])
def health():
    """健康检查"""
    return jsonify({
        "status": "ok",
        "service": "json-dsl-registry",
        "version": "1.0.0"
    })


@app.route('/resolve', methods=['GET'])
def resolve():
    """
    依赖解析接口
    GET /resolve?name=common-ui&version=^1.0.0
    """
    name = request.args.get('name', '').strip()
    version_constraint = request.args.get('version', '*').strip()

    if not name:
        return jsonify({"error": "缺少 name 参数"}), 400

    # 加载索引
    index = _load_index()

    # 查找包
    package_info = index['packages'].get(name)
    if not package_info:
        return jsonify({"error": f"包 '{name}' 不存在"}), 404

    # 选择最佳版本
    best_version = _select_best_version(package_info['versions'], version_constraint)
    if not best_version:
        return jsonify({
            "error": f"没有满足约束 '{version_constraint}' 的版本",
            "available_versions": package_info['versions']
        }), 404

    # 构造下载 URL
    path = package_info['path']
    filename = f"{name.split('/')[-1]}-{best_version}.json"
    download_url = f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{path}/{filename}"

    return jsonify({
        "name": name,
        "version": best_version,
        "download_url": download_url,
        "type": package_info.get('type', 'user'),
        "latest": package_info.get('latest')
    })


@app.route('/package/<path:name>', methods=['GET'])
def get_package(name):
    """
    获取包的元数据
    GET /package/common-ui
    GET /package/mycompany/frontend/ui-kit
    """
    # 加载索引
    index = _load_index()

    # 查找包
    package_info = index['packages'].get(name)
    if not package_info:
        return jsonify({"error": f"包 '{name}' 不存在"}), 404

    return jsonify({
        "name": name,
        "type": package_info.get('type', 'user'),
        "latest": package_info.get('latest'),
        "versions": package_info['versions'],
        "path": package_info['path'],
        "created_at": package_info.get('created_at'),
        "author_id": package_info.get('author_id')
    })


@app.route('/namespace/check', methods=['GET'])
def check_namespace():
    """
    检查命名空间是否可用
    GET /namespace/check?name=mycompany
    GET /namespace/check?name=mycompany/frontend
    """
    name = request.args.get('name', '').strip()

    if not name:
        return jsonify({"error": "缺少 name 参数"}), 400

    # 验证格式
    slash_count = name.count('/')
    if slash_count > 1:
        return jsonify({"error": "命名空间最多支持一级（如 org/team）"}), 400

    # 加载索引
    index = _load_index()

    # 检查是否已存在
    exists = name in index['namespaces']

    return jsonify({
        "name": name,
        "available": not exists,
        "exists": exists
    })


@app.route('/namespace/create', methods=['POST'])
@require_auth
def create_namespace():
    """
    创建命名空间（首次发布时调用）
    POST /namespace/create
    Body: {
      "namespace": "mycompany",
      "sub_namespace": "frontend"  # 可选
    }
    """
    body = request.get_json(silent=True) or {}
    namespace = body.get('namespace', '').strip()
    sub_namespace = body.get('sub_namespace', '').strip()

    if not namespace:
        return jsonify({"error": "缺少 namespace 参数"}), 400

    # 验证格式
    pattern = re.compile(r'^[a-z0-9][a-z0-9-_]*$')
    if not pattern.match(namespace):
        return jsonify({"error": "命名空间格式不正确（只能包含小写字母、数字、- 和 _）"}), 400

    if sub_namespace and not pattern.match(sub_namespace):
        return jsonify({"error": "子命名空间格式不正确"}), 400

    # 加载索引
    index = _load_index()

    user = request.supabase_user
    user_id = user.get('id')
    user_email = user.get('email', '')

    # 检查一级命名空间
    if namespace in index['namespaces']:
        existing = index['namespaces'][namespace]
        if existing['owner_id'] != user_id:
            return jsonify({"error": f"命名空间 '{namespace}' 已被其他用户占用"}), 403
    else:
        # 创建一级命名空间
        index['namespaces'][namespace] = {
            "owner_id": user_id,
            "owner_email": user_email,
            "created_at": datetime.utcnow().isoformat() + "Z",
            "sub_namespaces": []
        }

    # 检查二级命名空间
    if sub_namespace:
        full_namespace = f"{namespace}/{sub_namespace}"
        if full_namespace in index['namespaces']:
            existing = index['namespaces'][full_namespace]
            if existing['owner_id'] != user_id:
                return jsonify({"error": f"命名空间 '{full_namespace}' 已被其他用户占用"}), 403
        else:
            # 创建二级命名空间
            index['namespaces'][full_namespace] = {
                "owner_id": user_id,
                "created_at": datetime.utcnow().isoformat() + "Z"
            }
            # 更新一级命名空间的子列表
            if sub_namespace not in index['namespaces'][namespace]['sub_namespaces']:
                index['namespaces'][namespace]['sub_namespaces'].append(sub_namespace)

    # 保存索引
    _save_index(index)

    result_namespace = f"{namespace}/{sub_namespace}" if sub_namespace else namespace
    return jsonify({
        "message": "命名空间创建成功",
        "namespace": result_namespace,
        "owner_id": user_id
    })


@app.route('/publish', methods=['POST'])
@require_auth
def publish():
    """
    发布包到 Registry
    POST /publish
    Body: {
      "json_content": {...},  # 完整的 JSON-DSL 配置
      "force_update": false   # 是否强制更新
    }
    """
    body = request.get_json(silent=True) or {}
    json_content = body.get('json_content')
    force_update = body.get('force_update', False)

    if not json_content:
        return jsonify({"error": "缺少 json_content"}), 400

    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "无效的 JSON"}), 400

    # 解析包信息
    meta = json_content.get('meta', {})
    name = meta.get('name', '').strip()
    version = meta.get('version', '').strip()
    package_type = meta.get('type', 'library')

    if not name or not version:
        return jsonify({"error": "meta.name 和 meta.version 不能为空"}), 400

    # 验证包名格式
    valid, error_msg = _validate_package_name(name)
    if not valid:
        return jsonify({"error": error_msg}), 400

    # 验证版本号格式
    if not _validate_version(version):
        return jsonify({"error": "版本号格式不正确（必须是 x.y.z 格式）"}), 400

    # 权限检查
    user = request.supabase_user
    user_id = user.get('id')
    user_role = request.user_role

    slash_count = name.count('/')

    # 官方包（无 /）只有 admin 可以发布
    if slash_count == 0:
        if user_role != 'admin':
            return jsonify({"error": "只有管理员可以发布官方包（无命名空间的包）"}), 403
    else:
        # 用户包，检查命名空间所有权
        index = _load_index()

        # 提取一级或二级命名空间
        parts = name.split('/')
        if slash_count == 1:
            namespace = parts[0]
        else:  # slash_count == 2
            namespace = f"{parts[0]}/{parts[1]}"

        # 检查命名空间是否存在且属于该用户
        if namespace not in index['namespaces']:
            return jsonify({
                "error": f"命名空间 '{namespace}' 不存在，请先调用 /namespace/create 创建"
            }), 403

        ns_info = index['namespaces'][namespace]
        if ns_info['owner_id'] != user_id:
            return jsonify({"error": f"命名空间 '{namespace}' 不属于你"}), 403

    # 加载索引
    index = _load_index()

    # 检查包是否已存在
    if name in index['packages']:
        existing = index['packages'][name]
        if version in existing['versions']:
            if not force_update:
                return jsonify({
                    "error": f"版本 {version} 已存在",
                    "existing_versions": existing['versions']
                }), 409
            # force_update=true，允许覆盖

    # 构造存储路径
    path = name  # 如 common-ui 或 mycompany/frontend/ui-kit
    filename = f"{name.split('/')[-1]}-{version}.json"
    oss_key = f"{path}/{filename}"

    # 上传到 MinIO
    try:
        data_bytes = json.dumps(json_content, ensure_ascii=False, indent=2).encode('utf-8')
        minio_client.put_object(
            BUCKET_COMPONENT,
            oss_key,
            io.BytesIO(data_bytes),
            len(data_bytes),
            content_type="application/json",
        )
    except Exception as e:
        return jsonify({"error": f"上传失败: {str(e)}"}), 502

    # 更新索引
    if name not in index['packages']:
        index['packages'][name] = {
            "type": "official" if slash_count == 0 else "user",
            "latest": version,
            "versions": [version],
            "path": path,
            "author_id": user_id,
            "created_at": datetime.utcnow().isoformat() + "Z"
        }
    else:
        pkg = index['packages'][name]
        if version not in pkg['versions']:
            pkg['versions'].append(version)
        # 更新 latest（选择最新版本）
        pkg['versions'].sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
        pkg['latest'] = pkg['versions'][0]

    # 保存索引
    _save_index(index)

    download_url = f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{oss_key}"

    return jsonify({
        "message": "发布成功",
        "name": name,
        "version": version,
        "download_url": download_url
    })


# ═══════════════════════════════════════════════════════════
# 启动服务
# ═══════════════════════════════════════════════════════════

if __name__ == '__main__':
    print(f"[Registry] 启动 JSON-DSL Registry 服务，端口 {PORT}")
    print(f"[Registry] MinIO: {MINIO_ENDPOINT}")
    print(f"[Registry] Bucket: {BUCKET_COMPONENT}")
    app.run(host='0.0.0.0', port=PORT, debug=False)
