#!/usr/bin/env python3
"""
Store 模块 - JSON App 管理
"""

import json
import os
import uuid
import tempfile
import subprocess
from flask import request, jsonify, send_from_directory
from config import TEMPLATES_DIR, MINIO_PUBLIC_URL
from database import db_query, db_execute
from auth import require_auth, require_role


def _minio_upload(bucket, key, data, content_type="application/json"):
    """上传文件到 MinIO（使用 mc 命令行）"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        if isinstance(data, str):
            f.write(data)
        else:
            json.dump(data, f, ensure_ascii=False, indent=2)
        tmp_path = f.name

    result = subprocess.run(
        ["mc", "cp", tmp_path, f"app/{bucket}/{key}"],
        capture_output=True, text=True, timeout=30,
    )
    os.unlink(tmp_path)
    if result.returncode != 0:
        raise Exception(f"MinIO upload failed: {result.stderr}")
    return f"{MINIO_PUBLIC_URL}/{bucket}/{key}"


def _generate_appid():
    """生成不重复的 appid（UUID）"""
    max_attempts = 100
    for _ in range(max_attempts):
        appid = uuid.uuid4().hex
        exists = db_query(
            "SELECT id FROM app_registry WHERE id = %s",
            [appid],
            fetch_one=True
        )
        if not exists:
            return appid
    raise Exception("无法生成唯一的 appid")


def _check_appid_exists(appid):
    """检查 appid 是否已在数据库中存在"""
    if not appid:
        return False
    exists = db_query(
        "SELECT id FROM app_registry WHERE id = %s",
        [appid],
        fetch_one=True
    )
    return bool(exists)


def _increment_version(version_str):
    """将版本号的 patch 部分 +1，如 1.0.0 → 1.0.1"""
    parts = version_str.split('.')
    if len(parts) == 3:
        parts[2] = str(int(parts[2]) + 1)
    elif len(parts) == 2:
        parts.append('1')
    else:
        return version_str + '.0.1'
    return '.'.join(parts)


def store_apps():
    """列出所有公开 APP"""
    rows = db_query(
        "SELECT id, name, version, description, author_name, download_url, tags, icon_url, meta_json FROM app_registry WHERE type = 'app' AND is_public = true ORDER BY created_at DESC",
        fetch_all=True
    )
    apps = []
    for row in rows:
        app_data = {
            "id": row["id"] or "",
            "name": row["name"] or "",
            "version": row["version"] or "",
            "description": row["description"] or "",
            "author": row["author_name"] or "",
            "download_url": row["download_url"] or "",
            "tags": row["tags"] or []
        }
        # 优先从 icon_url 字段读取，如果没有则从 meta_json 读取
        icon_url = row.get("icon_url")
        if icon_url:
            app_data["icon_url"] = icon_url
        else:
            meta_json = row.get("meta_json")
            if meta_json and isinstance(meta_json, dict):
                app_data["icon_url"] = meta_json.get("icon_url", "")
            else:
                app_data["icon_url"] = ""
        apps.append(app_data)
    return jsonify({"apps": apps})


def store_components():
    """列出所有公开组件"""
    rows = db_query(
        "SELECT id, name, version, description, author_name, download_url, icon_url FROM app_registry WHERE type = 'component' AND is_public = true ORDER BY name",
        fetch_all=True
    )
    components = []
    for row in rows:
        comp_data = {
            "id": row["id"] or "",
            "name": row["name"] or "",
            "version": row["version"] or "",
            "description": row["description"] or "",
            "author": row["author_name"] or "",
            "download_url": row["download_url"] or "",
            "icon_url": row.get("icon_url", "") or ""
        }
        components.append(comp_data)
    return jsonify({"components": components})


@require_auth
def new_appid():
    """生成一个新的唯一 appid"""
    try:
        appid = _generate_appid()
        return jsonify({
            "appid": appid,
            "status": "success"
        })
    except Exception as e:
        return jsonify({
            "error": str(e),
            "status": "error"
        }), 500


@require_auth
@require_role("pro", "admin")
def store_publish():
    """发布 JSON-APP/组件到市场（支持新建和更新）"""
    try:
        return _do_store_publish()
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": f"服务器内部错误: {e}"}), 500

def _do_store_publish():
    body = request.get_json(silent=True) or {}
    json_content = body.get("json_content")
    force_update = body.get("force_update", False)
    if not json_content:
        return jsonify({"error": "json_content 不能为空"}), 400

    if isinstance(json_content, str):
        try:
            json_content = json.loads(json_content)
        except Exception:
            return jsonify({"error": "无效的 JSON"}), 400

    meta = json_content.get("meta", {})
    app_type = meta.get("type", "app")
    if app_type not in ("app", "component", "library"):
        return jsonify({"error": "meta.type 必须是 app 或 component"}), 400
    if app_type == "library":
        app_type = "component"

    name = meta.get("name", "unnamed")
    version = meta.get("version", "1.0.0")
    description = meta.get("description", "")
    dsl_spec = meta.get("dsl_spec", description)
    icon_url = meta.get("icon_url", "")

    app_id = json_content.get("appid")

    # appid 已存在 → 检测冲突或执行更新
    if app_id and _check_appid_exists(app_id):
        if not force_update:
            existing = db_query(
                "SELECT name, version, description FROM app_registry WHERE id = %s",
                [app_id], fetch_one=True
            )
            suggested = _increment_version(existing["version"])
            return jsonify({
                "conflict": True,
                "message": "该 appid 已存在，这将是一个更新操作",
                "existing": {
                    "appid": app_id,
                    "name": existing["name"],
                    "version": existing["version"],
                },
                "suggested_version": suggested,
            }), 409

        # force_update=true → 更新已有记录
        json_content["appid"] = app_id
        bucket = "json-app" if app_type == "app" else "json-component"
        oss_key = f"{app_id}/{name}-{version}.json"
        try:
            download_url = _minio_upload(bucket, oss_key, json_content)
        except Exception as e:
            return jsonify({"error": str(e)}), 502

        user = request.supabase_user
        author_name = user.get("user_metadata", {}).get("username", user.get("email", ""))
        db_execute(
            """UPDATE app_registry
               SET name = %s, version = %s, description = %s,
                   oss_key = %s, download_url = %s, meta_json = %s,
                   dsl_spec = %s, icon_url = %s
               WHERE id = %s""",
            [name, version, description, oss_key, download_url,
             json.dumps(meta, ensure_ascii=False), dsl_spec, icon_url, app_id]
        )
        return jsonify({
            "message": "更新成功",
            "appid": app_id,
            "download_url": download_url,
        })

    # 新 APP → 生成 appid 并 INSERT
    if not app_id:
        app_id = _generate_appid()
    json_content["appid"] = app_id

    bucket = "json-app" if app_type == "app" else "json-component"
    oss_key = f"{app_id}/{name}-{version}.json"
    try:
        download_url = _minio_upload(bucket, oss_key, json_content)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

    user = request.supabase_user
    user_id = user.get("id")
    author_name = user.get("user_metadata", {}).get("username", user.get("email", ""))
    db_execute(
        """INSERT INTO app_registry
           (id, type, name, version, description, author_id, author_name,
            oss_bucket, oss_key, download_url, meta_json, dsl_spec, icon_url)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        [
            app_id, app_type, name, version, description, user_id, author_name,
            bucket, oss_key, download_url,
            json.dumps(meta, ensure_ascii=False), dsl_spec, icon_url
        ]
    )

    return jsonify({
        "message": "发布成功",
        "appid": app_id,
        "download_url": download_url,
    })


