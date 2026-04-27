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

from config import (
    SUPABASE_URL, SUPABASE_ANON_KEY,
    MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_PUBLIC_URL, MINIO_SECURE
)
from database import (
    create_namespace, get_namespace_by_name, get_user_namespaces,
    add_namespace_member, remove_namespace_member, get_namespace_members,
    check_namespace_permission, update_namespace_member_role
)

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
    secure=MINIO_SECURE,
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


def _validate_namespace_name(name):
    """
    验证命名空间名称格式
    - 只允许小写字母、数字、- 和 _
    - 不能包含 / 和中文
    - 必须以字母或数字开头
    """
    if not name:
        return False, "命名空间名称不能为空"

    # 检查是否包含斜杠
    if '/' in name:
        return False, "命名空间名称不能包含 /"

    # 检查是否包含中文或其他非法字符
    pattern = re.compile(r'^[a-z0-9][a-z0-9-_]*$')
    if not pattern.match(name):
        return False, "命名空间名称格式不正确（只能包含小写字母、数字、- 和 _，且必须以字母或数字开头）"

    return True, ""


def _validate_package_name(name):
    """
    验证包名格式
    - 官方包: common-ui, data-utils (无 /)
    - 用户包: mycompany/app-name (只有一级 /)
    """
    if not name:
        return False, "包名不能为空"

    # 检查斜杠数量（只允许一级命名空间）
    slash_count = name.count('/')
    if slash_count > 1:
        return False, "包名只支持一级命名空间（如 mycompany/app-name）"

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


