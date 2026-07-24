// The cloud-minted write paths: creating a memory, revising a source and
// deleting one.
//
// These used to write the D1 read tables directly, which made the Worker a
// second write authority alongside the device sync path — the exact drift the
// memory log exists to end. They now mint zkr-shaped records, append them to
// `memory_log` under the `cloud` replica, and let the projection do every write
// to the read tables. Nothing in this file touches a read table.
//
// Every claim minted here still carries a citation: the text the caller sent is
// itself the source, evidence quotes it with a byte range, and the claim is
// linked to that evidence. A memory with no locator is not created.

import { Hono, type Context } from "hono";
import {
  appendMemoryLog,
  canonicalJson,
  type MemoryLogAppend,
} from "./memory-log";
import { projectMemory } from "./memory-projection";
import {
  deferVectorWork,
  drainPendingEmbeddings,
  enqueueClaimEmbeddings,
} from "./memory-vectors";
import type { AppEnv } from "./types";

/// Records the Worker mints on its own behalf carry this origin. It is a
/// replica like any device: it never assigns sequences, it only appends.
export const cloudReplicaId = "cloud";

const memoryWrite = new Hono<AppEnv>();

const sourceKinds = new Set([
  "conversation",
  "screen",
  "audio",
  "document",
  "integration",
  "user_correction",
]);

const recordId = () => crypto.randomUUID();

const text = (value: unknown, limit: number): string | null =>
  typeof value === "string" && value.trim().length > 0 && value.length <= limit
    ? value.trim()
    : null;

const json = async (
  request: Request,
): Promise<Record<string, unknown> | null> => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const contentHash = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
};

const currentSource = async (
  db: D1Database,
  uid: string,
  sourceId: string,
): Promise<{ payload: Record<string, unknown>; revision: number } | null> => {
  const row = await db
    .prepare(
      `SELECT payload, deleted_at FROM memory_records
       WHERE uid = ?1 AND record_kind = 'source' AND record_id = ?2`,
    )
    .bind(uid, sourceId)
    .first<{ payload: string; deleted_at: number | null }>();
  if (!row || row.deleted_at !== null) return null;
  const payload = JSON.parse(String(row.payload)) as Record<string, unknown>;
  const source = payload.source as Record<string, unknown> | undefined;
  const revision = Number(source?.revision ?? 0);
  if (!source || !Number.isSafeInteger(revision) || revision < 1) return null;
  return { payload, revision };
};

/// Appends, projects, and re-embeds in that order. The projection is derived,
/// so it may never describe a record the authority has not accepted.
const commit = async (
  context: Context<AppEnv>,
  uid: string,
  records: MemoryLogAppend[],
  claimIds: string[],
) => {
  await appendMemoryLog(context.env.DB, uid, cloudReplicaId, records);
  await projectMemory(context.env.DB, uid);
  const retracted = await context.env.DB.prepare(
    `SELECT id FROM memory_claims WHERE uid = ?1 AND retracted_at IS NOT NULL
       AND vector_indexed_at IS NOT NULL`,
  )
    .bind(uid)
    .all<{ id: string }>();
  const affected = [
    ...new Set([
      ...claimIds,
      ...(retracted.results ?? []).map((row) => row.id),
    ]),
  ];
  if (affected.length === 0) return;
  await context.env.DB.batch(
    enqueueClaimEmbeddings(context.env.DB, uid, affected),
  );
  deferVectorWork(
    () => drainPendingEmbeddings(context.env),
    (promise) => context.executionCtx.waitUntil(promise),
  );
};

