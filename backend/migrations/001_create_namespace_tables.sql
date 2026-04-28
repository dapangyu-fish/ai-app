-- 命名空间权限系统数据库表
-- 创建时间: 2026-04-27

-- 命名空间表
CREATE TABLE IF NOT EXISTS namespaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT UNIQUE NOT NULL,  -- 命名空间名称，如 "mycompany"（只有一层）
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by UUID NOT NULL  -- Supabase 用户 ID
);

-- 命名空间成员表
CREATE TABLE IF NOT EXISTS namespace_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  namespace_id UUID REFERENCES namespaces(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,  -- Supabase 用户 ID
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin')),  -- 只有 owner 和 admin
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  invited_by UUID,  -- 邀请人的 Supabase 用户 ID
  UNIQUE(namespace_id, user_id)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_namespace_members_user ON namespace_members(user_id);
CREATE INDEX IF NOT EXISTS idx_namespace_members_namespace ON namespace_members(namespace_id);

-- 注释
COMMENT ON TABLE namespaces IS '命名空间表，用于组织和管理包的发布权限';
COMMENT ON TABLE namespace_members IS '命名空间成员表，记录用户在命名空间中的角色';
COMMENT ON COLUMN namespace_members.role IS 'owner: 可发布包、可添加/移除成员、可删除命名空间; admin: 可发布包';
