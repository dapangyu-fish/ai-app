"""论坛 FaaS 后端：吧 / 主题 / 楼中楼回帖 / 点赞 + 用户主页 + 好友 + 私信。

身份：myapp_auth.current_user() = 当前调用者的组内假名（已验证、不可伪造）。
公开内容用 myapp_db 裸 SQL（人人可读）；写入把 author/owner 强制成当前用户的假名。
显示名 + 头像由客户端用真实平台信息同步进 profiles。
值一律用 %s 占位（禁 f-string 拼 SQL）。
"""
from flask import Flask, request, jsonify
import myapp_db
import myapp_auth

app = Flask(__name__)

INDENT_PX = 16
INDENT_CAP = 12
COLLAPSE_AFTER = 2


def _me():
    return myapp_auth.current_user()


def _need_login():
    return jsonify({"error": "login required"}), 401


def _sync_profile(me, body):
    """把调用者自报的真实昵称和头像写进自己的 profiles 行（只能改自己的）。"""
    name = str((body or {}).get("display_name") or "").strip()[:64]
    avatar = str((body or {}).get("avatar_url") or "").strip()[:512]
    if me and (name or avatar):
        myapp_db.execute(
            "INSERT INTO profiles (owner_id, display_name, avatar_url, updated_at) VALUES (%s, %s, %s, now()) "
            "ON CONFLICT (owner_id) DO UPDATE SET display_name = EXCLUDED.display_name, "
            "avatar_url = EXCLUDED.avatar_url, updated_at = now()",
            [me, name, avatar],
        )


def _name_of(owner_id):
    if not owner_id:
        return ""
    row = myapp_db.queryone("SELECT display_name FROM profiles WHERE owner_id = %s", [owner_id])
    return (row or {}).get("display_name", "") or ""


def _avatar_of(owner_id):
    if not owner_id:
        return ""
    row = myapp_db.queryone("SELECT avatar_url FROM profiles WHERE owner_id = %s", [owner_id])
    return (row or {}).get("avatar_url", "") or ""


def _are_friends(a, b):
    if not a or not b:
        return False
    row = myapp_db.queryone(
        "SELECT 1 FROM friendships WHERE status = 'accepted' AND "
        "((requester_id = %s AND addressee_id = %s) OR (requester_id = %s AND addressee_id = %s)) LIMIT 1",
        [a, b, b, a],
    )
    return bool(row)


def _liked_by_me(me, target_type, target_ids):
    """返回当前用户点赞过的 target_id 集合。"""
    if not me or not target_ids:
        return set()
    placeholders = ",".join(["%s"] * len(target_ids))
    rows = myapp_db.query(
        "SELECT target_id FROM likes WHERE user_id=%s AND target_type=%s AND target_id IN (" + placeholders + ")",
        [me, target_type] + target_ids,
    )
    return {r["target_id"] for r in rows}


# ── 身份 ──

@app.get("/whoami")
def whoami():
    me = _me()
    return jsonify({
        "me": me or "",
        "display_name": _name_of(me),
        "avatar_url": _avatar_of(me),
        "logged_in": bool(me),
    })


@app.post("/me")
def set_me():
    me = _me()
    if not me:
        return _need_login()
    _sync_profile(me, request.get_json(silent=True) or {})
    return jsonify({"ok": True})


# ── 吧 ──

@app.get("/boards")
def list_boards():
    q = str(request.args.get("q") or "").strip()
    base = (
        "SELECT b.id, b.name, b.intro, b.created_at, b.owner_id, "
        "COALESCE(p.display_name,'') AS owner_name, COALESCE(p.avatar_url,'') AS owner_avatar, "
        "(SELECT count(*) FROM threads t WHERE t.board_id = b.id) AS thread_count "
        "FROM boards b LEFT JOIN profiles p ON p.owner_id = b.owner_id "
    )
    if q:
        rows = myapp_db.query(base + "WHERE b.name ILIKE %s ORDER BY b.created_at DESC LIMIT 100", ["%" + q + "%"])
    else:
        rows = myapp_db.query(base + "ORDER BY b.created_at DESC LIMIT 100")
    return jsonify({"boards": rows})


