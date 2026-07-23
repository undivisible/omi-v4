import type { MemoryEvidence, PersonalMemory } from "./types";

// Read-side memory projections shared by the first-party `/v1` routes, the
// public API and the MCP server, so all three answer from exactly one query.

const parseJson = <T>(value: unknown, fallback: T): T => {
  if (typeof value !== "string") return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
};

export type RetrievedMemory = {
  query: string;
  items: Array<{
    memory: { kind: string; id: string };
    excerpt: string;
    relevance_basis_points: number;
    evidence_ids: string[];
  }>;
  gaps: string[];
};

export const retrieveCitedMemory = async (
  database: D1Database,
  uid: string,
  query: string,
  limit: number,
  now = Date.now(),
): Promise<RetrievedMemory> => {
  const match = query
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 16)
    .map((term) => `"${term.replaceAll('"', '""')}"`)
    .join(" AND ");
  const rows = await database
    .prepare(
      `SELECT c.id, c.content, bm25(memory_claims_fts) AS score
     FROM memory_claims_fts
     JOIN memory_claims c ON c.id = memory_claims_fts.id AND c.uid = memory_claims_fts.uid
     WHERE memory_claims_fts.uid = ?1 AND memory_claims_fts MATCH ?2
       AND c.status = 'accepted' AND c.retracted_at IS NULL
       AND (c.valid_from IS NULL OR c.valid_from <= ?4)
       AND (c.valid_to IS NULL OR c.valid_to > ?4)
       AND (c.recorded_until IS NULL OR c.recorded_until > ?4)
       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
     ORDER BY score, c.recorded_at DESC LIMIT ?3`,
    )
    .bind(uid, match, limit, now)
    .all();
  const candidates = rows.results ?? [];
  const citations =
    candidates.length === 0
      ? []
      : await database.batch(
          candidates.map((row) =>
            database
              .prepare(
                `SELECT ce.evidence_id FROM memory_claim_evidence ce
           JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
           JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
           JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
           WHERE ce.claim_id = ?1 AND ce.uid = ?2 AND ce.relation = 'supports'
             AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL`,
              )
              .bind(row.id, uid),
          ),
        );
  const items = candidates.flatMap((row, index) => {
    const evidenceIds = (citations[index]?.results ?? []).map((evidence) =>
      String((evidence as Record<string, unknown>).evidence_id),
    );
    return evidenceIds.length === 0
      ? []
      : [
          {
            memory: { kind: "claim", id: String(row.id) },
            excerpt: String(row.content),
            relevance_basis_points: Math.max(1, 10_000 - index * 500),
            evidence_ids: evidenceIds,
          },
        ];
  });
  return {
    query,
    items,
    gaps: items.length === 0 ? ["No cited memory matched the query."] : [],
  };
};

export const listProfileMemories = async (
  database: D1Database,
  uid: string,
  limit = 100,
  now = Date.now(),
): Promise<PersonalMemory[]> => {
  const rows = await database
    .prepare(
      `SELECT p.id, c.value, c.valid_from, c.valid_to, c.recorded_at, p.updated_at,
            p.profile_kind, p.status, s.kind AS source, e.id AS evidence_id,
            e.source_revision_id, e.quote, e.locator, s.id AS source_id
     FROM memory_profile_entries p
     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid
     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE p.uid = ?1 AND p.status != 'archived' AND c.status = 'accepted' AND c.retracted_at IS NULL
       AND (c.valid_from IS NULL OR c.valid_from <= ?2)
       AND (c.valid_to IS NULL OR c.valid_to > ?2)
       AND (c.recorded_until IS NULL OR c.recorded_until > ?2)
       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
       AND ce.relation = 'supports' AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL
     ORDER BY p.updated_at DESC LIMIT 500`,
    )
    .bind(uid, now)
    .all();
  const indexed = new Map<string, PersonalMemory>();
  for (const row of rows.results ?? []) {
    const id = String(row.id);
    const evidence: MemoryEvidence = {
      id: String(row.evidence_id),
      sourceId: String(row.source_id),
      sourceRevisionId: String(row.source_revision_id),
      quote: String(row.quote),
      locator: parseJson(row.locator, null),
    };
    const existing = indexed.get(id);
    if (existing) {
      existing.evidence.push(evidence);
      continue;
    }
    indexed.set(id, {
      id,
      content: String(row.value),
      source: String(row.source),
      evidence: [evidence],
      profileKind: row.profile_kind as PersonalMemory["profileKind"],
      status: row.status as PersonalMemory["status"],
      validFrom: row.valid_from === null ? null : Number(row.valid_from),
      validTo: row.valid_to === null ? null : Number(row.valid_to),
      createdAt: Number(row.recorded_at),
      updatedAt: Number(row.updated_at),
    });
  }
  return [...indexed.values()].slice(0, limit);
};

export const listDailyReviews = async (
  database: D1Database,
  uid: string,
  limit = 100,
): Promise<Record<string, unknown>[]> => {
  const rows = await database
    .prepare(
      `SELECT r.id, r.local_date, r.input_revision, r.body, r.created_at, r.updated_at,
            e.id AS evidence_id, e.quote, e.locator, e.source_revision_id, sr.source_id
     FROM memory_daily_reviews r
     LEFT JOIN memory_daily_review_citations rc ON rc.review_id = r.id AND rc.uid = r.uid
     LEFT JOIN memory_evidence e ON e.id = rc.evidence_id AND e.uid = rc.uid
     LEFT JOIN memory_source_revisions sr ON sr.id = e.source_revision_id AND sr.uid = e.uid
     WHERE r.uid = ?1 AND r.retracted_at IS NULL
     ORDER BY r.local_date DESC, r.updated_at DESC LIMIT 300`,
    )
    .bind(uid)
    .all();
  const reviews = new Map<string, Record<string, unknown>>();
  for (const row of rows.results ?? []) {
    const id = String(row.id);
    const review = reviews.get(id) ?? {
      id,
      localDate: String(row.local_date),
      inputRevision: String(row.input_revision),
      body: String(row.body),
      citations: [],
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    };
    if (row.evidence_id !== null)
      (review.citations as MemoryEvidence[]).push({
        id: String(row.evidence_id),
        sourceId: String(row.source_id),
        sourceRevisionId: String(row.source_revision_id),
        quote: String(row.quote),
        locator: parseJson(row.locator, null),
      });
    reviews.set(id, review);
  }
  return [...reviews.values()].slice(0, limit);
};
