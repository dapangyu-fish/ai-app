#!/usr/bin/env python3
"""Registry 包富化目录 —— capture 解析 + tech_stack 映射 + registry_packages 表访问

职责（见 docs/internal/LAUNCH_NOTES.md Part 8）：
  - capture：解析包 JSON 提 exports / dependencies / widgets_used / builtins_used，
    再确定性映射出 tech_stack。零 LLM。
  - DB 层：registry_packages 表的 upsert / 认领 / 写回。用裸 psycopg2，**不走
    database.py 的 db_query**，因为后者的 _safe_convert_row 会把 None→"" / JSONB→错类型，
    会毁了我们的 nullable + JSONB 字段。
  - enrich（LLM summary）不在这里 —— 那是 registry_enrich.py 调 backend /api/ai/summarize。

附加表，不替代 _index.json。publish 照旧写索引，额外调这里 upsert 一行。
"""

import json
import psycopg2
import requests
from psycopg2.extras import Json, RealDictCursor
from typing import Optional

from config import (
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD,
    SUPABASE_URL, SUPABASE_SERVICE_KEY,
)

# summary prompt 版本 —— 改了 enrich 的 prompt / schema 就 +1，全量自动重排
SUMMARY_PROMPT_VERSION = 2

# 连续失败软上限，达到标 failed（下一轮全量 sweep 会重置回 pending 再试）
MAX_REINDEX_ATTEMPTS = 5


# ═══════════════════════════════════════════════════════════
# DB 连接（独立，保留 NULL / JSONB 原始类型）
# ═══════════════════════════════════════════════════════════

def _conn():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD,
    )


# ═══════════════════════════════════════════════════════════
# tech_stack 映射 —— 从结构化信号确定性推导（不走 LLM）
# ═══════════════════════════════════════════════════════════

# (判定函数 → tech_stack 标签)。判定基于 widgets_used / builtins_used /
# dependencies / game entity kinds / JSON 结构特征，全部确定性推导，不走 LLM。
def _derive_tech_stack(
    widgets: set,
    builtins: set,
    deps: set,
    entity_kinds: set,
    structural_flags: set,
) -> list:
    tech = set()

    def any_builtin(*prefixes):
        return any(b.startswith(p) for b in builtins for p in prefixes)

    def any_dep(*prefixes):
        return any(d.startswith(p) for d in deps for p in prefixes)

    # 本地数据库
    if any_builtin("@db_") or "lib_database" in deps:
        tech.add("local-database")
    # 实时通讯
    if any_builtin("@im_") or "lib_im" in deps:
        tech.add("realtime-messaging")
    # OpenAI-compatible / SSE AI 工具
    if any_builtin("@http_sse"):
        tech.add("sse-streaming")
    if "lib_openai" in deps:
        tech.add("ai-chat")
        tech.add("openai-compatible")
        tech.add("sse-streaming")
    # 游戏引擎
    if "flame_game" in widgets:
        tech.add("game-engine")
    if any_builtin("@flame_game_input") or "game-controls" in deps:
        tech.add("virtual-gamepad")
    if any_builtin("@platformer."):
        tech.add("platformer-physics")
    if any_builtin("@animated_sprite.") or "animated_sprite" in entity_kinds:
        tech.add("animated-sprite")
    if any_builtin("@tiled.") or "tiled_map" in entity_kinds:
        tech.add("tiled-map")
    if "inline-map-data" in structural_flags:
        tech.add("inline-tiled-map")
    if "asset-bundle" in structural_flags:
        tech.add("asset-bundle")
    # 图表
    if "chart" in widgets:
        tech.add("charts")
    # 地图
    if "map" in widgets:
        tech.add("maps")
    # WebView
    if "webview" in widgets:
        tech.add("webview")
    # 相机
    if "camera" in widgets or any_builtin("@take_photo"):
        tech.add("camera")
    # 选图
    if "image_picker" in widgets or any_builtin("@pick_image"):
        tech.add("image-picker")
    # 媒体播放
    if "video" in widgets:
        tech.add("media-player")
    # 二维码
    if "qr_code" in widgets:
        tech.add("qr")
    # 启动器 / 应用市场
    if any_dep("launcher-") or any_builtin(
        "@my_apps_", "@launch_app", "@startup_default_", "@cache_clear",
    ):
        tech.add("launcher")
    if any_builtin("@market_list"):
        tech.add("app-market")
    # 文件 / 本地存储
    if any_builtin("@file_", "@storage_"):
        tech.add("file-storage")
    # HTTP / 外部 API
    if any_builtin("@http_"):
        tech.add("http-api")
    # 鉴权 / 用户
    if any_builtin("@get_user_info", "@get_auth_token", "@is_logged_in", "@update_profile") or "lib_user" in deps:
        tech.add("auth")
    # 生物识别
    if any_builtin("@biometric_auth"):
        tech.add("biometric")
    # 系统桥
    if any_builtin("@clipboard_"):
        tech.add("clipboard")
    if any_builtin("@share"):
        tech.add("share")
    if any_builtin("@request_permission", "@permission_status", "@open_app_settings"):
        tech.add("permissions")
    if any_builtin("@haptic"):
        tech.add("haptics")
    # i18n / 主题
    if any_builtin(
        "@set_locale", "@get_locale", "@set_theme", "@get_theme",
        "@set_framework_locale", "@get_framework_locale",
    ):
        tech.add("i18n-theming")
    # 通用 UI 库
    if "common-ui" in deps:
        tech.add("ui-kit")

    return sorted(tech)