@app.post("/boards")
def create_board():
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    name = str(body.get("name") or "").strip()[:32]
    if not name:
        return jsonify({"error": "吧名不能为空"}), 400
    _sync_profile(me, body)
    if myapp_db.queryone("SELECT id FROM boards WHERE name = %s", [name]):
        return jsonify({"error": "该吧已存在"}), 409
    row = myapp_db.queryone(
        "INSERT INTO boards (name, intro, owner_id) VALUES (%s, %s, %s) RETURNING id, name, intro, created_at",
        [name, str(body.get("intro") or "").strip()[:200], me],
    )
    row["owner_name"] = _name_of(me)
    return jsonify({"board": row, "is_owner": True})


@app.get("/board")
def get_board():
    bid = str(request.args.get("board_id") or "").strip()
    b = myapp_db.queryone(
        "SELECT b.id, b.name, b.intro, b.owner_id, b.created_at, "
        "COALESCE(p.display_name,'') AS owner_name, COALESCE(p.avatar_url,'') AS owner_avatar "
        "FROM boards b LEFT JOIN profiles p ON p.owner_id = b.owner_id WHERE b.id = %s",
        [bid],
    )
    if not b:
        return jsonify({"error": "吧不存在"}), 404
    b["is_owner"] = (_me() == b.get("owner_id"))
    return jsonify({"board": b})


# ── 主题帖 ──

@app.get("/threads")
def list_threads():
    bid = str(request.args.get("board_id") or "").strip()
    me = _me()
    rows = myapp_db.query(
        "SELECT t.id, t.board_id, t.author_id, t.title, t.body, t.like_count, t.reply_count, t.created_at, "
        "COALESCE(p.display_name,'') AS author_name, COALESCE(p.avatar_url,'') AS author_avatar "
        "FROM threads t LEFT JOIN profiles p ON p.owner_id = t.author_id "
        "WHERE t.board_id = %s ORDER BY t.created_at DESC LIMIT 100",
        [bid],
    )
    liked = _liked_by_me(me, "thread", [r["id"] for r in rows])
    for r in rows:
        r["liked_by_me"] = (r["id"] in liked)
    return jsonify({"threads": rows})


@app.post("/threads")
def create_thread():
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    bid = str(body.get("board_id") or "").strip()
    title = str(body.get("title") or "").strip()[:120]
    if not bid or not title:
        return jsonify({"error": "板块和标题必填"}), 400
    _sync_profile(me, body)
    if not myapp_db.queryone("SELECT id FROM boards WHERE id = %s", [bid]):
        return jsonify({"error": "吧不存在"}), 404
    row = myapp_db.queryone(
        "INSERT INTO threads (board_id, author_id, title, body) VALUES (%s, %s, %s, %s) "
        "RETURNING id, title, body, like_count, reply_count, created_at",
        [bid, me, title, str(body.get("body") or "").strip()[:5000]],
    )
    row["author_name"] = _name_of(me)
    row["author_avatar"] = _avatar_of(me)
    row["author_id"] = me
    row["liked_by_me"] = False
    return jsonify({"thread": row})


def _flatten_thread(rows, expanded):
    """把回帖按楼中楼树形先序拍平成一个扁平列表（客户端按 indent 缩进渲染）。"""
    expanded = set(expanded or [])
    children = {}
    for r in rows:
        children.setdefault(r.get("parent_id"), []).append(r)

    def frames_for(parent_id, depth, is_root):
        kids = children.get(parent_id, [])
        out = []
        show_all = is_root or len(kids) <= COLLAPSE_AFTER or (parent_id in expanded)
        if show_all:
            for k in kids:
                out.append(("node", k, depth))
            if (not is_root) and len(kids) > COLLAPSE_AFTER:
                out.append(("collapse", parent_id, depth))
        else:
            for k in kids[:COLLAPSE_AFTER]:
                out.append(("node", k, depth))
            out.append(("more", parent_id, depth, len(kids) - COLLAPSE_AFTER))
        return out

    ordered, seen = [], set()
    stack = list(reversed(frames_for(None, 0, True)))
    while stack:
        f = stack.pop()
        kind = f[0]
        if kind == "node":
            _, node, depth = f
            nid = node.get("id")
            if nid in seen:
                continue
            seen.add(nid)
            cap = depth if depth < INDENT_CAP else INDENT_CAP
            node["kind"] = "post"
            node["depth"] = cap
            node["indent"] = cap * INDENT_PX
            node["is_floor"] = (depth == 0)
            node["floor_label"] = "楼层" if depth == 0 else "楼中楼"
            ordered.append(node)
            for cf in reversed(frames_for(nid, depth + 1, False)):
                stack.append(cf)
        else:
            parent_id = f[1]
            depth = f[2]
            cap = depth if depth < INDENT_CAP else INDENT_CAP
            marker = {
                "id": kind + "-" + str(parent_id), "kind": kind, "parent_id": parent_id,
                "depth": cap, "indent": cap * INDENT_PX,
            }
            if kind == "more":
                marker["remaining"] = f[3]
            ordered.append(marker)
    return ordered


