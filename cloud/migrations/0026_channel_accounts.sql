CREATE TABLE channel_accounts (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  claimed_at INTEGER,
  claimed_by_uid TEXT,
  retired_at INTEGER
);
CREATE UNIQUE INDEX channel_accounts_live
ON channel_accounts(channel, channel_user_id)
WHERE claimed_at IS NULL AND retired_at IS NULL;
CREATE INDEX channel_accounts_identity
ON channel_accounts(channel, channel_user_id, created_at DESC);

CREATE TABLE channel_first_contact (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  asked_at INTEGER NOT NULL,
  answered_at INTEGER,
  PRIMARY KEY (channel, channel_user_id)
);