memoryWrite.post("/memories", async (context) => {
  const body = await json(context.req.raw);
  const content = text(body?.content, 20_000);
  const subject = text(body?.subject, 200) ?? "person";
  const predicate = text(body?.predicate, 200) ?? "remembers";
  const source = text(body?.source, 100) ?? "note";
  const profileKind = text(body?.profileKind, 20) ?? "current";
  const validFrom = Number(body?.validFrom ?? Date.now());
  const validTo =
    body?.validTo === undefined || body.validTo === null
      ? null
      : Number(body.validTo);
  const profileKey = text(body?.profileKey, 200) ?? predicate;
  if (
    !content ||
    !source ||
    !sourceKinds.has(source) ||
    (body?.evidence !== undefined && !Array.isArray(body.evidence)) ||
    (profileKind !== "stable" && profileKind !== "current") ||
    !Number.isSafeInteger(validFrom) ||
    validFrom <= 0 ||
    (validTo !== null && !Number.isFinite(validTo)) ||
    (validTo !== null && validTo < validFrom)
  )
    return context.json({ error: "Invalid memory" }, 400);
  const uid = context.get("auth").uid;
  const now = Date.now();
  const sourceRecordId = recordId();
  const evidenceRecordId = recordId();
  const claimRecordId = recordId();
  const profileRecordId = recordId();
  const scope = { tenant_id: uid, person_id: uid };
  const records: MemoryLogAppend[] = [
    {
      recordKind: "source",
      recordId: sourceRecordId,
      recordedAt: now,
      payload: {
        source: {
          ...scope,
          id: sourceRecordId,
          kind: source,
          revision: 1,
          content,
          recorded_at: now,
          deleted_at: null,
        },
      },
    },
    {
      recordKind: "evidence",
      recordId: evidenceRecordId,
      recordedAt: now,
      payload: {
        evidence: {
          ...scope,
          id: evidenceRecordId,
          source_id: sourceRecordId,
          source_revision: 1,
          quote: content,
          byte_range: {
            start: 0,
            end: new TextEncoder().encode(content).length,
          },
          recorded_at: now,
        },
        locator: body?.evidence ?? [],
      },
    },
    {
      recordKind: "claim",
      recordId: claimRecordId,
      recordedAt: now,
      payload: {
        ...scope,
        id: claimRecordId,
        subject,
        predicate,
        value: content,
        status: "accepted",
        valid_time: { from: validFrom, until: validTo },
        recorded_time: { from: now, until: null },
        tier: "long_term",
        processing_state: "processed",
      },
    },
    {
      recordKind: "claim_evidence",
      recordId: canonicalJson([claimRecordId, evidenceRecordId]),
      recordedAt: now,
      payload: {
        ...scope,
        claim_id: claimRecordId,
        evidence_id: evidenceRecordId,
        relation: "supports",
        confidence_basis_points: 10_000,
      },
    },
    {
      recordKind: "profile",
      recordId: profileRecordId,
      recordedAt: now,
      payload: {
        ...scope,
        id: profileRecordId,
        claim_id: claimRecordId,
        key: profileKey,
        value: content,
        stability: profileKind,
        recorded_at: now,
      },
    },
  ];
  await commit(context, uid, records, [claimRecordId]);
  return context.json(
    { id: profileRecordId, sourceId: sourceRecordId, claimId: claimRecordId },
    201,
  );
});

memoryWrite.post("/memory/sources/:sourceId/revisions", async (context) => {
  const body = await json(context.req.raw);
  const payload =
    body?.payload !== null &&
    typeof body?.payload === "object" &&
    !Array.isArray(body.payload)
      ? (body.payload as Record<string, unknown>)
      : null;
  const observedAt = Number(body?.observedAt ?? Date.now());
  if (!payload || !Number.isSafeInteger(observedAt) || observedAt <= 0)
    return context.json({ error: "Invalid source revision" }, 400);
  const uid = context.get("auth").uid;
  const sourceId = context.req.param("sourceId");
  const existing = await currentSource(context.env.DB, uid, sourceId);
  if (!existing) return context.json({ error: "Source not found" }, 404);
  const source = existing.payload.source as Record<string, unknown>;
  const revision = existing.revision + 1;
  const serialized = JSON.stringify(payload);
  await commit(
    context,
    uid,
    [
      {
        recordKind: "source",
        recordId: sourceId,
        recordedAt: observedAt,
        payload: {
          source: {
            ...source,
            revision,
            content: serialized,
            recorded_at: observedAt,
          },
        },
      },
    ],
    [],
  );
  return context.json(
    {
      id: `${sourceId}:revision:${revision}`,
      sourceId,
      revision,
      contentHash: await contentHash(serialized),
    },
    201,
  );
});

memoryWrite.delete("/memory/sources/:sourceId", async (context) => {
  const uid = context.get("auth").uid;
  const sourceId = context.req.param("sourceId");
  const existing = await currentSource(context.env.DB, uid, sourceId);
  if (!existing) return context.json({ error: "Source not found" }, 404);
  const now = Date.now();
  // A tombstone is a record, not an UPDATE. The projection propagates it to the
  // source's evidence and retracts every claim left without a live citation.
  await commit(
    context,
    uid,
    [
      {
        recordKind: "deletion",
        recordId: canonicalJson({ kind: "source", id: sourceId }),
        recordedAt: now,
        payload: {
          tenant_id: uid,
          person_id: uid,
          target: { kind: "source", id: sourceId },
          deleted_at: now,
        },
      },
    ],
    [],
  );
  return context.body(null, 204);
});

export default memoryWrite;
