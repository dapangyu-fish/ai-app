"""贴吧 FaaS 后端：公开论坛（吧 / 主题帖 / 回帖+楼中楼 / 搜索吧）。

身份：myapp_auth.current_user() = 当前调用者的应用内假名（已验证、不可伪造）。
公开内容用 myapp_db 裸 SQL（人人可读）；写入把 author/owner 强制成当前用户的假名，
所以谁都改不了别人的帖子/别人的显示名。显示名由客户端用真实平台昵称同步进 profiles。
值一律用 %s 占位（禁 f-string 拼 SQL）。
"""
from flask import Flask, request, jsonify
import myapp_db
import myapp_auth

app = Flask(__name__)


def _me():
    return myapp_auth.current_user()


def _need_login():
    return jsonify({"error": "login required"}), 401


def _sync_name(me, body):
    """把调用者自报的真实昵称写进自己的 profiles 行（只能改自己的）。"""
    name = str((body or {}).get("display_name") or "").strip()[:64]
    if me and name:
        myapp_db.execute(
            "INSERT INTO profiles (owner_id, display_name, updated_at) VALUES (%s, %s, now()) "
            "ON CONFLICT (owner_id) DO UPDATE SET display_name = EXCLUDED.display_name, updated_at = now()",
            [me, name],
        )


@app.get("/whoami")
def whoami():
    me = _me()
    row = myapp_db.queryone("SELECT display_name FROM profiles WHERE owner_id = %s", [me]) if me else None
    return jsonify({"me": me or "", "display_name": (row or {}).get("display_name", ""), "logged_in": bool(me)})


@app.post("/me")
def set_me():
    me = _me()
    if not me:
        return _need_login()
    _sync_name(me, request.get_json(silent=True) or {})
    return jsonify({"ok": True})


# ── 吧 ──

@app.get("/boards")
def list_boards():
    q = str(request.args.get("q") or "").strip()
    if q:
        rows = myapp_db.query(
            "SELECT b.id, b.name, b.intro, b.created_at, COALESCE(p.display_name,'') AS owner_name, "
            "(SELECT count(*) FROM threads t WHERE t.board_id = b.id) AS thread_count "
            "FROM boards b LEFT JOIN profiles p ON p.owner_id = b.owner_id "
            "WHERE b.name ILIKE %s ORDER BY b.created_at DESC LIMIT 100",
            ["%" + q + "%"],
        )
    else:
        rows = myapp_db.query(
            "SELECT b.id, b.name, b.intro, b.created_at, COALESCE(p.display_name,'') AS owner_name, "
            "(SELECT count(*) FROM threads t WHERE t.board_id = b.id) AS thread_count "
            "FROM boards b LEFT JOIN profiles p ON p.owner_id = b.owner_id "
            "ORDER BY b.created_at DESC LIMIT 100",
        )
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
    _sync_name(me, body)
    exists = myapp_db.queryone("SELECT id FROM boards WHERE name = %s", [name])
    if exists:
        return jsonify({"error": "该吧已存在"}), 409
    row = myapp_db.queryone(
        "INSERT INTO boards (name, intro, owner_id) VALUES (%s, %s, %s) RETURNING id, name, intro, created_at",
        [name, str(body.get("intro") or "").strip()[:200], me],
    )
    return jsonify({"board": row, "is_owner": True})


