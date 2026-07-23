PRAGMA foreign_keys = ON;

CREATE TABLE managed_speech_requests (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_message_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('transcribe', 'speak')),
  model TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('started', 'complete', 'failed')),
  request_hash TEXT NOT NULL,
  reserved_seconds INTEGER NOT NULL,
  estimated_cost_microusd INTEGER NOT NULL,
  result TEXT,
  upstream_status INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE UNIQUE INDEX managed_speech_requests_idempotency
  ON managed_speech_requests(uid, kind, client_message_id);
CREATE INDEX managed_speech_requests_uid_created
  ON managed_speech_requests(uid, created_at DESC);
