PRAGMA foreign_keys = ON;

-- Retires the per-replica projection namespace. Before this migration every
-- projected row was keyed by `zkr:<hex uid>:<hex replica>:<kind>:<hex id>`, so a
-- reinstall (new replica id) forked a second copy of the user's whole memory and
-- a second device's memory was invisible to the first. zkr record ids are
-- 128-bit random values, unique on their own, so the namespace bought nothing
-- and cost convergence.
--
-- What happens to existing data, exactly:
--   * Records staged in `zkr_memory_records` that predate the authoritative log
--     are appended to `memory_log` first, in their original per-replica order,
--     so nothing that was only ever staged is lost when the staging table goes.
--   * Every read-table row whose id carries the `zkr:` namespace is deleted and
--     rebuilt from the log under its bare record id on the next memory request.
--     No record is lost: those rows were always derived.
--   * Rows written directly by the old `POST /v1/memories` path keep their own
--     ids and are left untouched. They are legacy: readable and citable, but no
--     new write ever takes that path again.
--   * Vectorize entries for the deleted `zkr:` claim ids are orphaned; they are
--     re-embedded under the new ids by the pending-embedding drain, and a stale
--     vector whose id no longer joins to `memory_claims` is dropped at read.

INSERT INTO memory_log
  (uid, sequence, origin_replica, record_kind, record_id, payload, recorded_at, appended_at)
SELECT staged.uid,
       COALESCE(head.base, 0)
         + ROW_NUMBER() OVER (
             PARTITION BY staged.uid
             ORDER BY staged.source_sequence, staged.replica_id, staged.record_kind, staged.record_id
           ),
       staged.replica_id, staged.record_kind, staged.record_id, staged.payload,
       COALESCE(
         json_extract(staged.payload, '$.source.recorded_at'),
         json_extract(staged.payload, '$.evidence.recorded_at'),
         json_extract(staged.payload, '$.recorded_at'),
         json_extract(staged.payload, '$.recorded_time.from'),
         0
       ),
       unixepoch() * 1000
FROM zkr_memory_records staged
LEFT JOIN (
  SELECT uid, MAX(sequence) AS base FROM memory_log GROUP BY uid
) head ON head.uid = staged.uid
WHERE NOT EXISTS (
  SELECT 1 FROM memory_log current
  WHERE current.uid = staged.uid
    AND current.record_kind = staged.record_kind
    AND current.record_id = staged.record_id
);

-- The current revision of every record in the log, materialized. Derived
-- strictly from `memory_log` and rebuildable by deleting every row here and
-- resetting `memory_projection_state`; it exists so the read-table projection
-- can stay one set of SQL statements instead of a fold in TypeScript.
CREATE TABLE memory_records (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  record_kind TEXT NOT NULL CHECK (record_kind IN ('source', 'evidence', 'claim', 'claim_evidence', 'correction', 'deletion', 'profile', 'daily_review')),
  record_id TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  sequence INTEGER NOT NULL,
  recorded_at INTEGER NOT NULL,
  deleted_at INTEGER,
  PRIMARY KEY (uid, record_kind, record_id)
);
CREATE INDEX memory_records_uid_kind ON memory_records(uid, record_kind, sequence DESC);

CREATE TABLE memory_projection_state (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE PRIMARY KEY,
  sequence INTEGER NOT NULL,
  projected_at INTEGER NOT NULL
);

DELETE FROM pending_embeddings WHERE claim_id LIKE 'zkr:%';
DELETE FROM memory_claims_fts WHERE id LIKE 'zkr:%';
DELETE FROM memory_profile_entries WHERE claim_id LIKE 'zkr:%';
DELETE FROM memory_claim_evidence WHERE claim_id LIKE 'zkr:%' OR evidence_id LIKE 'zkr:%';
DELETE FROM memory_claims WHERE id LIKE 'zkr:%';
DELETE FROM memory_evidence WHERE id LIKE 'zkr:%';
DELETE FROM memory_source_revisions WHERE id LIKE 'zkr:%';
DELETE FROM memory_sources WHERE id LIKE 'zkr:%';

DROP TABLE zkr_memory_projection_state;
DROP TABLE zkr_memory_records;
