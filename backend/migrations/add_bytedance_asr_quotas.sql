-- 豆包ASR使用次数表
CREATE TABLE IF NOT EXISTS bytedance_asr_quotas (
    id SERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    date DATE NOT NULL,
    used_count INTEGER NOT NULL DEFAULT 0,
    UNIQUE(user_id, date)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_bytedance_asr_quotas_user_date ON bytedance_asr_quotas(user_id, date);
