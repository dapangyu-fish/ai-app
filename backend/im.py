#!/usr/bin/env python3
"""
OpenIM 集成路由
─────────────────────────────────────────────────────────
作用：业务系统 (Supabase) 用户 ↔ OpenIM 用户的桥接。

流程（客户端登录后）：
  1. 客户端用业务 token 调 POST /api/im/token
  2. 后端 require_auth 拿到 supabase_user
  3. 把 supabase user.id (UUID 字符串) 去掉 hyphen 后当 OpenIM userID
     ※ OpenIM 拒绝含 `-` 的 userID（errCode=1001 "userID is legal"），必须 strip
  4. 用 admin secret → admin_token → 确保 OpenIM 用户存在 → 签 user token
  5. 返回 {im_user_id, im_token, ws_url, api_url}

为啥 user_register 要每次都跑：
  OpenIM user_register 是幂等的（已存在不会报错），调用代价小（一次内部 RPC）。
  避免我们维护"哪些用户已注册过"的状态——保持后端无状态，重启 / 多副本都不影响。

admin_token 缓存：
  一次签 7 天有效。模块内存缓存 + 兜底过期就重签。
"""

import json
import time
import logging
import threading
import requests
from flask import jsonify, request
from auth import require_auth, _service_headers
from config import (
    OPENIM_API_URL,
    OPENIM_WS_URL,
    OPENIM_SECRET,
    OPENIM_PLATFORM_WEB,
    OPENIM_WEBHOOK_SECRET,
    SUPABASE_URL,
)
from database import db_execute, db_query
import push

logger = logging.getLogger(__name__)

# ── admin token 缓存 ──
_admin_token_cache = {"token": None, "expires_at": 0.0}
_admin_token_lock = threading.Lock()


def _new_operation_id() -> str:
    """OpenIM API 要求每个请求带 operationID（用作日志追踪），随手用时间戳"""
    return f"backend-{int(time.time() * 1000)}"


def _post_openim(path: str, body: dict, *, admin_token: str = None, timeout: int = 10) -> dict:
    """POST 调 OpenIM API。统一错误处理。

    OpenIM 响应格式：{"errCode": 0, "errMsg": "", "errDlt": "", "data": {...}}
    errCode == 0 表示成功，否则失败。
    """
    headers = {
        "Content-Type": "application/json",
        "operationID": _new_operation_id(),
    }
    if admin_token:
        headers["token"] = admin_token

    url = f"{OPENIM_API_URL.rstrip('/')}{path}"
    resp = requests.post(url, json=body, headers=headers, timeout=timeout)

    if resp.status_code != 200:
        raise RuntimeError(f"OpenIM {path} HTTP {resp.status_code}: {resp.text[:200]}")

    data = resp.json()
    if data.get("errCode", -1) != 0:
        raise RuntimeError(f"OpenIM {path} errCode={data.get('errCode')} errMsg={data.get('errMsg')}")

    return data.get("data", {})


def _get_admin_token(force_refresh: bool = False) -> str:
    """拿（或刷新）admin token。线程安全 + 缓存。"""
    now = time.time()
    if not force_refresh:
        with _admin_token_lock:
            if _admin_token_cache["token"] and _admin_token_cache["expires_at"] > now + 60:
                return _admin_token_cache["token"]

    # 重新签：用 secret 换 admin token（userID=imAdmin，platformID=平台号无所谓）
    data = _post_openim(
        "/auth/get_admin_token",
        {
            "secret": OPENIM_SECRET,
            "userID": "imAdmin",  # OpenIM 默认管理员 ID（v3.8 默认）
        },
    )
    token = data.get("token")
    if not token:
        raise RuntimeError(f"OpenIM admin token 响应缺 token 字段: {data}")
    # OpenIM token 默认 7 天，保守按 6 天缓存
    expires_at = now + 6 * 86400
    with _admin_token_lock:
        _admin_token_cache["token"] = token
        _admin_token_cache["expires_at"] = expires_at
    logger.info(f"[IM] 刷新 admin token 成功，缓存 6 天")
    return token