@app.get("/thread")
def get_thread():
    tid = str(request.args.get("thread_id") or "").strip()
    expanded = [x for x in str(request.args.get("expanded") or "").split(",") if x]
    me = _me()
    t = myapp_db.queryone(
        "SELECT t.id, t.board_id, t.title, t.body, t.like_count, t.reply_count, t.created_at, t.author_id, "
        "COALESCE(p.display_name,'') AS author_name, COALESCE(p.avatar_url,'') AS author_avatar "
        "FROM threads t LEFT JOIN profiles p ON p.owner_id = t.author_id WHERE t.id = %s",
        [tid],
    )
    if not t:
        return jsonify({"error": "帖子不存在"}), 404
    t["liked_by_me"] = bool(_liked_by_me(me, "thread", [tid]))
    rows = myapp_db.query(
        "SELECT po.id, po.parent_id, po.body, po.like_count, po.created_at, po.author_id, "
        "COALESCE(p.display_name,'') AS author_name, COALESCE(p.avatar_url,'') AS author_avatar "
        "FROM posts po LEFT JOIN profiles p ON p.owner_id = po.author_id "
        "WHERE po.thread_id = %s ORDER BY po.created_at ASC LIMIT 2000",
        [tid],
    )
    post_ids = [r["id"] for r in rows]
    liked_post_ids = _liked_by_me(me, "post", post_ids)
    flattened = _flatten_thread(rows, expanded)
    for item in flattened:
        if item.get("kind") == "post":
            item["liked_by_me"] = (item["id"] in liked_post_ids)
    return jsonify({"thread": t, "posts": flattened})


# ── 回帖 + 楼中楼 ──

@app.post("/posts")
def create_post():
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    tid = str(body.get("thread_id") or "").strip()
    text = str(body.get("body") or "").strip()[:5000]
    if not tid or not text:
        return jsonify({"error": "内容必填"}), 400
    _sync_profile(me, body)
    if not myapp_db.queryone("SELECT id FROM threads WHERE id = %s", [tid]):
        return jsonify({"error": "帖子不存在"}), 404
    parent = str(body.get("parent_id") or "").strip() or None
    if parent and not myapp_db.queryone("SELECT id FROM posts WHERE id = %s AND thread_id = %s", [parent, tid]):
        return jsonify({"error": "回复目标不存在"}), 404
    row = myapp_db.queryone(
        "INSERT INTO posts (thread_id, parent_id, author_id, body) VALUES (%s, %s, %s, %s) "
        "RETURNING id, parent_id, body, like_count, created_at",
        [tid, parent, me, text],
    )
    myapp_db.execute("UPDATE threads SET reply_count = reply_count + 1 WHERE id = %s", [tid])
    row["author_name"] = _name_of(me)
    row["author_avatar"] = _avatar_of(me)
    row["author_id"] = me
    row["kind"] = "post"
    row["liked_by_me"] = False
    return jsonify({"post": row})


@app.delete("/posts")
def delete_post():
    me = _me()
    if not me:
        return _need_login()
    pid = str(request.args.get("post_id") or "").strip()
    n = myapp_db.execute("DELETE FROM posts WHERE id = %s AND author_id = %s", [pid, me])
    if not n:
        return jsonify({"error": "无权删除或不存在"}), 403
    return jsonify({"ok": True})


# ── 点赞 ──

