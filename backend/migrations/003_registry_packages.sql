-- Registry 包富化目录表 —— AI summary / tags / tech_stack / 检索元数据
-- 创建时间: 2026-05-20
--
-- 设计（见 LAUNCH_NOTES.md Part 8）：
--   这是一张"附加表"，不替代 MinIO 上的 _index.json（仍是解析索引 name→versions/path）。
--   两者用 name 关联。publish 照旧写 _index.json，额外 upsert 这里一行。
--   零回归：现有 /packages /resolve 读 _index.json 的路径完全不动。
--
-- 三类字段：
--   ① capture（registry 确定性解析，零 LLM）：exports/dependencies/widgets_used/builtins_used/tech_stack
--   ② enrich（backend /api/ai/summarize 走 CLI+DeepSeek 产出）：summary_zh/en, category, domains, capabilities, use_case
--   ③ 调度/版本/容错：status 状态机 + summary_prompt_version + reindex_attempts
--
-- ⚠️ 不在这张表里加 embedding vector 列 —— 向量阶段（几百个包后）再单独迁移 + 装 pgvector，
--    避免现在给 jsonapp-postgres 引入扩展依赖。

CREATE TABLE IF NOT EXISTS registry_packages (
  name             TEXT PRIMARY KEY,   -- full_name（含 namespace），跟 _index.json 用 name 关联

  -- ① capture（纯解析）
  exports          JSONB DEFAULT '[]'::jsonb,   -- library 导出函数名
  dependencies     JSONB DEFAULT '[]'::jsonb,   -- 依赖的包名
  widgets_used     JSONB DEFAULT '[]'::jsonb,   -- 用到的 widget 类型
  builtins_used    JSONB DEFAULT '[]'::jsonb,   -- 用到的 @函数
  tech_stack       JSONB DEFAULT '[]'::jsonb,   -- 框架能力（从上面三个映射推导）

  -- ② enrich（LLM 产出）
  summary_zh       TEXT,
  summary_en       TEXT,
  category         TEXT,                        -- 单选受控：app|library|game|demo|tool
  domains          JSONB DEFAULT '[]'::jsonb,   -- 多选受控（语义领域）
  capabilities     JSONB DEFAULT '[]'::jsonb,   -- 半自由能力点
  use_case_zh      TEXT,
  use_case_en      TEXT,

  -- ③ 检索文档（拼接，给未来全文/向量）
  search_text      TEXT,

  -- ④ 调度 / 版本 / 容错
  status           TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  summary_model           TEXT,                 -- 哪个模型生成的
  summary_prompt_version  INT DEFAULT 0,        -- prompt 版本，升级时全量重排
  reindex_attempts INT NOT NULL DEFAULT 0,      -- 连续失败计数，≥5 标 failed
  indexed_at       TIMESTAMPTZ,                 -- 上次成功 enrich 时间
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- enrich worker 认领待处理行用（status + 版本）
CREATE INDEX IF NOT EXISTS idx_registry_packages_status ON registry_packages(status);
-- catalog 按 category / 时间筛选
CREATE INDEX IF NOT EXISTS idx_registry_packages_category ON registry_packages(category);

COMMENT ON TABLE registry_packages IS 'Registry 包富化目录：AI summary + tech_stack + 检索元数据。附加表，不替代 MinIO _index.json';
