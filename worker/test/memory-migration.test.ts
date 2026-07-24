import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";
import { appendMemoryLog } from "../src/memory-log";
import { ensureMemoryProjected } from "../src/memory-projection";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const apply = async (name: string) => {
  const sql = (await Bun.file(`migrations/${name}`).text()).replace(
    "PRAGMA foreign_keys = ON;",
    "",
  );
  // Comments are stripped before splitting: a semicolon inside a comment
  // would otherwise cut a statement in half.
  const code = sql
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("--"))
    .join("\n");
  for (const statement of code.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
  }
};

const namespaced = (kind: string, id: string) =>
  `zkr:alpha:desktop:${kind}:${id}`;

const stage = (kind: string, id: string, sequence: number, payload: unknown) =>
  database
    .prepare(
      `INSERT INTO zkr_memory_records
         (uid, replica_id, record_kind, record_id, payload, source_sequence, deleted_at)
       VALUES ('alpha', 'desktop', ?1, ?2, ?3, ?4, NULL)`,
    )
    .bind(kind, id, JSON.stringify(payload), sequence)
    .run();

const scope = { tenant_id: "alpha", person_id: "alpha" };

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of [
    "0001_initial.sql",
    "0002_memory_and_policy.sql",
    "0003_align_kr_model.sql",
    "0005_memory_search.sql",
    "0016_zkr_sync.sql",
    "0017_zkr_read_projection.sql",
    "0021_memory_vectors.sql",
    "0029_memory_authority_log.sql",
  ])
    await apply(name);
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1)",
    )
    .bind(now)
    .run();

  // A record that only ever reached the staging table, never the log.
  await stage("source", "source-1", 4, {
    source: {
      ...scope,
      id: "source-1",
      kind: "conversation",
      revision: 1,
      content: "Sam moved to Lisbon",
      recorded_at: 700,
      deleted_at: null,
    },
  });
  await stage("evidence", "evidence-1", 4, {
    evidence: {
      ...scope,
      id: "evidence-1",
      source_id: "source-1",
      source_revision: 1,
      quote: "Sam moved to Lisbon",
      byte_range: { start: 0, end: 19 },
      recorded_at: 700,
    },
    locator: {
      device_id: "desktop",
      provider: "omi",
      stream_id: "stream-9",
      segment_id: "segment-3",
      start_ms: 0,
      end_ms: 1000,
    },
  });
  await stage("claim", "claim-1", 5, {
    ...scope,
    id: "claim-1",
    subject: "Sam",
    predicate: "city",
    value: "Lisbon",
    status: "accepted",
    valid_time: { from: 600, until: null },
    recorded_time: { from: 700, until: null },
  });
  await stage("claim_evidence", '["claim-1","evidence-1"]', 5, {
    ...scope,
    claim_id: "claim-1",
    evidence_id: "evidence-1",
    relation: "supports",
    confidence_basis_points: 9_000,
  });

  // The old per-replica projection of that same staged record, which migration
  // 0030 deletes and rebuilds under the bare record id.
  await database.batch([
    database
      .prepare(
        "INSERT INTO memory_sources (id, uid, kind, created_at, updated_at) VALUES (?1, 'alpha', 'conversation', 700, 700)",
      )
      .bind(namespaced("source", "source-1")),
    database
      .prepare(
        `INSERT INTO memory_claims (id, uid, content, subject, predicate, value, recorded_at)
         VALUES (?1, 'alpha', 'Lisbon', 'Sam', 'city', 'Lisbon', 700)`,
      )
      .bind(namespaced("claim", "claim-1")),
  ]);

  // A log this user already has, so the backfill must start above it rather
  // than colliding on (uid, sequence).
  await appendMemoryLog(database, "alpha", "mobile", [
    {
      recordKind: "claim",
      recordId: "claim-pre-existing",
      recordedAt: 500,
      payload: {
        ...scope,
        id: "claim-pre-existing",
        subject: "Sam",
        predicate: "role",
        value: "engineer",
        status: "accepted",
        valid_time: { from: 400, until: null },
        recorded_time: { from: 500, until: null },
      },
    },
  ]);

  await apply("0030_memory_log_projection.sql");
});

afterAll(() => miniflare.dispose());

describe("migration 0030 on a database that already holds data", () => {
  test("staged records survive the drop of the staging table", async () => {
    const log = await database
      .prepare(
        "SELECT sequence, origin_replica, record_kind, record_id, recorded_at FROM memory_log WHERE uid = 'alpha' ORDER BY sequence",
      )
      .all();
    expect(log.results.map((row) => row.record_id)).toEqual([
      "claim-pre-existing",
      "evidence-1",
      "source-1",
      "claim-1",
      '["claim-1","evidence-1"]',
    ]);
    // The backfill starts above the sequence the user already had; nothing
    // shares a sequence and nothing overwrote the live entry.
    expect(log.results.map((row) => row.sequence)).toEqual([1, 2, 3, 4, 5]);
    expect(log.results[0]?.origin_replica).toBe("mobile");
    expect(log.results[1]?.origin_replica).toBe("desktop");
    // The record's own time, taken from the payload, not the migration clock.
    expect(Number(log.results[2]?.recorded_at)).toBe(700);
  });

  test("the rebuilt projection keeps every claim's locator", async () => {
    await ensureMemoryProjected(database, "alpha");
    const stale = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM memory_claims WHERE uid = 'alpha' AND id LIKE 'zkr:%'",
      )
      .first<{ count: number }>();
    expect(Number(stale?.count)).toBe(0);
    const cited = await database
      .prepare(
        `SELECT c.id, c.value, e.locator, r.source_id
         FROM memory_claims c
         JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
         JOIN memory_evidence e ON e.id = ce.evidence_id
         JOIN memory_source_revisions r ON r.id = e.source_revision_id
         WHERE c.uid = 'alpha' AND c.id = 'claim-1'`,
      )
      .first<{
        id: string;
        value: string;
        locator: string;
        source_id: string;
      }>();
    expect(cited?.value).toBe("Lisbon");
    expect(cited?.source_id).toBe("source-1");
    expect(JSON.parse(String(cited?.locator))).toMatchObject({
      stream_id: "stream-9",
      segment_id: "segment-3",
    });
  });

  test("the retired staging tables are gone", async () => {
    const tables = await database
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('zkr_memory_records', 'zkr_memory_projection_state', 'memory_records', 'memory_projection_state') ORDER BY name",
      )
      .all();
    expect(tables.results.map((row) => row.name)).toEqual([
      "memory_projection_state",
      "memory_records",
    ]);
  });
});
