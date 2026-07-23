import { Hono } from "hono";
import { appendMemoryLog, canonicalJson } from "./memory-log";
import { projectZkrMemory } from "./memory-projection";
import {
  deferVectorWork,
  drainPendingEmbeddings,
  enqueueClaimEmbeddings,
  projectedClaimId,
} from "./memory-vectors";
import type { AppEnv } from "./types";

type JsonObject = Record<string, unknown>;

type SyncRecord = {
  kind:
    | "source"
    | "evidence"
    | "claim"
    | "claim_evidence"
    | "correction"
    | "deletion"
    | "profile"
    | "daily_review";
  record: JsonObject;
};

type SyncCommit = {
  sequence: number;
  recordedAt: number;
  eventCount: number;
  firstEventIndex: number;
  records: SyncRecord[];
};

const memorySync = new Hono<AppEnv>();
const recordKinds = new Set([
  "source",
  "evidence",
  "claim",
  "claim_evidence",
  "correction",
  "deletion",
  "profile",
  "daily_review",
]);

const object = (value: unknown): JsonObject | null =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : null;

const text = (value: unknown, limit: number): string | null =>
  typeof value === "string" && value.length > 0 && value.length <= limit
    ? value
    : null;

const integer = (value: unknown, minimum: number): number | null =>
  Number.isSafeInteger(value) && Number(value) >= minimum
    ? Number(value)
    : null;

const scopedRecord = (value: unknown, uid: string): SyncRecord | null => {
  const envelope = object(value);
  const record = object(envelope?.record);
  const kind = envelope?.kind;
  if (!record || typeof kind !== "string" || !recordKinds.has(kind))
    return null;
  const scope =
    kind === "source"
      ? object(record.source)
      : kind === "evidence"
        ? object(record.evidence)
        : record;
  if (scope?.tenant_id !== uid || scope.person_id !== uid) return null;
  return { kind: kind as SyncRecord["kind"], record };
};

const parseCommit = (value: unknown, uid: string): SyncCommit | null => {
  const commit = object(value);
  const sequence = integer(commit?.sequence, 1);
  const recordedAt = integer(commit?.recorded_at, 0);
  const eventCount = integer(commit?.event_count, 1);
  const firstEventIndex = integer(commit?.first_event_index, 0);
  if (
    sequence === null ||
    recordedAt === null ||
    eventCount === null ||
    firstEventIndex === null ||
    !Array.isArray(commit?.records) ||
    commit.records.length === 0 ||
    firstEventIndex + commit.records.length > eventCount
  )
    return null;
  const records = commit.records.map((record) => scopedRecord(record, uid));
  if (records.some((record) => record === null)) return null;
  return {
    sequence,
    recordedAt,
    eventCount,
    firstEventIndex,
    records: records as SyncRecord[],
  };
};

const recordIdentity = (
  value: SyncRecord,
): {
  kind: SyncRecord["kind"];
  id: string;
  deletedAt: number | null;
} | null => {
  const { kind, record } = value;
  if (kind === "source") {
    const source = object(record.source);
    const id = text(source?.id, 500);
    return id ? { kind, id, deletedAt: integer(source?.deleted_at, 0) } : null;
  }
  if (kind === "evidence") {
    const evidence = object(record.evidence);
    const id = text(evidence?.id, 500);
    return id ? { kind, id, deletedAt: integer(record.deleted_at, 0) } : null;
  }
  if (kind === "claim" || kind === "profile" || kind === "daily_review") {
    const id = text(record.id, 500);
    return id ? { kind, id, deletedAt: null } : null;
  }
  if (kind === "claim_evidence") {
    const claimId = text(record.claim_id, 500);
    const evidenceId = text(record.evidence_id, 500);
    return claimId && evidenceId
      ? { kind, id: canonicalJson([claimId, evidenceId]), deletedAt: null }
      : null;
  }
  if (kind === "correction") {
    const oldId = text(record.superseded_claim_id, 500);
    const newId = text(record.claim_id, 500);
    return oldId && newId
      ? { kind, id: canonicalJson([oldId, newId]), deletedAt: null }
      : null;
  }
  const deletion = deletionTarget(value);
  return deletion
    ? {
        kind,
        id: canonicalJson(record.target),
        deletedAt: deletion.deletedAt,
      }
    : null;
};

