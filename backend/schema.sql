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

-- Agent 物理节点注册表。节点配置持久化在 Postgres；运行时在线状态由
-- last_seen_ms + ttl_seconds 以及 agent-node /health 探测共同判断。
CREATE TABLE IF NOT EXISTS agent_nodes (
    node_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL,
    capacity INTEGER NOT NULL DEFAULT 1,
    queue_max INTEGER NOT NULL DEFAULT 0,
    build_commit TEXT NOT NULL DEFAULT '',
    build_version TEXT NOT NULL DEFAULT '',
    labels JSONB NOT NULL DEFAULT '[]'::jsonb,
    owner_user_id TEXT NOT NULL DEFAULT '',
    visibility TEXT NOT NULL DEFAULT 'public',
    auth_public_key TEXT NOT NULL DEFAULT '',
    auth_key_id TEXT NOT NULL DEFAULT '',
    provider_mode TEXT NOT NULL DEFAULT '',
    provider_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    agent_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    last_seen_ms BIGINT NOT NULL DEFAULT 0,
    ttl_seconds INTEGER NOT NULL DEFAULT 120,
    paused BOOLEAN NOT NULL DEFAULT FALSE,
    pause_reason TEXT NOT NULL DEFAULT '',
    paused_at_ms BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_agent_nodes_owner_visibility ON agent_nodes (owner_user_id, visibility);

-- Registry 包富化目录（AI summary / tech_stack / 检索元数据）。
-- 附加表，不替代 MinIO _index.json；详见 migrations/003_registry_packages.sql + LAUNCH_NOTES Part 8
CREATE TABLE IF NOT EXISTS registry_packages (
    name             TEXT PRIMARY KEY,
    author_id        TEXT,
    author_name      TEXT,
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

-- 包点赞 / 下载（本地互动指标，不随 mirror 传播）
CREATE TABLE IF NOT EXISTS package_likes (
    package_name TEXT NOT NULL,
    user_id      TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (package_name, user_id)
);
CREATE TABLE IF NOT EXISTS package_installs (
    package_name TEXT NOT NULL,
    user_id      TEXT NOT NULL,
    first_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (package_name, user_id)
);
-- 每次成功运行/下载一行；install_count 使用该表统计。package_installs 保留为
-- per-user/per-device 去重明细，兼容旧数据和独立用户语义。
CREATE TABLE IF NOT EXISTS package_install_events (
    id           BIGSERIAL PRIMARY KEY,
    package_name TEXT NOT NULL,
    user_id      TEXT NOT NULL DEFAULT '',
    actor_type   TEXT NOT NULL DEFAULT '',
    source       TEXT NOT NULL DEFAULT '',
    user_agent   TEXT NOT NULL DEFAULT '',
    ip_hash      TEXT NOT NULL DEFAULT '',
    legacy_key   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User-generated backend services for JSON-APPs.
-- Code is stored outside the app database under FAAS_CODE_ROOT and mirrored to
-- an operator-managed Git repository. Agent containers never receive the Git or
-- OpenFaaS credentials.
CREATE TABLE IF NOT EXISTS faas_services (
    service_id      TEXT PRIMARY KEY,
    owner_user_id   TEXT NOT NULL,
    service_slug    TEXT NOT NULL,
    function_name   TEXT NOT NULL UNIQUE,
    status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'deploying', 'ready', 'failed', 'disabled')),
    active_commit   TEXT NOT NULL DEFAULT '',
    active_path     TEXT NOT NULL DEFAULT '',
    public_base_url TEXT NOT NULL DEFAULT '',
    routes          JSONB NOT NULL DEFAULT '[]'::jsonb,
    meta_json       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS faas_deployments (
    deployment_id   TEXT PRIMARY KEY,
    service_id      TEXT NOT NULL REFERENCES faas_services(service_id) ON DELETE CASCADE,
    owner_user_id   TEXT NOT NULL,
    commit_sha      TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'success', 'failed')),
    error           TEXT NOT NULL DEFAULT '',
    bundle_summary  JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at     TIMESTAMPTZ
);

-- Indexes for better performance
CREATE INDEX IF NOT EXISTS idx_app_registry_type ON app_registry(type);
CREATE INDEX IF NOT EXISTS idx_app_registry_is_public ON app_registry(is_public);
CREATE INDEX IF NOT EXISTS idx_app_registry_created_at ON app_registry(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_quotas_user_date ON chat_quotas(user_id, date);
CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_registry_packages_status ON registry_packages(status);
CREATE INDEX IF NOT EXISTS idx_registry_packages_category ON registry_packages(category);
CREATE INDEX IF NOT EXISTS idx_registry_packages_author ON registry_packages(author_id);
CREATE INDEX IF NOT EXISTS idx_package_likes_name ON package_likes(package_name);
CREATE INDEX IF NOT EXISTS idx_package_installs_name ON package_installs(package_name);
CREATE INDEX IF NOT EXISTS idx_package_install_events_name ON package_install_events(package_name);
CREATE INDEX IF NOT EXISTS idx_package_install_events_created_at ON package_install_events(created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_package_install_events_legacy_key
    ON package_install_events(legacy_key)
    WHERE legacy_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_faas_services_owner ON faas_services(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_faas_services_status ON faas_services(status);
CREATE INDEX IF NOT EXISTS idx_faas_deployments_service_created ON faas_deployments(service_id, created_at DESC);
