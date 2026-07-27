-- The vector drain treats 'pending' as ineligible, routes those ids to
-- index.delete_by_ids, and then stamps vector_indexed_at anyway
-- (wasm_glue.rs:289, :412). backfill_claim_vectors only selects rows where
-- that column IS NULL (:447), so a released claim would never be revisited and
-- semantic search would keep missing it.
--
-- Clearing the stamp puts them back in the backfill queue. This runs *before*
-- the release below so 'pending' still identifies exactly the stranded rows:
-- once they are flipped to 'processed' they are indistinguishable from claims
-- that were legitimately embedded, and re-embedding those would be a full
-- re-run of the corpus. Rows already queued in pending_embeddings are skipped,
-- matching the backfill's own guard.
UPDATE memory_claims
   SET vector_indexed_at = NULL
 WHERE vector_indexed_at IS NOT NULL
   AND zkr_processing_state = 'pending'
   AND status = 'accepted'
   AND retracted_at IS NULL
   AND (zkr_tier IS NULL OR zkr_tier != 'archive')
   AND NOT EXISTS (
     SELECT 1 FROM pending_embeddings p
      WHERE p.uid = memory_claims.uid AND p.claim_id = memory_claims.id
   );

-- Claims extracted from transcripts were minted with processing_state
-- 'pending', and nothing ever promoted them. Every read path requires
-- 'processed', so this memory was stored, synced and projected, then filtered
-- out of search, retrieval, currents and channel replies.
--
-- The hub now mints 'processed' (app/native/hub/src/extraction.rs). This
-- releases the rows already stranded. Claims that were superseded or retracted
-- are left alone: their exclusion comes from status/retracted_at and is
-- correct, not from this column.
UPDATE memory_claims
   SET zkr_processing_state = 'processed'
 WHERE zkr_processing_state = 'pending'
   AND status = 'accepted'
   AND retracted_at IS NULL;

-- The FTS projection is filtered on the same column, so the rows released
-- above were never indexed and keyword search would still miss them.
-- Rebuild it wholesale rather than trying to identify just the released rows:
-- the predicate below is the one projection_sql.rs uses, so this converges on
-- exactly what an incremental reprojection would produce.
DELETE FROM memory_claims_fts;

INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
SELECT c.id, c.uid, c.content, c.subject, c.predicate, c.value
  FROM memory_claims c
 WHERE c.status = 'accepted'
   AND c.retracted_at IS NULL
   AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
   AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed');

-- Currents are generated from the same filtered memory view, so every current
-- produced while the claims above were stranded was built from an effectively
-- empty corpus. Zeroing the state expires the 15-minute check interval and
-- drops the watermark below the released claims, so the next app open takes
-- the `new_memory` branch of heuristic_needs_refresh instead of waiting out
-- MIN_REGENERATE_INTERVAL_MS on stale input.
UPDATE currents_refresh_state
   SET last_checked_at = 0,
       last_regenerated_at = 0,
       memory_watermark = 0;
