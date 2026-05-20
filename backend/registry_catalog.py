#!/usr/bin/env python3
"""Registry 包富化目录 —— capture 解析 + tech_stack 映射 + registry_packages 表访问

职责（见 LAUNCH_NOTES.md Part 8）：
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
from psycopg2.extras import Json, RealDictCursor
from typing import Optional

from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD

# summary prompt 版本 —— 改了 enrich 的 prompt / schema 就 +1，全量自动重排
SUMMARY_PROMPT_VERSION = 1

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

# (判定函数 → tech_stack 标签)。判定基于 widgets_used / builtins_used / dependencies
def _derive_tech_stack(widgets: set, builtins: set, deps: set) -> list:
    tech = set()

    def any_builtin(*prefixes):
        return any(b.startswith(p) for b in builtins for p in prefixes)

    # 本地数据库
    if any_builtin("@db_") or "lib_database" in deps:
        tech.add("local-database")
    # 实时通讯
    if any_builtin("@im_") or "lib_im" in deps:
        tech.add("realtime-messaging")
    # 游戏引擎
    if "flame_game" in widgets:
        tech.add("game-engine")
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
    # i18n / 主题
    if any_builtin("@set_locale", "@get_locale", "@set_theme", "@get_theme"):
        tech.add("i18n-theming")
    # 通用 UI 库
    if "common-ui" in deps:
        tech.add("ui-kit")

    return sorted(tech)


# ═══════════════════════════════════════════════════════════
# capture —— 解析包 JSON 提结构化信号
# ═══════════════════════════════════════════════════════════

def _walk_collect(node, widget_types: set, builtins: set):
    """递归遍历 JSON 树，收集 widget type（"type" 字段）+ 内置函数（"call":"@xxx"）"""
    if isinstance(node, dict):
        t = node.get("type")
        if isinstance(t, str):
            widget_types.add(t)
        call = node.get("call")
        if isinstance(call, str) and call.startswith("@"):
            builtins.add(call)
        for v in node.values():
            _walk_collect(v, widget_types, builtins)
    elif isinstance(node, list):
        for item in node:
            _walk_collect(item, widget_types, builtins)


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
    # 只遍历 ui + steps + global.functions（业务逻辑所在），不遍历 meta
    _walk_collect(json_content.get("ui"), widget_types, builtins)
    _walk_collect(json_content.get("steps"), widget_types, builtins)
    _walk_collect((json_content.get("global") or {}).get("functions"), widget_types, builtins)

    # 去掉明显不是 widget 的 type 值（meta.type 的 app/library/component/widget）
    widget_types -= {"app", "library", "component", "widget"}

    tech_stack = _derive_tech_stack(widget_types, builtins, set(dependencies))

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

def upsert_capture(name: str, capture: dict) -> None:
    """publish / mirror sync 时调：写结构化字段 + 标 pending（触发后续 enrich）。
    富化字段（summary 等）不动；status 重置 pending 让 worker 重新生成。
    """
    sql = """
        INSERT INTO registry_packages
          (name, exports, dependencies, widgets_used, builtins_used, tech_stack,
           status, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, 'pending', NOW())
        ON CONFLICT (name) DO UPDATE SET
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
                name,
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
