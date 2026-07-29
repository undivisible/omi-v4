-- User-visible legacy API-key cutover receipts.
--
-- A legacy raw key is never imported: old upstream credentials are
-- unrecoverable by design. Each record only proves that an authenticated user
-- received a newly generated v4 replacement key and identifies its public D1
-- record for support/audit purposes.

CREATE TABLE api_key_migrations (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  replacement_key_id TEXT NOT NULL REFERENCES api_keys(id) ON DELETE RESTRICT,
  legacy_kind TEXT NOT NULL CHECK (legacy_kind IN ('mcp', 'dev')),
  created_at INTEGER NOT NULL,
  completed_at INTEGER NOT NULL
);
CREATE INDEX api_key_migrations_uid_completed
  ON api_key_migrations(uid, completed_at DESC);
CREATE UNIQUE INDEX api_key_migrations_replacement
  ON api_key_migrations(replacement_key_id);
