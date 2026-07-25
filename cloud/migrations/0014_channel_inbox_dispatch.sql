ALTER TABLE channel_inbox RENAME TO channel_inbox_legacy;

CREATE TABLE channel_inbox (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  event_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  text TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  lease_until INTEGER,
  lease_token TEXT,
  last_error TEXT,
  completed_at INTEGER,
  received_at INTEGER NOT NULL,
  UNIQUE (channel, event_id)
);

INSERT INTO channel_inbox
  (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, status, received_at)
SELECT id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload,
       CASE WHEN status = 'processing' THEN 'pending' ELSE status END,
       received_at
FROM channel_inbox_legacy;

DROP TABLE channel_inbox_legacy;

CREATE INDEX channel_inbox_uid_received ON channel_inbox(uid, received_at, id);

CREATE TABLE channel_inbox_completions (
  inbox_id TEXT NOT NULL REFERENCES channel_inbox(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  attempt INTEGER NOT NULL CHECK (attempt BETWEEN 1 AND 5),
  lease_token TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('retry')),
  result_status TEXT NOT NULL CHECK (result_status IN ('pending', 'failed')),
  completed_at INTEGER NOT NULL,
  PRIMARY KEY (inbox_id, lease_token),
  UNIQUE (inbox_id, attempt, outcome)
);
