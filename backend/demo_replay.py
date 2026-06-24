"""Demo replay — 免登录 super-demo 模式的服务端核心。

特殊 UUID 的 AI 任务不会路由到任何 agent-node，也不会真正创建 FaaS：
chat_start 识别到特殊 session_id 后直接走这里，用预录的 jsonl 通过 SSE 回放
（带极小 sleep，体感像一次很快的真实生成），最后给出一个**真实**的临时
JSON-app 链接（从随包的 app.json 现场重新上传，避免 24h presigned 过期）。

录制（一次性，在部署主机）：设置环境变量
  AI_DEMO_RECORD_SESSION_ID=<某次真实生成的 session_id>
  AI_DEMO_RECORD_PATH=backend/demo_replays/<base>.jsonl
ai_session.SessionStore.append_event / set_status 会把业务事件 tee 成 jsonl。
再把那次真实生成上传的 app.json 存成 backend/demo_replays/<base>.app.json。

详见 memory: demo-replay-mode。隔离：demo 是一个**真实但专用**的 Supabase 账号，
session 的 meta.user_id = 该账号 uid，stream/result 的归属校验天然隔离真实用户；
demo 永不进 submit_worker → 不占队列/配额/lease，也不碰 agent-node。
"""
import json
import logging
import os
import time

from flask import jsonify

import ai_session

logger = logging.getLogger(__name__)

REPLAY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo_replays")

# 特殊 demo UUID → 回放文件 basename（backend/demo_replays/<base>.jsonl[/.app.json]）
DEMO_SESSIONS = {
    "00000000-0000-0000-0000-000000000001": "forum_0001",
    "00000000-0000-0000-0000-000000000002": "pomodoro_0002",
    "00000000-0000-0000-0000-000000000003": "calculator",
    "00000000-0000-0000-0000-000000000004": "demo_5pages",
    "00000000-0000-0000-0000-000000000005": "demo_media",
    "00000000-0000-0000-0000-000000000006": "demo_video_browser",
    "00000000-0000-0000-0000-000000000007": "framework_quality_camera_inspection",
    "00000000-0000-0000-0000-000000000008": "framework_quality_course_player",
    "00000000-0000-0000-0000-000000000009": "framework_quality_ops_dashboard",
    "00000000-0000-0000-0000-000000000010": "framework_quality_smart_home",
    "00000000-0000-0000-0000-000000000011": "framework_quality_travel_pass",
    "00000000-0000-0000-0000-000000000012": "match3-pixel",
    "00000000-0000-0000-0000-000000000013": "native_quality_budget",
    "00000000-0000-0000-0000-000000000014": "native_quality_crm",
    "00000000-0000-0000-0000-000000000015": "native_quality_habits",
    "00000000-0000-0000-0000-000000000016": "native_quality_notes",
    "00000000-0000-0000-0000-000000000017": "native_quality_workout",
    "00000000-0000-0000-0000-000000000018": "super-app-demo",
    "00000000-0000-0000-0000-000000000019": "text-collector",
    "00000000-0000-0000-0000-000000000020": "demo_2048",
    "00000000-0000-0000-0000-000000000021": "demo_snake",
    "00000000-0000-0000-0000-000000000022": "demo_flappy_bird",
}

# 每条事件之间的 sleep，制造「很快的真实生成」体感；可用环境变量调
_REPLAY_SLEEP = float(os.environ.get("AI_DEMO_REPLAY_SLEEP", "0.05"))

DEMO_PROVIDER = "demo"


def is_demo_uuid(session_id) -> bool:
    return isinstance(session_id, str) and session_id in DEMO_SESSIONS


def _path(base: str, ext: str) -> str:
    return os.path.join(REPLAY_DIR, f"{base}.{ext}")


