PRAGMA foreign_keys = ON;

CREATE TABLE users (
  uid TEXT PRIMARY KEY,
  email TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE personal_memories (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  content TEXT NOT NULL,
  source TEXT NOT NULL,
  evidence TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(evidence)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX personal_memories_uid_updated ON personal_memories(uid, updated_at DESC);

CREATE TABLE currents (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'dismissed', 'done')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX currents_uid_updated ON currents(uid, updated_at DESC);

CREATE TABLE user_settings (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  value TEXT NOT NULL CHECK (json_valid(value)),
  updated_at INTEGER NOT NULL
);

CREATE TABLE entitlements (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  plan TEXT NOT NULL CHECK (plan IN ('byok', 'pro')),
  status TEXT NOT NULL CHECK (status IN ('active', 'inactive')),
  valid_until INTEGER,
  stripe_customer_id TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE channel_link_tokens (
  token_hash TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX channel_link_tokens_uid ON channel_link_tokens(uid, channel, created_at DESC);

CREATE TABLE channel_bindings (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  channel_user_id TEXT NOT NULL,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  verified_at INTEGER NOT NULL,
  revoked_at INTEGER,
  PRIMARY KEY (channel, channel_user_id)
);
CREATE INDEX channel_bindings_uid ON channel_bindings(uid, channel);

CREATE TABLE webhook_events (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  event_id TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (channel, event_id)
);

CREATE TABLE audit_events (
  id TEXT PRIMARY KEY,
  uid TEXT REFERENCES users(uid) ON DELETE SET NULL,
  actor_type TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details TEXT CHECK (details IS NULL OR json_valid(details)),
  created_at INTEGER NOT NULL
);
CREATE INDEX audit_events_uid_created ON audit_events(uid, created_at DESC);
