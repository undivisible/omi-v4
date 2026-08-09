PRAGMA foreign_keys = ON;

CREATE INDEX IF NOT EXISTS channel_deliveries_live_by_uid_channel
ON channel_deliveries(uid, channel, channel_chat_id)
WHERE state NOT IN ('sent', 'cancelled');

CREATE INDEX IF NOT EXISTS memory_claims_pending_vector
ON memory_claims(recorded_at, id)
WHERE vector_indexed_at IS NULL;
