PRAGMA foreign_keys = ON;

ALTER TABLE memory_evidence ADD COLUMN tombstoned_at INTEGER;
ALTER TABLE memory_claims ADD COLUMN zkr_tier TEXT;
ALTER TABLE memory_claims ADD COLUMN zkr_processing_state TEXT;

CREATE TABLE zkr_memory_projection_state (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  replica_id TEXT NOT NULL,
  source_sequence INTEGER NOT NULL,
  projected_at INTEGER NOT NULL,
  PRIMARY KEY (uid, replica_id)
);
