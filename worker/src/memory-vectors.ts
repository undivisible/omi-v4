import { embedTexts } from "./embeddings";
import type { Bindings } from "./types";

const maximumAttempts = 8;
const drainBatchSize = 32;
const backfillBatchSize = 100;
const deleteChunkSize = 100;
const snippetCharacters = 300;
const contextCharacterCap = 2_000;

export type MemoryVectorMatch = { id: string; content: string; score: number };

const hex = (value: string): string =>
  Array.from(new TextEncoder().encode(value), (byte) =>
    byte.toString(16).padStart(2, "0").toUpperCase(),
  ).join("");

export const projectedClaimId = (
  uid: string,
  replicaId: string,
  recordId: string,
): string => `zkr:${hex(uid)}:${hex(replicaId)}:claim:${hex(recordId)}`;

export const enqueueClaimEmbeddings = (
  db: D1Database,
  uid: string,
  claimIds: string[],
  now = Date.now(),
): D1PreparedStatement[] =>
  claimIds.map((claimId) =>
    db
      .prepare(
        `INSERT INTO pending_embeddings (uid, claim_id, enqueued_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(uid, claim_id) DO UPDATE SET
           enqueued_at = excluded.enqueued_at, attempts = 0, last_error = NULL`,
      )
      .bind(uid, claimId, now),
  );

type PendingRow = { uid: string; claim_id: string };

type ClaimRow = {
  id: string;
  uid: string;
  content: string;
  subject: string | null;
  predicate: string | null;
  recorded_at: number;
  eligible: number;
};

const claimText = (claim: ClaimRow): string =>
  [claim.subject, claim.predicate]
    .filter((value) => typeof value === "string" && value.length > 0)
    .concat(String(claim.content))
    .join(" | ");

export const drainPendingEmbeddings = async (
  env: Bindings,
  limit = drainBatchSize,
): Promise<void> => {
  if (!env.MEMORY_VECTORS) return;
  const pending = await env.DB.prepare(
    "SELECT uid, claim_id FROM pending_embeddings WHERE attempts < ?1 ORDER BY enqueued_at, claim_id LIMIT ?2",
  )
    .bind(maximumAttempts, limit)
    .all<PendingRow>();
  const rows = pending.results ?? [];
  if (rows.length === 0) return;
  const lookups = await env.DB.batch(
    rows.map((row) =>
      env.DB.prepare(
        `SELECT id, uid, content, subject, predicate, recorded_at,
                (status = 'accepted' AND retracted_at IS NULL
                 AND (zkr_tier IS NULL OR zkr_tier != 'archive')
                 AND (zkr_processing_state IS NULL OR zkr_processing_state = 'processed')) AS eligible
         FROM memory_claims WHERE id = ?1 AND uid = ?2`,
      ).bind(row.claim_id, row.uid),
    ),
  );
  const upserts: ClaimRow[] = [];
  const deletions: PendingRow[] = [];
  for (const [index, row] of rows.entries()) {
    const claim = lookups[index]?.results[0] as ClaimRow | undefined;
    if (claim && Number(claim.eligible) === 1) upserts.push(claim);
    else deletions.push(row);
  }
  const settled: PendingRow[] = [];
  const failed: Array<PendingRow & { error: string }> = [];
  if (deletions.length > 0) {
    try {
      await env.MEMORY_VECTORS.deleteByIds(
        deletions.map((row) => row.claim_id),
      );
      settled.push(...deletions);
    } catch (error) {
      failed.push(
        ...deletions.map((row) => ({ ...row, error: String(error) })),
      );
    }
  }
  if (upserts.length > 0) {
    const upsertRows = upserts.map((claim) => ({
      uid: claim.uid,
      claim_id: claim.id,
    }));
    const vectors = await embedTexts(
      env,
      upserts.map((claim) => claimText(claim)),
    );
    if (vectors === null) {
      failed.push(
        ...upsertRows.map((row) => ({ ...row, error: "Embedding failed" })),
      );
    } else {
      try {
        await env.MEMORY_VECTORS.upsert(
          upserts.map((claim, index) => ({
            id: claim.id,
            values: vectors[index] as number[],
            metadata: {
              uid: claim.uid,
              claimId: claim.id,
              kind: "claim",
              capturedAt: Number(claim.recorded_at),
            },
          })),
        );
        settled.push(...upsertRows);
      } catch (error) {
        failed.push(
          ...upsertRows.map((row) => ({ ...row, error: String(error) })),
        );
      }
    }
  }
  const now = Date.now();
  const statements = [
    ...settled.flatMap((row) => [
      env.DB.prepare(
        "DELETE FROM pending_embeddings WHERE uid = ?1 AND claim_id = ?2",
      ).bind(row.uid, row.claim_id),
      env.DB.prepare(
        "UPDATE memory_claims SET vector_indexed_at = ?1 WHERE id = ?2 AND uid = ?3",
      ).bind(now, row.claim_id, row.uid),
    ]),
    ...failed.map((row) =>
      env.DB.prepare(
        "UPDATE pending_embeddings SET attempts = attempts + 1, last_error = ?1 WHERE uid = ?2 AND claim_id = ?3",
      ).bind(row.error.slice(0, 500), row.uid, row.claim_id),
    ),
  ];
  if (statements.length > 0) await env.DB.batch(statements);
};

