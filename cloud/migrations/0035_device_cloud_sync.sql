PRAGMA foreign_keys = ON;

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  device_uid TEXT NOT NULL,
  name TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER,
  UNIQUE (uid, device_uid)
);
CREATE INDEX devices_uid_created ON devices(uid, created_at DESC);
CREATE INDEX devices_device_uid ON devices(device_uid);

CREATE TABLE device_tokens (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  prefix TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);
CREATE UNIQUE INDEX device_tokens_hash ON device_tokens(token_hash);
CREATE INDEX device_tokens_prefix_live ON device_tokens(prefix, revoked_at);

CREATE TABLE device_audio_uploads (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  start_seq INTEGER NOT NULL,
  packet_count INTEGER NOT NULL,
  byte_count INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX device_audio_uploads_device_created
  ON device_audio_uploads(device_id, created_at DESC);