# ═══════════════════════════════════════════════════════════
# capture —— 解析包 JSON 提结构化信号
# ═══════════════════════════════════════════════════════════

def _walk_collect(
    node,
    widget_types: set,
    builtins: set,
    entity_kinds: set,
    structural_flags: set,
):
    """递归遍历 JSON 树，收集 widget type（"type" 字段）+ 内置函数（"call":"@xxx"）"""
    if isinstance(node, dict):
        t = node.get("type")
        if isinstance(t, str):
            widget_types.add(t)
        kind = node.get("kind")
        if isinstance(kind, str):
            entity_kinds.add(kind)
        call = node.get("call")
        if isinstance(call, str) and call.startswith("@"):
            builtins.add(call)
        if "map_data" in node:
            structural_flags.add("inline-map-data")
        for v in node.values():
            _walk_collect(v, widget_types, builtins, entity_kinds, structural_flags)
    elif isinstance(node, list):
        for item in node:
            _walk_collect(item, widget_types, builtins, entity_kinds, structural_flags)


def parse_capture(json_content: dict) -> dict:
    """从包 JSON 提结构化字段。返回 dict，可直接喂 upsert_capture。

    注意：widget type 收集会把 'app'/'library' 这类 meta.type 也扫进来（因为它们也叫 type），
    所以这里只保留"已知 widget 类型"... 但 registry 不持有 widget 注册表。
    折中：widgets_used 收集所有 type 字段值，下游展示/检索时容忍噪声（meta.type 也就 app/library 几个）。
    """
    meta = json_content.get("meta", {}) if isinstance(json_content, dict) else {}

    exports = meta.get("exports") or json_content.get("exports") or []
    if not isinstance(exports, list):
        exports = []

    deps_raw = json_content.get("dependencies") or {}
    dependencies = list(deps_raw.keys()) if isinstance(deps_raw, dict) else (
        deps_raw if isinstance(deps_raw, list) else []
    )

    widget_types: set = set()
    builtins: set = set()
    entity_kinds: set = set()
    structural_flags: set = set()
    if isinstance(json_content.get("assets"), dict) and json_content.get("assets"):
        structural_flags.add("asset-bundle")
    # 只遍历 ui + steps + global.functions（业务逻辑所在），不遍历 meta
    _walk_collect(json_content.get("ui"), widget_types, builtins, entity_kinds, structural_flags)
    _walk_collect(json_content.get("steps"), widget_types, builtins, entity_kinds, structural_flags)
    _walk_collect(
        (json_content.get("global") or {}).get("functions"),
        widget_types,
        builtins,
        entity_kinds,
        structural_flags,
    )

    # 去掉明显不是 widget 的 type 值（meta.type 的 app/library/component/widget）
    widget_types -= {"app", "library", "component", "widget"}

    tech_stack = _derive_tech_stack(
        widget_types,
        builtins,
        set(dependencies),
        entity_kinds,
        structural_flags,
    )

    return {
        "exports": sorted(exports) if all(isinstance(e, str) for e in exports) else exports,
        "dependencies": sorted(dependencies),
        "widgets_used": sorted(widget_types),
        "builtins_used": sorted(builtins),
        "tech_stack": tech_stack,
    }


