-- User-generated FaaS backend services.
-- This is intentionally additive; it does not affect existing JSON-APP,
-- Registry, IM, or Agent tables.

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

CREATE INDEX IF NOT EXISTS idx_faas_services_owner ON faas_services(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_faas_services_status ON faas_services(status);
CREATE INDEX IF NOT EXISTS idx_faas_deployments_service_created ON faas_deployments(service_id, created_at DESC);
