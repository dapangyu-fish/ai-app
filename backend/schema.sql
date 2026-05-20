-- JSON-APP Backend Database Schema
-- PostgreSQL 15.8

CREATE TABLE IF NOT EXISTS app_registry (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK (type IN ('app', 'component')),
    name TEXT NOT NULL,
    version TEXT NOT NULL DEFAULT '1.0.0',
    description TEXT NOT NULL DEFAULT '',
    author_id UUID,
    author_name TEXT NOT NULL DEFAULT '',
    oss_bucket TEXT NOT NULL DEFAULT '',
    oss_key TEXT NOT NULL DEFAULT '',
    download_url TEXT NOT NULL DEFAULT '',
    tags TEXT[] DEFAULT '{}'::TEXT[],
    is_public BOOLEAN DEFAULT true,
    meta_json JSONB DEFAULT '{}'::JSONB,
    dsl_spec TEXT DEFAULT '',
    icon_url TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chat_quotas (
    id SERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    date DATE NOT NULL,
    used_count INTEGER NOT NULL DEFAULT 0,
    UNIQUE(user_id, date)
);

-- 设备推送 token —— 通道无关结构，加新通道(fcm/getui/huawei...)不需要改 schema
-- channel        : 'apns' | 'fcm' | 'getui' | ...（与 backend/push/ 下注册的 provider 一一对应）
-- channel_meta   : 通道私有字段，e.g. APNs 的 {"env": "sandbox"|"production"}
-- user_id 用 TEXT 是历史遗留（早期写的就是 text，没必要为了类型改动一次迁移）
CREATE TABLE IF NOT EXISTS device_tokens (
    user_id TEXT NOT NULL,
    channel VARCHAR(32) NOT NULL,
    token TEXT NOT NULL,
    channel_meta JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, channel, token)
);

-- Registry 包富化目录（AI summary / tech_stack / 检索元数据）。
-- 附加表，不替代 MinIO _index.json；详见 migrations/003_registry_packages.sql + LAUNCH_NOTES Part 8
CREATE TABLE IF NOT EXISTS registry_packages (
    name             TEXT PRIMARY KEY,
    exports          JSONB DEFAULT '[]'::jsonb,
    dependencies     JSONB DEFAULT '[]'::jsonb,
    widgets_used     JSONB DEFAULT '[]'::jsonb,
    builtins_used    JSONB DEFAULT '[]'::jsonb,
    tech_stack       JSONB DEFAULT '[]'::jsonb,
    summary_zh       TEXT,
    summary_en       TEXT,
    category         TEXT,
    domains          JSONB DEFAULT '[]'::jsonb,
    capabilities     JSONB DEFAULT '[]'::jsonb,
    use_case_zh      TEXT,
    use_case_en      TEXT,
    search_text      TEXT,
    status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'processing', 'done', 'failed')),
    summary_model           TEXT,
    summary_prompt_version  INT DEFAULT 0,
    reindex_attempts INT NOT NULL DEFAULT 0,
    indexed_at       TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for better performance
CREATE INDEX IF NOT EXISTS idx_app_registry_type ON app_registry(type);
CREATE INDEX IF NOT EXISTS idx_app_registry_is_public ON app_registry(is_public);
CREATE INDEX IF NOT EXISTS idx_app_registry_created_at ON app_registry(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_quotas_user_date ON chat_quotas(user_id, date);
CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_registry_packages_status ON registry_packages(status);
CREATE INDEX IF NOT EXISTS idx_registry_packages_category ON registry_packages(category);
