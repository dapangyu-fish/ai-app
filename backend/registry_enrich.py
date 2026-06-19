#!/usr/bin/env python3
"""Registry enrich worker —— 后台给包补 AI summary

并发模型（见 docs/internal/LAUNCH_NOTES.md Part 8）：
  - pg_try_advisory_lock 选主：gunicorn 多 worker 里只有 1 个真正跑 loop（拿不到锁的
    睡着重试，leader 挂了别人接管）→ 不会"大量并发轮询"
  - 那一个 loop 每 ENRICH_POLL_INTERVAL 秒认领 ENRICH_BATCH 行，**串行**调 backend
    /api/ai/summarize（backend 那边还有 3 并发小池硬上限）
  - 失败 5 次标 failed；每隔若干轮做一次全量 sweep 把 failed 重置回 pending 再试

两种触发模式都靠 claim_pending 的查询条件覆盖：
  - 新发布 → upsert_capture 标 pending → 下一轮处理（低延迟）
  - 历史/prompt 升级 → status='done' AND summary_prompt_version 落后 → 重排
"""

import threading
import time

import os

import psycopg2
import requests

from config import (
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD,
)
import registry_catalog

# advisory lock 的固定 key（任意常量，全局唯一即可）
_ADVISORY_LOCK_KEY = 778811

# 每多少轮做一次"failed → pending"全量 sweep
_SWEEP_EVERY_N_LOOPS = 60


def _try_become_leader(lock_conn) -> bool:
    """尝试拿 advisory lock。拿到 = 我是 leader。锁随 lock_conn 这条连接存活。"""
    try:
        with lock_conn.cursor() as cur:
            cur.execute("SELECT pg_try_advisory_lock(%s)", [_ADVISORY_LOCK_KEY])
            got = cur.fetchone()[0]
        lock_conn.commit()
        return bool(got)
    except Exception as e:
        print(f"[Enrich] advisory lock 获取异常: {e}")
        return False


def _enrich_one(name: str, load_package_json, summarize_url: str, admin_token: str) -> bool:
    """处理单个包：load JSON → 调 backend summarize → 写回。成功 True。"""
    try:
        json_content = load_package_json(name)
        if not json_content:
            print(f"[Enrich] {name}: 加载包 JSON 失败，跳过")
            registry_catalog.mark_failed_or_retry(name)
            return False

        resp = requests.post(
            summarize_url,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {admin_token}",
            },
            json={"json_content": json_content},
            timeout=180,  # backend CLI 自己有 120s 超时，这里给足余量
        )
        if resp.status_code != 200:
            print(f"[Enrich] {name}: backend summarize {resp.status_code}: {resp.text[:200]}")
            registry_catalog.mark_failed_or_retry(name)
            return False

        enrich = resp.json()
        registry_catalog.save_enrich(name, enrich, enrich.get("model", "deepseek"))
        print(f"[Enrich] ✅ {name}: summary 已写入 (category={enrich.get('category')})")
        return True
    except Exception as e:
        print(f"[Enrich] {name}: 异常 {e}")
        registry_catalog.mark_failed_or_retry(name)
        return False


def start_worker(load_package_json, poll_interval: int = 30, batch: int = 5) -> threading.Thread:
    """起后台 enrich 线程。load_package_json(name)->dict 由 registry_server 注入
    （它有 minio_client + _load_index 能定位并读包文件）。"""
    # summarize 在 backend，不在 registry 自己
    backend_url = os.environ.get("BACKEND_INTERNAL_URL", "")
    admin_token = os.environ.get("REGISTRY_ADMIN_TOKEN", "")

    if not backend_url:
        print("[Enrich] 未配置 BACKEND_INTERNAL_URL，enrich worker 不启动")
        return None
    if not admin_token:
        print("[Enrich] 未配置 REGISTRY_ADMIN_TOKEN，enrich worker 不启动")
        return None

    summarize_url = f"{backend_url.rstrip('/')}/api/ai/summarize"

    def loop():
        time.sleep(8)  # 等 DB / backend 起来
        # 这条连接专门 hold advisory lock，整个进程生命周期不关
        lock_conn = None
        is_leader = False
        loop_count = 0
        while True:
            try:
                if lock_conn is None or lock_conn.closed:
                    lock_conn = psycopg2.connect(
                        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                        user=DB_USER, password=DB_PASSWORD,
                    )
                    is_leader = False
                if not is_leader:
                    is_leader = _try_become_leader(lock_conn)
                    if not is_leader:
                        time.sleep(poll_interval)  # 不是 leader，睡着等
                        continue
                    print("[Enrich] 成为 leader，开始 enrich 轮询")

                # 是 leader：认领一批处理
                names = registry_catalog.claim_pending(limit=batch)
                for name in names:
                    _enrich_one(name, load_package_json, summarize_url, admin_token)

                loop_count += 1
                if loop_count % _SWEEP_EVERY_N_LOOPS == 0:
                    n = registry_catalog.reset_failed_to_pending()
                    if n:
                        print(f"[Enrich] 全量 sweep: {n} 个 failed 重置回 pending")

            except Exception as e:
                print(f"[Enrich] loop 异常: {e}")
                # 连接可能坏了，下一轮重建
                try:
                    if lock_conn and not lock_conn.closed:
                        lock_conn.close()
                except Exception:
                    pass
                lock_conn = None
                is_leader = False

            time.sleep(poll_interval)

    t = threading.Thread(target=loop, name="registry-enrich", daemon=True)
    t.start()
    print(f"[Enrich] 后台 worker 已起，backend={summarize_url}, interval={poll_interval}s, batch={batch}")
    return t
