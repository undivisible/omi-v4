const projectedId = (alias: string, kind: string, id: string) =>
  `'zkr:' || hex(CAST(${alias}.uid AS BLOB)) || ':' || hex(CAST(${alias}.replica_id AS BLOB)) || ':${kind}:' || hex(CAST(${id} AS BLOB))`;

const sourceId = projectedId("s", "source", "s.record_id");
const evidenceSourceId = projectedId(
  "e",
  "source",
  "json_extract(e.payload, '$.evidence.source_id')",
);
const evidenceId = projectedId("e", "evidence", "e.record_id");
const claimId = projectedId("c", "claim", "c.record_id");
const linkClaimId = projectedId(
  "l",
  "claim",
  "json_extract(l.payload, '$.claim_id')",
);
const linkEvidenceId = projectedId(
  "l",
  "evidence",
  "json_extract(l.payload, '$.evidence_id')",
);
const profileId = projectedId("p", "profile", "p.record_id");
const profileClaimId = projectedId(
  "p",
  "claim",
  "json_extract(p.payload, '$.claim_id')",
);

export const projectZkrMemory = async (
  db: D1Database,
  uid: string,
  replicaId: string,
) => {
  await db.batch([
    db
      .prepare(
        `INSERT INTO memory_sources
           (id, uid, kind, external_id, created_at, updated_at, tombstoned_at)
         SELECT ${sourceId}, s.uid, json_extract(s.payload, '$.source.kind'), ${sourceId},
                json_extract(s.payload, '$.source.recorded_at'),
                json_extract(s.payload, '$.source.recorded_at'),
                COALESCE(s.deleted_at, json_extract(s.payload, '$.source.deleted_at'))
         FROM zkr_memory_records s
         WHERE s.uid = ?1 AND s.replica_id = ?2 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           kind = excluded.kind,
           updated_at = excluded.updated_at,
           tombstoned_at = excluded.tombstoned_at`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT ${sourceId} || ':revision:' || json_extract(s.payload, '$.source.revision'),
                ${sourceId}, s.uid, json_extract(s.payload, '$.source.revision'),
                hex(CAST(json_extract(s.payload, '$.source.content') AS BLOB)),
                s.payload, json_extract(s.payload, '$.source.recorded_at'),
                json_extract(s.payload, '$.source.recorded_at')
         FROM zkr_memory_records s
         WHERE s.uid = ?1 AND s.replica_id = ?2 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           content_hash = excluded.content_hash,
           payload = excluded.payload,
           observed_at = excluded.observed_at`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT DISTINCT ${evidenceSourceId} || ':revision:' || json_extract(e.payload, '$.evidence.source_revision'),
                ${evidenceSourceId}, e.uid, json_extract(e.payload, '$.evidence.source_revision'),
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
           observed_at = excluded.observed_at`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_evidence
           (id, uid, source_revision_id, quote, locator, byte_start, byte_end, created_at, tombstoned_at)
         SELECT ${evidenceId}, e.uid,
                ${evidenceSourceId} || ':revision:' || json_extract(e.payload, '$.evidence.source_revision'),
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
           tombstoned_at = excluded.tombstoned_at`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_claims
           (id, uid, content, subject, predicate, value, valid_from, valid_to,
            recorded_at, recorded_until, retracted_at, status, zkr_tier, zkr_processing_state)
         SELECT ${claimId}, c.uid, json_extract(c.payload, '$.value'),
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
           zkr_processing_state = excluded.zkr_processing_state`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `DELETE FROM memory_claims_fts
         WHERE id IN (
           SELECT ${claimId} FROM zkr_memory_records c
           WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
         )`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
         SELECT c.id, c.uid, c.content, c.subject, c.predicate, c.value
         FROM memory_claims c
         WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL
           AND c.zkr_processing_state = 'processed' AND c.zkr_tier != 'archive'
           AND c.id IN (
             SELECT ${claimId} FROM zkr_memory_records c
             WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
           )`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `DELETE FROM memory_claim_evidence
         WHERE uid = ?1 AND claim_id IN (
           SELECT ${claimId} FROM zkr_memory_records c
           WHERE c.uid = ?1 AND c.replica_id = ?2 AND c.record_kind = 'claim'
         )`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_claim_evidence
           (uid, claim_id, evidence_id, relation, confidence_basis_points)
         SELECT l.uid, ${linkClaimId}, ${linkEvidenceId},
                json_extract(l.payload, '$.relation'),
                json_extract(l.payload, '$.confidence_basis_points')
         FROM zkr_memory_records l
         JOIN memory_claims c ON c.id = ${linkClaimId} AND c.uid = l.uid
         JOIN memory_evidence e ON e.id = ${linkEvidenceId} AND e.uid = l.uid
         WHERE l.uid = ?1 AND l.replica_id = ?2 AND l.record_kind = 'claim_evidence'
           AND l.deleted_at IS NULL
         ON CONFLICT(claim_id, evidence_id) DO UPDATE SET
           relation = excluded.relation,
           confidence_basis_points = excluded.confidence_basis_points`,
      )
      .bind(uid, replicaId),
    db
      .prepare(
        `INSERT INTO memory_profile_entries
           (id, uid, claim_id, profile_kind, status, profile_key, profile_value, created_at, updated_at)
         SELECT ${profileId}, p.uid, ${profileClaimId},
                json_extract(p.payload, '$.stability'),
                CASE WHEN p.deleted_at IS NULL AND c.status = 'accepted' AND c.retracted_at IS NULL
                     THEN 'active' ELSE 'archived' END,
                json_extract(p.payload, '$.key'), json_extract(p.payload, '$.value'),
                json_extract(p.payload, '$.recorded_at'), json_extract(p.payload, '$.recorded_at')
         FROM zkr_memory_records p
         JOIN memory_claims c ON c.id = ${profileClaimId} AND c.uid = p.uid
         WHERE p.uid = ?1 AND p.replica_id = ?2 AND p.record_kind = 'profile'
         ON CONFLICT(id) DO UPDATE SET
           profile_kind = excluded.profile_kind,
           status = excluded.status,
           profile_key = excluded.profile_key,
           profile_value = excluded.profile_value,
           updated_at = excluded.updated_at`,
      )
      .bind(uid, replicaId),
  ]);
  const source = await db
    .prepare(
      "SELECT COALESCE(MAX(source_sequence), 0) AS sequence FROM zkr_memory_records WHERE uid = ?1 AND replica_id = ?2",
    )
    .bind(uid, replicaId)
    .first<{ sequence: number }>();
  await db
    .prepare(
      `INSERT INTO zkr_memory_projection_state (uid, replica_id, source_sequence, projected_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(uid, replica_id) DO UPDATE SET
         source_sequence = excluded.source_sequence,
         projected_at = excluded.projected_at`,
    )
    .bind(uid, replicaId, Number(source?.sequence ?? 0), Date.now())
    .run();
};

export const ensureZkrMemoryProjected = async (db: D1Database, uid: string) => {
  const pending = await db
    .prepare(
      `SELECT records.replica_id
       FROM (
         SELECT replica_id, MAX(source_sequence) AS source_sequence
         FROM zkr_memory_records WHERE uid = ?1 GROUP BY replica_id
       ) records
       LEFT JOIN zkr_memory_projection_state state
         ON state.uid = ?1 AND state.replica_id = records.replica_id
       WHERE state.source_sequence IS NULL OR state.source_sequence < records.source_sequence
       ORDER BY records.replica_id LIMIT 100`,
    )
    .bind(uid)
    .all<{ replica_id: string }>();
  for (const row of pending.results)
    await projectZkrMemory(db, uid, row.replica_id);
};
