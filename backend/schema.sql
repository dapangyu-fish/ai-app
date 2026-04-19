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

-- Indexes for better performance
CREATE INDEX IF NOT EXISTS idx_app_registry_type ON app_registry(type);
CREATE INDEX IF NOT EXISTS idx_app_registry_is_public ON app_registry(is_public);
CREATE INDEX IF NOT EXISTS idx_app_registry_created_at ON app_registry(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_quotas_user_date ON chat_quotas(user_id, date);
