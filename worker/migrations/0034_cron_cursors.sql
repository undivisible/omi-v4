PRAGMA foreign_keys = ON;

-- Per-cron keyset cursors so minute ticks rotate through onboarded users
-- instead of always scanning the first page of uid order.
CREATE TABLE cron_cursors (
  name TEXT PRIMARY KEY,
  last_uid TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);