@app.route('/packages', methods=['GET'])
def list_packages():
    """
    列出所有可用的包
    GET /packages?type=app  # 可选：过滤类型（app/library）
    """
    filter_type = request.args.get('type', '').strip()

    # 加载索引
    index = _load_index()

    packages = []
    for name, info in index['packages'].items():
        # 获取最新版本的元数据
        latest_version = info.get('latest', info['versions'][0] if info['versions'] else '1.0.0')
        path = info['path']
        filename = f"{name.split('/')[-1]}-{latest_version}.json"
        download_url = f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{path}/{filename}"

        # 尝试从 MinIO 读取完整的包信息（包含 description 等）
        description = ''
        author = ''
        package_type = info.get('type', 'library')

        try:
            oss_key = f"{path}/{filename}"
            response = minio_client.get_object(BUCKET_COMPONENT, oss_key)
            content = json.loads(response.read().decode('utf-8'))
            meta = content.get('meta', {})
            description = meta.get('description', '')
            author = meta.get('author', '')
            package_type = meta.get('type', 'library')
        except Exception:
            pass

        # 类型过滤
        if filter_type and package_type != filter_type:
            continue

        packages.append({
            "name": name,
            "version": latest_version,
            "description": description,
            "author": author,
            "type": package_type,
            "download_url": download_url,
            "created_at": info.get('created_at'),
            "registry_type": info.get('type', 'user')  # official/user
        })

    return jsonify({
        "packages": packages,
        "total": len(packages)
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


@app.route('/my-namespaces', methods=['GET'])
@require_auth
def my_namespaces():
    """
    获取当前用户拥有的所有命名空间（从数据库读取）
    GET /my-namespaces
    """
    user = request.supabase_user
    user_id = user.get('id')

    try:
        namespaces = get_user_namespaces(user_id)
        result = []
        for ns in namespaces:
            result.append({
                "id": ns['id'],
                "name": ns['name'],
                "description": ns.get('description', ''),
                "role": ns['role'],
                "created_at": ns.get('created_at', '')
            })
        return jsonify({"namespaces": result})
    except Exception as e:
        print(f"[Registry] Error fetching namespaces: {e}")
        return jsonify({"error": "获取命名空间失败"}), 500


@app.route('/namespace/check', methods=['GET'])
def check_namespace():
    """
    检查命名空间是否可用（从数据库检查）
    GET /namespace/check?name=mycompany
    """
    name = request.args.get('name', '').strip()

    if not name:
        return jsonify({"error": "缺少 name 参数"}), 400

    # 验证格式
    valid, error_msg = _validate_namespace_name(name)
    if not valid:
        return jsonify({"error": error_msg}), 400

    # 检查是否已存在
    try:
        existing = get_namespace_by_name(name)
        exists = existing is not None
        return jsonify({
            "name": name,
            "available": not exists,
            "exists": exists
        })
    except Exception as e:
        print(f"[Registry] Error checking namespace: {e}")
        return jsonify({"error": "检查命名空间失败"}), 500


@app.route('/namespace/create', methods=['POST'])
@require_auth
def create_namespace_route():
    """
    创建命名空间（写入数据库）
    POST /namespace/create
    Body: {
      "namespace": "mycompany",
      "description": "My Company"  # 可选
    }
    """
    body = request.get_json(silent=True) or {}
    namespace = body.get('namespace', '').strip()
    description = body.get('description', '').strip()

    if not namespace:
        return jsonify({"error": "缺少 namespace 参数"}), 400

    # 验证格式
    valid, error_msg = _validate_namespace_name(namespace)
    if not valid:
        return jsonify({"error": error_msg}), 400

    user = request.supabase_user
    user_id = user.get('id')

    try:
        # 检查命名空间是否已存在
        existing = get_namespace_by_name(namespace)
        if existing:
            return jsonify({"error": f"命名空间 '{namespace}' 已被占用"}), 403

        # 创建命名空间
        namespace_id = create_namespace(namespace, description, user_id)
        if not namespace_id:
            return jsonify({"error": "创建命名空间失败"}), 500

        # 添加创建者为 owner
        add_namespace_member(namespace_id, user_id, 'owner', user_id)

        return jsonify({
            "message": "命名空间创建成功",
            "id": namespace_id,
            "namespace": namespace,
            "owner_id": user_id
        })
    except Exception as e:
        print(f"[Registry] Error creating namespace: {e}")
        return jsonify({"error": "创建命名空间失败"}), 500


@app.route('/package/<path:name>', methods=['DELETE'])
@require_auth
def delete_package(name):
    """
    删除包（仅管理员）
    DELETE /package/common-ui
    DELETE /package/mycompany/frontend/ui-kit
    """
    # 1. 权限检查：只有 admin 可以删除
    if request.user_role != 'admin':
        return jsonify({"error": "只有管理员可以删除包"}), 403

    # 2. 加载索引，检查包是否存在
    index = _load_index()
    if name not in index['packages']:
        return jsonify({"error": f"包 '{name}' 不存在"}), 404

    package_info = index['packages'][name]

    # 3. 从 MinIO 删除所有版本的文件
    path = package_info['path']
    deleted_files = []
    for version in package_info['versions']:
        filename = f"{name.split('/')[-1]}-{version}.json"
        oss_key = f"{path}/{filename}"
        try:
            minio_client.remove_object(BUCKET_COMPONENT, oss_key)
            deleted_files.append(oss_key)
            print(f"[Registry] 已删除文件: {oss_key}")
        except Exception as e:
            print(f"[Registry] 删除文件失败: {oss_key}, {e}")

    # 4. 从索引中删除包信息
    del index['packages'][name]
    _save_index(index)

    print(f"[Registry] 包 '{name}' 已从索引中删除")

    return jsonify({
        "message": "包已永久删除",
        "name": name,
        "deleted_versions": package_info['versions'],
        "deleted_files": deleted_files
    })


@app.route('/publish', methods=['POST'])
@require_auth
def publish():
    """
    发布包到 Registry（v2 — 弹窗驱动）
    POST /publish
    Body: {
      "json_content": {...},      // 完整 JSON-DSL 内容
      "namespace": "mycompany",   // 用户选择的命名空间（admin 官方包可为空）
      "name": "my-cool-app",      // 用户确认的包名
      "appid": "08ad186c-...",    // 用户确认的 UUID
      "version": "1.0.0",         // 用户确认的版本号
      "description": "...",       // 描述
      "type": "app"               // app 或 library
    }
    """
    body = request.get_json(silent=True) or {}
    json_content = body.get('json_content')

    if not json_content:
        return jsonify({"error": "缺少 json_content"}), 400

    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "无效的 JSON"}), 400

    # ── 从请求体顶层获取用户确认的 meta 信息 ──
    namespace = body.get('namespace', '').strip()
    pkg_name = body.get('name', '').strip()
    appid = body.get('appid', '').strip()
    version = body.get('version', '').strip()
    description = body.get('description', '').strip()
    package_type = body.get('type', 'app').strip()

    # 兼容旧客户端：如果顶层没传，就从 json_content 里取
    if not pkg_name:
        pkg_name = json_content.get('meta', {}).get('name', '').strip()
    if not version:
        version = json_content.get('meta', {}).get('version', '').strip()
    if not appid:
        appid = json_content.get('appid', '').strip()
    if not description:
        description = json_content.get('meta', {}).get('description', '').strip()

    # ── 基础格式校验 ──
    if not pkg_name:
        return jsonify({"error": "包名不能为空"}), 400
    if not version:
        return jsonify({"error": "版本号不能为空"}), 400
    if not appid:
        return jsonify({"error": "appid 不能为空"}), 400

    uuid_pattern = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
    if not uuid_pattern.match(appid):
        return jsonify({"error": "appid 格式必须是标准 UUID（带连字符）"}), 400

    if not _validate_version(version):
        return jsonify({"error": "版本号格式不正确（必须是 x.y.z 格式）"}), 400

    # ── 确定完整包名 (full_name) ──
    user = request.supabase_user
    user_id = user.get('id')
    user_role = request.user_role

    if namespace:
        # 用户包：full_name = namespace/pkg_name
        full_name = f"{namespace}/{pkg_name}"
    else:
        # 官方包（无命名空间）
        if user_role != 'admin':
            return jsonify({"error": "普通用户必须选择命名空间"}), 403
        full_name = pkg_name

    # 验证 full_name 格式
    valid, error_msg = _validate_package_name(full_name)
    if not valid:
        return jsonify({"error": error_msg}), 400

    # ── 命名空间权限校验 ──
    index = _load_index()

    if namespace:
        if namespace not in index.get('namespaces', {}):
            return jsonify({"error": f"命名空间 '{namespace}' 不存在，请先创建"}), 403
        ns_info = index['namespaces'][namespace]
        if ns_info.get('owner_id') != user_id:
            return jsonify({"error": f"命名空间 '{namespace}' 不属于你"}), 403

    # ── ★ UUID 交叉检测 ──
    for existing_name, existing_pkg in index.get('packages', {}).items():
        existing_appid = existing_pkg.get('appid', '')
        if existing_appid == appid:
            if existing_name == full_name:
                # 情况 B：同一个包，同一个 appid → 更新操作
                break
            else:
                # 情况 A：appid 被其他包占用 → 拦截
                return jsonify({
                    "error": "UUID 已被其他包使用，请点击「随机生成」获取新的 UUID",
                    "uuid_conflict": True,
                    "conflicting_package": existing_name
                }), 409

    # ── 版本号校验 ──
    if full_name in index.get('packages', {}):
        existing_pkg = index['packages'][full_name]
        existing_versions = existing_pkg.get('versions', [])

        if version in existing_versions:
            return jsonify({
                "error": f"版本 {version} 已存在，版本号不能重复",
                "existing_versions": existing_versions
            }), 409

        # 检查版本号是否递增
        latest = existing_pkg.get('latest', '0.0.0')
        def _parse_ver(v):
            return tuple(int(p) for p in v.split('.'))
        if _parse_ver(version) <= _parse_ver(latest):
            return jsonify({
                "error": f"版本号必须大于当前最新版本 {latest}",
                "latest_version": latest
            }), 409

    # ── 将用户确认的 meta 写回 json_content ──
    if 'meta' not in json_content:
        json_content['meta'] = {}
    json_content['meta']['name'] = full_name
    json_content['meta']['version'] = version
    json_content['meta']['description'] = description
    json_content['meta']['type'] = package_type
    json_content['appid'] = appid

    # ── 上传到 MinIO ──
    path = full_name
    filename = f"{full_name.split('/')[-1]}-{version}.json"
    oss_key = f"{path}/{filename}"

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

    # ── 更新索引 ──
    slash_count = full_name.count('/')
    if full_name not in index['packages']:
        index['packages'][full_name] = {
            "type": "official" if slash_count == 0 else "user",
            "latest": version,
            "versions": [version],
            "path": path,
            "author_id": user_id,
            "appid": appid,
            "created_at": datetime.utcnow().isoformat() + "Z"
        }
    else:
        pkg = index['packages'][full_name]
        if version not in pkg['versions']:
            pkg['versions'].append(version)
        pkg['versions'].sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
        pkg['latest'] = pkg['versions'][0]
        pkg['appid'] = appid  # 更新 appid（允许用户改 name 但保持 appid）

    _save_index(index)

    download_url = f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{oss_key}"

    return jsonify({
        "message": "发布成功",
        "name": full_name,
        "version": version,
        "appid": appid,
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