@app.post("/likes")
def like():
    """点赞一个主题帖或回帖。target_type: 'thread' | 'post'"""
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    target_type = str(body.get("target_type") or "").strip()
    target_id = str(body.get("target_id") or "").strip()
    if target_type not in ("thread", "post") or not target_id:
        return jsonify({"error": "参数错误"}), 400

    # upsert 点赞记录
    myapp_db.execute(
        "INSERT INTO likes (user_id, target_type, target_id) VALUES (%s, %s, %s) "
        "ON CONFLICT (user_id, target_type, target_id) DO NOTHING",
        [me, target_type, target_id],
    )
    # 更新对应目标的计数
    table = "threads" if target_type == "thread" else "posts"
    myapp_db.execute(
        "UPDATE " + table + " SET like_count = (SELECT count(*) FROM likes WHERE target_type=%s AND target_id=%s) WHERE id=%s",
        [target_type, target_id, target_id],
    )
    row = myapp_db.queryone("SELECT like_count FROM " + table + " WHERE id=%s", [target_id])
    return jsonify({"ok": True, "like_count": (row or {}).get("like_count", 0)})


@app.delete("/likes")
def unlike():
    """取消点赞。"""
    me = _me()
    if not me:
        return _need_login()
    target_type = str(request.args.get("target_type") or "").strip()
    target_id = str(request.args.get("target_id") or "").strip()
    if target_type not in ("thread", "post") or not target_id:
        return jsonify({"error": "参数错误"}), 400

    myapp_db.execute(
        "DELETE FROM likes WHERE user_id=%s AND target_type=%s AND target_id=%s",
        [me, target_type, target_id],
    )
    table = "threads" if target_type == "thread" else "posts"
    myapp_db.execute(
        "UPDATE " + table + " SET like_count = (SELECT count(*) FROM likes WHERE target_type=%s AND target_id=%s) WHERE id=%s",
        [target_type, target_id, target_id],
    )
    row = myapp_db.queryone("SELECT like_count FROM " + table + " WHERE id=%s", [target_id])
    return jsonify({"ok": True, "like_count": (row or {}).get("like_count", 0)})


# ── 用户主页 ──

@app.get("/user")
def get_user():
    uid = str(request.args.get("owner_id") or "").strip()
    if not uid:
        return jsonify({"error": "缺少 owner_id"}), 400
    me = _me()
    stats = myapp_db.queryone(
        "SELECT (SELECT count(*) FROM boards  WHERE owner_id  = %s) AS board_count, "
        "       (SELECT count(*) FROM threads WHERE author_id = %s) AS thread_count, "
        "       (SELECT count(*) FROM posts   WHERE author_id = %s) AS post_count",
        [uid, uid, uid],
    ) or {}
    threads = myapp_db.query(
        "SELECT t.id, t.title, t.like_count, t.reply_count, t.created_at, "
        "COALESCE(b.name,'') AS board_name "
        "FROM threads t LEFT JOIN boards b ON b.id = t.board_id "
        "WHERE t.author_id = %s ORDER BY t.created_at DESC LIMIT 30",
        [uid],
    )
    rel = {"is_self": me == uid, "is_friend": False, "outgoing_pending": False, "incoming_pending": False}
    if me and me != uid:
        rel["is_friend"] = _are_friends(me, uid)
        if not rel["is_friend"]:
            out = myapp_db.queryone(
                "SELECT 1 FROM friendships WHERE status='pending' AND requester_id=%s AND addressee_id=%s",
                [me, uid],
            )
            inc = myapp_db.queryone(
                "SELECT 1 FROM friendships WHERE status='pending' AND requester_id=%s AND addressee_id=%s",
                [uid, me],
            )
            rel["outgoing_pending"] = bool(out)
            rel["incoming_pending"] = bool(inc)
    return jsonify({
        "user": {
            "owner_id": uid,
            "display_name": _name_of(uid),
            "avatar_url": _avatar_of(uid),
            "board_count": stats.get("board_count", 0),
            "thread_count": stats.get("thread_count", 0),
            "post_count": stats.get("post_count", 0),
        },
        "threads": threads, "rel": rel,
    })


# ── 好友 ──

@app.get("/friends")
def list_friends():
    me = _me()
    if not me:
        return _need_login()
    rows = myapp_db.query(
        "SELECT CASE WHEN f.requester_id = %s THEN f.addressee_id ELSE f.requester_id END AS owner_id "
        "FROM friendships f WHERE f.status='accepted' AND (f.requester_id=%s OR f.addressee_id=%s)",
        [me, me, me],
    )
    friends = []
    for r in rows:
        oid = r.get("owner_id")
        friends.append({
            "owner_id": oid,
            "display_name": _name_of(oid),
            "avatar_url": _avatar_of(oid),
        })
    friends.sort(key=lambda x: x["display_name"] or x["owner_id"])
    return jsonify({"friends": friends})


