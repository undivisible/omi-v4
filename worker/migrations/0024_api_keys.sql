PRAGMA foreign_keys = ON;

CREATE TABLE api_keys (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  name TEXT NOT NULL,
  prefix TEXT NOT NULL,
  key_hash TEXT NOT NULL,
  scopes TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(scopes)),
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  expires_at INTEGER,
  revoked_at INTEGER
);
CREATE UNIQUE INDEX api_keys_hash ON api_keys(key_hash);
CREATE INDEX api_keys_prefix_live ON api_keys(prefix, revoked_at);
CREATE INDEX api_keys_uid_created ON api_keys(uid, created_at DESC);
