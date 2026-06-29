#!/usr/bin/env python3
"""平台 jsonapp 库的 schema 迁移 runner（见 docs/planning/version-management.md §3.6）。

之前 `backend/migrations/00N_*.sql` 手动应用、无 tracking 表、无法知道某库到底跑过哪些。
本 runner 自举一张 `schema_migrations`，按文件名顺序应用**未应用**的迁移并记录校验和。

用法（在能连 jsonapp 库的环境，如 backend 容器内，读 DB_* / DB_DIRECT_* 环境变量）：
  python migrate.py            # 应用所有未应用的 00N_*.sql（迁移须幂等）
  python migrate.py --mark     # 只把现有迁移标记为已应用（首次接入/给已存在的库打基线）
  python migrate.py --status   # 只打印已应用 / 待应用

迁移走 DB_DIRECT_*（绕过 PgBouncer，DDL 不进池），回落 DB_*。
"""
import glob
import hashlib
import os
import sys

MIGRATIONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "migrations")


def _conn():
    import psycopg2
    return psycopg2.connect(
        host=os.environ.get("DB_DIRECT_HOST") or os.environ.get("DB_HOST", "127.0.0.1"),
        port=int(os.environ.get("DB_DIRECT_PORT") or os.environ.get("DB_PORT", "5432")),
        dbname=os.environ.get("DB_NAME", "jsonapp"),
        user=os.environ.get("DB_USER", "jsonapp"),
        password=os.environ.get("DB_PASSWORD", ""),
        connect_timeout=10,
    )


def _migration_files():
    return sorted(glob.glob(os.path.join(MIGRATIONS_DIR, "[0-9]*.sql")))


def run(*, mark_only: bool = False, status_only: bool = False) -> int:
    conn = _conn()
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        " id text PRIMARY KEY,"
        " checksum text NOT NULL,"
        " applied_at timestamptz NOT NULL DEFAULT now())"
    )
    conn.commit()
    cur.execute("SELECT id FROM schema_migrations")
    applied = {r[0] for r in cur.fetchall()}

    pending = [p for p in _migration_files() if os.path.basename(p) not in applied]
    if status_only:
        print(f"[migrate] applied={sorted(applied)}")
        print(f"[migrate] pending={[os.path.basename(p) for p in pending]}")
        cur.close()
        conn.close()
        return 0

    for path in pending:
        mid = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            sql = f.read()
        checksum = hashlib.sha256(sql.encode("utf-8")).hexdigest()
        if mark_only:
            cur.execute(
                "INSERT INTO schema_migrations(id, checksum) VALUES (%s, %s)"
                " ON CONFLICT (id) DO NOTHING",
                (mid, checksum),
            )
            print(f"[migrate] marked {mid} as applied (no-run)")
        else:
            print(f"[migrate] applying {mid} ...")
            cur.execute(sql)
            cur.execute(
                "INSERT INTO schema_migrations(id, checksum) VALUES (%s, %s)",
                (mid, checksum),
            )
            print(f"[migrate] applied {mid}")
        conn.commit()

    cur.close()
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(
        run(mark_only="--mark" in sys.argv, status_only="--status" in sys.argv)
    )
