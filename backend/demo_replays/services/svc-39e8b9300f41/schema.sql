-- 论坛 FaaS 后端 schema：吧 / 主题 / 回帖 / 点赞 + 用户身份 + 好友 + 私信
-- 主键一律 UUID；公开内容公开可读；写入强制 author_id/owner_id = current_user()

-- ── 论坛 ──

-- 吧（讨论区）：任意登录用户可创建，创建者即吧主
CREATE TABLE IF NOT EXISTS boards (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,
  intro       text NOT NULL DEFAULT '',
  owner_id    text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 主题帖
CREATE TABLE IF NOT EXISTS threads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id    uuid NOT NULL,
  author_id   text NOT NULL,
  title       text NOT NULL,
  body        text NOT NULL DEFAULT '',
  like_count  integer NOT NULL DEFAULT 0,
  reply_count integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 回帖 + 楼中楼（parent_id NULL=楼层，非NULL=楼中楼）
CREATE TABLE IF NOT EXISTS posts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   uuid NOT NULL,
  parent_id   uuid,
  author_id   text NOT NULL,
  body        text NOT NULL,
  like_count  integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 点赞（多态：可赞主题也可赞回帖）
CREATE TABLE IF NOT EXISTS likes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     text NOT NULL,
  target_type text NOT NULL,
  target_id   uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT likes_target_chk CHECK (target_type IN ('thread','post')),
  CONSTRAINT likes_user_target_uniq UNIQUE (user_id, target_type, target_id)
);

-- ── 身份 ──

CREATE TABLE IF NOT EXISTS profiles (
  owner_id     text PRIMARY KEY,
  display_name text NOT NULL DEFAULT '',
  avatar_url   text NOT NULL DEFAULT '',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ── 社交 ──

CREATE TABLE IF NOT EXISTS friendships (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id  text NOT NULL,
  addressee_id  text NOT NULL,
  status        text NOT NULL DEFAULT 'pending',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT friendships_status_chk CHECK (status IN ('pending','accepted')),
  CONSTRAINT friendships_pair_uniq UNIQUE (requester_id, addressee_id)
);

CREATE TABLE IF NOT EXISTS messages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id     text NOT NULL,
  recipient_id  text NOT NULL,
  body          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_boards_name      ON boards (name);
CREATE INDEX IF NOT EXISTS idx_threads_board    ON threads (board_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_threads_author   ON threads (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_thread     ON posts (thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_posts_parent     ON posts (parent_id);
CREATE INDEX IF NOT EXISTS idx_likes_target     ON likes (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_likes_user       ON likes (user_id, target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_friend_requester ON friendships (requester_id);
CREATE INDEX IF NOT EXISTS idx_friend_addressee ON friendships (addressee_id, status);
CREATE INDEX IF NOT EXISTS idx_messages_pair    ON messages (sender_id, recipient_id, created_at);
