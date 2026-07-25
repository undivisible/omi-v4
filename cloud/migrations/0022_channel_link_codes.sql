CREATE TABLE channel_link_codes (
  code_hash TEXT PRIMARY KEY,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX channel_link_codes_sender
ON channel_link_codes(channel, channel_user_id, expires_at DESC);

ALTER TABLE channel_bindings ADD COLUMN conversation_reset_cursor INTEGER;
