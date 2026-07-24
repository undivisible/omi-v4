import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import memorySync from "../src/memory-sync";
import routes from "../src/routes";
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

const routeRequest = (uid: string, path: string, init?: RequestInit) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/", routes);
  return app.request(path, init, { DB: database } as AppEnv["Bindings"]);
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

const evidence = (
  uid: string,
  id: string,
  sourceId: string,
  quote: string,
) => ({
  kind: "evidence",
  record: {
    evidence: {
      id,
      tenant_id: uid,
      person_id: uid,
      source_id: sourceId,
      source_revision: 1,
      quote,
      byte_range: null,
      recorded_at: 11,
    },
    locator: {
      device_id: "desktop",
      provider: "omi",
      stream_id: "stream",
      segment_id: "segment",
      start_ms: 0,
      end_ms: 1000,
    },
    deleted_at: null,
  },
});

const claimEvidence = (uid: string, claimId: string, evidenceId: string) => ({
  kind: "claim_evidence",
  record: {
    tenant_id: uid,
    person_id: uid,
    claim_id: claimId,
    evidence_id: evidenceId,
    relation: "supports",
    confidence_basis_points: 9000,
  },
});

const profile = (uid: string, id: string, claimId: string, value: string) => ({
  kind: "profile",
  record: {
    id,
    tenant_id: uid,
    person_id: uid,
    key: "priority",
    value,
    stability: "current",
    claim_id: claimId,
    recorded_at: 11,
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
  for (const name of [
    "0001_initial.sql",
    "0002_memory_and_policy.sql",
    "0003_align_kr_model.sql",
    "0005_memory_search.sql",
    "0012_currents.sql",
    "0015_currents_generation.sql",
    "0016_zkr_sync.sql",
    "0017_zkr_read_projection.sql",
    "0021_memory_vectors.sql",
    "0029_memory_authority_log.sql",
    "0030_memory_log_projection.sql",
  ]) {
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
      .prepare("SELECT COUNT(*) AS count FROM memory_records")
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
        "SELECT record_kind, record_id FROM memory_records WHERE uid = 'alpha' ORDER BY record_kind",
      )
      .all();
    expect(applied.results).toEqual([
      { record_kind: "claim", record_id: "old-claim" },
      { record_kind: "source", record_id: "source-1" },
    ]);
    const log = await database
      .prepare(
        "SELECT sequence, origin_replica, record_kind, record_id FROM memory_log WHERE uid = 'alpha' ORDER BY sequence",
      )
      .all();
    expect(log.results).toEqual([
      {
        sequence: 1,
        origin_replica: "desktop",
        record_kind: "source",
        record_id: "source-1",
      },
      {
        sequence: 2,
        origin_replica: "desktop",
        record_kind: "claim",
        record_id: "old-claim",
      },
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
        "SELECT COUNT(*) AS count FROM memory_records WHERE uid = 'alpha'",
      )
      .first<{ count: number }>();
    expect(Number(count?.count)).toBe(2);
    const log = await database
      .prepare("SELECT COUNT(*) AS count FROM memory_log WHERE uid = 'alpha'")
      .first<{ count: number }>();
    expect(Number(log?.count)).toBe(2);
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
        "SELECT deleted_at FROM memory_records WHERE uid = 'alpha' AND record_kind = 'claim' AND record_id = 'old-claim'",
      )
      .first<{ deleted_at: number | null }>();
    expect(Number(oldClaim?.deleted_at)).toBe(22);
    const kinds = await database
      .prepare(
        "SELECT record_kind FROM memory_log WHERE uid = 'alpha' AND origin_replica = 'desktop' AND sequence > 2 ORDER BY record_kind",
      )
      .all();
    expect(kinds.results.map((row) => row.record_kind)).toEqual([
      "claim",
      "claim",
      "correction",
      "deletion",
    ]);
  });

  test("projects cited synced memory into retrieval, the portal, and Currents without crossing UIDs", async () => {
    const records = [
      source("alpha", "projection-source", "Ship the concise release"),
      evidence(
        "alpha",
        "projection-evidence",
        "projection-source",
        "Ship the concise release",
      ),
      {
        ...claim("alpha", "projection-claim"),
        record: {
          ...claim("alpha", "projection-claim").record,
          subject: "Sam",
          predicate: "priority",
          value: "Ship the concise release",
          kind: "task",
        },
      },
      claimEvidence("alpha", "projection-claim", "projection-evidence"),
      profile(
        "alpha",
        "projection-profile",
        "projection-claim",
        "Ship the concise release",
      ),
    ];
    const synced = await request(
      "alpha",
      page("projection", 1, records.length, 0, records),
    );
    expect(await synced.json()).toEqual({
      replica_id: "projection",
      commits: [{ sequence: 1, status: "applied" }],
    });

    const memories = (await (
      await routeRequest("alpha", "/memories")
    ).json()) as {
      memories: Array<{
        content: string;
        evidence: Array<{ quote: string; locator: unknown }>;
      }>;
    };
    expect(memories.memories).toEqual([
      expect.objectContaining({
        content: "Ship the concise release",
        evidence: [
          expect.objectContaining({
            quote: "Ship the concise release",
            locator: expect.objectContaining({ segment_id: "segment" }),
          }),
        ],
      }),
    ]);
    const retrieval = (await (
      await routeRequest("alpha", "/memory/retrieve?q=concise%20release")
    ).json()) as { items: Array<{ evidence_ids: string[] }> };
    expect(retrieval.items).toHaveLength(1);
    expect(retrieval.items[0]?.evidence_ids).toHaveLength(1);
    expect(await (await routeRequest("beta", "/memories")).json()).toEqual({
      memories: [],
    });
    expect(
      await (
        await routeRequest("beta", "/memory/retrieve?q=concise%20release")
      ).json(),
    ).toEqual({
      query: "concise release",
      items: [],
      gaps: ["No cited memory matched the query."],
    });

    const generated = await routeRequest("alpha", "/currents/generate", {
      method: "POST",
    });
    expect(generated.status).toBe(201);
    expect(await generated.json()).toMatchObject({
      current: {
        title: "Revisit: Ship the concise release",
        evidence: [expect.objectContaining({})],
      },
    });
  });

  test("reprojects corrections and tagged deletions without leaving visible or eligible memory", async () => {
    const corrected = [
      {
        ...claim("alpha", "projection-claim", "superseded"),
        record: {
          ...claim("alpha", "projection-claim", "superseded").record,
          subject: "Sam",
          predicate: "priority",
          value: "Ship the concise release",
          kind: "task",
          recorded_time: { from: 11, until: 21 },
        },
      },
      {
        kind: "correction",
        record: {
          tenant_id: "alpha",
          person_id: "alpha",
          superseded_claim_id: "projection-claim",
          claim_id: "replacement-claim",
          source_id: "projection-source",
          evidence_id: "projection-evidence",
          valid_at: 20,
          recorded_at: 21,
        },
      },
      {
        kind: "deletion",
        record: {
          tenant_id: "alpha",
          person_id: "alpha",
          target: { kind: "evidence", id: "projection-evidence" },
          deleted_at: 22,
        },
      },
    ];
    expect(
      await (
        await request(
          "alpha",
          page("projection", 2, corrected.length, 0, corrected),
        )
      ).json(),
    ).toEqual({
      replica_id: "projection",
      commits: [{ sequence: 2, status: "applied" }],
    });
    expect(await (await routeRequest("alpha", "/memories")).json()).toEqual({
      memories: [],
    });
    expect(
      await (
        await routeRequest("alpha", "/memory/retrieve?q=concise%20release")
      ).json(),
    ).toEqual({
      query: "concise release",
      items: [],
      gaps: ["No cited memory matched the query."],
    });
    expect(
      await (
        await routeRequest("alpha", "/currents/generate", { method: "POST" })
      ).json(),
    ).toEqual({ current: null });
    expect(await (await routeRequest("alpha", "/currents")).json()).toEqual({
      currents: [],
    });
  });
});