def _ensure_user_registered(user_id: str, *, nickname: str = "", face_url: str = "", admin_token: str = None) -> None:
    """确保 OpenIM 里有这个用户。已存在的会报错 — 我们把"已存在"当成功处理。

    OpenIM v3.8 user_register 协议：
      POST /user/user_register
      body: { "users": [ { "userID": "...", "nickname": "...", "faceURL": "..." } ], "secret": "..." }
      （注意：v3.8 这里直接吃 secret，不一定要 admin token；我们两个都带稳一点）
    """
    if admin_token is None:
        admin_token = _get_admin_token()

    body = {
        "secret": OPENIM_SECRET,
        "users": [
            {
                "userID": user_id,
                "nickname": nickname or user_id[:8],  # 默认显示 ID 前 8 位
                "faceURL": face_url or "",
            }
        ],
    }
    try:
        _post_openim("/user/user_register", body, admin_token=admin_token)
    except RuntimeError as e:
        msg = str(e).lower()
        # OpenIM 里"已存在"会报 errCode=1102 之类。我们当作成功
        if "1102" in msg or "exist" in msg or "registered" in msg:
            return
        raise


def _sign_user_token(user_id: str, platform_id: int, admin_token: str = None) -> str:
    """给 user 签一个 IM token（业务后端代签，客户端只拿到这个 token，不接触 secret）"""
    if admin_token is None:
        admin_token = _get_admin_token()

    data = _post_openim(
        "/auth/get_user_token",
        {
            "secret": OPENIM_SECRET,
            "platformID": platform_id,
            "userID": user_id,
        },
        admin_token=admin_token,
    )
    token = data.get("token")
    if not token:
        raise RuntimeError(f"OpenIM get_user_token 响应缺 token 字段: {data}")
    return token


# ============================================================
# Flask 路由
# ============================================================

def _to_im_user_id(supabase_user_id: str) -> str:
    """Supabase UUID → OpenIM userID。去掉 hyphen（OpenIM 拒绝含 - 的 userID）"""
    return (supabase_user_id or "").replace("-", "")


@require_auth
def get_im_token():
    """
    POST /api/im/token

    Body (可选): { "platform": 1 }     # 1=iOS 2=Android 5=Web ...

    Returns 200:
      {
        "im_user_id": "...",     # Supabase UUID 去掉 - 后的形式（OpenIM userID 限制）
        "im_token": "...",
        "ws_url": "ws://...",
        "api_url": "http://...",
      }
    """
    user = request.supabase_user
    raw_user_id = str(user.get("id", ""))
    if not raw_user_id:
        return jsonify({"error": "Supabase 用户没有 id 字段"}), 500

    user_id = _to_im_user_id(raw_user_id)

    body = request.get_json(silent=True) or {}
    platform_id = int(body.get("platform", OPENIM_PLATFORM_WEB))

    # nickname / 头像 — 从 Supabase 用户元数据取
    meta = user.get("user_metadata", {}) or {}
    nickname = meta.get("username") or user.get("email", "").split("@")[0] or user_id[:8]
    face_url = meta.get("avatar_url", "") or ""

    try:
        admin_token = _get_admin_token()
        _ensure_user_registered(user_id, nickname=nickname, face_url=face_url, admin_token=admin_token)
        im_token = _sign_user_token(user_id, platform_id, admin_token=admin_token)
    except RuntimeError as e:
        # admin token 可能过期，强制刷一次再重试一次
        try:
            admin_token = _get_admin_token(force_refresh=True)
            _ensure_user_registered(user_id, nickname=nickname, face_url=face_url, admin_token=admin_token)
            im_token = _sign_user_token(user_id, platform_id, admin_token=admin_token)
        except RuntimeError as e2:
            logger.error(f"[IM] 取 token 失败 user={user_id}: {e2}")
            return jsonify({"error": f"OpenIM error: {e2}"}), 502

    return jsonify({
        "im_user_id": user_id,
        "im_token": im_token,
        "ws_url": OPENIM_WS_URL,
        "api_url": OPENIM_API_URL,
    })


