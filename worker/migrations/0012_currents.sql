PRAGMA foreign_keys = ON;

CREATE TABLE currents_v2 (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  evidence_id TEXT NOT NULL REFERENCES memory_evidence(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  reason TEXT NOT NULL,
  confidence_basis_points INTEGER NOT NULL CHECK (confidence_basis_points BETWEEN 0 AND 10000),
  proposed_action TEXT NOT NULL CHECK (json_valid(proposed_action)),
  status TEXT NOT NULL CHECK (status IN ('candidate', 'surfaced', 'accepted', 'snoozed', 'dismissed', 'completed', 'expired')),
  surface_at INTEGER NOT NULL,
  expires_at INTEGER,
  snoozed_until INTEGER,
  feedback_reference TEXT,
  execution_reference TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (expires_at IS NULL OR expires_at > surface_at),
  CHECK (snoozed_until IS NULL OR snoozed_until > surface_at)
);

INSERT INTO currents_v2
  (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action,
   status, surface_at, created_at, updated_at)
SELECT c.id, c.uid, e.id, c.title, c.summary, 'Imported Current', 5000,
       json_object('kind', 'review', 'instruction', c.summary),
       CASE c.status WHEN 'active' THEN 'surfaced' WHEN 'done' THEN 'completed' ELSE 'dismissed' END,
       c.created_at, c.created_at, c.updated_at
FROM currents c
JOIN memory_evidence e ON e.uid = c.uid
WHERE e.id = (SELECT e2.id FROM memory_evidence e2 WHERE e2.uid = c.uid ORDER BY e2.created_at, e2.id LIMIT 1);

ALTER TABLE currents RENAME TO legacy_currents_uncited;
ALTER TABLE currents_v2 RENAME TO currents;
CREATE INDEX currents_uid_rank ON currents(uid, status, surface_at, confidence_basis_points DESC, updated_at DESC);

CREATE TABLE current_feedback (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  current_id TEXT NOT NULL REFERENCES currents(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('snoozed', 'dismissed')),
  created_at INTEGER NOT NULL,
  UNIQUE (uid, current_id)
);

CREATE TABLE current_executions (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  current_id TEXT NOT NULL REFERENCES currents(id) ON DELETE CASCADE,
  state TEXT NOT NULL CHECK (state IN ('awaiting_approval', 'approved', 'rejected', 'succeeded', 'failed', 'outcome_unknown')),
  action TEXT NOT NULL CHECK (json_valid(action)),
  approval_nonce_hash TEXT NOT NULL UNIQUE,
  approved_at INTEGER,
  outcome TEXT CHECK (outcome IS NULL OR json_valid(outcome)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (uid, current_id)
);
