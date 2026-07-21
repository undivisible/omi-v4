PRAGMA foreign_keys = ON;

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE REFERENCES users(uid) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE conversation_messages (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_message_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  source TEXT NOT NULL CHECK (source IN ('app', 'web', 'desktop', 'telegram', 'blooio')),
  text TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  channel_message_id TEXT,
  delivery_id TEXT REFERENCES channel_deliveries(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (conversation_id, client_message_id)
);

CREATE INDEX conversation_messages_replay
ON conversation_messages(uid, conversation_id, cursor);

CREATE TABLE conversation_replay_cursors (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  client_id TEXT NOT NULL,
  cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (uid, conversation_id, client_id)
);
