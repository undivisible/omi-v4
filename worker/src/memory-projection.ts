// The D1 read tables, projected from the authoritative memory log.
//
// There is exactly one write authority: `memory_log`. This module folds the log
// forward into `memory_records` (the current revision of each record) and then
// rewrites the read tables from it. Nothing here decides ordering — the log
// arrives already sequenced by the Worker — and no caller may write the read
// tables directly. See `docs/memory-authority.md`.
//
// Records are keyed by their bare zkr record id. There is deliberately no
// per-replica namespace: zkr ids are 128-bit random values, so two devices never
// collide, and a reinstall that replays the same records converges on the same
// rows instead of forking a duplicate memory.

import { readMemoryLog } from "./memory-log";

const projectionPageSize = 500;

type JsonObject = Record<string, unknown>;

const object = (value: unknown): JsonObject | null =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : null;

const text = (value: unknown, limit: number): string | null =>
  typeof value === "string" && value.length > 0 && value.length <= limit
    ? value
    : null;

const integer = (value: unknown): number | null =>
  Number.isSafeInteger(value) ? Number(value) : null;

/// The record a `deletion` entry tombstones, in the two shapes zkr exports it:
/// an externally tagged `{"Source": "<id>"}` and an internally tagged
/// `{"kind": "source", "id": "<id>"}`.
export const deletionTarget = (
  payload: unknown,
): { kind: string; id: string; deletedAt: number } | null => {
  const record = object(payload);
  const target = object(record?.target);
  const taggedKind = text(target?.kind, 100);
  const taggedId = text(target?.id, 500);
  const entry = target ? Object.entries(target)[0] : undefined;
  const id = taggedId ?? text(entry?.[1], 500);
  const deletedAt = integer(record?.deleted_at);
  if (!id || deletedAt === null) return null;
  const kind = (taggedKind ?? entry?.[0] ?? "")
    .replaceAll(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .replace("profile_entry", "profile");
  return kind ? { kind, id, deletedAt } : null;
};

/// A record's own tombstone, when it carries one inline rather than through a
/// separate `deletion` entry.
const inlineDeletedAt = (kind: string, payload: unknown): number | null => {
  const record = object(payload);
  if (!record) return null;
  if (kind === "source") return integer(object(record.source)?.deleted_at);
  if (kind === "deletion") return deletionTarget(payload)?.deletedAt ?? null;
  return integer(record.deleted_at);
};

const sourceId = "s.record_id";
const evidenceSourceId = "json_extract(e.payload, '$.evidence.source_id')";
const evidenceId = "e.record_id";
const claimId = "c.record_id";
const linkClaimId = "json_extract(l.payload, '$.claim_id')";
const linkEvidenceId = "json_extract(l.payload, '$.evidence_id')";
const profileId = "p.record_id";
const profileClaimId = "json_extract(p.payload, '$.claim_id')";

/// Every timestamp the read tables require falls back to the log entry's own
/// `recorded_at` rather than the projection's wall clock. A record whose zkr
/// payload omits a time still lands, and replaying the log from zero produces
/// byte-identical rows — a projection that reached for `Date.now()` here would
/// differ on every rebuild.
const sourceRecordedAt =
  "COALESCE(json_extract(s.payload, '$.source.recorded_at'), s.recorded_at)";
const evidenceRecordedAt =
  "COALESCE(json_extract(e.payload, '$.evidence.recorded_at'), e.recorded_at)";
const claimRecordedAt =
  "COALESCE(json_extract(c.payload, '$.recorded_time.from'), c.recorded_at)";
const profileRecordedAt =
  "COALESCE(json_extract(p.payload, '$.recorded_at'), p.recorded_at)";

/// Folds new log entries into `memory_records`. A later log sequence always
/// wins, so replaying the log from zero produces the same table as following it
/// incrementally.
const materializeRecords = async (
  db: D1Database,
  uid: string,
  after: number,
): Promise<number> => {
  let cursor = after;
  for (;;) {
    const page = await readMemoryLog(db, uid, cursor, projectionPageSize);
    if (page.records.length === 0)
      return page.head > cursor ? page.head : cursor;
    const statements: D1PreparedStatement[] = [];
    for (const entry of page.records) {
      statements.push(
        db
          .prepare(
            `INSERT INTO memory_records (uid, record_kind, record_id, payload, sequence, recorded_at, deleted_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(uid, record_kind, record_id) DO UPDATE SET
               payload = excluded.payload,
               sequence = excluded.sequence,
               recorded_at = excluded.recorded_at,
               deleted_at = COALESCE(excluded.deleted_at, memory_records.deleted_at)
             WHERE excluded.sequence >= memory_records.sequence`,
          )
          .bind(
            uid,
            entry.record_kind,
            entry.record_id,
            JSON.stringify(entry.payload),
            entry.sequence,
            entry.recorded_at,
            inlineDeletedAt(entry.record_kind, entry.payload),
          ),
      );
      const target =
        entry.record_kind === "deletion" ? deletionTarget(entry.payload) : null;
      if (target)
        statements.push(
          db
            .prepare(
              `UPDATE memory_records SET deleted_at = ?1, sequence = ?2
               WHERE uid = ?3 AND record_kind = ?4 AND record_id = ?5 AND sequence <= ?2`,
            )
            .bind(
              target.deletedAt,
              entry.sequence,
              uid,
              target.kind,
              target.id,
            ),
        );
    }
    await db.batch(statements);
    cursor = page.next_after;
    if (page.complete) return Math.max(cursor, page.head);
  }
};

/// Rewrites the read tables for one uid from `memory_records`.
export const projectMemory = async (db: D1Database, uid: string) => {
  const state = await db
    .prepare("SELECT sequence FROM memory_projection_state WHERE uid = ?1")
    .bind(uid)
    .first<{ sequence: number }>();
  const projected = await materializeRecords(
    db,
    uid,
    Number(state?.sequence ?? 0),
  );
  const now = Date.now();
  await db.batch([
    db
      .prepare(
        `INSERT INTO memory_sources
           (id, uid, kind, external_id, created_at, updated_at, tombstoned_at)
         SELECT ${sourceId}, s.uid, json_extract(s.payload, '$.source.kind'), ${sourceId},
                ${sourceRecordedAt}, ${sourceRecordedAt},
                COALESCE(s.deleted_at, json_extract(s.payload, '$.source.deleted_at'))
         FROM memory_records s
         WHERE s.uid = ?1 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           kind = excluded.kind,
           updated_at = excluded.updated_at,
           tombstoned_at = excluded.tombstoned_at`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT ${sourceId} || ':revision:' || json_extract(s.payload, '$.source.revision'),
                ${sourceId}, s.uid, json_extract(s.payload, '$.source.revision'),
                hex(CAST(json_extract(s.payload, '$.source.content') AS BLOB)),
                s.payload, ${sourceRecordedAt}, ${sourceRecordedAt}
         FROM memory_records s
         WHERE s.uid = ?1 AND s.record_kind = 'source'
         ON CONFLICT(id) DO UPDATE SET
           content_hash = excluded.content_hash,
           payload = excluded.payload,
           observed_at = excluded.observed_at`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_source_revisions
           (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
         SELECT DISTINCT ${evidenceSourceId} || ':revision:' || json_extract(e.payload, '$.evidence.source_revision'),
                ${evidenceSourceId}, e.uid, json_extract(e.payload, '$.evidence.source_revision'),
                hex(CAST(json_extract(s.payload, '$.source.content') AS BLOB)),
                s.payload, ${sourceRecordedAt}, ${sourceRecordedAt}
         FROM memory_records e
         JOIN memory_records s ON s.uid = e.uid
           AND s.record_kind = 'source'
           AND s.record_id = json_extract(e.payload, '$.evidence.source_id')
         WHERE e.uid = ?1 AND e.record_kind = 'evidence'
         ON CONFLICT(id) DO UPDATE SET
           content_hash = excluded.content_hash,
           payload = excluded.payload,
           observed_at = excluded.observed_at`,
      )
      .bind(uid),
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
                ${evidenceRecordedAt},
                COALESCE(e.deleted_at, s.deleted_at, json_extract(s.payload, '$.source.deleted_at'))
         FROM memory_records e
         JOIN memory_records s ON s.uid = e.uid
           AND s.record_kind = 'source'
           AND s.record_id = json_extract(e.payload, '$.evidence.source_id')
         WHERE e.uid = ?1 AND e.record_kind = 'evidence'
         ON CONFLICT(id) DO UPDATE SET
           source_revision_id = excluded.source_revision_id,
           quote = excluded.quote,
           locator = excluded.locator,
           byte_start = excluded.byte_start,
           byte_end = excluded.byte_end,
           tombstoned_at = excluded.tombstoned_at`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_claims
           (id, uid, content, subject, predicate, value, valid_from, valid_to,
            recorded_at, recorded_until, retracted_at, status, zkr_tier, zkr_processing_state)
         SELECT ${claimId}, c.uid, json_extract(c.payload, '$.value'),
                json_extract(c.payload, '$.subject'), json_extract(c.payload, '$.predicate'),
                json_extract(c.payload, '$.value'), json_extract(c.payload, '$.valid_time.from'),
                json_extract(c.payload, '$.valid_time.until'),
                ${claimRecordedAt},
                COALESCE(json_extract(c.payload, '$.recorded_time.until'), c.deleted_at),
                CASE WHEN c.deleted_at IS NOT NULL
                       OR json_extract(c.payload, '$.status') != 'accepted'
                       OR EXISTS (
                         SELECT 1 FROM memory_records correction
                         WHERE correction.uid = c.uid
                           AND correction.record_kind = 'correction' AND correction.deleted_at IS NULL
                           AND json_extract(correction.payload, '$.superseded_claim_id') = c.record_id
                       )
                     THEN COALESCE(c.deleted_at, json_extract(c.payload, '$.recorded_time.until'), 0)
                     ELSE NULL END,
                CASE WHEN c.deleted_at IS NULL
                       AND json_extract(c.payload, '$.status') = 'accepted'
                       AND NOT EXISTS (
                         SELECT 1 FROM memory_records correction
                         WHERE correction.uid = c.uid
                           AND correction.record_kind = 'correction' AND correction.deleted_at IS NULL
                           AND json_extract(correction.payload, '$.superseded_claim_id') = c.record_id
                       )
                     THEN 'accepted' ELSE 'superseded' END,
                COALESCE(json_extract(c.payload, '$.tier'), 'long_term'),
                COALESCE(json_extract(c.payload, '$.processing_state'), 'processed')
         FROM memory_records c
         WHERE c.uid = ?1 AND c.record_kind = 'claim'
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
      .bind(uid),
    db
      .prepare(
        `DELETE FROM memory_claims_fts
         WHERE id IN (
           SELECT ${claimId} FROM memory_records c
           WHERE c.uid = ?1 AND c.record_kind = 'claim'
         )`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
         SELECT c.id, c.uid, c.content, c.subject, c.predicate, c.value
         FROM memory_claims c
         WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL
           AND c.zkr_processing_state = 'processed' AND c.zkr_tier != 'archive'
           AND c.id IN (
             SELECT ${claimId} FROM memory_records c
             WHERE c.uid = ?1 AND c.record_kind = 'claim'
           )`,
      )
      .bind(uid),
    db
      .prepare(
        `DELETE FROM memory_claim_evidence
         WHERE uid = ?1 AND claim_id IN (
           SELECT ${claimId} FROM memory_records c
           WHERE c.uid = ?1 AND c.record_kind = 'claim'
         )`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_claim_evidence
           (uid, claim_id, evidence_id, relation, confidence_basis_points)
         SELECT l.uid, ${linkClaimId}, ${linkEvidenceId},
                json_extract(l.payload, '$.relation'),
                json_extract(l.payload, '$.confidence_basis_points')
         FROM memory_records l
         JOIN memory_claims c ON c.id = ${linkClaimId} AND c.uid = l.uid
         JOIN memory_evidence e ON e.id = ${linkEvidenceId} AND e.uid = l.uid
         WHERE l.uid = ?1 AND l.record_kind = 'claim_evidence'
           AND l.deleted_at IS NULL
         ON CONFLICT(claim_id, evidence_id) DO UPDATE SET
           relation = excluded.relation,
           confidence_basis_points = excluded.confidence_basis_points`,
      )
      .bind(uid),
    db
      .prepare(
        `INSERT INTO memory_profile_entries
           (id, uid, claim_id, profile_kind, status, profile_key, profile_value, created_at, updated_at)
         SELECT ${profileId}, p.uid, ${profileClaimId},
                json_extract(p.payload, '$.stability'),
                CASE WHEN p.deleted_at IS NULL AND c.status = 'accepted' AND c.retracted_at IS NULL
                     THEN 'active' ELSE 'archived' END,
                json_extract(p.payload, '$.key'), json_extract(p.payload, '$.value'),
                ${profileRecordedAt}, ${profileRecordedAt}
         FROM memory_records p
         JOIN memory_claims c ON c.id = ${profileClaimId} AND c.uid = p.uid
         WHERE p.uid = ?1 AND p.record_kind = 'profile'
         ON CONFLICT(id) DO UPDATE SET
           profile_kind = excluded.profile_kind,
           status = excluded.status,
           profile_key = excluded.profile_key,
           profile_value = excluded.profile_value,
           updated_at = excluded.updated_at`,
      )
      .bind(uid),
    // A claim is only as alive as its citation. When every source revision it
    // cites has been tombstoned the claim is retracted here, in the projection,
    // rather than by whichever endpoint happened to delete the source — that
    // rule belongs to the evidence model, not to a route.
    db
      .prepare(
        `UPDATE memory_claims SET retracted_at = COALESCE(retracted_at, ?2),
           recorded_until = COALESCE(recorded_until, ?2), status = 'superseded'
         WHERE uid = ?1 AND retracted_at IS NULL
           AND EXISTS (
             SELECT 1 FROM memory_claim_evidence ce
             WHERE ce.claim_id = memory_claims.id AND ce.uid = ?1
           )
           AND NOT EXISTS (
             SELECT 1 FROM memory_claim_evidence ce
             JOIN memory_evidence e ON e.id = ce.evidence_id
             JOIN memory_source_revisions r ON r.id = e.source_revision_id
             JOIN memory_sources s ON s.id = r.source_id
             WHERE ce.claim_id = memory_claims.id AND ce.uid = ?1
               AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL
           )`,
      )
      .bind(uid, now),
    db
      .prepare(
        `DELETE FROM memory_claims_fts
         WHERE uid = ?1 AND id IN (
           SELECT id FROM memory_claims
           WHERE uid = ?1 AND (retracted_at IS NOT NULL OR status != 'accepted')
         )`,
      )
      .bind(uid),
    db
      .prepare(
        `UPDATE memory_daily_reviews SET retracted_at = ?2
         WHERE uid = ?1 AND retracted_at IS NULL AND EXISTS (
           SELECT 1 FROM memory_daily_review_citations rc
           JOIN memory_evidence e ON e.id = rc.evidence_id
           WHERE rc.review_id = memory_daily_reviews.id AND rc.uid = ?1
             AND e.tombstoned_at IS NOT NULL
         )`,
      )
      .bind(uid, now),
  ]);
  await db
    .prepare(
      `INSERT INTO memory_projection_state (uid, sequence, projected_at)
       VALUES (?1, ?2, ?3)
       ON CONFLICT(uid) DO UPDATE SET
         sequence = MAX(memory_projection_state.sequence, excluded.sequence),
         projected_at = excluded.projected_at`,
    )
    .bind(uid, projected, now)
    .run();
};

/// Projects only when the log has moved past what the read tables reflect.
export const ensureMemoryProjected = async (db: D1Database, uid: string) => {
  const head = await db
    .prepare(
      "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM memory_log WHERE uid = ?1",
    )
    .bind(uid)
    .first<{ sequence: number }>();
  const state = await db
    .prepare("SELECT sequence FROM memory_projection_state WHERE uid = ?1")
    .bind(uid)
    .first<{ sequence: number }>();
  if (Number(head?.sequence ?? 0) <= Number(state?.sequence ?? 0)) return;
  await projectMemory(db, uid);
};