@app.get("/friends/requests")
def list_requests():
    me = _me()
    if not me:
        return _need_login()
    rows = myapp_db.query(
        "SELECT requester_id, created_at FROM friendships "
        "WHERE status='pending' AND addressee_id=%s ORDER BY created_at DESC",
        [me],
    )
    reqs = [{
        "owner_id": r.get("requester_id"),
        "display_name": _name_of(r.get("requester_id")),
        "avatar_url": _avatar_of(r.get("requester_id")),
        "created_at": r.get("created_at"),
    } for r in rows]
    return jsonify({"requests": reqs, "count": len(reqs)})


@app.post("/friends/request")
def request_friend():
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    _sync_profile(me, body)
    target = str(body.get("to") or "").strip()
    if not target:
        return jsonify({"error": "缺少对象"}), 400
    if target == me:
        return jsonify({"error": "不能加自己为好友"}), 400
    if not myapp_db.queryone("SELECT 1 FROM profiles WHERE owner_id=%s", [target]):
        return jsonify({"error": "用户不存在"}), 404
    if _are_friends(me, target):
        return jsonify({"ok": True, "status": "accepted"})
    rev = myapp_db.queryone(
        "SELECT id FROM friendships WHERE status='pending' AND requester_id=%s AND addressee_id=%s",
        [target, me],
    )
    if rev:
        myapp_db.execute("UPDATE friendships SET status='accepted', updated_at=now() WHERE id=%s", [rev["id"]])
        return jsonify({"ok": True, "status": "accepted"})
    myapp_db.execute(
        "INSERT INTO friendships (requester_id, addressee_id, status) VALUES (%s, %s, 'pending') "
        "ON CONFLICT (requester_id, addressee_id) DO NOTHING",
        [me, target],
    )
    return jsonify({"ok": True, "status": "pending"})


@app.post("/friends/accept")
def accept_friend():
    me = _me()
    if not me:
        return _need_login()
    frm = str((request.get_json(silent=True) or {}).get("from") or "").strip()
    n = myapp_db.execute(
        "UPDATE friendships SET status='accepted', updated_at=now() "
        "WHERE status='pending' AND requester_id=%s AND addressee_id=%s",
        [frm, me],
    )
    if not n:
        return jsonify({"error": "没有待处理的请求"}), 404
    return jsonify({"ok": True})


@app.post("/friends/reject")
def reject_friend():
    me = _me()
    if not me:
        return _need_login()
    frm = str((request.get_json(silent=True) or {}).get("from") or "").strip()
    myapp_db.execute(
        "DELETE FROM friendships WHERE status='pending' AND requester_id=%s AND addressee_id=%s",
        [frm, me],
    )
    return jsonify({"ok": True})


# ── 私信 ──

@app.get("/dm")
def dm_history():
    me = _me()
    if not me:
        return _need_login()
    peer = str(request.args.get("peer") or "").strip()
    if not peer:
        return jsonify({"error": "缺少对象"}), 400
    if not _are_friends(me, peer):
        return jsonify({"error": "仅好友之间可私信", "messages": []}), 403
    rows = myapp_db.query(
        "SELECT id, sender_id, recipient_id, body, created_at FROM messages "
        "WHERE (sender_id=%s AND recipient_id=%s) OR (sender_id=%s AND recipient_id=%s) "
        "ORDER BY created_at ASC LIMIT 500",
        [me, peer, peer, me],
    )
    for r in rows:
        r["is_me"] = (r.get("sender_id") == me)
    return jsonify({
        "peer": {"owner_id": peer, "display_name": _name_of(peer), "avatar_url": _avatar_of(peer)},
        "messages": rows,
    })


@app.post("/dm")
def dm_send():
    me = _me()
    if not me:
        return _need_login()
    body = request.get_json(silent=True) or {}
    peer = str(body.get("to") or "").strip()
    text = str(body.get("body") or "").strip()[:2000]
    if not peer or not text:
        return jsonify({"error": "内容必填"}), 400
    if not _are_friends(me, peer):
        return jsonify({"error": "仅好友之间可私信"}), 403
    row = myapp_db.queryone(
        "INSERT INTO messages (sender_id, recipient_id, body) VALUES (%s, %s, %s) "
        "RETURNING id, sender_id, recipient_id, body, created_at",
        [me, peer, text],
    )
    row["is_me"] = True
    return jsonify({"message": row})
