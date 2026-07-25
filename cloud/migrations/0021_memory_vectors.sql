PRAGMA foreign_keys = ON;

ALTER TABLE memory_claims ADD COLUMN vector_indexed_at INTEGER;

CREATE TABLE pending_embeddings (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  claim_id TEXT NOT NULL,
  enqueued_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  PRIMARY KEY (uid, claim_id)
);
CREATE INDEX pending_embeddings_drain ON pending_embeddings(attempts, enqueued_at);