# ═══════════════════════════════════════════════════════════
# DB 操作
# ═══════════════════════════════════════════════════════════

def upsert_capture(name: str, capture: dict,
                   author_id: Optional[str] = None,
                   author_name: Optional[str] = None) -> None:
    """publish / mirror sync 时调：写结构化字段 + author + 标 pending（触发后续 enrich）。
    富化字段（summary 等）不动；status 重置 pending 让 worker 重新生成。
    author_id/name 传 None 时保留原值（COALESCE），避免 mirror 覆盖本地作者。
    """
    sql = """
        INSERT INTO registry_packages
          (name, author_id, author_name, exports, dependencies, widgets_used,
           builtins_used, tech_stack, status, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'pending', NOW())
        ON CONFLICT (name) DO UPDATE SET
          author_id      = COALESCE(EXCLUDED.author_id, registry_packages.author_id),
          author_name    = COALESCE(EXCLUDED.author_name, registry_packages.author_name),
          exports        = EXCLUDED.exports,
          dependencies   = EXCLUDED.dependencies,
          widgets_used   = EXCLUDED.widgets_used,
          builtins_used  = EXCLUDED.builtins_used,
          tech_stack     = EXCLUDED.tech_stack,
          status         = 'pending',
          reindex_attempts = 0,
          updated_at     = NOW()
    """
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, [
                name, author_id, author_name,
                Json(capture["exports"]), Json(capture["dependencies"]),
                Json(capture["widgets_used"]), Json(capture["builtins_used"]),
                Json(capture["tech_stack"]),
            ])
        conn.commit()
    finally:
        conn.close()


def claim_pending(limit: int = 5) -> list:
    """enrich worker 认领待处理行。pending 或 prompt 版本落后的，置 processing 返回。
    用 FOR UPDATE SKIP LOCKED 防多实例重复（虽然有 advisory lock 选主兜底，双保险）。
    """
    sql = """
        WITH picked AS (
            SELECT name FROM registry_packages
            WHERE status = 'pending'
               OR (status = 'done' AND summary_prompt_version < %s)
            ORDER BY updated_at
            LIMIT %s
            FOR UPDATE SKIP LOCKED
        )
        UPDATE registry_packages p
        SET status = 'processing', updated_at = NOW()
        FROM picked
        WHERE p.name = picked.name
        RETURNING p.name
    """
    conn = _conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, [SUMMARY_PROMPT_VERSION, limit])
            rows = cur.fetchall()
        conn.commit()
        return [r["name"] for r in rows]
    finally:
        conn.close()


def save_enrich(name: str, enrich: dict, model: str) -> None:
    """enrich 成功：写 summary 字段 + status=done + 版本号 + 时间。
    search_text 在 SQL 里用 LLM 产出 + 已存的 capture 列（tech_stack/exports/deps）拼，
    worker 不用再查一遍 capture。给未来全文/向量检索用。
    """
    name_label = name  # full_name 也塞进检索文本
    caps_text = " ".join(str(c) for c in (enrich.get("capabilities") or []))
    domains_text = " ".join(enrich.get("domains") or [])
    sql = """
        UPDATE registry_packages SET
          summary_zh = %s, summary_en = %s,
          category = %s, domains = %s, capabilities = %s,
          use_case_zh = %s, use_case_en = %s,
          search_text = concat_ws(' ',
              %s, %s, %s, %s, %s, %s,
              tech_stack::text, exports::text, dependencies::text),
          status = 'done', summary_model = %s,
          summary_prompt_version = %s, reindex_attempts = 0,
          indexed_at = NOW(), updated_at = NOW()
        WHERE name = %s
    """
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, [
                enrich.get("summary_zh"), enrich.get("summary_en"),
                enrich.get("category"), Json(enrich.get("domains") or []),
                Json(enrich.get("capabilities") or []),
                enrich.get("use_case_zh"), enrich.get("use_case_en"),
                # search_text 拼接片段
                name_label,
                enrich.get("summary_zh") or "", enrich.get("summary_en") or "",
                caps_text, domains_text, enrich.get("category") or "",
                model, SUMMARY_PROMPT_VERSION, name,
            ])
        conn.commit()
    finally:
        conn.close()


