CREATE TABLE managed_ai_requests (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('started', 'streaming', 'complete', 'failed', 'timeout', 'cancelled')),
  input_characters INTEGER NOT NULL,
  requested_max_output_tokens INTEGER NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  estimated_cost_microusd INTEGER,
  actual_cost_microusd INTEGER,
  upstream_status INTEGER,
  finalization_attempts INTEGER NOT NULL DEFAULT 0,
  finalized_at INTEGER,
  admission_settled_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX managed_ai_requests_uid_created
ON managed_ai_requests(uid, created_at DESC);
