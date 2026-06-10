-- Package run/download events.
-- 004_package_social.sql kept package_installs as per-user/per-device unique
-- rows. This table records every successful run/download event so public Web
-- guest runs and repeated runs can increase the visible counter.

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

CREATE INDEX IF NOT EXISTS idx_package_install_events_name
  ON package_install_events(package_name);

CREATE INDEX IF NOT EXISTS idx_package_install_events_created_at
  ON package_install_events(created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_package_install_events_legacy_key
  ON package_install_events(legacy_key)
  WHERE legacy_key IS NOT NULL;

INSERT INTO package_install_events
  (package_name, user_id, actor_type, source, created_at, legacy_key)
SELECT package_name, user_id, 'legacy', 'legacy_unique', first_at,
       package_name || E'\x1f' || user_id
FROM package_installs
ON CONFLICT DO NOTHING;