export const backfillClaimVectors = async (
  env: Bindings,
  limit = backfillBatchSize,
): Promise<number> => {
  if (!env.MEMORY_VECTORS) return 0;
  const rows = await env.DB.prepare(
    `SELECT c.id, c.uid FROM memory_claims c
     WHERE c.vector_indexed_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM pending_embeddings p
         WHERE p.uid = c.uid AND p.claim_id = c.id
       )
     ORDER BY c.recorded_at, c.id LIMIT ?1`,
  )
    .bind(limit)
    .all<{ id: string; uid: string }>();
  const claims = rows.results ?? [];
  if (claims.length === 0) return 0;
  const now = Date.now();
  await env.DB.batch(
    claims.flatMap((claim) =>
      enqueueClaimEmbeddings(env.DB, claim.uid, [claim.id], now),
    ),
  );
  return claims.length;
};

export const deleteClaimVectors = async (
  env: Bindings,
  claimIds: string[],
): Promise<void> => {
  if (!env.MEMORY_VECTORS || claimIds.length === 0) return;
  for (let offset = 0; offset < claimIds.length; offset += deleteChunkSize) {
    try {
      await env.MEMORY_VECTORS.deleteByIds(
        claimIds.slice(offset, offset + deleteChunkSize),
      );
    } catch {}
  }
};

export const searchMemoryClaims = async (
  env: Bindings,
  uid: string,
  query: string,
  topK = 8,
): Promise<MemoryVectorMatch[]> => {
  if (!env.MEMORY_VECTORS) return [];
  const vectors = await embedTexts(env, [query]);
  const vector = vectors?.[0];
  if (!vector) return [];
  const result = await env.MEMORY_VECTORS.query(vector, {
    topK,
    filter: { uid },
    returnValues: false,
    returnMetadata: "none",
  });
  const matches = (result.matches ?? []).filter(
    (match) => typeof match.id === "string" && match.id.length > 0,
  );
  if (matches.length === 0) return [];
  const now = Date.now();
  const lookups = await env.DB.batch(
    matches.map((match) =>
      env.DB.prepare(
        `SELECT id, content FROM memory_claims
         WHERE id = ?1 AND uid = ?2
           AND status = 'accepted' AND retracted_at IS NULL
           AND (valid_from IS NULL OR valid_from <= ?3)
           AND (valid_to IS NULL OR valid_to > ?3)
           AND (recorded_until IS NULL OR recorded_until > ?3)
           AND (zkr_tier IS NULL OR zkr_tier != 'archive')
           AND (zkr_processing_state IS NULL OR zkr_processing_state = 'processed')`,
      ).bind(match.id, uid, now),
    ),
  );
  return matches.flatMap((match, index) => {
    const claim = lookups[index]?.results[0] as
      | { id: string; content: string }
      | undefined;
    return claim
      ? [
          {
            id: String(claim.id),
            content: String(claim.content),
            score: Number(match.score ?? 0),
          },
        ]
      : [];
  });
};

export const memoryContextFor = async (
  env: Bindings,
  uid: string,
  query: string,
  cap = contextCharacterCap,
): Promise<string | null> => {
  try {
    const items = await searchMemoryClaims(env, uid, query, 8);
    if (items.length === 0) return null;
    let output = "Relevant synced memory (server-retrieved, may be partial):";
    for (const item of items) {
      const line = `\n- ${item.content.slice(0, snippetCharacters)}`;
      if (output.length + line.length > cap) break;
      output += line;
    }
    return output;
  } catch {
    return null;
  }
};

export const deferVectorWork = (
  operation: () => Promise<unknown>,
  waitUntil?: (promise: Promise<unknown>) => void,
): void => {
  try {
    waitUntil?.(Promise.resolve());
  } catch {
    return;
  }
  const promise = operation().catch(() => undefined);
  try {
    waitUntil?.(promise);
  } catch {}
};