def mark_failed_or_retry(name: str) -> None:
    """enrich 失败：attempts+1。<上限回 pending 等下轮；≥上限标 failed。"""
    sql = """
        UPDATE registry_packages SET
          reindex_attempts = reindex_attempts + 1,
          status = CASE WHEN reindex_attempts + 1 >= %s THEN 'failed' ELSE 'pending' END,
          updated_at = NOW()
        WHERE name = %s
    """
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, [MAX_REINDEX_ATTEMPTS, name])
        conn.commit()
    finally:
        conn.close()


def reset_failed_to_pending() -> int:
    """全量 sweep 用：把 failed 重置回 pending 再给一次机会。返回重置行数。"""
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE registry_packages SET status='pending', reindex_attempts=0 WHERE status='failed'"
            )
            n = cur.rowcount
        conn.commit()
        return n
    finally:
        conn.close()


def upsert_from_mirror(name: str, pkg: dict) -> None:
    """mirror 下游用：直接把上游 manifest 带来的富化数据拷进来，status=done，
    不重新跑 LLM（信任上游，省钱）。pkg 是 manifest 里的包条目。"""
    sql = """
        INSERT INTO registry_packages
          (name, author_id, author_name,
           exports, dependencies, widgets_used, builtins_used, tech_stack,
           summary_zh, summary_en, category, domains, capabilities,
           use_case_zh, use_case_en, search_text,
           status, summary_model, summary_prompt_version, indexed_at, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                'done', %s, %s, NOW(), NOW())
        ON CONFLICT (name) DO UPDATE SET
          author_id=COALESCE(EXCLUDED.author_id, registry_packages.author_id),
          author_name=COALESCE(EXCLUDED.author_name, registry_packages.author_name),
          exports=EXCLUDED.exports, dependencies=EXCLUDED.dependencies,
          widgets_used=EXCLUDED.widgets_used, builtins_used=EXCLUDED.builtins_used,
          tech_stack=EXCLUDED.tech_stack,
          summary_zh=EXCLUDED.summary_zh, summary_en=EXCLUDED.summary_en,
          category=EXCLUDED.category, domains=EXCLUDED.domains,
          capabilities=EXCLUDED.capabilities,
          use_case_zh=EXCLUDED.use_case_zh, use_case_en=EXCLUDED.use_case_en,
          search_text=EXCLUDED.search_text, status='done',
          summary_model=EXCLUDED.summary_model,
          summary_prompt_version=EXCLUDED.summary_prompt_version,
          indexed_at=NOW(), updated_at=NOW()
    """
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, [
                name, pkg.get("author_id"), pkg.get("author_name"),
                Json(pkg.get("exports") or []), Json(pkg.get("dependencies") or []),
                Json(pkg.get("widgets_used") or []), Json(pkg.get("builtins_used") or []),
                Json(pkg.get("tech_stack") or []),
                pkg.get("summary_zh"), pkg.get("summary_en"),
                pkg.get("category"), Json(pkg.get("domains") or []),
                Json(pkg.get("capabilities") or []),
                pkg.get("use_case_zh"), pkg.get("use_case_en"),
                pkg.get("search_text"),
                pkg.get("summary_model"), pkg.get("summary_prompt_version") or 0,
            ])
        conn.commit()
    finally:
        conn.close()


def catalog_map() -> dict:
    """返回 name -> 富化字段 dict，给 build_manifest 拼进 manifest 用。只取有 summary 的。"""
    conn = _conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("""
                SELECT name, author_id, author_name,
                       exports, dependencies, widgets_used, builtins_used, tech_stack,
                       summary_zh, summary_en, category, domains, capabilities,
                       use_case_zh, use_case_en, search_text, summary_model, summary_prompt_version
                FROM registry_packages WHERE status = 'done'
            """)
            return {r["name"]: dict(r) for r in cur.fetchall()}
    finally:
        conn.close()


