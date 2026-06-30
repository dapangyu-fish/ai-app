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


def _checksum(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return hashlib.sha256(f.read().encode("utf-8")).hexdigest()


def _verify_checksums(cur, files: list[str]) -> int:
    """对已应用且磁盘文件仍在的迁移，比对库内 checksum 与当前文件 hash。

    不一致 = 已应用迁移被就地改写（DB 与磁盘 SQL 漂移）。runner 只按文件名判 pending，
    永不会重跑它，故这里发出告警让漂移可见（见 §11.2-#5，把 checksum 列从死数据变护栏）。
    返回漂移条数。"""
    cur.execute("SELECT id, checksum FROM schema_migrations")
    stored = dict(cur.fetchall())
    by_name = {os.path.basename(p): p for p in files}
    drift = 0
    for mid, db_sum in stored.items():
        path = by_name.get(mid)
        if path is None:
            continue  # 已应用但文件已删/改名——单独情形，不在此判
        disk_sum = _checksum(path)
        if disk_sum != db_sum:
            drift += 1
            print(
                f"[migrate] ⚠️ DRIFT: {mid} 已应用但磁盘内容已变"
                f"（db={db_sum[:12]}… disk={disk_sum[:12]}…）——DB 不会重跑它，需人工核对",
                file=sys.stderr,
            )
    return drift


def run(*, mark_only: bool = False, status_only: bool = False) -> int:
    conn = _conn()
    conn.autocommit = False
    cur = conn.cursor()

    # 建 tracking 表前先探测它是否已存在 + 平台库是否已有其它表。
    # 关键安全闸（§11.1-#3）：若 tracking 表是本次新建、而平台库已有 schema（存量主机，
    # 历史迁移早被手动 psql 流程跑过），自动跑裸 migrate.py 会从 001 重放、撞已删的列而崩。
    # 此时自动打基线（marker），等价于手动 --mark，使存量主机首次部署的自动迁移安全幂等。
    cur.execute("SELECT to_regclass('public.schema_migrations')")
    tracking_existed = cur.fetchone()[0] is not None
    cur.execute(
        "SELECT count(*) FROM information_schema.tables"
        " WHERE table_schema='public' AND table_name <> 'schema_migrations'"
    )
    has_existing_schema = cur.fetchone()[0] > 0

    cur.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        " id text PRIMARY KEY,"
        " checksum text NOT NULL,"
        " applied_at timestamptz NOT NULL DEFAULT now())"
    )
    conn.commit()
    cur.execute("SELECT id FROM schema_migrations")
    applied = {r[0] for r in cur.fetchall()}

    files = _migration_files()
    pending = [p for p in files if os.path.basename(p) not in applied]

    if status_only:
        print(f"[migrate] applied={sorted(applied)}")
        print(f"[migrate] pending={[os.path.basename(p) for p in pending]}")
        drift = _verify_checksums(cur, files)
        cur.close()
        conn.close()
        return 2 if drift else 0

    auto_baseline = (not tracking_existed) and has_existing_schema and not applied
    if auto_baseline and not mark_only:
        print(
            "[migrate] 检测到平台库已有 schema 但无 tracking 表 → 自动打基线"
            "（mark 现有迁移为已应用，不重放），避免存量主机首次部署崩溃"
        )

    effective_mark = mark_only or auto_baseline
    for path in pending:
        mid = os.path.basename(path)
        checksum = _checksum(path)
        if effective_mark:
            cur.execute(
                "INSERT INTO schema_migrations(id, checksum) VALUES (%s, %s)"
                " ON CONFLICT (id) DO NOTHING",
                (mid, checksum),
            )
            print(f"[migrate] marked {mid} as applied (no-run)")
        else:
            print(f"[migrate] applying {mid} ...")
            cur.execute(open(path, encoding="utf-8").read())
            cur.execute(
                "INSERT INTO schema_migrations(id, checksum) VALUES (%s, %s)",
                (mid, checksum),
            )
            print(f"[migrate] applied {mid}")
        conn.commit()

    # 应用后核对已应用迁移的 checksum 漂移（非致命，仅告警）。
    _verify_checksums(cur, files)
    cur.close()
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(
        run(mark_only="--mark" in sys.argv, status_only="--status" in sys.argv)
    )