@require_auth
def lookup_user():
    """
    GET /api/im/users/lookup?user_id=xxx

    把 OpenIM userID 映射回业务用户名 / 头像，给客户端的好友卡片用。
    传进来的 user_id 可能带 / 不带 hyphen，统一 strip 后再查 OpenIM。
    """
    target_user_id = _to_im_user_id((request.args.get("user_id") or "").strip())
    if not target_user_id:
        return jsonify({"error": "缺少 user_id 参数"}), 400

    try:
        admin_token = _get_admin_token()
        data = _post_openim(
            "/user/get_users_info",
            {"userIDs": [target_user_id]},
            admin_token=admin_token,
        )
    except RuntimeError as e:
        logger.error(f"[IM] lookup 失败 user={target_user_id}: {e}")
        return jsonify({"error": str(e)}), 502

    users = data.get("usersInfo") or data.get("users") or []
    if not users:
        return jsonify({"error": "用户不存在"}), 404

    u = users[0]
    return jsonify({
        "user_id": u.get("userID", target_user_id),
        "nickname": u.get("nickname", ""),
        "face_url": u.get("faceURL", ""),
    })


# ============================================================
# 用户搜索（加好友用）
# ============================================================

# 缓存 Supabase 用户表，60 秒过期一次
# 因为 admin/users 接口没有"模糊搜索"参数，得拉全表然后内存里 filter。
# 几十-几百用户量级 OK，上千就要换成数据库直接查。
_users_cache = {"users": None, "expires_at": 0.0}
_users_cache_lock = threading.Lock()
_USERS_CACHE_TTL = 60.0


def _list_supabase_users(force_refresh: bool = False):
    """拉 Supabase 全部用户。带缓存，避免每次搜索都打 Admin API"""
    now = time.time()
    if not force_refresh:
        with _users_cache_lock:
            if _users_cache["users"] is not None and _users_cache["expires_at"] > now:
                return _users_cache["users"]

    # Supabase Admin API 默认 50 条 / 页，per_page 最大 1000
    resp = requests.get(
        f"{SUPABASE_URL}/auth/v1/admin/users",
        headers=_service_headers(),
        params={"per_page": 1000},
        timeout=10,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"Supabase admin/users HTTP {resp.status_code}: {resp.text[:200]}")

    users = resp.json().get("users", [])
    with _users_cache_lock:
        _users_cache["users"] = users
        _users_cache["expires_at"] = now + _USERS_CACHE_TTL
    return users


@require_auth
def search_users():
    """
    GET /api/im/users/search?q=xxx[&limit=20]

    给"加好友"的搜索框用：
      - q 是 email 前缀 / username 前缀 / 完整 user_id（带或不带 hyphen 都行）
      - 三种字段都试一遍，模糊匹配（ILIKE %q%），合并结果
      - 排除当前登录用户自己
      - 默认返回前 20 条

    每条返回：
      { im_user_id, nickname, email, face_url }
        im_user_id 是去掉 - 的形式，可直接用于 OpenIM 操作。
    """
    q = (request.args.get("q") or "").strip()
    if len(q) < 2:
        # 至少两个字符才搜，避免误触全列表
        return jsonify({"users": []})

    try:
        limit = max(1, min(50, int(request.args.get("limit", "20"))))
    except (TypeError, ValueError):
        limit = 20

    me_id = str(request.supabase_user.get("id", ""))
    me_im_id = _to_im_user_id(me_id)

    try:
        all_users = _list_supabase_users()
    except RuntimeError as e:
        logger.error(f"[IM] search users 拉表失败: {e}")
        return jsonify({"error": str(e)}), 502

    q_lower = q.lower()
    q_no_hyphen = q.replace("-", "").lower()

    matches = []
    for u in all_users:
        uid = str(u.get("id", ""))
        if uid == me_id:
            continue  # 排除自己

        email = (u.get("email") or "").lower()
        meta = u.get("user_metadata") or {}
        username = (meta.get("username") or "").lower()
        avatar_url = meta.get("avatar_url") or ""

        # 三种字段任一匹配就算命中
        hit = (
            (email and q_lower in email) or
            (username and q_lower in username) or
            (uid and q_no_hyphen in uid.replace("-", "").lower())
        )
        if not hit:
            continue

        matches.append({
            "im_user_id": _to_im_user_id(uid),
            "nickname": meta.get("username") or email.split("@")[0] or uid[:8],
            "email": u.get("email", ""),
            "face_url": avatar_url,
            # 一个相关性分数：完全匹配 > 前缀匹配 > 包含匹配，给客户端做排序参考
            "_rank": _rank_user(u, q_lower, q_no_hyphen, me_im_id),
        })
        if len(matches) >= limit * 2:  # 多搜一点再排序裁剪
            break

    matches.sort(key=lambda x: x["_rank"])
    matches = matches[:limit]
    for m in matches:
        m.pop("_rank", None)

    return jsonify({"users": matches})