def get_catalog(names: Optional[list] = None) -> list:
    """读富化目录（给 /packages 或 /catalog join 用）。names=None 取全部 done 的。"""
    base = """
        SELECT name, exports, dependencies, widgets_used, builtins_used, tech_stack,
               summary_zh, summary_en, category, domains, capabilities,
               use_case_zh, use_case_en, status
        FROM registry_packages
    """
    conn = _conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            if names:
                cur.execute(base + " WHERE name = ANY(%s)", [list(names)])
            else:
                cur.execute(base)
            return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


# ═══════════════════════════════════════════════════════════
# 作者解析（按 author_id 实时查 Supabase 头像/用户名，带进程内缓存）
# ═══════════════════════════════════════════════════════════

_author_cache: dict = {}  # user_id -> {nickname, avatar_url}（进程内缓存，避免每次详情页都打 Supabase）


def resolve_author(author_id: Optional[str], fallback_name: Optional[str] = None) -> dict:
    """user_id → {id, nickname, avatar_url}。查不到用 fallback_name（存的 author_name）兜底。
    跨实例场景：mirror 来的包 author_id 是上游 Supabase 的，下游自己 Supabase 查不到，
    这时 nickname 退到 fallback_name，avatar 为空。"""
    if not author_id:
        return {"id": None, "nickname": fallback_name or "", "avatar_url": ""}
    if author_id in _author_cache:
        c = _author_cache[author_id]
        return {"id": author_id, "nickname": c["nickname"] or fallback_name or "",
                "avatar_url": c["avatar_url"]}
    info = {"nickname": "", "avatar_url": ""}
    try:
        resp = requests.get(
            f"{SUPABASE_URL}/auth/v1/admin/users/{author_id}",
            headers={"apikey": SUPABASE_SERVICE_KEY,
                     "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}"},
            timeout=8,
        )
        if resp.status_code == 200:
            u = resp.json()
            um = u.get("user_metadata", {}) or {}
            info["nickname"] = um.get("username") or (u.get("email") or "").split("@")[0]
            info["avatar_url"] = um.get("avatar_url") or ""
            _author_cache[author_id] = info
    except Exception as e:
        print(f"[Catalog] resolve_author {author_id} 失败: {e}")
    return {
        "id": author_id,
        "nickname": info["nickname"] or fallback_name or "",
        "avatar_url": info["avatar_url"],
    }


# ═══════════════════════════════════════════════════════════
# 点赞 / 下载
# ═══════════════════════════════════════════════════════════

_install_event_table_ready = False


def _ensure_install_event_table(cur) -> None:
    """Ensure per-run install events exist and seed old unique install rows once."""
    global _install_event_table_ready
    if _install_event_table_ready:
        return
    cur.execute("""
        CREATE TABLE IF NOT EXISTS package_install_events (
          id           BIGSERIAL PRIMARY KEY,
          package_name TEXT NOT NULL,
          user_id      TEXT NOT NULL DEFAULT '',
          actor_type   TEXT NOT NULL DEFAULT '',
          source       TEXT NOT NULL DEFAULT '',
          user_agent   TEXT NOT NULL DEFAULT '',
          ip_hash      TEXT NOT NULL DEFAULT '',
          legacy_key   TEXT,
          created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_package_install_events_name
        ON package_install_events(package_name)
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_package_install_events_created_at
        ON package_install_events(created_at DESC)
    """)
    cur.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_package_install_events_legacy_key
        ON package_install_events(legacy_key)
        WHERE legacy_key IS NOT NULL
    """)
    cur.execute("""
        INSERT INTO package_install_events
          (package_name, user_id, actor_type, source, created_at, legacy_key)
        SELECT package_name, user_id, 'legacy', 'legacy_unique', first_at,
               package_name || E'\\x1f' || user_id
        FROM package_installs
        ON CONFLICT DO NOTHING
    """)
    cur.connection.commit()
    _install_event_table_ready = True


def record_install(
    name: str,
    user_id: str,
    *,
    actor_type: str = "user",
    source: str = "",
    user_agent: str = "",
    ip_hash: str = "",
) -> None:
    """Record one app run/download event and keep the legacy unique actor table."""
    conn = _conn()
    try:
        with conn.cursor() as cur:
            _ensure_install_event_table(cur)
            cur.execute(
                "INSERT INTO package_installs (package_name, user_id) VALUES (%s, %s) "
                "ON CONFLICT (package_name, user_id) DO NOTHING",
                [name, user_id],
            )
            cur.execute(
                """INSERT INTO package_install_events
                   (package_name, user_id, actor_type, source, user_agent, ip_hash)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                [
                    name,
                    user_id,
                    actor_type[:32],
                    source[:80],
                    user_agent[:512],
                    ip_hash[:128],
                ],
            )
        conn.commit()
    finally:
        conn.close()


