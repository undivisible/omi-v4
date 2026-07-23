// The authoritative memory log. This is the record of truth for a user's
// memory: a record is not remembered until the Worker has appended it here and
// assigned it a sequence. Devices mint records (that is where evidence and
// transcript locators come from) but never decide ordering, and the D1 read
// tables are a projection rebuildable from this log. See
// `docs/memory-authority.md` for the conflict-resolution rules this file
// implements.

export const memoryLogKinds = new Set([
  "source",
  "evidence",
  "claim",
  "claim_evidence",
  "correction",
  "deletion",
  "profile",
  "daily_review",
]);

export type MemoryLogAppend = {
  recordKind: string;
  recordId: string;
  payload: unknown;
  recordedAt: number;
};

export type MemoryLogEntry = {
  sequence: number;
  origin_replica: string;
  record_kind: string;
  record_id: string;
  payload: unknown;
  recorded_at: number;
  appended_at: number;
};

// Stable key order so an identical record re-sent by a retrying device compares
// equal to the copy already in the log and is skipped rather than reordered.
export const canonicalJson = (value: unknown): string => {
  if (Array.isArray(value))
    return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const entry = value as Record<string, unknown>;
    return `{${Object.keys(entry)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(entry[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
};

// One statement per record, run inside a single D1 batch so each append sees
// the sequences allocated by the appends before it. Two concurrent requests can
// both read the same MAX(sequence); the primary key turns that into a failed
// batch the caller retries, never into two records sharing a sequence.
const appendStatement = (
  db: D1Database,
  uid: string,
  originReplica: string,
  record: MemoryLogAppend,
  appendedAt: number,
): D1PreparedStatement =>
  db
    .prepare(
      `INSERT INTO memory_log
         (uid, sequence, origin_replica, record_kind, record_id, payload, recorded_at, appended_at)
       SELECT ?1,
              COALESCE((SELECT MAX(sequence) FROM memory_log WHERE uid = ?1), 0) + 1,
              ?2, ?3, ?4, ?5, ?6, ?7
       WHERE NOT EXISTS (
         SELECT 1 FROM memory_log current
         WHERE current.uid = ?1 AND current.origin_replica = ?2
           AND current.record_kind = ?3 AND current.record_id = ?4
           AND current.payload = ?5
           AND current.sequence = (
             SELECT MAX(newest.sequence) FROM memory_log newest
             WHERE newest.uid = ?1 AND newest.origin_replica = ?2
               AND newest.record_kind = ?3 AND newest.record_id = ?4
           )
       )`,
    )
    .bind(
      uid,
      originReplica,
      record.recordKind,
      record.recordId,
      canonicalJson(record.payload),
      record.recordedAt,
      appendedAt,
    );

export const appendMemoryLog = async (
  db: D1Database,
  uid: string,
  originReplica: string,
  records: MemoryLogAppend[],
  appendedAt = Date.now(),
): Promise<number> => {
  const appendable = records.filter((record) =>
    memoryLogKinds.has(record.recordKind),
  );
  if (appendable.length === 0) return 0;
  await db.batch(
    appendable.map((record) =>
      appendStatement(db, uid, originReplica, record, appendedAt),
    ),
  );
  const head = await db
    .prepare(
      "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM memory_log WHERE uid = ?1",
    )
    .bind(uid)
    .first<{ sequence: number }>();
  return Number(head?.sequence ?? 0);
};

export const readMemoryLog = async (
  db: D1Database,
  uid: string,
  after: number,
  limit: number,
): Promise<{
  records: MemoryLogEntry[];
  next_after: number;
  head: number;
  complete: boolean;
}> => {
  const rows = await db
    .prepare(
      `SELECT sequence, origin_replica, record_kind, record_id, payload, recorded_at, appended_at
       FROM memory_log WHERE uid = ?1 AND sequence > ?2 ORDER BY sequence LIMIT ?3`,
    )
    .bind(uid, after, limit)
    .all();
  const records = (rows.results ?? []).map((row) => ({
    sequence: Number(row.sequence),
    origin_replica: String(row.origin_replica),
    record_kind: String(row.record_kind),
    record_id: String(row.record_id),
    payload: JSON.parse(String(row.payload)) as unknown,
    recorded_at: Number(row.recorded_at),
    appended_at: Number(row.appended_at),
  }));
  const head = await db
    .prepare(
      "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM memory_log WHERE uid = ?1",
    )
    .bind(uid)
    .first<{ sequence: number }>();
  const nextAfter =
    records.length === 0 ? after : records[records.length - 1]!.sequence;
  return {
    records,
    next_after: nextAfter,
    head: Number(head?.sequence ?? 0),
    complete: nextAfter >= Number(head?.sequence ?? 0),
  };
};

// A replica reports how far its local mirror has caught up so the Worker can
// tell a device that has never synced from one that is merely behind.
export const recordMirrorCursor = (
  db: D1Database,
  uid: string,
  replicaId: string,
  mirroredSequence: number,
  updatedAt = Date.now(),
): Promise<unknown> =>
  db
    .prepare(
      `INSERT INTO memory_log_cursors (uid, replica_id, mirrored_sequence, updated_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(uid, replica_id) DO UPDATE SET
         mirrored_sequence = MAX(memory_log_cursors.mirrored_sequence, excluded.mirrored_sequence),
         updated_at = excluded.updated_at`,
    )
    .bind(uid, replicaId, mirroredSequence, updatedAt)
    .run();
