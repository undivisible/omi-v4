CREATE TABLE managed_stt_sessions (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  idempotency_key TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  language TEXT NOT NULL,
  encoding TEXT NOT NULL,
  sample_rate INTEGER NOT NULL,
  channels INTEGER NOT NULL,
  diarize INTEGER NOT NULL,
  interim_results INTEGER NOT NULL,
  device_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('minting', 'issued', 'failed')),
  reserved_seconds INTEGER NOT NULL,
  estimated_cost_microusd INTEGER NOT NULL,
  token_expires_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (uid, idempotency_key)
);
CREATE INDEX managed_stt_sessions_uid_created
ON managed_stt_sessions(uid, created_at DESC);
