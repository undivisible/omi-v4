PRAGMA foreign_keys = ON;

CREATE TABLE memory_log (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  origin_replica TEXT NOT NULL,
  record_kind TEXT NOT NULL CHECK (record_kind IN ('source', 'evidence', 'claim', 'claim_evidence', 'correction', 'deletion', 'profile', 'daily_review')),
  record_id TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  recorded_at INTEGER NOT NULL,
  appended_at INTEGER NOT NULL,
  PRIMARY KEY (uid, sequence)
);
CREATE INDEX memory_log_identity ON memory_log(uid, origin_replica, record_kind, record_id, sequence DESC);

CREATE TABLE memory_log_cursors (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  replica_id TEXT NOT NULL,
  mirrored_sequence INTEGER NOT NULL CHECK (mirrored_sequence >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (uid, replica_id)
);
