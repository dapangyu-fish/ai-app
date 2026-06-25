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

# 每条事件之间的 sleep。保留「逐字吐」体感，但事件已精简（去重/去重复通道/合并），
# 故整体很快（多数 demo 2-4s）。可用环境变量覆盖。
_REPLAY_SLEEP = float(os.environ.get("AI_DEMO_REPLAY_SLEEP", "0.18"))

DEMO_PROVIDER = "demo"

# Demo 专用对象存储桶：所有 demo 的 app.json 预先固定上传到这里（public-read），
# 回放时直接返回固定公共 URL，不再每次临时上传/预签名 → 更快、链接稳定不过期。
# 桶的创建/上传由 myapp-ctl 部署后步骤负责（集群初始化的一部分），见 scripts/myapp_ctl.py。
DEMO_BUCKET = os.environ.get("AI_DEMO_BUCKET", "demo")


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


def _minio_client():
    from minio import Minio
    return Minio(
        ai_session.MINIO_ENDPOINT,
        access_key=ai_session.MINIO_ACCESS_KEY,
        secret_key=ai_session.MINIO_SECRET_KEY,
        secure=ai_session.MINIO_SECURE,
    )


def _demo_public_policy() -> dict:
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": ["*"]},
            "Action": ["s3:GetObject"],
            "Resource": [f"arn:aws:s3:::{DEMO_BUCKET}/*"],
        }],
    }


def ensure_demo_assets(force: bool = False) -> dict:
    """确保 demo 桶存在、public-read，并把每个 <base>.app.json 固定上传成 <base>.json。
    幂等：内容未变（按 size+md5/etag 比对）则跳过上传。返回 {base: 是否本次上传}。
    后端启动后由 myapp-ctl 部署步骤调用（集群初始化的一部分），首个回放也会兜底调用。
    MinIO 不可用时抛异常，由调用方决定降级。"""
    import hashlib
    import io
    import json as _json

    if not ai_session.MINIO_ACCESS_KEY or not ai_session.MINIO_SECRET_KEY:
        raise RuntimeError("backend MinIO credentials are not configured")

    client = _minio_client()
    if not client.bucket_exists(DEMO_BUCKET):
        client.make_bucket(DEMO_BUCKET)
    try:
        client.set_bucket_policy(DEMO_BUCKET, _json.dumps(_demo_public_policy()))
    except Exception as e:  # 策略设置失败不致命（桶可能已是 public）
        logger.warning("[DEMO] set public policy failed bucket=%s: %s", DEMO_BUCKET, e)

    result = {}
    for base in sorted(set(DEMO_SESSIONS.values())):
        app_path = _path(base, "app.json")
        if not os.path.exists(app_path):
            continue  # 纯前端内嵌 demo 无随包 app.json
        with open(app_path, "rb") as f:
            data = f.read()
        key = f"{base}.json"
        need = True
        if not force:
            try:
                st = client.stat_object(DEMO_BUCKET, key)
                if st.size == len(data) and (st.etag or "").strip('"') == hashlib.md5(data).hexdigest():
                    need = False  # 内容未变 → 跳过
            except Exception:
                need = True
        if need:
            client.put_object(
                DEMO_BUCKET, key, io.BytesIO(data), len(data),
                content_type="application/json",
            )
        result[base] = need
    logger.info("[DEMO] assets ensured bucket=%s uploaded=%d/%d",
                DEMO_BUCKET, sum(1 for v in result.values() if v), len(result))
    return result


def _demo_public_url(base: str) -> str:
    """固定公共 URL（demo 桶 public-read，path-style 直取，无需预签名）。"""
    return f"{ai_session.MINIO_PUBLIC_URL.rstrip('/')}/{DEMO_BUCKET}/{base}.json"


# None=未探测；True=demo 桶就绪用固定 URL；False=不可用，降级到旧的临时预签名上传
_assets_ready = None


def _resolve_app_url(base: str):
    """回放交付链接：优先固定公共 URL（不每次上传）；demo 桶不可用时降级回临时上传。
    没有随包 app.json（纯前端内嵌）→ 返回 None，沿用录制里的原链接。"""
    if not os.path.exists(_path(base, "app.json")):
        return None
    global _assets_ready
    if _assets_ready is None:
        try:
            ensure_demo_assets()
            _assets_ready = True
        except Exception as e:
            logger.warning("[DEMO] ensure_demo_assets unavailable, fall back to temp upload: %s", e)
            _assets_ready = False
    if _assets_ready:
        return _demo_public_url(base)
    return _mint_fresh_url(base)


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


def _wake_sse(store, session_id: str):
    """唤醒可能阻塞在 xread 上的 SSE 连接。

    set_status 只更新 meta（HSET），不往 stream 写事件；而 SSE handler 此刻多半正阻塞在
    `xread BLOCK` 上等新事件——状态变更不会让它返回（实测 eventlet 下 block 超时也迟迟不触发，
    回放线程结束后那条连接会一直挂到客户端 20s idle 超时才重连）。这里补一条轻量 stream 事件，
    让阻塞的 xread 立刻醒来；它下一轮即读到 terminal 状态并发 `[DONE]`，秒出「下载并运行」按钮。
    必须在 set_status(terminal) 之后调用（Redis 单线程保证 HSET 先于 XADD 可见）。"""
    try:
        store.append_event(session_id, {"status": ai_session.STATUS_DONE})
    except Exception:
        logger.warning("[DEMO] wake-sse append failed sid=%s", session_id)


def _replay_worker(session_id: str, base: str):
    store = ai_session.SessionStore()
    jsonl = _path(base, "jsonl")
    fresh = _resolve_app_url(base)
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
        _wake_sse(store, session_id)
        return
    except Exception as e:
        logger.exception("[DEMO] replay failed sid=%s: %s", session_id, e)
        store.set_status(session_id, ai_session.STATUS_FAILED, error=str(e))
        _wake_sse(store, session_id)
        return

    actions = _rewrite_actions_url(final.get("client_actions") or [], fresh)
    store.set_status(
        session_id,
        ai_session.STATUS_DONE,
        final_text=final.get("final_text"),
        final_thinking=final.get("final_thinking"),
        client_actions=actions,
    )
    _wake_sse(store, session_id)
    logger.info("[DEMO] replay done sid=%s base=%s events_final=%s", session_id, base, bool(final))
