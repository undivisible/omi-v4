PRAGMA foreign_keys = ON;

-- Daily and nightly digests reuse the daily-review storage: a digest is just a
-- review row with a `kind`. Existing client-authored reviews are the evening
-- "what you did" recap, so they default to 'nightly'; the new morning "what you
-- need to do" digest is 'daily'. One row per user, per local date, per kind is
-- guaranteed by the pre-existing UNIQUE (uid, local_date, input_revision): the
-- worker writes a fixed input_revision per kind ('worker-daily'/'worker-nightly'),
-- so re-running the cron in the same local day is an idempotent no-op.
ALTER TABLE memory_daily_reviews
  ADD COLUMN kind TEXT NOT NULL DEFAULT 'nightly'
  CHECK (kind IN ('daily', 'nightly'));

-- The cron runs every minute for every user, but a digest fires only inside a
-- single local-hour window. Without a per-user zone that window can only be
-- guessed, so the offset is stored here (minutes east of UTC) and defaults to 0
-- (UTC) until a client reports the device zone. The window logic reads this
-- column, so a digest never fires "every tick" — only when the user's local
-- clock enters the morning (daily) or evening (nightly) hour.
ALTER TABLE users
  ADD COLUMN digest_utc_offset_minutes INTEGER NOT NULL DEFAULT 0;
