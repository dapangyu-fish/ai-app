-- 包社交化：作者归属 + 点赞 + 下载量
-- 创建时间: 2026-05-20
--
-- 设计（见 LAUNCH_NOTES Part 8 + 市场详情页讨论）：
--   - registry_packages 加 author_id/author_name：用来 GROUP BY 算"用户总下载/总点赞"
--     + 列出某用户发布的所有 app
--   - package_likes / package_installs：per-user 明细表
--       likes  支持 toggle（我点没点）+ count
--       installs 去重（同一用户开 N 次算 1 次下载）
--   - 这俩是"本地互动指标"，**不随 mirror 传播**（prod 的点赞 ≠ 自部署实例的）。
--     summary 是内容所以传播，点赞是互动所以不传播。
--   - 头像不存这里，按 author_id 实时查 Supabase（user_metadata.avatar_url）。

ALTER TABLE registry_packages ADD COLUMN IF NOT EXISTS author_id   TEXT;
ALTER TABLE registry_packages ADD COLUMN IF NOT EXISTS author_name TEXT;

CREATE INDEX IF NOT EXISTS idx_registry_packages_author ON registry_packages(author_id);

-- 点赞（per-user toggle）
CREATE TABLE IF NOT EXISTS package_likes (
  package_name TEXT NOT NULL,
  user_id      TEXT NOT NULL,   -- 点赞者 Supabase user id
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (package_name, user_id)
);
CREATE INDEX IF NOT EXISTS idx_package_likes_name ON package_likes(package_name);

-- 下载/安装（per-user 去重，下载量 = 独立用户数）
CREATE TABLE IF NOT EXISTS package_installs (
  package_name TEXT NOT NULL,
  user_id      TEXT NOT NULL,   -- 下载者 Supabase user id（未登录可用设备 id 兜底）
  first_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (package_name, user_id)
);
CREATE INDEX IF NOT EXISTS idx_package_installs_name ON package_installs(package_name);

COMMENT ON TABLE package_likes IS '包点赞，per-user，本地互动指标不随 mirror 传播';
COMMENT ON TABLE package_installs IS '包下载/安装，per-user 去重，本地互动指标不随 mirror 传播';
