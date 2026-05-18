#!/usr/bin/env python3
"""
Registry Mirror —— 跨实例的索引同步 + 按需文件代理缓存。

设计要点（来自需求确认）：
  1. 首次只同步索引（不一次性下载所有文件），用到哪个再代理过去拉
  2. 索引每 REGISTRY_MIRROR_SYNC_INTERVAL_SEC 秒同步一次（默认 10 分钟）
  3. 冲突策略：版本号不重叠 → union；同号 → upstream 赢（本地仍可发新版本号）
  4. 链式 mirror：A 镜像 B，A 的 /mirror/manifest 把"自有 + 从 B 镜的"统一对外曝露，
     URL 全指向 A 自己（C 镜像 A 时只看到 A，不知道 B 的存在）
  5. /mirror/manifest 公开访问，无需 token
  6. 不镜像 namespace 表（namespace 库本地独立；读路径不查 namespace 表，自然能用）

索引 schema 改动（向后兼容）：
  packages[name] 加可选字段 `version_sources: {version: source}`
    source = "local"              本地发布
    source = "https://upstream..."  从该上游同步来的（chain mirror 时 = 上一跳）
  没有这个字段视为全部 "local"（兼容旧索引）
"""

import io
import json
import logging
import threading
import time
from datetime import datetime
from typing import Dict, Any, Optional, Tuple

import requests
from minio import Minio
from minio.error import S3Error


logger = logging.getLogger(__name__)

# 进程级 RLock：所有 _load_index → 改 → _save_index 的临界区都要持有它。
# RLock 是因为有些场景嵌套（比如 publish 内部又走 helper 加锁），保持简单
index_lock = threading.RLock()

INDEX_FILE = "_index.json"


# ═════════════════════════════════════════════════════════════
# Source 解析
# ═════════════════════════════════════════════════════════════

def get_version_source(pkg_info: Dict[str, Any], version: str) -> str:
    """返回该 version 的 source。缺失字段 = local（向后兼容旧索引）"""
    return (pkg_info.get("version_sources") or {}).get(version, "local")


def is_local_version(pkg_info: Dict[str, Any], version: str) -> bool:
    return get_version_source(pkg_info, version) == "local"


# ═════════════════════════════════════════════════════════════
# Manifest 构造（自己作为 upstream 给别人看）
# ═════════════════════════════════════════════════════════════

def build_manifest(index_data: Dict[str, Any], my_base_url: str) -> Dict[str, Any]:
    """把本地 _index.json 转成对外的 mirror manifest。

    URL 全部指回 my_base_url —— 这样别人 mirror 我，看到的 source 就是我，
    递归代理的链路自动成立（不暴露我的更上游）。
    """
    my_base_url = my_base_url.rstrip("/")
    packages = []
    for name, info in (index_data.get("packages") or {}).items():
        versions_out = []
        for v in info.get("versions", []):
            versions_out.append({
                "version": v,
                "filename": f"{name.split('/')[-1]}-{v}.json",
                "download_url": f"{my_base_url}/mirror/file/{name}/{v}",
            })
        packages.append({
            "name": name,
            "type": info.get("type", "user"),
            "appid": info.get("appid"),
            "latest": info.get("latest"),
            "created_at": info.get("created_at"),
            "versions": versions_out,
        })
    return {
        "registry_version": "1.0",
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "source_registry": my_base_url,
        "packages": packages,
    }


# ═════════════════════════════════════════════════════════════
# 索引合并（核心：upstream 版本赢，本地新版本号保留）
# ═════════════════════════════════════════════════════════════

def merge_manifest_into_index(
    local_index: Dict[str, Any],
    upstream_manifest: Dict[str, Any],
    upstream_url: str,
) -> Tuple[int, int]:
    """把 upstream manifest 合并进 local_index（in-place）。

    返回 (新增版本数, 替换版本数)。
    """
    upstream_url = upstream_url.rstrip("/")
    added = 0
    replaced = 0

    if "packages" not in local_index:
        local_index["packages"] = {}

    for up_pkg in upstream_manifest.get("packages") or []:
        name = up_pkg.get("name")
        if not name:
            continue

        up_versions = [v.get("version") for v in (up_pkg.get("versions") or []) if v.get("version")]
        if not up_versions:
            continue

        if name in local_index["packages"]:
            local_pkg = local_index["packages"][name]
        else:
            local_pkg = {
                "type": up_pkg.get("type", "user"),
                "path": name,
                "appid": up_pkg.get("appid"),
                "created_at": up_pkg.get("created_at") or (datetime.utcnow().isoformat() + "Z"),
                "author_id": None,           # 镜像来的没有本地 author
                "versions": [],
                "version_sources": {},
            }
            local_index["packages"][name] = local_pkg

        # 确保 version_sources 字段存在（旧索引兼容）
        if "version_sources" not in local_pkg:
            local_pkg["version_sources"] = {v: "local" for v in local_pkg.get("versions", [])}
        if "versions" not in local_pkg:
            local_pkg["versions"] = []

        for v in up_versions:
            existing_source = local_pkg["version_sources"].get(v)
            if existing_source is None:
                # 新版本号 → 加入
                local_pkg["versions"].append(v)
                local_pkg["version_sources"][v] = upstream_url
                added += 1
            elif existing_source == "local":
                # 同号冲突：upstream 赢。文件在本地 MinIO 留着但被影响（孤儿，不删）
                local_pkg["version_sources"][v] = upstream_url
                replaced += 1
                logger.warning(
                    "[Mirror] %s@%s: local 版本被 upstream(%s) 覆盖",
                    name, v, upstream_url,
                )
            else:
                # 已经是某个 upstream 来的（可能是同一个 upstream 刷新，也可能换了 upstream）
                if existing_source != upstream_url:
                    local_pkg["version_sources"][v] = upstream_url
                # 不计 replaced（不算新动作）

        # 排版本，更新 latest
        local_pkg["versions"] = sorted(
            set(local_pkg["versions"]),
            key=lambda x: tuple(int(p) for p in x.split(".")),
            reverse=True,
        )
        if local_pkg["versions"]:
            local_pkg["latest"] = local_pkg["versions"][0]

    return added, replaced