def _rank_user(u, q_lower: str, q_no_hyphen: str, me_im_id: str) -> int:
    """越小越靠前。完全匹配 / 前缀 / 包含 各档分。"""
    uid = str(u.get("id", ""))
    email = (u.get("email") or "").lower()
    username = ((u.get("user_metadata") or {}).get("username") or "").lower()
    uid_no_hyphen = uid.replace("-", "").lower()

    # 完全匹配
    if uid_no_hyphen == q_no_hyphen or email == q_lower or username == q_lower:
        return 0
    # 前缀匹配
    if email.startswith(q_lower) or username.startswith(q_lower):
        return 1
    # 包含匹配
    return 2


# ============================================================
# APNs 推送 —— 客户端 token 上传 + OpenIM webhook 回调
# ============================================================

@require_auth
def upload_push_token():
    """
    POST /api/im/push_token

    Body: {
      "channel": "apns" | "fcm" | "getui" | ...,
      "token":   "<token string>",
      "meta":    { ... }    # 通道私有字段；APNs: {"env": "sandbox"|"production"}
    }

    UPSERT 主键 (user_id, channel, token)。同 user 可有多 row（多设备 / 多通道并存）。

    后端不维护 channel 白名单——以 push.is_supported() 为准，只允许已注册 provider。
    新增通道：在 backend/push/ 加 provider 模块即可，本接口不用改。
    """
    user = request.supabase_user
    raw_user_id = str(user.get("id", ""))
    if not raw_user_id:
        return jsonify({"error": "no user id"}), 500

    body = request.get_json(silent=True) or {}
    channel = (body.get("channel") or "").strip().lower()
    token = (body.get("token") or "").strip()
    meta = body.get("meta") or {}

    if not channel:
        return jsonify({"error": "channel 必填"}), 400
    if not push.is_supported(channel):
        return jsonify({
            "error": f"channel '{channel}' 暂不支持",
            "supported": push.supported_channels(),
        }), 400
    if not token or len(token) > 256:
        return jsonify({"error": "token 非法"}), 400
    if not isinstance(meta, dict):
        return jsonify({"error": "meta 必须是 object"}), 400

    db_execute(
        """
        INSERT INTO device_tokens (user_id, channel, token, channel_meta, updated_at)
        VALUES (%s, %s, %s, %s::jsonb, NOW())
        ON CONFLICT (user_id, channel, token)
        DO UPDATE SET channel_meta = EXCLUDED.channel_meta, updated_at = NOW()
        """,
        (raw_user_id, channel, token, json.dumps(meta)),
    )
    logger.info(
        f"[Push] token registered user={raw_user_id[:8]} channel={channel} meta={meta} ...{token[-8:]}"
    )
    return jsonify({"ok": True})


@require_auth
def remove_push_token():
    """
    DELETE /api/im/push_token

    Body: { "channel": "apns" | "fcm" | ..., "token": "<token>" }

    精确删 (user_id, channel, token) 这一行；用于客户端 logout / 切账号时清理。
    幂等：行不存在也返 ok（避免重复 logout 报错）。
    只删调用者自己的 row（user_id 来自 auth），不影响该 user 其他设备的 token。
    """
    user = request.supabase_user
    raw_user_id = str(user.get("id", ""))
    if not raw_user_id:
        return jsonify({"error": "no user id"}), 500

    body = request.get_json(silent=True) or {}
    channel = (body.get("channel") or "").strip().lower()
    token = (body.get("token") or "").strip()
    if not channel or not token:
        return jsonify({"error": "channel/token 必填"}), 400

    db_execute(
        "DELETE FROM device_tokens WHERE user_id=%s AND channel=%s AND token=%s",
        (raw_user_id, channel, token),
    )
    logger.info(
        f"[Push] token unregistered user={raw_user_id[:8]} channel={channel} ...{token[-8:]}"
    )
    return jsonify({"ok": True})


