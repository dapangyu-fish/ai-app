-- 广场社区 FaaS 后端 schema（公开内容论坛 + 身份 + 好友 + 私信）
-- 规则：UUID 主键（禁自增）；公开内容公开可读，写入记作者的组内假名
-- （author_id / owner_id = myapp_auth.current_user()，不可伪造）。
-- 好友 / 私信只在本服务组内、用组内假名互通（跨 App 关联不了同一个人，符合假名隔离）。
-- 部署期由属主角色执行；运行时角色只有 DML 权限（不能改表结构）。

-- ── 论坛 ──

-- 板块（分区）：任意登录用户可创建，创建者即版主
CREATE TABLE IF NOT EXISTS boards (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,          -- 板块名，全局唯一
  intro       text NOT NULL DEFAULT '',      -- 板块简介
  icon        text NOT NULL DEFAULT 'forum', -- 板块图标（客户端图标名）
  owner_id    text NOT NULL,                 -- 版主 = 创建者的组内假名
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 主题帖
CREATE TABLE IF NOT EXISTS threads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id    uuid NOT NULL,
  author_id   text NOT NULL,                 -- 发帖人假名
  title       text NOT NULL,
  body        text NOT NULL DEFAULT '',
  reply_count integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 回帖 + 楼中楼（无限嵌套：parent_id 为 NULL 是楼层，非 NULL 是回某条回复）
CREATE TABLE IF NOT EXISTS posts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   uuid NOT NULL,
  parent_id   uuid,                          -- NULL=直接回主题(楼层)；非NULL=楼中楼
  author_id   text NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ── 身份 ──

-- 用户显示名：自助同步，函数强制 owner_id = current_user()（改不了别人的）。
-- display_name 由客户端用用户的真实平台昵称同步进来。
CREATE TABLE IF NOT EXISTS profiles (
  owner_id     text PRIMARY KEY,             -- 组内假名
  display_name text NOT NULL DEFAULT '',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ── 社交（好友 / 私信）──

-- 好友关系：一条边一行，记发起方 / 接收方（都是组内假名）。
-- status: 'pending'=请求待处理；'accepted'=已是好友。无序对去重在函数里查双向。
CREATE TABLE IF NOT EXISTS friendships (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id  text NOT NULL,
  addressee_id  text NOT NULL,
  status        text NOT NULL DEFAULT 'pending',  -- pending | accepted
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT friendships_status_chk CHECK (status IN ('pending','accepted')),
  CONSTRAINT friendships_pair_uniq UNIQUE (requester_id, addressee_id)
);

-- 私信：只在已是好友的两人之间收发（在函数里校验）。
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
CREATE INDEX IF NOT EXISTS idx_friend_requester ON friendships (requester_id);
CREATE INDEX IF NOT EXISTS idx_friend_addressee ON friendships (addressee_id, status);
CREATE INDEX IF NOT EXISTS idx_messages_pair    ON messages (sender_id, recipient_id, created_at);
