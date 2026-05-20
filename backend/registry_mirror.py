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
import threading
import time
import traceback
from datetime import datetime
from typing import Dict, Any, Optional, Tuple

import requests
from minio import Minio
from minio.error import S3Error


# 这个模块所有日志走 print() —— 跟 registry_server.py / store.py 等其他后端模块风格一致。
# 历史教训：本来用 logging.getLogger(__name__).info(...)，但项目没全局 basicConfig，
# 默认 WARNING+，sync 进度全被吞，ops 时啥也看不见

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

def build_manifest(
    index_data: Dict[str, Any],
    my_base_url: str,
    minio_client: Optional[Minio] = None,
    bucket: Optional[str] = None,
    catalog: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """把本地 _index.json 转成对外的 mirror manifest。

    URL 全部指回 my_base_url —— 这样别人 mirror 我，看到的 source 就是我，
    递归代理的链路自动成立（不暴露我的更上游）。

    如果传了 minio_client/bucket，会读每个包 latest 版本的 JSON 抽取 meta.type /
    description / author 一并塞进 manifest。否则字段缺失，下游 fallback 到本地兜底。
    必须传，否则下游过滤 `?type=app` 会失效（manifest 没 meta_type，sync 完
    本地索引也没，filter 用了不存在的字段 → 永远不匹配）
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

        # 读 latest 文件抽 meta（如果本地有这个文件 & 客户端传了 minio）
        meta_type = info.get("meta_type")     # 优先用 index 缓存
        description = info.get("description", "")
        author = info.get("author", "")
        latest = info.get("latest")

        if meta_type is None and minio_client and bucket and latest:
            # index 没存 meta —— 现读现填（建 manifest 时一次性，缓存住）
            path = info.get("path", name)
            filename = f"{name.split('/')[-1]}-{latest}.json"
            try:
                resp = minio_client.get_object(bucket, f"{path}/{filename}")
                content = json.loads(resp.read().decode("utf-8"))
                m = content.get("meta", {})
                meta_type = m.get("type", "library")
                description = description or m.get("description", "")
                author = author or m.get("author", "")
            except Exception:
                meta_type = "library"  # 默认值

        entry = {
            "name": name,
            "type": info.get("type", "user"),
            "meta_type": meta_type or "library",
            "description": description,
            "author": author,
            "appid": info.get("appid"),
            "latest": latest,
            "created_at": info.get("created_at"),
            "versions": versions_out,
        }
        # 富化字段（summary/tags/tech_stack）随 manifest 传给下游，下游直接拷不用重跑 LLM
        cat = (catalog or {}).get(name)
        if cat:
            for k in ("exports", "dependencies", "widgets_used", "builtins_used",
                      "tech_stack", "summary_zh", "summary_en", "category", "domains",
                      "capabilities", "use_case_zh", "use_case_en", "search_text",
                      "summary_model", "summary_prompt_version"):
                if cat.get(k) is not None:
                    entry[k] = cat[k]
        packages.append(entry)
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

        # 拷贝 upstream 的 meta 字段进本地 index，让 /packages?type 过滤不需要去读文件
        # 这些字段是"latest 版本视角"的（manifest 也是按 latest 取的），随每次 sync 刷新
        for meta_field in ("meta_type", "description", "author"):
            if up_pkg.get(meta_field):
                local_pkg[meta_field] = up_pkg[meta_field]

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
                print(f"[Mirror] WARN: {name}@{v} 本地版本被 upstream({upstream_url}) 覆盖")
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

        # 上游 manifest 带了富化数据（summary 等）→ 直接拷进本地 registry_packages，
        # status=done，不在下游重跑 LLM（信任上游，省钱）。失败吞掉不影响 index 合并
        if up_pkg.get("summary_zh") or up_pkg.get("summary_en"):
            try:
                import registry_catalog
                registry_catalog.upsert_from_mirror(name, up_pkg)
            except Exception as e:
                print(f"[Mirror] 拷富化数据失败（忽略）{name}: {e}")

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
        print(f"[Mirror] ERROR 拉 upstream manifest 失败: {e}")
        return None

    with index_lock:
        local_index = load_index_fn()
        added, replaced = merge_manifest_into_index(local_index, manifest, upstream_url)
        save_index_fn(local_index)

    print(f"[Mirror] sync 完成: upstream={upstream_url}, +{added} 新版本, {replaced} 替换")
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
            print(f"[Mirror] ERROR 拉 {fetch_url} 失败: HTTP {resp.status_code}")
            return False
        content = resp.content
    except Exception as e:
        print(f"[Mirror] ERROR 拉 {fetch_url} 失败: {e}")
        return False

    try:
        minio_client.put_object(
            bucket, oss_key,
            io.BytesIO(content), len(content),
            content_type="application/json",
        )
        print(f"[Mirror] 缓存 {fetch_url} → {bucket}/{oss_key} ({len(content)} bytes)")
        return True
    except Exception as e:
        print(f"[Mirror] ERROR 写本地 MinIO 失败 {bucket}/{oss_key}: {e}")
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
                print(f"[Mirror] ERROR sync 循环异常: {e}")
                traceback.print_exc()
            if interval_sec <= 0 and first:
                print("[Mirror] interval<=0，仅同步一次")
                return
            first = False
            time.sleep(max(interval_sec, 30))   # 30s 下限防误配

    t = threading.Thread(target=loop, name="registry-mirror-sync", daemon=True)
    t.start()
    print(f"[Mirror] 后台同步线程已起，upstream={upstream_url}, interval={interval_sec}s")
    return t