def _supabase_id_from_im_id(im_user_id: str) -> str | None:
    """OpenIM userID（去 hyphen 后的 32 hex） → Supabase user.id（带 hyphen 的 UUID）

    DB 里我们存的是 raw Supabase user.id（带 hyphen）。这里把 32 hex 重新插回 hyphen。
    标准 UUID 格式：8-4-4-4-12
    """
    s = (im_user_id or "").strip()
    if len(s) != 32 or "-" in s:
        return s or None  # 已经是 UUID 形式或者奇怪的 ID，原样返回
    return f"{s[0:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:32]}"


def _check_users_online(im_user_ids: list[str]) -> set[str]:
    """查 OpenIM 哪些 userID 当前在线。

    OpenIM API: POST /user/get_users_online_status
      body: { "userIDs": [...] }
      need: admin token
      resp.data.successResult: [
        {"userID": "...", "status": "online"|"offline", "detailPlatformStatus": [...]}
      ]

    返回 online 的 userID set。任何异常静默返空 set（fail-open：宁可多推也别漏推）
    """
    if not im_user_ids:
        return set()
    try:
        admin_token = _get_admin_token()
        data = _post_openim(
            "/user/get_users_online_status",
            {"userIDs": list(im_user_ids)},
            admin_token=admin_token,
        )
        # OpenIM 这个接口的 data 是 list 直接挂在 resp.data 上（不是 successResult）
        results = data if isinstance(data, list) else data.get("successResult") or []
        online = set()
        for item in results:
            uid = item.get("userID")
            if not uid:
                continue
            # status 是 "online" 或 "offline"；也兜底看 detailPlatformStatus 里有没有平台 online
            if item.get("status") == "online":
                online.add(uid)
                continue
            details = item.get("detailPlatformStatus") or []
            if any(d.get("status") == "online" for d in details):
                online.add(uid)
        return online
    except Exception as e:
        logger.warning(f"[Push] _check_users_online failed: {e} —— fail-open，全推")
        return set()


def _dispatch_to_user(*, sup_id: str, payload: push.PushPayload, log_prefix: str) -> int:
    """查 device_tokens 按 channel 派发推送，返回成功送达条数。

    expired_token=True → DELETE 掉那条 row（自愈，不需要后台任务清理）
    其他失败 → 记日志，不动 DB（下次推送会重试）

    通道无关：循环不知道也不关心 channel 是 apns/fcm/getui，全靠 push.dispatch 路由
    """
    rows = db_query(
        "SELECT channel, token, channel_meta FROM device_tokens WHERE user_id = %s",
        (sup_id,),
        fetch_all=True,
    ) or []

    pushed = 0
    for row in rows:
        channel = row.get("channel")
        token = row.get("token")
        # psycopg2 默认把 JSONB 解码成 dict；防御性兜底空字符串/None
        meta = row.get("channel_meta") or {}
        if isinstance(meta, str):
            try:
                meta = json.loads(meta) if meta else {}
            except Exception:
                meta = {}
        if not channel or not token:
            continue

        result = push.dispatch(channel=channel, token=token, meta=meta, payload=payload)
        if result.ok:
            pushed += 1
        elif result.expired_token:
            db_execute(
                "DELETE FROM device_tokens WHERE user_id=%s AND channel=%s AND token=%s",
                (sup_id, channel, token),
            )
            logger.info(
                f"{log_prefix} 已清理失效 token user={sup_id[:8]} channel={channel} ...{token[-8:]}"
            )
    return pushed


