//! zkr read-model projection SQL (`memory-projection.ts` `projectZkrMemory`).
//! The `projectedId` string-concatenation expressions are reproduced verbatim;
//! every statement is bound `(uid, replica_id)` as `?1`/`?2`.

/// `projectedId(alias, kind, id)` from memory-projection.ts.
fn projected_id(alias: &str, kind: &str, id: &str) -> String {
    format!(
        "'zkr:' || hex(CAST({alias}.uid AS BLOB)) || ':' || hex(CAST({alias}.replica_id AS BLOB)) || ':{kind}:' || hex(CAST({id} AS BLOB))"
    )
}

/// The ten INSERT/DELETE statements batched by `projectZkrMemory`, in order.
pub(super) fn projection_statements() -> Vec<String> {
    let source_id = projected_id("s", "source", "s.record_id");
    let evidence_source_id = projected_id(
        "e",
        "source",
        "json_extract(e.payload, '$.evidence.source_id')",
    );
    let evidence_id = projected_id("e", "evidence", "e.record_id");
    let claim_id = projected_id("c", "claim", "c.record_id");
    let link_claim_id = projected_id("l", "claim", "json_extract(l.payload, '$.claim_id')");
    let link_evidence_id =
        projected_id("l", "evidence", "json_extract(l.payload, '$.evidence_id')");
    let profile_id = projected_id("p", "profile", "p.record_id");
    let profile_claim_id = projected_id("p", "claim", "json_extract(p.payload, '$.claim_id')");

    vec![
        format!(
            "INSERT INTO memory_sources
           (id, uid, kind, external_id, created_at, updated_at, tombstoned_at)
         SELECT {source_id}, s.uid, json_extract(s.payload, '$.source.kind'), {source_id},
                json_extract(s.payload, '$.source.recorded_at'),
                json_extract(s.payload, '$.source.recorded_at'),
                COALESCE(s.deleted_at, json_extract(s.payload, '$.source.deleted_at'))
         FROM zkr_memory_records s
         WHERE s.uid = ?1 AND s.replica_id = ?2 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           kind = excluded.kind,
           updated_at = excluded.updated_at,
           tombstoned_at = excluded.tombstoned_at"
        ),
        format!(
            "INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT {source_id} || ':revision:' || json_extract(s.payload, '$.source.revision'),
                {source_id}, s.uid, json_extract(s.payload, '$.source.revision'),
                hex(CAST(json_extract(s.payload, '$.source.content') AS BLOB)),
                s.payload, json_extract(s.payload, '$.source.recorded_at'),
                json_extract(s.payload, '$.source.recorded_at')
         FROM zkr_memory_records s
         WHERE s.uid = ?1 AND s.replica_id = ?2 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           content_hash = excluded.content_hash,
           payload = excluded.payload,
           observed_at = excluded.observed_at"
        ),
        format!(
            "INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT DISTINCT {evidence_source_id} || ':revision:' || json_extract(e.payload, '$.evidence.source_revision'),
                {evidence_source_id}, e.uid, json_extract(e.payload, '$.evidence.source_revision'),
                hex(CAST(json_extract(s.payload, '$.source.content') AS BLOB)),
                s.payload, json_extract(s.payload, '$.source.recorded_at'),
                json_extract(s.payload, '$.source.recorded_at')
         FROM zkr_memory_records e
         JOIN zkr_memory_records s ON s.uid = e.uid AND s.replica_id = e.replica_id
           AND s.record_kind = 'source'
           AND s.record_id = json_extract(e.payload, '$.evidence.source_id')
         WHERE e.uid = ?1 AND e.replica_id = ?2 AND e.record_kind = 'evidence'
         ON CONFLICT(id) DO UPDATE SET
           content_hash = excluded.content_hash,
           payload = excluded.payload,
           observed_at = excluded.observed_at"
        ),
        format!(
            "INSERT INTO memory_evidence
           (id, uid, source_revision_id, quote, locator, byte_start, byte_end, created_at, tombstoned_at)
         SELECT {evidence_id}, e.uid,
                {evidence_source_id} || ':revision:' || json_extract(e.payload, '$.evidence.source_revision'),
                json_extract(e.payload, '$.evidence.quote'),
                json_extract(e.payload, '$.locator'),
                json_extract(e.payload, '$.evidence.byte_range.start'),
                json_extract(e.payload, '$.evidence.byte_range.end'),
                json_extract(e.payload, '$.evidence.recorded_at'),
                COALESCE(e.deleted_at, s.deleted_at, json_extract(s.payload, '$.source.deleted_at'))
         FROM zkr_memory_records e
         JOIN zkr_memory_records s ON s.uid = e.uid AND s.replica_id = e.replica_id
           AND s.record_kind = 'source'
           AND s.record_id = json_extract(e.payload, '$.evidence.source_id')
         WHERE e.uid = ?1 AND e.replica_id = ?2 AND e.record_kind = 'evidence'
         ON CONFLICT(id) DO UPDATE SET
           source_revision_id = excluded.source_revision_id,
           quote = excluded.quote,
           locator = excluded.locator,
           byte_start = excluded.byte_start,
           byte_end = excluded.byte_end,
           tombstoned_at = excluded.tombstoned_at"
        ),
        format!(
            "INSERT INTO memory_claims
           (id, uid, content, subject, predicate, value, valid_from, valid_to,
            recorded_at, recorded_until, retracted_at, status, zkr_tier, zkr_processing_state)
         SELECT {claim_id}, c.uid, json_extract(c.payload, '$.value'),
                json_extract(c.payload, '$.subject'), json_extract(c.payload, '$.predicate'),
                json_extract(c.payload, '$.value'), json_extract(c.payload, '$.valid_time.from'),
                json_extract(c.payload, '$.valid_time.until'),
                json_extract(c.payload, '$.recorded_time.from'),
                COALESCE(json_extract(c.payload, '$.recorded_time.until'), c.deleted_at),
                CASE WHEN c.deleted_at IS NOT NULL
                       OR json_extract(c.payload, '$.status') != 'accepted'
                       OR EXISTS (
                         SELECT 1 FROM zkr_memory_records correction
                         WHERE correction.uid = c.uid AND correction.replica_id = c.replica_id
                           AND correction.record_kind = 'correction' AND correction.deleted_at IS NULL
                           AND json_extract(correction.payload, '$.superseded_claim_id') = c.record_id
                       )
                     THEN COALESCE(c.deleted_at, json_extract(c.payload, '$.recorded_time.until'), 0)
                     ELSE NULL END,
                CASE WHEN c.deleted_at IS NULL
                       AND json_extract(c.payload, '$.status') = 'accepted'
                       AND NOT EXISTS (
                         SELECT 1 FROM zkr_memory_records correction
                         WHERE correction.uid = c.uid AND correction.replica_id = c.replica_id
                           AND correction.record_kind = 'correction' AND correction.deleted_at IS NULL
                           AND json_extract(correction.payload, '$.superseded_claim_id') = c.record_id
                       )
                     THEN 'accepted' ELSE 'superseded' END,
                COALESCE(json_extract(c.payload, '$.tier'), 'long_term'),
                COALESCE(json_extract(c.payload, '$.processing_state'), 'processed')
         FROM zkr_memory_records c
         WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
         ON CONFLICT(id) DO UPDATE SET
           content = excluded.content,
           subject = excluded.subject,
           predicate = excluded.predicate,
           value = excluded.value,
           valid_from = excluded.valid_from,
           valid_to = excluded.valid_to,
           recorded_at = excluded.recorded_at,
           recorded_until = excluded.recorded_until,
           retracted_at = excluded.retracted_at,
           status = excluded.status,
           zkr_tier = excluded.zkr_tier,
           zkr_processing_state = excluded.zkr_processing_state"
        ),
        format!(
            "DELETE FROM memory_claims_fts
         WHERE id IN (
           SELECT {claim_id} FROM zkr_memory_records c
           WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
         )"
        ),
        format!(
            "INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
         SELECT c.id, c.uid, c.content, c.subject, c.predicate, c.value
         FROM memory_claims c
         WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL
           AND c.zkr_processing_state = 'processed' AND c.zkr_tier != 'archive'
           AND c.id IN (
             SELECT {claim_id} FROM zkr_memory_records c
             WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
           )"
        ),
        format!(
            "DELETE FROM memory_claim_evidence
         WHERE uid = ?1 AND claim_id IN (
           SELECT {claim_id} FROM zkr_memory_records c
           WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
         )"
        ),
        format!(
            "INSERT INTO memory_claim_evidence
           (uid, claim_id, evidence_id, relation, confidence_basis_points)
         SELECT l.uid, {link_claim_id}, {link_evidence_id},
                json_extract(l.payload, '$.relation'),
                json_extract(l.payload, '$.confidence_basis_points')
         FROM zkr_memory_records l
         JOIN memory_claims c ON c.id = {link_claim_id} AND c.uid = l.uid
         JOIN memory_evidence e ON e.id = {link_evidence_id} AND e.uid = l.uid
         WHERE l.uid = ?1 AND l.replica_id = ?2 AND l.record_kind = 'claim_evidence'
           AND l.deleted_at IS NULL
         ON CONFLICT(claim_id, evidence_id) DO UPDATE SET
           relation = excluded.relation,
           confidence_basis_points = excluded.confidence_basis_points"
        ),
        format!(
            "INSERT INTO memory_profile_entries
           (id, uid, claim_id, profile_kind, status, profile_key, profile_value, created_at, updated_at)
         SELECT {profile_id}, p.uid, {profile_claim_id},
                json_extract(p.payload, '$.stability'),
                CASE WHEN p.deleted_at IS NULL AND c.status = 'accepted' AND c.retracted_at IS NULL
                     THEN 'active' ELSE 'archived' END,
                json_extract(p.payload, '$.key'), json_extract(p.payload, '$.value'),
                json_extract(p.payload, '$.recorded_at'), json_extract(p.payload, '$.recorded_at')
         FROM zkr_memory_records p
         JOIN memory_claims c ON c.id = {profile_claim_id} AND c.uid = p.uid
         WHERE p.uid = ?1 AND p.replica_id = ?2 AND p.record_kind = 'profile'
         ON CONFLICT(id) DO UPDATE SET
           profile_kind = excluded.profile_kind,
           status = excluded.status,
           profile_key = excluded.profile_key,
           profile_value = excluded.profile_value,
           updated_at = excluded.updated_at"
        ),
    ]
}