@require_auth
def store_delete(app_id):
    """下架 APP/组件"""
    row = db_query("SELECT author_id FROM app_registry WHERE id = %s", [app_id], fetch_one=True)
    if not row:
        return jsonify({"error": "未找到"}), 404

    user_id = request.supabase_user.get("id")
    if str(row["author_id"]) != str(user_id) and request.user_role != "admin":
        return jsonify({"error": "只有作者或管理员可以删除"}), 403

    db_execute("DELETE FROM app_registry WHERE id = %s", [app_id])
    return jsonify({"message": "已删除"})


def app_list():
    """旧接口：列出 templates/ 目录下的 JSON 应用"""
    apps = []
    try:
        files = sorted(os.listdir(TEMPLATES_DIR))
        for f in files:
            if not f.endswith(".json"):
                continue
            try:
                with open(os.path.join(TEMPLATES_DIR, f), 'r', encoding='utf-8') as fh:
                    data = json.load(fh)
                meta = data.get("meta", {})
                apps.append({
                    "name": meta.get("name", f),
                    "version": meta.get("version", "1.0.0"),
                    "description": meta.get("description", ""),
                    "icon_url": meta.get("icon_url", ""),
                    "author": meta.get("author", ""),
                    "download": f"/download/{f}",
                })
            except Exception:
                continue
    except Exception:
        pass
    return jsonify({"apps": apps})


def download_file(filename):
    """下载 templates/ 目录下的文件"""
    return send_from_directory(TEMPLATES_DIR, filename)
