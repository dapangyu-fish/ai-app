#!/usr/bin/env python3
"""
数据库模块 - PostgreSQL 连接和操作
"""

import psycopg2
from psycopg2.extras import DictCursor
from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
from datetime import date


def get_db_connection():
    """获取数据库连接"""
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    return conn


def _safe_convert_row(row):
    """安全转换数据库行：NULL (None) → 空字符串或合适的默认值"""
    result = dict(row)
    for key, value in result.items():
        if value is None:
            if key == "tags":
                result[key] = []
            elif key == "meta_json":
                result[key] = {}
            elif key == "is_public":
                result[key] = True
            else:
                result[key] = ""
    return result


def db_query(sql, params=None, fetch_one=False, fetch_all=False):
    """执行查询语句"""
    conn = get_db_connection()
    try:
        with conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(sql, params or ())
            if fetch_one:
                result = cur.fetchone()
                return _safe_convert_row(result) if result else None
            elif fetch_all:
                results = cur.fetchall()
                return [_safe_convert_row(row) for row in results]
            else:
                conn.commit()
                return None
    finally:
        conn.close()


def db_execute(sql, params=None):
    """执行更新/删除/插入语句"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
        conn.commit()
    finally:
        conn.close()


def get_quota_info(user_id, role, role_quotas):
    """获取用户配额信息 (used, limit, remaining)"""
    limit = role_quotas.get(role, 30)
    today = date.today().isoformat()
    row = db_query(
        "SELECT used_count FROM chat_quotas WHERE user_id = %s AND date = %s",
        [user_id, today],
        fetch_one=True
    )
    used = row["used_count"] if row else 0
    return used, limit, max(0, limit - used)


def increment_quota(user_id):
    """增加用户今日配额使用量"""
    today = date.today().isoformat()
    db_execute(
        """INSERT INTO chat_quotas (user_id, date, used_count)
           VALUES (%s, %s, 1)
           ON CONFLICT (user_id, date)
           DO UPDATE SET used_count = chat_quotas.used_count + 1""",
        [user_id, today]
    )
