#!/usr/bin/env python3
"""
JSON-DSL Registry Server
独立的包注册中心服务，负责依赖解析和命名空间管理

启动: python backend/registry_server.py
端口: 3254
域名: https://myapp-registry.dapangyu.work
"""

import io
import hashlib
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
    MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_PUBLIC_URL, MINIO_SECURE,
    REGISTRY_BASE_URL, REGISTRY_UPSTREAM, REGISTRY_MIRROR_SYNC_INTERVAL_SEC,
)
from database import (
    create_namespace, get_namespace_by_name, get_user_namespaces,
    add_namespace_member, remove_namespace_member, get_namespace_members,
    check_namespace_permission, update_namespace_member_role
)
from auth import find_user_by_email, find_user_by_phone
from registry_mirror import (
    index_lock, build_manifest, sync_once,
    proxy_fetch_and_cache, file_exists_in_minio,
    get_version_source, is_local_version,
    start_background_sync,
)
import registry_catalog
from validate_json_app import validate_json_content
from flask import redirect, Response

BUCKET_APP = "json-app"
BUCKET_COMPONENT = "json-component"
INDEX_FILE = "_index.json"

PORT = 3254

app = Flask(__name__)


@app.after_request
def add_cors_headers(response):
    response.headers.setdefault("Access-Control-Allow-Origin", "*")
    response.headers.setdefault(
        "Access-Control-Allow-Methods",
        "GET, POST, PUT, DELETE, OPTIONS",
    )
    response.headers.setdefault(
        "Access-Control-Allow-Headers",
        "Authorization, Content-Type, X-Requested-With",
    )
    response.headers.setdefault("Access-Control-Max-Age", "86400")
    return response

# MinIO 客户端
minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=MINIO_SECURE,
)


def _ensure_buckets():
    """确保 registry 用到的 MinIO 桶存在且 public-read（幂等）。

    全新 all-in-one 部署里这些桶从未被创建过（没人发布过组件），_save_index /
    mirror 同步首次写入时就会 NoSuchBucket，普通 publish 也一样会炸。registry
    必须保证自己的存储桶存在，并设 public-read（与既有 json-component/models
    约定一致），客户端才能凭 MINIO_PUBLIC_URL 直链下载包文件。
    """
    for bucket in (BUCKET_COMPONENT, BUCKET_APP):
        try:
            if not minio_client.bucket_exists(bucket):
                minio_client.make_bucket(bucket)
                print(f"[Registry] 建桶 {bucket}")
            policy = {
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"AWS": ["*"]},
                    "Action": ["s3:GetObject"],
                    "Resource": [f"arn:aws:s3:::{bucket}/*"],
                }],
            }
            minio_client.set_bucket_policy(bucket, json.dumps(policy))
        except Exception as e:  # 不让建桶失败拖垮启动；下次启动/发布会重试
            print(f"[Registry] WARN ensure bucket {bucket} 失败: {e}")

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

        # 管理员 token：从 .env 读 REGISTRY_ADMIN_TOKEN（不再用 hardcoded test-token）
        # 用于发布脚本 / migrate_templates 等 server-side 工具绕过 supabase 鉴权
        admin_token = os.environ.get("REGISTRY_ADMIN_TOKEN", "")
        if admin_token and token == admin_token:
            admin_author_email = os.environ.get(
                "REGISTRY_ADMIN_AUTHOR_EMAIL",
                "2501808198@qq.com",
            ).strip()
            admin_author_id = os.environ.get(
                "REGISTRY_ADMIN_AUTHOR_ID",
                admin_author_email,
            ).strip() or admin_author_email
            admin_author_name = os.environ.get(
                "REGISTRY_ADMIN_AUTHOR_NAME",
                admin_author_email,
            ).strip() or admin_author_email
            request.supabase_user = {
                "id": admin_author_id,
                "email": admin_author_email,
                "user_metadata": {
                    "username": admin_author_name,
                },
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


def _optional_bearer_user_id():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    token = auth[7:]

    admin_token = os.environ.get("REGISTRY_ADMIN_TOKEN", "")
    if admin_token and token == admin_token:
        return os.environ.get(
            "REGISTRY_ADMIN_AUTHOR_ID",
            os.environ.get("REGISTRY_ADMIN_AUTHOR_EMAIL", "admin"),
        ).strip() or "admin"

    try:
        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers=_supabase_headers(token),
            timeout=8,
        )
        if resp.status_code == 200:
            return resp.json().get("id")
    except Exception:
        pass
    return None