def offline_push_hook():
    """
    POST /api/im/offline_push_hook?secret=<OPENIM_WEBHOOK_SECRET>

    OpenIM 在用户离线收到消息时调这个接口（webhooks.yml 配置 beforeOfflinePush.enable=true）
    我们查 device_tokens，按每条 row 的 channel 派发到对应 provider（apns / fcm / getui ...）

    OpenIM v3.8 webhook payload 结构（实测）：
      {
        "callbackCommand": "callbackBeforeOfflinePushCommand",
        "operationID": "...",
        "platformID": 1,
        "userIDs": ["receiver1", "receiver2"],     ← OpenIM userID 形式（去 hyphen）
        "title": "...",
        "content": "...",
        "seq": 123,
        ...
      }

    返回：OpenIM 期望 { "errCode": 0 } 表示通过；其他状态码 OpenIM 会按 failedContinue 处理
    """
    # 简易共享密钥校验（OpenIM 不支持 Bearer header，只能 query 或自定义 header）
    # 同 after_send_msg：OpenIM 会拼 /callbackXxxCommand 到 URL 末尾，用 startswith
    secret_raw = request.args.get("secret") or request.headers.get("X-OpenIM-Webhook-Secret") or ""
    if not (secret_raw == OPENIM_WEBHOOK_SECRET or secret_raw.startswith(f"{OPENIM_WEBHOOK_SECRET}/")):
        return jsonify({"errCode": 1001, "errMsg": "bad secret"}), 401

    payload = request.get_json(silent=True) or {}
    receiver_im_ids = payload.get("userIDs") or []
    if not receiver_im_ids:
        # 单聊只有一个 recv：fallback
        recv = payload.get("recvID")
        if recv:
            receiver_im_ids = [recv]
    title = payload.get("title") or ""
    content = payload.get("content") or "你收到一条新消息"
    sender_nickname = payload.get("senderNickname") or ""
    conversation_id = payload.get("conversationID") or ""

    # 标题兜底：OpenIM 不一定会塞 title，自己拼一个
    if not title:
        title = sender_nickname or "新消息"

    pushed_count = 0
    for im_id in receiver_im_ids:
        sup_id = _supabase_id_from_im_id(im_id)
        if not sup_id:
            continue
        pushed_count += _dispatch_to_user(
            sup_id=sup_id,
            payload=push.PushPayload(
                title=title,
                body=content,
                custom={
                    "conversation_id": conversation_id,
                    "im_user_id": im_id,
                },
                collapse_id=conversation_id or None,
            ),
            log_prefix="[Push.offline_push_hook]",
        )

    logger.info(f"[Push] offline_push_hook: receivers={len(receiver_im_ids)} pushed={pushed_count}")
    # 返回 errCode=0，让 OpenIM 继续走它的 push 流程（即使我们成功了，OpenIM 内置 push
    # 也是 disabled 的，反正只走我们这一条）
    return jsonify({"errCode": 0, "errMsg": ""})


# 不同 contentType 的"消息正文"提取规则
# 参考 OpenIM message 协议：101=text, 102=picture, 103=voice, 104=video, 105=file, 106=@text...
def _extract_msg_body_for_push(content_type: int, content_str: str) -> str:
    """从 OpenIM content 字段（JSON 字符串）里提取要展示在推送 banner 上的正文。"""
    import json
    try:
        c = json.loads(content_str) if content_str else {}
    except Exception:
        c = {}
    if content_type == 101:                       # text
        return (c.get("content") or "").strip() or "新消息"
    if content_type in (102, 109):                # picture / card
        return "[图片]"
    if content_type == 103:                       # voice
        return "[语音]"
    if content_type == 104:                       # video
        return "[视频]"
    if content_type == 105:                       # file
        return "[文件]"
    if content_type == 106:                       # @ text
        return (c.get("text") or "").strip() or "[@消息]"
    if content_type == 110:                       # location
        return "[位置]"
    if content_type == 114:                       # merge
        return "[合并消息]"
    return "新消息"


