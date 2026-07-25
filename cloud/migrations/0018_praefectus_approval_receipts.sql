PRAGMA foreign_keys = ON;

CREATE TABLE current_executions_v2 (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  current_id TEXT NOT NULL REFERENCES currents(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK (state IN ('awaiting_approval', 'approved', 'rejected', 'succeeded', 'failed', 'outcome_unknown', 'cancelled_before_effect', 'expired_before_effect')),
  action TEXT NOT NULL CHECK (json_valid(action)),
  approval_nonce_hash TEXT NOT NULL UNIQUE,
  approved_at INTEGER,
  outcome TEXT CHECK (outcome IS NULL OR json_valid(outcome)),
  outcome_reported_at INTEGER,
  operation_id TEXT,
  proposal_id TEXT,
  action_hash TEXT CHECK (action_hash IS NULL OR length(action_hash) = 64),
  risk TEXT CHECK (risk IS NULL OR risk IN ('reversible', 'external', 'destructive')),
  policy_generation INTEGER CHECK (policy_generation IS NULL OR policy_generation >= 0),
  receipt_id TEXT,
  receipt_token_hash TEXT,
  receipt_issued_at INTEGER,
  receipt_expires_at INTEGER CHECK (receipt_expires_at IS NULL OR receipt_expires_at > receipt_issued_at),
  receipt_claimed_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (uid, current_id)
);

INSERT INTO current_executions_v2
  (id, uid, current_id, state, action, approval_nonce_hash, approved_at, outcome, created_at, updated_at)
SELECT id, uid, current_id, state, action, approval_nonce_hash, approved_at, outcome, created_at, updated_at
FROM current_executions;

DROP TABLE current_executions;
ALTER TABLE current_executions_v2 RENAME TO current_executions;

CREATE UNIQUE INDEX current_executions_uid_operation
  ON current_executions(uid, operation_id) WHERE operation_id IS NOT NULL;
CREATE UNIQUE INDEX current_executions_uid_proposal
  ON current_executions(uid, proposal_id) WHERE proposal_id IS NOT NULL;
CREATE UNIQUE INDEX current_executions_receipt_id
  ON current_executions(receipt_id) WHERE receipt_id IS NOT NULL;
CREATE UNIQUE INDEX current_executions_receipt_token
  ON current_executions(receipt_token_hash) WHERE receipt_token_hash IS NOT NULL;
