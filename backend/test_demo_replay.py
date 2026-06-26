"""模拟单测：验证全部 demo 回放案例可用（无需 Redis / agent-node / FaaS）。

对每个 DEMO_SESSIONS 条目：
  1) is_demo_uuid 命中；
  2) <base>.jsonl 每行合法 JSON，恰有 1 个 _demo_final，且带 json_app_ready；
  3) <base>.app.json 合法 JSON 且有 dsl/meta/ui；
  4) 用 FakeStore 跑 demo_replay._replay_worker（monkeypatch 掉真实上传），断言：
     - 至少 append 了若干事件；
     - 流里 json_app_ready 事件的 url 被替换成了「现场重传」的新链接；
     - 终态为 DONE 且 client_actions 带 json_app_ready（新链接）。
全部通过 → 退出码 0。可直接 `python3 test_demo_replay.py` 跑，也兼容 pytest。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_session
import demo_replay

REPLAY_DIR = demo_replay.REPLAY_DIR


class FakeStore:
    """记录 create_meta/append_event/set_status，绝不碰真实 Redis。"""
    def __init__(self):
        self.events = []
        self.final = None
        self.meta_created = False

    def create_meta(self, sid, **kw):
        self.meta_created = True

    def append_event(self, sid, ev):
        self.events.append(ev)

    def set_status(self, sid, status, **kw):
        self.final = (status, kw)


def _check_files(uuid, base, errors):
    if not demo_replay.is_demo_uuid(uuid):
        errors.append(f"{base}: is_demo_uuid({uuid}) is False")
    jl = os.path.join(REPLAY_DIR, f"{base}.jsonl")
    aj = os.path.join(REPLAY_DIR, f"{base}.app.json")
    if not os.path.exists(jl):
        errors.append(f"{base}: missing {base}.jsonl"); return
    if not os.path.exists(aj):
        errors.append(f"{base}: missing {base}.app.json"); return
    # jsonl integrity
    finals = 0; has_url = False
    for i, line in enumerate(open(jl, encoding="utf-8")):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception as e:
            errors.append(f"{base}: jsonl line {i+1} bad json: {e}"); return
        if isinstance(ev, dict) and "_demo_final" in ev:
            finals += 1
            cas = (ev["_demo_final"] or {}).get("client_actions") or []
            if any(a.get("type") == "json_app_ready" for a in cas):
                has_url = True
    if finals != 1:
        errors.append(f"{base}: expected exactly 1 _demo_final, got {finals}")
    if not has_url:
        errors.append(f"{base}: _demo_final has no json_app_ready")
    # app.json integrity
    try:
        app = json.load(open(aj, encoding="utf-8"))
    except Exception as e:
        errors.append(f"{base}: app.json bad json: {e}"); return
    for k in ("dsl", "meta", "ui"):
        if k not in app:
            errors.append(f"{base}: app.json missing '{k}'")


def _simulate_replay(uuid, base, errors):
    store = FakeStore()
    fake_url = f"https://fake-refreshed.invalid/{base}.json"
    orig_ss = ai_session.SessionStore
    orig_up = ai_session._upload_temp_json_app
    orig_sleep = demo_replay._REPLAY_SLEEP
    ai_session.SessionStore = lambda: store
    ai_session._upload_temp_json_app = lambda data: fake_url
    demo_replay._REPLAY_SLEEP = 0
    try:
        demo_replay._replay_worker(uuid, base)
    except Exception as e:
        errors.append(f"{base}: _replay_worker raised {e!r}"); return
    finally:
        ai_session.SessionStore = orig_ss
        ai_session._upload_temp_json_app = orig_up
        demo_replay._REPLAY_SLEEP = orig_sleep

    if len(store.events) < 3:
        errors.append(f"{base}: too few replayed events ({len(store.events)})")
    # streamed json_app_ready url must be refreshed
    stream_urls = [ev.get("client_action", {}).get("url")
                   for ev in store.events
                   if isinstance(ev.get("client_action"), dict)
                   and ev["client_action"].get("type") == "json_app_ready"]
    if not stream_urls:
        errors.append(f"{base}: no json_app_ready in replayed stream")
    elif any(u != fake_url for u in stream_urls):
        errors.append(f"{base}: streamed json_app_ready url not refreshed: {stream_urls}")
    # terminal status
    if not store.final or store.final[0] != ai_session.STATUS_DONE:
        errors.append(f"{base}: final status != DONE ({store.final})")
        return
    cas = store.final[1].get("client_actions") or []
    final_urls = [a.get("url") for a in cas if a.get("type") == "json_app_ready"]
    if not final_urls:
        errors.append(f"{base}: final client_actions has no json_app_ready")
    elif final_urls[0] != fake_url:
        errors.append(f"{base}: final json_app_ready url not refreshed: {final_urls}")


def run():
    errors = []
    sessions = demo_replay.DEMO_SESSIONS
    for uuid, base in sessions.items():
        _check_files(uuid, base, errors)
        _simulate_replay(uuid, base, errors)
    n = len(sessions)
    print(f"demo cases: {n}")
    if errors:
        print(f"FAILURES ({len(errors)}):")
        for e in errors:
            print("  -", e)
        return 1
    print(f"OK: all {n} demo cases pass (files valid + replay simulated → DONE with refreshed json_app_ready)")
    return 0


def test_all_demo_cases():  # pytest entry
    assert run() == 0


if __name__ == "__main__":
    sys.exit(run())