def set_like(name: str, user_id: str, liked: bool) -> None:
    conn = _conn()
    try:
        with conn.cursor() as cur:
            if liked:
                cur.execute(
                    "INSERT INTO package_likes (package_name, user_id) VALUES (%s, %s) "
                    "ON CONFLICT DO NOTHING", [name, user_id])
            else:
                cur.execute(
                    "DELETE FROM package_likes WHERE package_name=%s AND user_id=%s",
                    [name, user_id])
        conn.commit()
    finally:
        conn.close()


def _counts(cur, name: str) -> tuple:
    # cur 可能是 RealDictCursor（fetchone 返 dict），用列别名按 key 取，别用 [0]
    _ensure_install_event_table(cur)
    cur.execute("SELECT count(*) AS c FROM package_likes WHERE package_name=%s", [name])
    likes = cur.fetchone()["c"]
    cur.execute("SELECT count(*) AS c FROM package_install_events WHERE package_name=%s", [name])
    installs = cur.fetchone()["c"]
    return likes, installs


def get_app_detail(name: str, viewer_id: Optional[str] = None) -> Optional[dict]:
    """单 app 详情：catalog 富化 + author + 点赞/下载量 + (登录则)我点没点。"""
    conn = _conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("""
                SELECT name, author_id, author_name, exports, dependencies, tech_stack,
                       summary_zh, summary_en, category, domains, capabilities,
                       use_case_zh, use_case_en, status
                FROM registry_packages WHERE name=%s
            """, [name])
            row = cur.fetchone()
            if not row:
                return None
            d = dict(row)
            likes, installs = _counts(cur, name)
            d["like_count"] = likes
            d["install_count"] = installs
            d["liked_by_me"] = False
            if viewer_id:
                cur.execute(
                    "SELECT 1 FROM package_likes WHERE package_name=%s AND user_id=%s",
                    [name, viewer_id])
                d["liked_by_me"] = cur.fetchone() is not None
        d["author"] = resolve_author(d.get("author_id"), d.get("author_name"))
        return d
    finally:
        conn.close()


def get_user_profile(author_id: str) -> dict:
    """用户主页：作者信息 + 总下载/总点赞（名下所有 app 之和）+ app 列表。"""
    conn = _conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            _ensure_install_event_table(cur)
            # 名下所有包 + 各自点赞/下载量
            cur.execute("""
                SELECT p.name, p.author_name, p.category, p.summary_zh, p.summary_en, p.tech_stack,
                       (SELECT count(*) FROM package_likes l WHERE l.package_name=p.name)    AS like_count,
                       (SELECT count(*) FROM package_install_events i WHERE i.package_name=p.name) AS install_count
                FROM registry_packages p
                WHERE p.author_id = %s
                ORDER BY p.name
            """, [author_id])
            apps = [dict(r) for r in cur.fetchall()]
        total_likes = sum(a["like_count"] for a in apps)
        total_installs = sum(a["install_count"] for a in apps)
        fallback_name = apps[0]["author_name"] if apps else None
        return {
            "author": resolve_author(author_id, fallback_name),
            "total_likes": total_likes,
            "total_installs": total_installs,
            "app_count": len(apps),
            "apps": apps,
        }
    finally:
        conn.close()


def set_all_authors(author_id: str, author_name: str) -> int:
    """一次性把所有包的作者刷成指定用户（修历史乱作者用）。返回影响行数。"""
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE registry_packages SET author_id=%s, author_name=%s, updated_at=NOW()",
                [author_id, author_name])
            n = cur.rowcount
        conn.commit()
        return n
    finally:
        conn.close()
