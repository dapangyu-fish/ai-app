-- device_tokens 升级为 (channel, channel_meta) 二维结构
-- 创建时间: 2026-05-07
--
-- 背景：原 schema 用 platform='ios'|'android' 区分 token，无法承载
--   1) iOS APNs 的 sandbox vs production 区分（dev 包 vs TF/AppStore 不能互推）
--   2) Android 同设备双通道（FCM + 厂商 geTui/华为/小米）
--   3) 未来通道扩展（VoIP / Live Activity / 其他厂商）
--
-- 新结构：
--   channel       VARCHAR(32) NOT NULL    -- 'apns' | 'fcm' | 'getui' | 'huawei' | ...
--   channel_meta  JSONB NOT NULL DEFAULT '{}'  -- 通道私有字段，schema 不再需要因新通道变化
--                                             apns:  {"env": "sandbox"|"production"}
--                                             fcm:   {"app_id": "..."} 或 {}
--                                             getui: {"app_id": "...", "vendor": "huawei"}
--
-- 应用方法（在服务器上执行）:
--   ssh root@myapp-backend.dapangyu.work
--   docker exec -i <postgres容器> psql -U <user> -d <db> < 002_device_tokens_channels.sql
--   # 或者 supabase 走 supabase studio SQL editor 直接粘贴
--
-- 部署顺序（避免 schema/code 错位）：
--   1) 应用本迁移（旧代码若仍在运行会因 platform 列消失而 INSERT 报错——所以下一步要快）
--   2) git pull + 重启 backend
--   3) 客户端发新版（iOS 端会用新协议 {channel, token, meta} 重新注册）
--      —— 老客户端如果没更新会因 channel 必填而注册失败，但不会推送丢失（推送走 backend webhook，
--          backend 已经按 channel 派发，token 早就在表里了）

BEGIN;

-- 1. 加新列
ALTER TABLE device_tokens ADD COLUMN IF NOT EXISTS channel VARCHAR(32);
ALTER TABLE device_tokens ADD COLUMN IF NOT EXISTS channel_meta JSONB NOT NULL DEFAULT '{}'::jsonb;

-- 2. 回填
--    iOS 行 → channel='apns', meta.env='sandbox'（之前后端全局走 APNS_USE_SANDBOX=true，
--             所以历史能收到推送的 token 全是 sandbox 的；TF token 即便有也已被
--             apns BadDeviceToken 自愈逻辑删过了）
--    Android 行 → channel='fcm' 占位（PR1 阶段还没 fcm provider，下次推会被
--                 push.dispatch 跳过；FCM provider 上线后客户端重新注册即可）
UPDATE device_tokens
SET channel = CASE
        WHEN platform = 'ios' THEN 'apns'
        WHEN platform = 'android' THEN 'fcm'
        ELSE platform
    END,
    channel_meta = CASE
        WHEN platform = 'ios' AND (channel_meta IS NULL OR channel_meta = '{}'::jsonb)
            THEN '{"env": "sandbox"}'::jsonb
        ELSE channel_meta
    END
WHERE channel IS NULL AND platform IS NOT NULL;

-- 3. channel 设 NOT NULL（回填完成后）
ALTER TABLE device_tokens ALTER COLUMN channel SET NOT NULL;

-- 4. 删旧主键 / 唯一约束（按 platform）→ 加新主键（按 channel）
--    实测线上 PK 是复合 (user_id, platform, token)，contype='p'；用 DO 块同时兼容
--    contype='p'（PK）和 contype='u'（unique）两种写法
DO $$
DECLARE c text;
BEGIN
    FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'device_tokens'::regclass AND contype IN ('p', 'u')
    LOOP
        EXECUTE format('ALTER TABLE device_tokens DROP CONSTRAINT %I', c);
    END LOOP;
END $$;

ALTER TABLE device_tokens
    ADD CONSTRAINT device_tokens_pkey
    PRIMARY KEY (user_id, channel, token);

-- 5. 删旧 platform 列；同时清理早期废弃的 bundle_id 列（若存在）
--    bundle_id 是上一版的设计，从未被代码读写，所有行都是 NULL，跟着一起清掉
ALTER TABLE device_tokens DROP COLUMN IF EXISTS platform;
ALTER TABLE device_tokens DROP COLUMN IF EXISTS bundle_id;

-- 6. 索引（如果之前没有的话，按新 user_id 单列加一个，方便 SELECT WHERE user_id=）
CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);

COMMIT;
