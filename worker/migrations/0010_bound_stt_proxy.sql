CREATE TABLE managed_stt_sessions_v2 (
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
  status TEXT NOT NULL CHECK (status IN ('ready', 'streaming', 'complete', 'failed')),
  reserved_seconds INTEGER NOT NULL,
  estimated_cost_microusd INTEGER NOT NULL,
  claimed_at INTEGER,
  completed_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (uid, idempotency_key)
);
INSERT INTO managed_stt_sessions_v2
  (id, uid, idempotency_key, provider, model, language, encoding, sample_rate,
   channels, diarize, interim_results, device_id, source_id, status,
   reserved_seconds, estimated_cost_microusd, created_at, updated_at)
SELECT id, uid, idempotency_key, provider, model, language, encoding, sample_rate,
       channels, diarize, interim_results, device_id, source_id,
       'failed',
       reserved_seconds, estimated_cost_microusd, created_at, updated_at
FROM managed_stt_sessions;
DROP TABLE managed_stt_sessions;
ALTER TABLE managed_stt_sessions_v2 RENAME TO managed_stt_sessions;
CREATE INDEX managed_stt_sessions_uid_created
ON managed_stt_sessions(uid, created_at DESC);