def _clean_install_actor_id(value):
    value = str(value or "").strip()
    if not value:
        return ""
    value = re.sub(r"[^a-zA-Z0-9_.:@-]", "_", value)
    return value[:160]


def _install_ip_hash():
    raw_ip = (
        request.headers.get("CF-Connecting-IP")
        or request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        or request.remote_addr
        or ""
    )
    if not raw_ip:
        return ""
    salt = os.environ.get("REGISTRY_INSTALL_IP_HASH_SALT", "myapp-registry-install")
    return hashlib.sha256(f"{salt}:{raw_ip}".encode("utf-8")).hexdigest()


# Registry 全局索引（_index.json）的 schema 版本。改索引结构时 bump（见
# docs/planning/version-management.md §3.6）；加载时 MAJOR 不符则告警，便于发现
# "新代码读旧索引 / 旧代码读新索引" 的不兼容。
INDEX_SCHEMA_VERSION = "1.0"


def _check_index_version(idx: dict) -> None:
    got = str((idx or {}).get("version") or "").strip()
    if not got:
        return
    if got.split(".")[0] != INDEX_SCHEMA_VERSION.split(".")[0]:
        print(
            f"[Registry] ⚠️ 索引 schema 版本不兼容：读到 {got!r}，本代码期望 "
            f"{INDEX_SCHEMA_VERSION!r}（MAJOR 不符）。请确认 registry 镜像与索引版本匹配。"
        )


def _load_index():
    """从 MinIO 加载全局索引文件"""
    try:
        response = minio_client.get_object(BUCKET_COMPONENT, INDEX_FILE)
        data = response.read()
        idx = json.loads(data.decode('utf-8'))
        _check_index_version(idx)
        return idx
    except Exception as e:
        # 索引文件不存在，返回空结构
        print(f"[Registry] 索引文件不存在或加载失败: {e}")
        return {
            "version": INDEX_SCHEMA_VERSION,
            "updated_at": datetime.utcnow().isoformat() + "Z",
            "packages": {},
            "namespaces": {}
        }


def _save_index(index_data):
    """保存全局索引文件到 MinIO。**只在 index_lock 内调用**"""
    index_data["updated_at"] = datetime.utcnow().isoformat() + "Z"
    data_bytes = json.dumps(index_data, ensure_ascii=False, indent=2).encode('utf-8')

    minio_client.put_object(
        BUCKET_COMPONENT,
        INDEX_FILE,
        io.BytesIO(data_bytes),
        len(data_bytes),
        content_type="application/json",
    )


def _download_url_for_version(name, version, package_info, path):
    """根据 version_sources 决定 download URL。
    本地版本：MinIO 直链（最快）；镜像版本：本地代理端点（按需缓存）"""
    filename = f"{name.split('/')[-1]}-{version}.json"
    if is_local_version(package_info, version):
        return f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{path}/{filename}"
    # 镜像版本走本地 /mirror/file，触发按需缓存
    return f"{REGISTRY_BASE_URL.rstrip('/')}/mirror/file/{name}/{version}"


def _resolve_appid_payload(appid):
    """按 appid 解析公开包。只读接口，用于 Web 分享链接直达 JSON-APP。"""
    appid = (appid or "").strip()
    uuid_pattern = re.compile(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )
    if not uuid_pattern.match(appid):
        return {"error": "appid 格式必须是标准 UUID（带连字符）"}, 400

    index = _load_index()
    for name, info in index.get('packages', {}).items():
        if str(info.get('appid', '')).lower() != appid.lower():
            continue

        versions = info.get('versions') or []
        version = info.get('latest') or (versions[0] if versions else None)
        if not version:
            return {"error": f"appid '{appid}' 对应的包没有可用版本"}, 404

        path = info.get('path') or name
        download_url = _download_url_for_version(name, version, info, path)
        return {
            "appid": info.get('appid') or appid,
            "name": name,
            "version": version,
            "download_url": download_url,
            "displayName": info.get('displayName') or info.get('display_name'),
            "description": info.get('description', ''),
            "author": info.get('author', ''),
            "type": info.get('meta_type', 'app'),
            "registry_type": info.get('type', 'user'),
            "latest": info.get('latest'),
            "source": get_version_source(info, version),
        }, 200

    return {"error": f"appid '{appid}' 不存在"}, 404


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


def _parse_positive_int(value, default, *, min_value=1, max_value=None):
    try:
        n = int(value)
    except (TypeError, ValueError):
        n = default
    n = max(min_value, n)
    if max_value is not None:
        n = min(max_value, n)
    return n


