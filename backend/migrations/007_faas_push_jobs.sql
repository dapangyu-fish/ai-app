-- Isolated FaaS git push-job queue.
-- The backend validates a bundle and ENQUEUES a push job; a dedicated worker
-- (outside the request path and outside any Agent container) commits ONLY the
-- one user's subtree and pushes it to the shared myapp-faas-services repo,
-- serialized with retry/backoff. One user's failure is contained to its job
-- and never blocks another user's services. This is intentionally additive.

CREATE TABLE IF NOT EXISTS faas_push_jobs (
  job_id          TEXT PRIMARY KEY,
  owner_user_id   TEXT NOT NULL,
  service_id      TEXT NOT NULL,
  service_rel     TEXT NOT NULL,                       -- repo-relative subtree, e.g. 9a/eb/<uid>/<service_id>
  files           JSONB NOT NULL DEFAULT '{}'::jsonb,  -- validated files to materialize + commit
  commit_message  TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'running', 'success', 'failed')),
  attempts        INT NOT NULL DEFAULT 0,
  max_attempts    INT NOT NULL DEFAULT 5,
  commit_sha      TEXT NOT NULL DEFAULT '',
  pushed          BOOLEAN NOT NULL DEFAULT FALSE,
  error           TEXT NOT NULL DEFAULT '',
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),   -- backoff gate
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at      TIMESTAMPTZ,
  finished_at     TIMESTAMPTZ
);

-- Worker claims the oldest claimable pending job whose backoff gate has passed.
CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_claim
  ON faas_push_jobs(status, next_attempt_at, created_at);
CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_service
  ON faas_push_jobs(service_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_owner
  ON faas_push_jobs(owner_user_id, created_at DESC);