# ═════════════════════════════════════════════════════════════
# Sync 一次
# ═════════════════════════════════════════════════════════════

def sync_once(
    upstream_url: str,
    minio_client: Minio,
    bucket: str,
    load_index_fn,
    save_index_fn,
    timeout_sec: int = 20,
) -> Optional[Tuple[int, int]]:
    """从 upstream 拉一次 manifest 合并到本地。返回 (added, replaced) 或 None（失败）。

    load_index_fn / save_index_fn 由 registry_server 注入，保持单一数据访问层。
    """
    try:
        resp = requests.get(
            f"{upstream_url.rstrip('/')}/mirror/manifest",
            timeout=timeout_sec,
        )
        resp.raise_for_status()
        manifest = resp.json()
    except Exception as e:
        logger.error("[Mirror] 拉 upstream manifest 失败: %s", e)
        return None

    with index_lock:
        local_index = load_index_fn()
        added, replaced = merge_manifest_into_index(local_index, manifest, upstream_url)
        save_index_fn(local_index)

    logger.info(
        "[Mirror] sync 完成: upstream=%s, +%d 新版本, %d 替换",
        upstream_url, added, replaced,
    )
    return added, replaced


# ═════════════════════════════════════════════════════════════
# 文件按需代理 + 缓存
# ═════════════════════════════════════════════════════════════

def file_exists_in_minio(minio_client: Minio, bucket: str, key: str) -> bool:
    try:
        minio_client.stat_object(bucket, key)
        return True
    except S3Error as e:
        if e.code in ("NoSuchKey", "NoSuchObject"):
            return False
        raise


def proxy_fetch_and_cache(
    upstream_url: str,
    name: str,
    version: str,
    minio_client: Minio,
    bucket: str,
    oss_key: str,
    timeout_sec: int = 30,
) -> bool:
    """从 upstream 拉单个版本文件，写入本地 MinIO。已存在则跳过。"""
    if file_exists_in_minio(minio_client, bucket, oss_key):
        return True

    fetch_url = f"{upstream_url.rstrip('/')}/mirror/file/{name}/{version}"
    try:
        resp = requests.get(fetch_url, timeout=timeout_sec, allow_redirects=True)
        if resp.status_code != 200:
            logger.error("[Mirror] 拉 %s 失败: HTTP %d", fetch_url, resp.status_code)
            return False
        content = resp.content
    except Exception as e:
        logger.error("[Mirror] 拉 %s 失败: %s", fetch_url, e)
        return False

    try:
        minio_client.put_object(
            bucket, oss_key,
            io.BytesIO(content), len(content),
            content_type="application/json",
        )
        logger.info("[Mirror] 缓存 %s → %s/%s (%d bytes)", fetch_url, bucket, oss_key, len(content))
        return True
    except Exception as e:
        logger.error("[Mirror] 写本地 MinIO 失败 %s/%s: %s", bucket, oss_key, e)
        return False


# ═════════════════════════════════════════════════════════════
# 后台同步线程
# ═════════════════════════════════════════════════════════════

def start_background_sync(
    upstream_url: str,
    interval_sec: int,
    minio_client: Minio,
    bucket: str,
    load_index_fn,
    save_index_fn,
) -> threading.Thread:
    """起一个 daemon 线程，每 interval_sec 跑一次 sync_once。
    interval_sec <= 0 则只跑一次首发，不进入循环。
    """
    def loop():
        # 启动后先延 5s 等 MinIO/网络就绪
        time.sleep(5)
        first = True
        while True:
            try:
                sync_once(upstream_url, minio_client, bucket,
                          load_index_fn, save_index_fn)
            except Exception as e:
                logger.exception("[Mirror] sync 循环异常: %s", e)
            if interval_sec <= 0 and first:
                logger.info("[Mirror] interval<=0，仅同步一次")
                return
            first = False
            time.sleep(max(interval_sec, 30))   # 30s 下限防误配

    t = threading.Thread(target=loop, name="registry-mirror-sync", daemon=True)
    t.start()
    logger.info("[Mirror] 后台同步线程已起，upstream=%s, interval=%ds",
                upstream_url, interval_sec)
    return t
