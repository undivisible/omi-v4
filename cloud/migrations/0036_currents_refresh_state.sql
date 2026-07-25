PRAGMA foreign_keys = ON;

-- Tracks when currents were last checked/regenerated on app open so refresh
-- stays cheap (TTL) without replacing the daily cron batch path.
CREATE TABLE currents_refresh_state (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  last_checked_at INTEGER NOT NULL DEFAULT 0,
  last_regenerated_at INTEGER NOT NULL DEFAULT 0,
  memory_watermark INTEGER NOT NULL DEFAULT 0
);