def _normalize_search_text(value):
    if value is None:
        return ""
    if isinstance(value, dict):
        return " ".join(_normalize_search_text(v) for v in value.values())
    if isinstance(value, (list, tuple)):
        return " ".join(_normalize_search_text(v) for v in value)
    return str(value).lower()


def _package_matches_query(pkg, query):
    if not query:
        return True
    haystack = " ".join(
        _normalize_search_text(pkg.get(k))
        for k in ("name", "displayName", "description", "author", "type")
    )
    return query in haystack


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
    appid = request.args.get('appid', '').strip() or request.args.get('app_id', '').strip()
    version_constraint = request.args.get('version', '*').strip()

    if appid and not name:
        payload, status = _resolve_appid_payload(appid)
        return jsonify(payload), status

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

    # 构造下载 URL（local vs mirrored 走不同路径）
    path = package_info['path']
    download_url = _download_url_for_version(name, best_version, package_info, path)

    return jsonify({
        "name": name,
        "version": best_version,
        "download_url": download_url,
        "appid": package_info.get('appid'),
        "type": package_info.get('type', 'user'),
        "latest": package_info.get('latest'),
        "source": get_version_source(package_info, best_version),
    })


@app.route('/resolve_appid', methods=['GET'])
def resolve_appid():
    """
    按 appid 解析公开 JSON-APP。
    GET /resolve_appid?appid=08ad186c-...
    """
    appid = request.args.get('appid', '').strip() or request.args.get('app_id', '').strip()
    payload, status = _resolve_appid_payload(appid)
    return jsonify(payload), status