def start(session_id: str, user_id: str):
    """在 chat_start 里被调用：建 meta（标记 provider=demo 供 SSE 僵尸检测豁免），
    起一个后台线程回放 jsonl，立即返回与正常 chat_start 同形状的响应。"""
    base = DEMO_SESSIONS[session_id]
    store = ai_session.SessionStore()
    # create_meta 会清掉旧 stream/meta → 重复点同一个 demo 是幂等的
    store.create_meta(
        session_id,
        user_id=user_id,
        provider=DEMO_PROVIDER,
        agent=DEMO_PROVIDER,
        quota_used=0,
        quota_limit=0,
        quota_remaining=0,
        status=ai_session.STATUS_RUNNING,  # 非 QUEUED，避免 SSE 反复发 queue 状态
    )
    ai_session._executor.submit(_replay_worker, session_id, base)
    logger.info("[DEMO] replay started sid=%s base=%s user=%s", session_id, base, user_id)
    return jsonify({
        "session_id": session_id,
        "status": "running",
        "resumed": False,
        "agent": DEMO_PROVIDER,
        "agent_scope": "public",
        "generation_pipeline": "demo_replay",
        "queue_position": 0,
    })


def _mint_fresh_url(base: str):
    """把随包的 app.json 重新上传，拿一个新的 24h presigned URL（避免录制时的链接过期）。
    没有 app.json（如纯前端 demo 已把完整 JSON 内嵌在事件里）或上传失败 → 返回 None，沿用录制里的链接。"""
    app_path = _path(base, "app.json")
    if not os.path.exists(app_path):
        return None
    try:
        with open(app_path, "rb") as f:
            return ai_session._upload_temp_json_app(f.read())
    except Exception as e:  # MinIO 不可用（如本机）等 → 退回录制链接
        logger.warning("[DEMO] mint fresh url failed base=%s: %s", base, e)
        return None


def _rewrite_event_url(ev: dict, fresh: str) -> dict:
    if not fresh or not isinstance(ev, dict):
        return ev
    ca = ev.get("client_action")
    if isinstance(ca, dict) and ca.get("type") == "json_app_ready":
        ev = dict(ev)
        ca = dict(ca)
        ca["url"] = fresh
        ev["client_action"] = ca
    return ev


def _rewrite_actions_url(actions, fresh: str):
    if not fresh or not isinstance(actions, list):
        return actions
    out = []
    replaced = False
    for a in actions:
        if isinstance(a, dict) and a.get("type") == "json_app_ready":
            a = dict(a)
            a["url"] = fresh
            replaced = True
        out.append(a)
    if not replaced:
        out.append({"type": "json_app_ready", "url": fresh})
    return out


def _replay_worker(session_id: str, base: str):
    store = ai_session.SessionStore()
    jsonl = _path(base, "jsonl")
    fresh = _mint_fresh_url(base)
    final = {}
    try:
        with open(jsonl, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                ev = json.loads(line)
                # 录制末尾的哨兵行，重建终态 meta（final_text/client_actions 等）
                if isinstance(ev, dict) and "_demo_final" in ev:
                    final = ev.get("_demo_final") or {}
                    continue
                store.append_event(session_id, _rewrite_event_url(ev, fresh))
                time.sleep(_REPLAY_SLEEP)
    except FileNotFoundError:
        logger.error("[DEMO] replay file missing: %s", jsonl)
        store.append_event(session_id, {"status": "error", "message": "demo replay 暂不可用"})
        store.set_status(session_id, ai_session.STATUS_FAILED, error="demo replay not available")
        return
    except Exception as e:
        logger.exception("[DEMO] replay failed sid=%s: %s", session_id, e)
        store.set_status(session_id, ai_session.STATUS_FAILED, error=str(e))
        return

    actions = _rewrite_actions_url(final.get("client_actions") or [], fresh)
    store.set_status(
        session_id,
        ai_session.STATUS_DONE,
        final_text=final.get("final_text"),
        final_thinking=final.get("final_thinking"),
        client_actions=actions,
    )
    logger.info("[DEMO] replay done sid=%s base=%s events_final=%s", session_id, base, bool(final))
