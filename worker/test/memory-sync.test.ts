import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import memorySync from "../src/memory-sync";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const request = (uid: string, body: Record<string, unknown>) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/memory/zkr-sync", memorySync);
  return app.request(
    "/memory/zkr-sync",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    { DB: database } as AppEnv["Bindings"],
  );
};

const source = (uid: string, id: string, content: string) => ({
  kind: "source",
  record: {
    source: {
      id,
      tenant_id: uid,
      person_id: uid,
      revision: 1,
      kind: "conversation",
      content,
      captured_at: 10,
      recorded_at: 11,
      deleted_at: null,
    },
    ingestion_key: null,
    origin_evidence_id: null,
    origin_claim_id: null,
  },
});

const claim = (uid: string, id: string, status = "accepted") => ({
  kind: "claim",
  record: {
    id,
    tenant_id: uid,
    person_id: uid,
    subject: "Sam",
    predicate: "employer",
    value: id === "old-claim" ? "Acme" : "Beta",
    kind: "fact",
    valid_time: { from: 10, until: null },
    recorded_time: { from: 11, until: null },
    status,
  },
});

const page = (
  replicaId: string,
  sequence: number,
  eventCount: number,
  firstEventIndex: number,
  records: unknown[],
) => ({
  export_format: 1,
  database_schema_version: 8,
  replica_id: replicaId,
  high_water_mark: sequence,
  commits: [
    {
      sequence,
      recorded_at: 11 + sequence,
      event_count: eventCount,
      first_event_index: firstEventIndex,
      records,
    },
  ],
});

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of ["0001_initial.sql", "0016_zkr_sync.sql"]) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    for (const statement of sql.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1), ('beta', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(() => miniflare.dispose());

describe("zkr memory sync", () => {
  test("rejects records whose zkr scope differs from the Firebase UID", async () => {
    const response = await request(
      "alpha",
      page("desktop", 1, 1, 0, [source("beta", "foreign", "secret")]),
    );
    expect(response.status).toBe(400);
    const count = await database
      .prepare("SELECT COUNT(*) AS count FROM zkr_sync_events")
      .first<{ count: number }>();
    expect(Number(count?.count)).toBe(0);
  });

  test("stages split commits and applies only after every index is present", async () => {
    const first = await request(
      "alpha",
      page("desktop", 2, 2, 0, [source("alpha", "source-1", "hello")]),
    );
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      replica_id: "desktop",
      commits: [{ sequence: 2, status: "staged" }],
    });
    const before = await database
      .prepare("SELECT COUNT(*) AS count FROM zkr_memory_records")
      .first<{ count: number }>();
    expect(Number(before?.count)).toBe(0);

    const second = await request(
      "alpha",
      page("desktop", 2, 2, 1, [claim("alpha", "old-claim")]),
    );
    expect(await second.json()).toEqual({
      replica_id: "desktop",
      commits: [{ sequence: 2, status: "applied" }],
    });
    const applied = await database
      .prepare(
        "SELECT record_kind, record_id FROM zkr_memory_records WHERE uid = 'alpha' ORDER BY record_kind",
      )
      .all();
    expect(applied.results).toEqual([
      { record_kind: "claim", record_id: "old-claim" },
      { record_kind: "source", record_id: "source-1" },
    ]);
  });

  test("acknowledges exact replay without duplicating authority", async () => {
    const replay = await request(
      "alpha",
      page("desktop", 2, 2, 0, [
        source("alpha", "source-1", "hello"),
        claim("alpha", "old-claim"),
      ]),
    );
    expect(await replay.json()).toEqual({
      replica_id: "desktop",
      commits: [{ sequence: 2, status: "replayed" }],
    });
    const count = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM zkr_memory_records WHERE uid = 'alpha'",
      )
      .first<{ count: number }>();
    expect(Number(count?.count)).toBe(2);
  });

  test("applies correction and deletion records in one completed commit", async () => {
    const records = [
      claim("alpha", "old-claim", "superseded"),
      claim("alpha", "new-claim"),
      {
        kind: "correction",
        record: {
          tenant_id: "alpha",
          person_id: "alpha",
          superseded_claim_id: "old-claim",
          claim_id: "new-claim",
          source_id: "correction-source",
          evidence_id: "correction-evidence",
          valid_at: 20,
          recorded_at: 21,
        },
      },
      {
        kind: "deletion",
        record: {
          tenant_id: "alpha",
          person_id: "alpha",
          target: { Claim: "old-claim" },
          deleted_at: 22,
        },
      },
    ];
    const response = await request(
      "alpha",
      page("desktop", 3, records.length, 0, records),
    );
    expect(await response.json()).toEqual({
      replica_id: "desktop",
      commits: [{ sequence: 3, status: "applied" }],
    });
    const oldClaim = await database
      .prepare(
        "SELECT deleted_at FROM zkr_memory_records WHERE uid = 'alpha' AND replica_id = 'desktop' AND record_kind = 'claim' AND record_id = 'old-claim'",
      )
      .first<{ deleted_at: number | null }>();
    expect(Number(oldClaim?.deleted_at)).toBe(22);
    const kinds = await database
      .prepare(
        "SELECT record_kind FROM zkr_memory_records WHERE uid = 'alpha' AND replica_id = 'desktop' AND source_sequence = 3 ORDER BY record_kind",
      )
      .all();
    expect(kinds.results.map((row) => row.record_kind)).toEqual([
      "claim",
      "claim",
      "correction",
      "deletion",
    ]);
  });
});
