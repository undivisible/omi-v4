PRAGMA foreign_keys = ON;

-- Marks that the daily Currents cron has already run for this user on this
-- local calendar day (same wall-clock window as digests). Keeps generation
-- idempotent across minute ticks without inventing fake current rows.
CREATE TABLE currents_daily_batches (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  local_date TEXT NOT NULL,
  created_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (uid, local_date)
);