def after_send_msg():
    """
    POST /api/im/after_send_msg?secret=<OPENIM_WEBHOOK_SECRET>

    OpenIM `afterSendSingleMsg` webhook —— 单聊每条消息发送后都会调一次，与
    收件人在线状态无关。我们这边自己查在线状态决定推不推（避免在线时双重打扰）。

    设计理由：v3.8 的 `beforeOfflinePush` 钩子写在 geTui/fcm/jpush provider 内部，
    没配 provider 就走不到。详见 PUSH_ARCHITECTURE.md。

    URL 约定坑：OpenIM 会自动在配置的 url 后面拼 `/<callbackCommand>`，比如
    `?secret=xxx` → `?secret=xxx/callbackAfterSendSingleMsgCommand`，所以 secret
    校验要 startswith / split，不能 `==`。

    OpenIM v3.8 afterSendSingleMsg payload（实测）：
      {
        "callbackCommand": "callbackAfterSendSingleMsgCommand",
        "operationID": "...",
        "sendID": "<sender im userID>",
        "recvID": "<receiver im userID>",
        "clientMsgID": "...", "serverMsgID": "...",
        "senderPlatformID": 1,
        "senderNickname": "...",
        "senderFaceURL": "https://...",
        "sessionType": 1,                  # 1=单聊 2=群 3=超级群
        "msgFrom": 100, "contentType": 101,
        "content": "{\\"content\\":\\"hi\\"}",   # JSON 字符串，结构随 contentType
        "seq": 37, "sendTime": 1777..., "createTime": 1777..., "status": 2,
        "ex": "..."
      }

    永远返回 `{errCode: 0}`，避免推送错误反阻塞 IM 主流程
    """
    # 校验共享密钥（OpenIM 会自动拼 /callbackXxxCommand 到 URL 末尾，
    # 导致 secret query 后面被加 "/callbackXxx"，所以用 startswith 而不是 ==）
    secret_raw = request.args.get("secret") or request.headers.get("X-OpenIM-Webhook-Secret") or ""
    if not (secret_raw == OPENIM_WEBHOOK_SECRET or secret_raw.startswith(f"{OPENIM_WEBHOOK_SECRET}/")):
        return jsonify({"errCode": 1001, "errMsg": "bad secret"}), 401

    payload = request.get_json(silent=True) or {}

    # OpenIM 一个 URL 接收所有 callback，靠 callbackCommand 字段区分。
    # 我们这个路由只处理 afterSendSingleMsg，其他 command 直接放过（很可能是
    # 配置时多开了 beforeSendSingleMsg 之类的副作用）
    cmd = payload.get("callbackCommand") or ""
    if cmd and cmd != "callbackAfterSendSingleMsgCommand":
        return jsonify({"errCode": 0, "errMsg": ""})

    # 只处理单聊（sessionType=1）。群消息走另一个 webhook（afterSendGroupMsg），暂不实现
    session_type = payload.get("sessionType")
    if session_type and session_type != 1:
        return jsonify({"errCode": 0, "errMsg": ""})

    send_id = payload.get("sendID") or ""
    recv_id = payload.get("recvID") or ""
    if not recv_id:
        return jsonify({"errCode": 0, "errMsg": ""})

    # 自己给自己发不推
    if send_id == recv_id:
        return jsonify({"errCode": 0, "errMsg": ""})

    sender_nickname = payload.get("senderNickname") or "新消息"
    content_type = int(payload.get("contentType") or 0)
    content_str = payload.get("content") or ""

    # 只推用户可见的消息类型，跳过 typing / 已读回执 / 系统通知 / custom 等
    # 101=text 102=picture 103=voice 104=video 105=file 106=@text 108=card
    # 109=location 114=quote
    PUSHABLE_CONTENT_TYPES = {101, 102, 103, 104, 105, 106, 108, 109, 114}
    if content_type not in PUSHABLE_CONTENT_TYPES:
        return jsonify({"errCode": 0, "errMsg": ""})

    body_text = _extract_msg_body_for_push(content_type, content_str)

    # 在线判断：在线就直接 short-circuit（OpenIM 自己会通过长连接送给在线 app）
    online = _check_users_online([recv_id])
    if recv_id in online:
        logger.info(f"[Push] after_send_msg: recv={recv_id[:8]} online，跳过")
        return jsonify({"errCode": 0, "errMsg": ""})

    # 离线：查 device_tokens 分发
    sup_id = _supabase_id_from_im_id(recv_id)
    if not sup_id:
        logger.info(f"[Push] after_send_msg: recv={recv_id[:8]} 无法换 supabase id")
        return jsonify({"errCode": 0, "errMsg": ""})

    # APNs collapse-id 上限 64 字节。用对话两端 user id 各取前 16 hex 拼，
    # 避免 si_<32hex>_<32hex> 超长被 Apple 拒（InvalidCollapseId）
    a, b = sorted([send_id, recv_id])
    conversation_id = f"si_{a[:16]}_{b[:16]}"   # 3 + 16 + 1 + 16 = 36 chars，安全

    pushed_count = _dispatch_to_user(
        sup_id=sup_id,
        payload=push.PushPayload(
            title=sender_nickname,
            body=body_text,
            custom={
                "conversation_id": conversation_id,
                "sender_id": send_id,
                "msg_seq": payload.get("seq"),
            },
            collapse_id=conversation_id,
        ),
        log_prefix="[Push.after_send_msg]",
    )

    logger.info(
        f"[Push] after_send_msg: send={send_id[:8]} recv={recv_id[:8]} "
        f"type={content_type} pushed={pushed_count}"
    )
    return jsonify({"errCode": 0, "errMsg": ""})