@app.get("/board")
def get_board():
    bid = str(request.args.get("board_id") or "").strip()
    b = myapp_db.queryone(
        "SELECT b.id, b.name, b.intro, b.owner_id, b.created_at, COALESCE(p.display_name,'') AS owner_name "
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
    rows = myapp_db.query(
        "SELECT t.id, t.title, t.body, t.reply_count, t.created_at, COALESCE(p.display_name,'') AS author_name "
        "FROM threads t LEFT JOIN profiles p ON p.owner_id = t.author_id "
        "WHERE t.board_id = %s ORDER BY t.created_at DESC LIMIT 100",
        [bid],
    )
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
    _sync_name(me, body)
    if not myapp_db.queryone("SELECT id FROM boards WHERE id = %s", [bid]):
        return jsonify({"error": "吧不存在"}), 404
    row = myapp_db.queryone(
        "INSERT INTO threads (board_id, author_id, title, body) VALUES (%s, %s, %s, %s) "
        "RETURNING id, title, body, created_at",
        [bid, me, title, str(body.get("body") or "").strip()[:5000]],
    )
    return jsonify({"thread": row})


@app.get("/thread")
def get_thread():
    tid = str(request.args.get("thread_id") or "").strip()
    t = myapp_db.queryone(
        "SELECT t.id, t.board_id, t.title, t.body, t.created_at, t.author_id, "
        "COALESCE(p.display_name,'') AS author_name "
        "FROM threads t LEFT JOIN profiles p ON p.owner_id = t.author_id WHERE t.id = %s",
        [tid],
    )
    if not t:
        return jsonify({"error": "帖子不存在"}), 404
    # 全部回帖一次取出（含楼中楼），后端按 parent_id 做先序 DFS 排好序并标 depth，
    # 客户端只要按 depth 缩进渲染一个扁平列表，即可呈现无限层级的楼中楼。
    rows = myapp_db.query(
        "SELECT po.id, po.parent_id, po.body, po.created_at, po.author_id, "
        "COALESCE(p.display_name,'') AS author_name "
        "FROM posts po LEFT JOIN profiles p ON p.owner_id = po.author_id "
        "WHERE po.thread_id = %s ORDER BY po.created_at ASC LIMIT 2000",
        [tid],
    )
    children = {}
    for r in rows:
        children.setdefault(r.get("parent_id"), []).append(r)
    ordered = []
    # 迭代式 DFS（不递归，避免深层栈问题）。栈里放 (节点, 深度)，倒序压栈保证时间正序。
    stack = [(r, 0) for r in reversed(children.get(None, []))]
    seen = set()
    while stack:
        node, depth = stack.pop()
        nid = node.get("id")
        if nid in seen:
            continue
        seen.add(nid)
        capped = depth if depth < 12 else 12  # 数据无限层级，视觉缩进封顶防溢出
        node["depth"] = capped
        node["indent"] = capped * 14  # 客户端直接用作 paddingLeft（像素）
        ordered.append(node)
        kids = children.get(nid, [])
        for k in reversed(kids):
            stack.append((k, depth + 1))
    return jsonify({"thread": t, "posts": ordered})


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
    _sync_name(me, body)
    if not myapp_db.queryone("SELECT id FROM threads WHERE id = %s", [tid]):
        return jsonify({"error": "帖子不存在"}), 404
    parent = str(body.get("parent_id") or "").strip() or None
    if parent and not myapp_db.queryone("SELECT id FROM posts WHERE id = %s AND thread_id = %s", [parent, tid]):
        return jsonify({"error": "回复目标不存在"}), 404
    row = myapp_db.queryone(
        "INSERT INTO posts (thread_id, parent_id, author_id, body) VALUES (%s, %s, %s, %s) "
        "RETURNING id, parent_id, body, created_at",
        [tid, parent, me, text],
    )
    myapp_db.execute("UPDATE threads SET reply_count = reply_count + 1 WHERE id = %s", [tid])
    return jsonify({"post": row})


@app.delete("/posts")
def delete_post():
    me = _me()
    if not me:
        return _need_login()
    pid = str(request.args.get("post_id") or "").strip()
    # 只能删自己的回帖（author_id 强制等于调用者）——防止改/删别人的
    n = myapp_db.execute("DELETE FROM posts WHERE id = %s AND author_id = %s", [pid, me])
    if not n:
        return jsonify({"error": "无权删除或不存在"}), 403
    return jsonify({"ok": True})
