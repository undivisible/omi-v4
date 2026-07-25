PRAGMA foreign_keys = ON;

CREATE TABLE zkr_sync_commits (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  replica_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  recorded_at INTEGER NOT NULL,
  event_count INTEGER NOT NULL CHECK (event_count > 0),
  applied_at INTEGER,
  PRIMARY KEY (uid, replica_id, sequence)
);
CREATE INDEX zkr_sync_commits_uid_applied ON zkr_sync_commits(uid, applied_at, sequence);

CREATE TABLE zkr_sync_events (
  uid TEXT NOT NULL,
  replica_id TEXT NOT NULL,
  commit_sequence INTEGER NOT NULL,
  event_index INTEGER NOT NULL CHECK (event_index >= 0),
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  PRIMARY KEY (uid, replica_id, commit_sequence, event_index),
  FOREIGN KEY (uid, replica_id, commit_sequence)
    REFERENCES zkr_sync_commits(uid, replica_id, sequence) ON DELETE CASCADE
);

CREATE TABLE zkr_memory_records (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  replica_id TEXT NOT NULL,
  record_kind TEXT NOT NULL CHECK (record_kind IN ('source', 'evidence', 'claim', 'claim_evidence', 'correction', 'deletion', 'profile', 'daily_review')),
  record_id TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  source_sequence INTEGER NOT NULL,
  deleted_at INTEGER,
  PRIMARY KEY (uid, replica_id, record_kind, record_id)
);
CREATE INDEX zkr_memory_records_uid_kind ON zkr_memory_records(uid, record_kind, source_sequence DESC);
