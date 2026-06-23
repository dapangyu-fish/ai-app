-- 贴吧 FaaS 后端 schema（公开内容论坛）
-- 规则：用 UUID 主键（不要用自增主键）；公开可读，写入记作者的组内假名（author_id =
-- myapp_auth.current_user()，不可伪造）；profiles 自助显示名（只能改自己的）。
-- 部署期由属主角色执行；运行时角色只有数据读写权限（不能改表结构）。

-- 吧（板块）：任意登录用户可创建，创建者即吧主
CREATE TABLE IF NOT EXISTS boards (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,          -- 「xxx吧」里的 xxx，全局唯一
  intro       text NOT NULL DEFAULT '',
  owner_id    text NOT NULL,                 -- 吧主 = 创建者的组内假名
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

-- 回帖 + 楼中楼（无限嵌套：parent_id 为 NULL 是楼层，非 NULL 是回某条回帖）
CREATE TABLE IF NOT EXISTS posts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   uuid NOT NULL,
  parent_id   uuid,                          -- NULL=直接回主题(楼层)；非NULL=楼中楼
  author_id   text NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 用户在本吧的显示名：自助设置，函数强制 owner_id = current_user()（改不了别人的）。
-- display_name 由客户端用用户的真实平台昵称同步进来（见 playbook 的昵称章节）。
CREATE TABLE IF NOT EXISTS profiles (
  owner_id     text PRIMARY KEY,             -- 组内假名
  display_name text NOT NULL DEFAULT '',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_boards_name      ON boards (name);
CREATE INDEX IF NOT EXISTS idx_threads_board    ON threads (board_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_thread     ON posts (thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_posts_parent     ON posts (parent_id);
