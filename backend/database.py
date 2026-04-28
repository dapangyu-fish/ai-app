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


# ═══════════════════════════════════════════════════════════
# 命名空间权限管理
# ═══════════════════════════════════════════════════════════

def create_namespace(name, description, created_by):
    """创建命名空间"""
    db_execute(
        """INSERT INTO namespaces (name, description, created_by)
           VALUES (%s, %s, %s)""",
        [name, description, created_by]
    )
    # 获取刚创建的命名空间 ID
    row = db_query(
        "SELECT id FROM namespaces WHERE name = %s",
        [name],
        fetch_one=True
    )
    return row['id'] if row else None


def get_namespace_by_name(name):
    """根据名称获取命名空间"""
    return db_query(
        "SELECT * FROM namespaces WHERE name = %s",
        [name],
        fetch_one=True
    )


def get_user_namespaces(user_id):
    """获取用户拥有权限的所有命名空间"""
    return db_query(
        """SELECT n.id, n.name, n.description, n.created_at, nm.role
           FROM namespaces n
           JOIN namespace_members nm ON n.id = nm.namespace_id
           WHERE nm.user_id = %s
           ORDER BY n.created_at DESC""",
        [user_id],
        fetch_all=True
    )


def add_namespace_member(namespace_id, user_id, role, invited_by):
    """添加命名空间成员"""
    db_execute(
        """INSERT INTO namespace_members (namespace_id, user_id, role, invited_by)
           VALUES (%s, %s, %s, %s)
           ON CONFLICT (namespace_id, user_id)
           DO UPDATE SET role = EXCLUDED.role""",
        [namespace_id, user_id, role, invited_by]
    )


def remove_namespace_member(namespace_id, user_id):
    """移除命名空间成员"""
    db_execute(
        "DELETE FROM namespace_members WHERE namespace_id = %s AND user_id = %s",
        [namespace_id, user_id]
    )


def get_namespace_members(namespace_id):
    """获取命名空间的所有成员"""
    return db_query(
        """SELECT user_id, role, joined_at, invited_by
           FROM namespace_members
           WHERE namespace_id = %s
           ORDER BY joined_at ASC""",
        [namespace_id],
        fetch_all=True
    )


def check_namespace_permission(namespace_name, user_id):
    """检查用户是否有命名空间的发布权限（owner 或 admin）"""
    row = db_query(
        """SELECT nm.role
           FROM namespaces n
           JOIN namespace_members nm ON n.id = nm.namespace_id
           WHERE n.name = %s AND nm.user_id = %s""",
        [namespace_name, user_id],
        fetch_one=True
    )
    if not row:
        return False, None
    return True, row['role']


def update_namespace_member_role(namespace_id, user_id, new_role):
    """更新命名空间成员的角色"""
    db_execute(
        """UPDATE namespace_members
           SET role = %s
           WHERE namespace_id = %s AND user_id = %s""",
        [new_role, namespace_id, user_id]
    )