const deletionTarget = (
  record: SyncRecord,
): { kind: string; id: string; deletedAt: number } | null => {
  if (record.kind !== "deletion") return null;
  const target = object(record.record.target);
  const taggedKind = text(target?.kind, 100);
  const taggedId = text(target?.id, 500);
  const entry = target ? Object.entries(target)[0] : undefined;
  const id = taggedId ?? text(entry?.[1], 500);
  const deletedAt = integer(record.record.deleted_at, 0);
  if (!id || deletedAt === null) return null;
  const kind = (taggedKind ?? entry?.[0] ?? "")
    .replaceAll(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .replace("profile_entry", "profile");
  return recordKinds.has(kind) ? { kind, id, deletedAt } : null;
};

const touchedClaimIds = (
  uid: string,
  replicaId: string,
  records: SyncRecord[],
): string[] => {
  const rawIds = new Set<string>();
  for (const record of records) {
    if (record.kind === "claim") {
      const id = text(record.record.id, 500);
      if (id) rawIds.add(id);
    }
    if (record.kind === "correction") {
      const superseded = text(record.record.superseded_claim_id, 500);
      const replacement = text(record.record.claim_id, 500);
      if (superseded) rawIds.add(superseded);
      if (replacement) rawIds.add(replacement);
    }
    const target = deletionTarget(record);
    if (target?.kind === "claim") rawIds.add(target.id);
  }
  return [...rawIds].map((id) => projectedClaimId(uid, replicaId, id));
};

const applyCommit = async (
  db: D1Database,
  uid: string,
  replicaId: string,
  commit: SyncCommit,
): Promise<{ status: "applied" | "replayed"; claimIds: string[] }> => {
  const existing = await db
    .prepare(
      "SELECT applied_at FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
    )
    .bind(uid, replicaId, commit.sequence)
    .first<{ applied_at: number | null }>();
  if (existing?.applied_at !== null && existing?.applied_at !== undefined) {
    await projectZkrMemory(db, uid, replicaId);
    return { status: "replayed", claimIds: [] };
  }
  const rows = await db
    .prepare(
      "SELECT event_index, payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 ORDER BY event_index",
    )
    .bind(uid, replicaId, commit.sequence)
    .all<{ event_index: number; payload: string }>();
  if (
    rows.results.length !== commit.eventCount ||
    rows.results.some((row, index) => Number(row.event_index) !== index)
  )
    return { status: "replayed", claimIds: [] };
  const records = rows.results.map(
    (row) => JSON.parse(row.payload) as SyncRecord,
  );
  const identities = records.map(recordIdentity);
  if (identities.some((identity) => identity === null))
    throw new Error("Invalid staged zkr record");
  const now = Date.now();
  const statements: D1PreparedStatement[] = records.map((record, index) => {
    const identity = identities[index]!;
    return db
      .prepare(
        `INSERT INTO zkr_memory_records
           (uid, replica_id, record_kind, record_id, payload, source_sequence, deleted_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(uid, replica_id, record_kind, record_id) DO UPDATE SET
           payload = excluded.payload,
           source_sequence = excluded.source_sequence,
           deleted_at = excluded.deleted_at
         WHERE excluded.source_sequence >= zkr_memory_records.source_sequence`,
      )
      .bind(
        uid,
        replicaId,
        identity.kind,
        identity.id,
        canonicalJson(record.record),
        commit.sequence,
        identity.deletedAt,
      );
  });
  for (const record of records) {
    const target = deletionTarget(record);
    if (target)
      statements.push(
        db
          .prepare(
            `UPDATE zkr_memory_records SET deleted_at = ?1, source_sequence = ?2
             WHERE uid = ?3 AND replica_id = ?4 AND record_kind = ?5 AND record_id = ?6
               AND source_sequence <= ?2`,
          )
          .bind(
            target.deletedAt,
            commit.sequence,
            uid,
            replicaId,
            target.kind,
            target.id,
          ),
      );
  }
  await db.batch(statements);
  // The log is appended before the projection is refreshed: the projection is
  // derived, so it may never describe a record the authority has not accepted.
  await appendMemoryLog(
    db,
    uid,
    replicaId,
    records.map((record, index) => ({
      recordKind: identities[index]!.kind,
      recordId: identities[index]!.id,
      payload: record.record,
      recordedAt: commit.recordedAt,
    })),
    now,
  );
  await projectZkrMemory(db, uid, replicaId);
  await db
    .prepare(
      "UPDATE zkr_sync_commits SET applied_at = ?1 WHERE uid = ?2 AND replica_id = ?3 AND sequence = ?4 AND applied_at IS NULL",
    )
    .bind(now, uid, replicaId, commit.sequence)
    .run();
  return {
    status: "applied",
    claimIds: touchedClaimIds(uid, replicaId, records),
  };
};

memorySync.post("/", async (context) => {
  let body: JsonObject | null = null;
  try {
    body = object(await context.req.json());
  } catch {
    return context.json({ error: "Invalid zkr sync payload" }, 400);
  }
  const uid = context.get("auth").uid;
  const replicaId = text(body?.replica_id, 200);
  if (body?.export_format !== 1 || !replicaId || !Array.isArray(body.commits))
    return context.json({ error: "Invalid zkr sync payload" }, 400);
  const commits = body.commits.map((commit) => parseCommit(commit, uid));
  if (commits.some((commit) => commit === null))
    return context.json({ error: "Invalid or foreign zkr scope" }, 400);
  const statuses: Array<{ sequence: number; status: string }> = [];
  const pendingClaimIds = new Set<string>();
  for (const commit of commits as SyncCommit[]) {
    const existingCommit = await context.env.DB.prepare(
      "SELECT recorded_at, event_count, applied_at FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
    )
      .bind(uid, replicaId, commit.sequence)
      .first<{
        recorded_at: number;
        event_count: number;
        applied_at: number | null;
      }>();
    if (
      existingCommit &&
      (Number(existingCommit.recorded_at) !== commit.recordedAt ||
        Number(existingCommit.event_count) !== commit.eventCount)
    )
      return context.json({ error: "Conflicting zkr commit replay" }, 409);
    const payloads = commit.records.map((record) => canonicalJson(record));
    const indexes = payloads.map(
      (_, offset) => commit.firstEventIndex + offset,
    );
    const existingEvents = await context.env.DB.batch(
      indexes.map((index) =>
        context.env.DB.prepare(
          "SELECT payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 AND event_index = ?4",
        ).bind(uid, replicaId, commit.sequence, index),
      ),
    );
    if (
      existingEvents.some((result, index) => {
        const row = result.results[0] as { payload?: string } | undefined;
        return row?.payload !== undefined && row.payload !== payloads[index];
      })
    )
      return context.json({ error: "Conflicting zkr event replay" }, 409);
    await context.env.DB.batch([
      context.env.DB.prepare(
        `INSERT OR IGNORE INTO zkr_sync_commits
             (uid, replica_id, sequence, recorded_at, event_count)
           VALUES (?1, ?2, ?3, ?4, ?5)`,
      ).bind(
        uid,
        replicaId,
        commit.sequence,
        commit.recordedAt,
        commit.eventCount,
      ),
      ...payloads.map((payload, index) =>
        context.env.DB.prepare(
          `INSERT OR IGNORE INTO zkr_sync_events
               (uid, replica_id, commit_sequence, event_index, payload)
             VALUES (?1, ?2, ?3, ?4, ?5)`,
        ).bind(uid, replicaId, commit.sequence, indexes[index], payload),
      ),
    ]);
    const persistedCommit = await context.env.DB.prepare(
      "SELECT recorded_at, event_count FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
    )
      .bind(uid, replicaId, commit.sequence)
      .first<{ recorded_at: number; event_count: number }>();
    const persistedEvents = await context.env.DB.prepare(
      "SELECT event_index, payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 ORDER BY event_index",
    )
      .bind(uid, replicaId, commit.sequence)
      .all<{ event_index: number; payload: string }>();
    const persistedByIndex = new Map(
      persistedEvents.results.map((row) => [
        Number(row.event_index),
        row.payload,
      ]),
    );
    if (
      Number(persistedCommit?.recorded_at) !== commit.recordedAt ||
      Number(persistedCommit?.event_count) !== commit.eventCount ||
      indexes.some(
        (eventIndex, index) =>
          persistedByIndex.get(eventIndex) !== payloads[index],
      )
    )
      return context.json({ error: "Conflicting zkr commit replay" }, 409);
    if (persistedEvents.results.length !== commit.eventCount) {
      statuses.push({ sequence: commit.sequence, status: "staged" });
      continue;
    }
    const applied = await applyCommit(context.env.DB, uid, replicaId, commit);
    for (const claimId of applied.claimIds) pendingClaimIds.add(claimId);
    statuses.push({ sequence: commit.sequence, status: applied.status });
  }
  if (pendingClaimIds.size > 0) {
    await context.env.DB.batch(
      enqueueClaimEmbeddings(context.env.DB, uid, [...pendingClaimIds]),
    );
    deferVectorWork(
      () => drainPendingEmbeddings(context.env),
      (promise) => context.executionCtx.waitUntil(promise),
    );
  }
  return context.json({ replica_id: replicaId, commits: statuses });
});

export default memorySync;
