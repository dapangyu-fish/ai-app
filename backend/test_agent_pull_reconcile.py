#!/usr/bin/env python3
"""agent_pull_live_running_count reconciliation: the dashboard's active_runs must
reflect runs ACTUALLY running, not stale set members left by a crash / swallowed
release. Stale (terminal / no-meta / last_seen too old) members are dropped on read."""
from __future__ import annotations

import json
import sys
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# minimal stubs so ai_session imports without real deps
flask = types.ModuleType("flask")
flask.jsonify = lambda *a, **k: None
flask.request = object()
sys.modules["flask"] = flask
redis_mod = types.ModuleType("redis")
redis_mod.Redis = object
redis_mod.exceptions = types.SimpleNamespace(RedisError=type("RedisError", (Exception,), {}))
sys.modules["redis"] = redis_mod
minio = types.ModuleType("minio")
minio.Minio = type("Minio", (), {})
sys.modules["minio"] = minio
dotenv = types.ModuleType("dotenv")
dotenv.load_dotenv = lambda *a, **k: None
sys.modules["dotenv"] = dotenv
for _n in ("jwt", "requests"):
    sys.modules[_n] = types.ModuleType(_n)

import ai_session  # noqa: E402

NODE = "node-1"
NOW = int(time.time() * 1000)
STALE = (ai_session.AGENT_PULL_RUN_STALE_SECONDS + 120) * 1000

# run_id -> job meta (None = no meta in redis, i.e. expired/never written)
RUNS = {
    "run-live": {"status": "running", "last_seen_at": str(NOW)},
    "run-assigned-fresh": {"status": "assigned", "last_seen_at": str(NOW - 5000)},
    "run-done": {"status": "done", "last_seen_at": str(NOW)},
    "run-failed": {"status": "failed", "last_seen_at": str(NOW)},
    "run-nometa": None,
    "run-stale": {"status": "running", "last_seen_at": str(NOW - STALE)},
}
LIVE_EXPECTED = {"run-live", "run-assigned-fresh"}


class _FakeRedis:
    def __init__(self):
        self.members = {r.encode() for r in RUNS}
        self.sremmed = []

    def smembers(self, key):
        return set(self.members)

    def hgetall(self, key):
        k = key.decode() if isinstance(key, bytes) else str(key)
        # job key is ai:agent_pull:job:<run_id> ; derive run_id from the known keys
        for run_id, meta in RUNS.items():
            if k == ai_session._agent_pull_job_key(run_id):
                if meta is None:
                    return {}
                return {kk.encode(): vv.encode() for kk, vv in meta.items()}
        return {}

    def srem(self, key, *ids):
        for i in ids:
            b = i if isinstance(i, bytes) else str(i).encode()
            self.members.discard(b)
            self.sremmed.append(b.decode())
        return len(ids)


def test_reconcile_counts_only_live_and_reaps_stale():
    fake = _FakeRedis()
    ai_session.get_redis = lambda: fake
    n = ai_session.agent_pull_live_running_count(NODE)
    assert n == len(LIVE_EXPECTED), f"expected {len(LIVE_EXPECTED)} live, got {n}"
    reaped = set(fake.sremmed)
    assert reaped == {"run-done", "run-failed", "run-nometa", "run-stale"}, f"reaped={reaped}"
    # live ones must remain in the set
    remaining = {m.decode() for m in fake.members}
    assert remaining == LIVE_EXPECTED, f"remaining={remaining}"


def test_empty_node_is_zero():
    fake = _FakeRedis(); fake.members = set()
    ai_session.get_redis = lambda: fake
    assert ai_session.agent_pull_live_running_count(NODE) == 0
    assert ai_session.agent_pull_live_running_count("") == 0


if __name__ == "__main__":
    test_reconcile_counts_only_live_and_reaps_stale()
    test_empty_node_is_zero()
    print(json.dumps({"ok": True}, sort_keys=True))