@app.route('/packages', methods=['GET'])
def list_packages():
    """
    列出所有可用的包
    GET /packages?type=app&page=1&per_page=20&q=chat&namespace=/
    """
    filter_type = request.args.get('type', '').strip()
    query = (request.args.get('q') or request.args.get('search') or '').strip().lower()
    namespace_arg = request.args.get('namespace')
    namespace = namespace_arg.strip() if namespace_arg is not None else None
    page = _parse_positive_int(request.args.get('page'), 1)
    per_page = _parse_positive_int(request.args.get('per_page'), 20, max_value=100)

    # 加载索引
    index = _load_index()

    packages = []
    for name, info in index['packages'].items():
        if namespace is not None:
            if namespace in ('', '/', '_official_'):
                if '/' in name:
                    continue
            elif not name.startswith(f"{namespace}/"):
                continue

        # 获取最新版本的元数据
        latest_version = info.get('latest', info['versions'][0] if info['versions'] else '1.0.0')
        path = info['path']
        filename = f"{name.split('/')[-1]}-{latest_version}.json"
        download_url = _download_url_for_version(name, latest_version, info, path)

        # 拿 meta（type/description/author）顺序：
        # 1. index 里有 meta_type 直接用（publish 时存的 / mirror sync 拷来的）
        # 2. 否则去 MinIO 读文件（local 版本必有；mirror 版本只在缓存命中时才能读到）
        # 3. 读不到就默认 library
        meta_type = info.get('meta_type')
        description = info.get('description', '')
        author = info.get('author', '')
        display_name = info.get('displayName') or info.get('display_name')

        if (meta_type is None or display_name is None) and (is_local_version(info, latest_version) or file_exists_in_minio(
            minio_client, BUCKET_COMPONENT, f"{path}/{filename}"
        )):
            try:
                response = minio_client.get_object(BUCKET_COMPONENT, f"{path}/{filename}")
                content = json.loads(response.read().decode('utf-8'))
                meta = content.get('meta', {})
                meta_type = meta.get('type', 'library')
                description = description or meta.get('description', '')
                author = author or meta.get('author', '')
                display_name = display_name if display_name is not None else meta.get('displayName')
            except Exception:
                pass

        package_type = meta_type or 'library'

        # 类型过滤
        if filter_type and package_type != filter_type:
            continue

        pkg = {
            "name": name,
            "version": latest_version,
            "appid": info.get('appid'),
            "displayName": display_name,
            "description": description,
            "author": author,
            "type": package_type,
            "download_url": download_url,
            "created_at": info.get('created_at'),
            "registry_type": info.get('type', 'user'),  # official/user
            "source": get_version_source(info, latest_version),
        }
        if not _package_matches_query(pkg, query):
            continue
        packages.append(pkg)

    packages.sort(key=lambda p: (p.get("created_at") or ""), reverse=True)
    total = len(packages)
    start = (page - 1) * per_page
    end = start + per_page
    paged = packages[start:end]

    return jsonify({
        "packages": paged,
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if total else 0,
        "has_more": end < total,
        "q": query,
        "namespace": namespace,
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


@app.route('/namespaces', methods=['GET'])
def list_public_namespaces():
    """
    列出探索页可切换的公开空间（从包索引归纳）。
    GET /namespaces?q=gsy
    """
    query = (request.args.get('q') or request.args.get('search') or '').strip().lower()
    index = _load_index()
    buckets = {
        '/': {
            'name': '/',
            'display_name': 'Official',
            'package_count': 0,
            'latest_created_at': '',
        }
    }

    for name, info in (index.get('packages') or {}).items():
        namespace = name.split('/', 1)[0] if '/' in name else '/'
        bucket = buckets.setdefault(namespace, {
            'name': namespace,
            'display_name': namespace,
            'package_count': 0,
            'latest_created_at': '',
        })
        bucket['package_count'] += 1
        created_at = info.get('created_at') or ''
        if created_at > (bucket.get('latest_created_at') or ''):
            bucket['latest_created_at'] = created_at

    namespaces = list(buckets.values())
    if query:
        namespaces = [
            ns for ns in namespaces
            if query in ns['name'].lower()
            or query in ns.get('display_name', '').lower()
        ]

    namespaces.sort(
        key=lambda ns: (
            0 if ns['name'] == '/' else 1,
            -(ns.get('package_count') or 0),
            ns['name'],
        )
    )
    return jsonify({"namespaces": namespaces, "total": len(namespaces), "q": query})


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

    # 2-4. 索引读+改+写 + MinIO 文件清理，整段需要在锁内（同 publish）
    with index_lock:
        index = _load_index()
        if name not in index['packages']:
            return jsonify({"error": f"包 '{name}' 不存在"}), 404

        package_info = index['packages'][name]

        # 3. 从 MinIO 删除所有版本的文件（含 mirror 缓存到本地的文件）
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
    package_type = body.get('type', '').strip()

    # 兼容旧客户端：如果顶层没传，就从 json_content 里取
    if not pkg_name:
        pkg_name = json_content.get('meta', {}).get('name', '').strip()
    if not version:
        version = json_content.get('meta', {}).get('version', '').strip()
    if not appid:
        appid = json_content.get('appid', '').strip()
    if not description:
        description = json_content.get('meta', {}).get('description', '').strip()
    if not package_type:
        package_type = json_content.get('meta', {}).get('type', 'app').strip()

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
    # 作者展示名：优先 username，退到 email 前缀
    author_name = (user.get('user_metadata', {}) or {}).get('username') \
        or (user.get('email') or '').split('@')[0] or None

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

    # ── 命名空间权限校验（从数据库检查）──
    if namespace:
        try:
            has_permission, role = check_namespace_permission(namespace, user_id)
            if not has_permission:
                return jsonify({"error": f"命名空间 '{namespace}' 不存在或你没有发布权限"}), 403
            print(f"[Registry] User {user_id} has {role} permission for namespace {namespace}")
        except Exception as e:
            print(f"[Registry] Error checking namespace permission: {e}")
            return jsonify({"error": "权限检查失败"}), 500

    validation_warnings = []

    # ── 索引读+改+写 必须在同一把 index_lock 内，否则会和 mirror sync 抢写 ──
    with index_lock:
        index = _load_index()

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
                src = get_version_source(existing_pkg, version)
                if src != "local":
                    return jsonify({
                        "error": f"版本 {version} 已被上游 mirror 占用（来源 {src}），请用更高的版本号",
                        "existing_versions": existing_versions,
                        "version_source": src,
                    }), 409
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
        json_content['meta']['author'] = author_name or json_content['meta'].get('author', '')
        json_content['appid'] = appid
        display_name = json_content['meta'].get('displayName')

        # ── JSON-DSL 静态发布门禁 ──
        # Agent 生成提示词会要求上传前本地跑 validate_json_app.py，但客户端/脚本/旧
        # Agent 都可能绕过。Registry 是最后一道门：ERROR 级问题直接拒绝发布，
        # WARN 随响应返回但不阻塞。
        findings = validate_json_content(json_content)
        validation_errors = [f for f in findings if f.level == "ERROR"]
        validation_warnings = [f for f in findings if f.level == "WARN"]
        if validation_errors:
            return jsonify({
                "error": "JSON-APP 静态校验失败，请修复后再发布",
                "validation_errors": [
                    {"path": f.path, "message": f.message}
                    for f in validation_errors[:50]
                ],
                "validation_warnings": [
                    {"path": f.path, "message": f.message}
                    for f in validation_warnings[:50]
                ],
            }), 400

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
                "created_at": datetime.utcnow().isoformat() + "Z",
                "version_sources": {version: "local"},
                # 存 latest 视角的 meta，避免 /packages?type 还要去读文件
                "meta_type": package_type,
                "description": description,
                "author": author_name,
                "displayName": display_name,
            }
        else:
            pkg = index['packages'][full_name]
            if version not in pkg['versions']:
                pkg['versions'].append(version)
            pkg['versions'].sort(key=lambda v: tuple(int(p) for p in v.split('.')), reverse=True)
            pkg['latest'] = pkg['versions'][0]
            pkg['appid'] = appid  # 更新 appid（允许用户改 name 但保持 appid）
            # 新版本一定是本地发的（已经通过上面的同号检查）
            pkg.setdefault("version_sources", {})[version] = "local"
            # 如果这次 publish 的就是 latest，刷新 meta
            if version == pkg['latest']:
                pkg["meta_type"] = package_type
                pkg["description"] = description
                pkg["author"] = author_name
                pkg["displayName"] = display_name

        _save_index(index)

    # ── 附加：捕获结构化元数据进 registry_packages（不影响上面的 _index.json 发布流程）──
    # 解析失败/DB 不可用都吞掉，绝不让富化拖累发布主流程。enrich（LLM summary）由后台
    # worker 异步补，这里只 capture + 标 pending
    try:
        capture = registry_catalog.parse_capture(json_content)
        registry_catalog.upsert_capture(
            full_name, capture,
            author_id=user_id,
            author_name=author_name,
        )
    except Exception as e:
        print(f"[Registry] capture 失败（忽略，不影响发布）: {full_name}: {e}")

    download_url = f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{oss_key}"

    return jsonify({
        "message": "发布成功",
        "name": full_name,
        "version": version,
        "appid": appid,
        "download_url": download_url,
        "validation_warnings": [
            {"path": f.path, "message": f.message}
            for f in validation_warnings[:50]
        ],
    })


# ═══════════════════════════════════════════════════════════
# 命名空间成员管理 API
# ═══════════════════════════════════════════════════════════

@app.route('/namespace/<namespace_id>/members', methods=['GET'])
@require_auth
def get_members(namespace_id):
    """
    获取命名空间的所有成员
    GET /namespace/{namespace_id}/members
    """
    try:
        members = get_namespace_members(namespace_id)
        return jsonify({"members": members})
    except Exception as e:
        print(f"[Registry] Error fetching members: {e}")
        return jsonify({"error": "获取成员列表失败"}), 500


@app.route('/namespace/<namespace_id>/members', methods=['POST'])
@require_auth
def add_member(namespace_id):
    """
    添加命名空间成员（仅 owner 可操作）
    POST /namespace/{namespace_id}/members
    Body: {
      "email": "user@example.com",  # 邮箱（二选一）
      "phone": "+86 138xxxx",       # 手机号（二选一，预留）
      "role": "admin"               # owner 或 admin
    }
    """
    body = request.get_json(silent=True) or {}
    email = body.get('email', '').strip()
    phone = body.get('phone', '').strip()
    role = body.get('role', 'admin').strip()

    # 必须提供邮箱或手机号之一
    if not email and not phone:
        return jsonify({"error": "必须提供邮箱或手机号"}), 400

    if role not in ('owner', 'admin'):
        return jsonify({"error": "角色必须是 owner 或 admin"}), 400

    user = request.supabase_user
    current_user_id = user.get('id')

    try:
        # 检查当前用户是否是 owner
        members = get_namespace_members(namespace_id)
        is_owner = any(m['user_id'] == current_user_id and m['role'] == 'owner' for m in members)

        if not is_owner:
            return jsonify({"error": "只有 owner 可以添加成员"}), 403

        # 通过邮箱或手机号查找用户 ID
        target_user_id = None
        if email:
            target_user_id = find_user_by_email(email)
            if not target_user_id:
                return jsonify({"error": f"未找到邮箱为 {email} 的用户"}), 404
        elif phone:
            target_user_id = find_user_by_phone(phone)
            if not target_user_id:
                return jsonify({"error": f"未找到手机号为 {phone} 的用户"}), 404

        # 检查用户是否已经是成员
        is_member = any(m['user_id'] == target_user_id for m in members)
        if is_member:
            return jsonify({"error": "该用户已经是成员"}), 409

        # 添加成员
        add_namespace_member(namespace_id, target_user_id, role, current_user_id)

        return jsonify({
            "message": "成员已添加",
            "user_id": target_user_id,
            "role": role
        })

    except Exception as e:
        print(f"[Registry] Error adding member: {e}")
        return jsonify({"error": "添加成员失败"}), 500


@app.route('/namespace/<namespace_id>/members/<user_id>', methods=['DELETE'])
@require_auth
def remove_member(namespace_id, user_id):
    """
    移除命名空间成员（仅 owner 可操作）
    DELETE /namespace/{namespace_id}/members/{user_id}
    """
    current_user = request.supabase_user
    current_user_id = current_user.get('id')

    try:
        # 检查当前用户是否是 owner
        members = get_namespace_members(namespace_id)
        is_owner = any(m['user_id'] == current_user_id and m['role'] == 'owner' for m in members)

        if not is_owner:
            return jsonify({"error": "只有 owner 可以移除成员"}), 403

        # 不能移除自己
        if user_id == current_user_id:
            return jsonify({"error": "不能移除自己"}), 400

        remove_namespace_member(namespace_id, user_id)
        return jsonify({"message": "成员已移除"})

    except Exception as e:
        print(f"[Registry] Error removing member: {e}")
        return jsonify({"error": "移除成员失败"}), 500


@app.route('/namespace/<namespace_id>/members/<user_id>', methods=['PUT'])
@require_auth
def update_member_role(namespace_id, user_id):
    """
    更新命名空间成员角色（仅 owner 可操作）
    PUT /namespace/{namespace_id}/members/{user_id}
    Body: {
      "role": "admin"  # owner 或 admin
    }
    """
    body = request.get_json(silent=True) or {}
    new_role = body.get('role', '').strip()

    if new_role not in ('owner', 'admin'):
        return jsonify({"error": "角色必须是 owner 或 admin"}), 400

    current_user = request.supabase_user
    current_user_id = current_user.get('id')

    try:
        # 检查当前用户是否是 owner
        members = get_namespace_members(namespace_id)
        is_owner = any(m['user_id'] == current_user_id and m['role'] == 'owner' for m in members)

        if not is_owner:
            return jsonify({"error": "只有 owner 可以更新成员角色"}), 403

        update_namespace_member_role(namespace_id, user_id, new_role)
        return jsonify({"message": "角色已更新", "role": new_role})

    except Exception as e:
        print(f"[Registry] Error updating member role: {e}")
        return jsonify({"error": "更新角色失败"}), 500


# ═══════════════════════════════════════════════════════════
# Mirror API —— 上游曝露给下游同步的接口
# ═══════════════════════════════════════════════════════════

@app.route('/mirror/manifest', methods=['GET'])
def mirror_manifest():
    """对外的 mirror 清单。公开访问，无 token。
    URL 全指向 REGISTRY_BASE_URL（自己），下游 mirror 我时 source 永远是我，
    chain mirror 自然成立。带富化数据（summary/tags/tech_stack），下游直接拷不重跑 LLM。"""
    with index_lock:
        index = _load_index()
    # catalog 富化数据从 registry_packages 取，拼进 manifest 让下游免 LLM 拷过去
    try:
        catalog = registry_catalog.catalog_map()
    except Exception as e:
        print(f"[Registry] catalog_map 失败（manifest 不带富化）: {e}")
        catalog = {}
    return jsonify(build_manifest(index, REGISTRY_BASE_URL, minio_client, BUCKET_COMPONENT, catalog))


@app.route('/catalog', methods=['GET'])
def catalog():
    """富化目录 —— 给 AI 生成挑参考包用。每个包带 summary/tags/tech_stack/exports/deps。
    公开只读。可选 ?status=done 只看已富化的。"""
    only_done = request.args.get('status') == 'done'
    try:
        rows = registry_catalog.get_catalog()
    except Exception as e:
        return jsonify({"error": f"catalog 读取失败: {e}", "packages": []}), 500
    if only_done:
        rows = [r for r in rows if r.get('status') == 'done']
    return jsonify({"packages": rows, "total": len(rows)})


@app.route('/catalog/backfill', methods=['POST'])
@require_auth
def catalog_backfill():
    """给现有包补 capture（exports/deps/widgets/tech_stack）+ 标 pending，
    让 enrich worker 后续生成 summary。仅 admin。首次上线 / migration 后跑一次。"""
    if request.user_role != 'admin':
        return jsonify({"error": "只有管理员可以 backfill"}), 403

    with index_lock:
        index = _load_index()
    names = list((index.get("packages") or {}).keys())

    pkgs = index.get("packages") or {}
    captured, failed = 0, 0
    for name in names:
        try:
            content = _load_package_json(name)
            if not content:
                failed += 1
                continue
            cap = registry_catalog.parse_capture(content)
            # author_id 从 _index.json 取（历史归属）；author_name 后面刷作者时统一改
            author_id = (pkgs.get(name) or {}).get("author_id")
            registry_catalog.upsert_capture(name, cap, author_id=author_id)
            captured += 1
        except Exception as e:
            print(f"[Registry] backfill {name} 失败: {e}")
            failed += 1

    return jsonify({
        "message": "backfill 完成，enrich worker 会异步生成 summary",
        "total": len(names),
        "captured": captured,
        "failed": failed,
    })


@app.route('/admin/set_all_authors', methods=['POST'])
@require_auth
def admin_set_all_authors():
    """一次性把所有包作者刷成指定用户（修历史乱作者）。仅 admin。
    Body: {"author_id": "...", "author_name": "..."}"""
    if request.user_role != 'admin':
        return jsonify({"error": "只有管理员可以刷作者"}), 403
    body = request.get_json(silent=True) or {}
    author_id = (body.get("author_id") or "").strip()
    author_name = (body.get("author_name") or "").strip()
    if not author_id or not author_name:
        return jsonify({"error": "author_id 和 author_name 必填"}), 400
    n = registry_catalog.set_all_authors(author_id, author_name)
    return jsonify({"message": "已刷新所有包作者", "updated": n,
                    "author_id": author_id, "author_name": author_name})


@app.route('/packages/<path:name>/detail', methods=['GET'])
def package_detail(name):
    """app 详情：富化 + 作者(头像) + 点赞/下载量 + (登录则)我点没点。
    可选 ?viewer=<user_id> 传当前用户拿点赞态（或走 Authorization）。"""
    viewer = request.args.get('viewer')
    if not viewer:
        # 也支持从 Bearer token 解析（登录用户）
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            try:
                r = requests.get(f"{SUPABASE_URL}/auth/v1/user",
                                 headers=_supabase_headers(auth[7:]), timeout=8)
                if r.status_code == 200:
                    viewer = r.json().get("id")
            except Exception:
                pass
    detail = registry_catalog.get_app_detail(name, viewer)
    if not detail:
        return jsonify({"error": f"包 '{name}' 不存在"}), 404
    return jsonify(detail)


@app.route('/users/<author_id>/profile', methods=['GET'])
def user_profile(author_id):
    """用户主页：头像/名字 + 总下载/总点赞 + 他发布的 app 列表。公开只读。"""
    return jsonify(registry_catalog.get_user_profile(author_id))


@app.route('/packages/<path:name>/install', methods=['POST'])
def package_install(name):
    """运行/下载埋点。登录、游客和未登录 Web 都可记录；每次成功运行都计数。"""
    with index_lock:
        index = _load_index()
        if name not in index.get("packages", {}):
            return jsonify({"error": f"包 '{name}' 不存在"}), 404

    body = request.get_json(silent=True) or {}
    user_id = _optional_bearer_user_id()
    actor_type = "user" if user_id else "guest"
    actor_id = _clean_install_actor_id(user_id or body.get("client_user_id"))
    if not actor_id:
        actor_type = "anonymous"
        actor_id = f"anon:{_install_ip_hash()[:32] or 'unknown'}"
    source = _clean_install_actor_id(body.get("source") or request.args.get("source") or "")
    registry_catalog.record_install(
        name,
        actor_id,
        actor_type=actor_type,
        source=source,
        user_agent=request.headers.get("User-Agent", ""),
        ip_hash=_install_ip_hash(),
    )
    return jsonify({"ok": True})


@app.route('/packages/<path:name>/like', methods=['POST', 'DELETE'])
@require_auth
def package_like(name):
    """点赞 / 取消。"""
    registry_catalog.set_like(name, request.supabase_user.get("id"),
                              liked=(request.method == 'POST'))
    return jsonify({"ok": True, "liked": request.method == 'POST'})


@app.route('/mirror/file/<path:name>/<version>', methods=['GET'])
def mirror_file(name, version):
    """按需文件代理：本地有就 302 到本地 MinIO；没有就先去 source 拉、缓存、再 302。
    name 是包全名（含 namespace 斜杠），version 是 x.y.z。"""
    # 加载索引，确认包/版本存在
    with index_lock:
        index = _load_index()
        pkg = index.get('packages', {}).get(name)
    if not pkg:
        return jsonify({"error": f"包 '{name}' 不存在"}), 404
    if version not in pkg.get('versions', []):
        return jsonify({"error": f"包 '{name}' 没有版本 {version}"}), 404

    filename = f"{name.split('/')[-1]}-{version}.json"
    path = pkg.get('path', name)
    oss_key = f"{path}/{filename}"

    # 本地（或已缓存）→ 直接 302 到 MinIO 公开 URL（json-component 是 anonymous download）
    if file_exists_in_minio(minio_client, BUCKET_COMPONENT, oss_key):
        return redirect(f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{oss_key}", code=302)

    # 镜像版本未缓存 → 去 source 拉
    source = get_version_source(pkg, version)
    if source == "local":
        # 标记是 local 但 MinIO 里没文件？数据不一致，404 兜底
        return jsonify({"error": f"包 '{name}@{version}' 标记为本地但文件不存在"}), 404

    ok = proxy_fetch_and_cache(
        source, name, version,
        minio_client, BUCKET_COMPONENT, oss_key,
    )
    if not ok:
        return jsonify({"error": f"从上游 {source} 拉取失败"}), 502

    return redirect(f"{MINIO_PUBLIC_URL}/{BUCKET_COMPONENT}/{oss_key}", code=302)


@app.route('/mirror/sync', methods=['POST'])
@require_auth
def mirror_sync_trigger():
    """手动触发一次同步（仅 admin）"""
    if request.user_role != 'admin':
        return jsonify({"error": "只有管理员可以触发 mirror sync"}), 403
    if not REGISTRY_UPSTREAM:
        return jsonify({"error": "本实例未配置 REGISTRY_UPSTREAM"}), 400

    result = sync_once(
        REGISTRY_UPSTREAM, minio_client, BUCKET_COMPONENT,
        _load_index, _save_index,
    )
    if result is None:
        return jsonify({"error": "sync 失败，看 server 日志"}), 502
    added, replaced = result
    return jsonify({
        "message": "sync 完成",
        "upstream": REGISTRY_UPSTREAM,
        "added": added,
        "replaced": replaced,
    })


# ═══════════════════════════════════════════════════════════
# 启动服务
# ═══════════════════════════════════════════════════════════

def _maybe_start_mirror_sync():
    """如果配了 REGISTRY_UPSTREAM 就起后台同步线程"""
    if not REGISTRY_UPSTREAM:
        print("[Registry] REGISTRY_UPSTREAM 未配置，跳过 mirror 同步")
        return
    print(f"[Registry] Mirror 模式开启，上游 = {REGISTRY_UPSTREAM}, "
          f"间隔 = {REGISTRY_MIRROR_SYNC_INTERVAL_SEC}s")
    start_background_sync(
        REGISTRY_UPSTREAM, REGISTRY_MIRROR_SYNC_INTERVAL_SEC,
        minio_client, BUCKET_COMPONENT,
        _load_index, _save_index,
    )


def _load_package_json(name: str):
    """给 enrich worker 用：按包名从 MinIO 读 latest 版本的完整 JSON。
    路径靠 _index.json 解析（_index.json 仍是解析索引的权威）。读不到返 None。"""
    with index_lock:
        index = _load_index()
        pkg = index.get("packages", {}).get(name)
    if not pkg:
        return None
    latest = pkg.get("latest") or (pkg.get("versions") or [None])[0]
    if not latest:
        return None
    path = pkg.get("path", name)
    filename = f"{name.split('/')[-1]}-{latest}.json"
    oss_key = f"{path}/{filename}"
    try:
        resp = minio_client.get_object(BUCKET_COMPONENT, oss_key)
        return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[Registry] _load_package_json 读 {oss_key} 失败: {e}")
        return None


def _maybe_start_enrich_worker():
    """起 AI summary 富化后台 worker（advisory lock 选主，只有一个 gunicorn worker 真跑）"""
    import os
    if not os.environ.get("BACKEND_INTERNAL_URL"):
        print("[Registry] BACKEND_INTERNAL_URL 未配置，跳过 enrich worker（summary 不生成）")
        return
    import registry_enrich
    poll = int(os.environ.get("ENRICH_POLL_INTERVAL", "30"))
    batch = int(os.environ.get("ENRICH_BATCH", "5"))
    registry_enrich.start_worker(_load_package_json, poll_interval=poll, batch=batch)


# gunicorn 不走 __main__，import 时就把后台线程起起来（advisory lock 保证多 worker 只一个干活）
_ensure_buckets()
_maybe_start_mirror_sync()
_maybe_start_enrich_worker()


if __name__ == '__main__':
    print(f"[Registry] 启动 JSON-DSL Registry 服务，端口 {PORT}")
    print(f"[Registry] MinIO: {MINIO_ENDPOINT}")
    print(f"[Registry] Bucket: {BUCKET_COMPONENT}")
    app.run(host='0.0.0.0', port=PORT, debug=False)
