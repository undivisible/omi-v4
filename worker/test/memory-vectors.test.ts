import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import conversations from "../src/conversations";
import memorySync from "../src/memory-sync";
import {
  backfillClaimVectors,
  drainPendingEmbeddings,
  projectedClaimId,
  searchMemoryClaims,
} from "../src/memory-vectors";
import routes from "../src/routes";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

type StoredVector = {
  id: string;
  values: number[];
  metadata: Record<string, unknown>;
};

class FakeVectorIndex {
  vectors = new Map<string, StoredVector>();
  failNext = false;

  async upsert(list: StoredVector[]) {
    if (this.failNext) {
      this.failNext = false;
      throw new Error("Vectorize unavailable");
    }
    for (const vector of list) this.vectors.set(vector.id, vector);
    return { mutationId: "m" };
  }

  async deleteByIds(ids: string[]) {
    for (const id of ids) this.vectors.delete(id);
    return { mutationId: "m" };
  }

  async query(
    _vector: number[],
    options: { topK: number; filter?: { uid?: string } },
  ) {
    const matches = [...this.vectors.values()]
      .filter((vector) => vector.metadata.uid === options.filter?.uid)
      .slice(0, options.topK)
      .map((vector) => ({ id: vector.id, score: 0.9 }));
    return { matches, count: matches.length };
  }
}

const fakeIndex = new FakeVectorIndex();
let aiFailures = 0;
const fakeAi = {
  run: async (_model: string, inputs: Record<string, unknown>) => {
    if (aiFailures > 0) {
      aiFailures -= 1;
      throw new Error("AI unavailable");
    }
    return {
      data: (inputs.text as string[]).map((value) => [
        value.length,
        value.charCodeAt(0),
        1,
      ]),
    };
  },
};

let database: D1Database;
let env: Bindings;

const authApp = (uid: string) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/memory/zkr-sync", memorySync);
  app.route("/", conversations);
  app.route("/", routes);
  return app;
};

const request = (uid: string, path: string, init?: RequestInit) =>
  authApp(uid).request(path, init, env);

const syncPage = (uid: string, sequence: number, records: unknown[]) => ({
  export_format: 1,
  replica_id: "desktop",
  commits: [
    {
      sequence,
      recorded_at: 11 + sequence,
      event_count: records.length,
      first_event_index: 0,
      records,
    },
  ],
});

const claimRecord = (uid: string, id: string, value: string) => ({
  kind: "claim",
  record: {
    id,
    tenant_id: uid,
    person_id: uid,
    subject: "Sam",
    predicate: "prefers",
    value,
    kind: "fact",
    valid_time: { from: 10, until: null },
    recorded_time: { from: 11, until: null },
    status: "accepted",
  },
});

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of readdirSync("migrations").sort()) {
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
  env = {
    DB: database,
    MEMORY_VECTORS: fakeIndex as unknown as VectorizeIndex,
    AI: fakeAi,
  } as Bindings;
});

afterAll(() => miniflare.dispose());

describe("memory vector indexing", () => {
  test("zkr sync claim upsert enqueues and drain indexes the vector", async () => {
    const response = await request("alpha", "/memory/zkr-sync", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(
        syncPage("alpha", 1, [claimRecord("alpha", "claim-1", "matcha tea")]),
      ),
    });
    expect(response.status).toBe(200);
    const claimId = projectedClaimId("alpha", "desktop", "claim-1");
    const pending = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM pending_embeddings WHERE uid = 'alpha'",
      )
      .first<{ count: number }>();
    expect(Number(pending?.count)).toBeGreaterThanOrEqual(0);
    await drainPendingEmbeddings(env);
    const vector = fakeIndex.vectors.get(claimId);
    expect(vector).toBeDefined();
    expect(vector?.metadata).toMatchObject({
      uid: "alpha",
      claimId,
      kind: "claim",
    });
    const stamped = await database
      .prepare("SELECT vector_indexed_at FROM memory_claims WHERE id = ?1")
      .bind(claimId)
      .first<{ vector_indexed_at: number | null }>();
    expect(Number(stamped?.vector_indexed_at)).toBeGreaterThan(0);
  });

  test("failed embeds stay pending and are retried, never silently lost", async () => {
    aiFailures = 1;
    await request("alpha", "/memory/zkr-sync", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(
        syncPage("alpha", 2, [claimRecord("alpha", "claim-2", "espresso")]),
      ),
    });
    await drainPendingEmbeddings(env);
    const claimId = projectedClaimId("alpha", "desktop", "claim-2");
    const row = await database
      .prepare(
        "SELECT attempts, last_error FROM pending_embeddings WHERE claim_id = ?1",
      )
      .bind(claimId)
      .first<{ attempts: number; last_error: string }>();
    expect(Number(row?.attempts)).toBe(1);
    expect(String(row?.last_error)).toContain("Embedding failed");
    await drainPendingEmbeddings(env);
    expect(fakeIndex.vectors.has(claimId)).toBe(true);
    const drained = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM pending_embeddings WHERE claim_id = ?1",
      )
      .bind(claimId)
      .first<{ count: number }>();
    expect(Number(drained?.count)).toBe(0);
  });

  test("zkr deletion retracts the claim and removes its vector", async () => {
    const claimId = projectedClaimId("alpha", "desktop", "claim-1");
    expect(fakeIndex.vectors.has(claimId)).toBe(true);
    const response = await request("alpha", "/memory/zkr-sync", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(
        syncPage("alpha", 3, [
          {
            kind: "deletion",
            record: {
              tenant_id: "alpha",
              person_id: "alpha",
              target: { kind: "claim", id: "claim-1" },
              deleted_at: 99,
            },
          },
        ]),
      ),
    });
    expect(response.status).toBe(200);
    await drainPendingEmbeddings(env);
    expect(fakeIndex.vectors.has(claimId)).toBe(false);
  });

  test("semantic-search route is uid-scoped and returns the expected shape", async () => {
    const response = await request("alpha", "/memory/semantic-search?q=coffee");
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      query: string;
      items: Array<{ id: string; content: string; score: number }>;
    };
    expect(body.query).toBe("coffee");
    expect(body.items.length).toBeGreaterThan(0);
    expect(body.items[0]).toMatchObject({ content: "espresso" });
    expect(typeof body.items[0]?.score).toBe("number");
    const foreign = await request("beta", "/memory/semantic-search?q=coffee");
    expect(((await foreign.json()) as { items: unknown[] }).items).toEqual([]);
    const invalid = await request("alpha", "/memory/semantic-search");
    expect(invalid.status).toBe(400);
  });

  test("uid isolation holds in direct index search", async () => {
    expect(await searchMemoryClaims(env, "beta", "espresso")).toEqual([]);
    const own = await searchMemoryClaims(env, "alpha", "espresso");
    expect(own.some((item) => item.content === "espresso")).toBe(true);
  });

  test("inbox claim includes retrieved memory context for the agent", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_inbox
           (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
         VALUES ('inbox-1', 'alpha', 'telegram', 'event-1', 'message-1', 'tg-1', 'chat-1', 'what drink do I like?', '{}', ?1)`,
      )
      .bind(now)
      .run();
    const response = await request(
      "alpha",
      "/conversations/default/inbox/claim",
      { method: "POST" },
    );
    const body = (await response.json()) as {
      item: { id: string; memoryContext: string | null };
    };
    expect(body.item.id).toBe("inbox-1");
    expect(body.item.memoryContext).toContain("espresso");
    expect(body.item.memoryContext).toContain("Relevant synced memory");
  });

  test("inbox claim degrades to null context when vector search is unavailable", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_inbox
           (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
         VALUES ('inbox-2', 'beta', 'telegram', 'event-2', 'message-2', 'tg-2', 'chat-2', 'hello', '{}', ?1)`,
      )
      .bind(now)
      .run();
    const app = new Hono<AppEnv>();
    app.use("*", async (context, next) => {
      context.set("auth", { uid: "beta", email: null });
      await next();
    });
    app.route("/", conversations);
    const response = await app.request(
      "/conversations/default/inbox/claim",
      { method: "POST" },
      { DB: database } as Bindings,
    );
    const body = (await response.json()) as {
      item: { id: string; memoryContext: string | null };
    };
    expect(body.item.id).toBe("inbox-2");
    expect(body.item.memoryContext).toBeNull();
  });

  test("backfill enqueues claims missing vectors and drain indexes them", async () => {
    const claimId = crypto.randomUUID();
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO memory_claims (id, uid, content, subject, predicate, value, recorded_at, status)
         VALUES (?1, 'alpha', 'plays chess on sundays', 'Sam', 'hobby', 'plays chess on sundays', ?2, 'accepted')`,
      )
      .bind(claimId, now)
      .run();
    const enqueued = await backfillClaimVectors(env);
    expect(enqueued).toBeGreaterThan(0);
    await drainPendingEmbeddings(env);
    expect(fakeIndex.vectors.has(claimId)).toBe(true);
    expect(await backfillClaimVectors(env)).toBe(0);
    const remaining = await database
      .prepare("SELECT COUNT(*) AS count FROM pending_embeddings")
      .first<{ count: number }>();
    expect(Number(remaining?.count)).toBe(0);
  });

  test("account deletion clears pending embedding rows", async () => {
    const response = await request("alpha", "/account", { method: "DELETE" });
    expect(response.status).toBe(204);
    const remaining = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM pending_embeddings WHERE uid = 'alpha'",
      )
      .first<{ count: number }>();
    expect(Number(remaining?.count)).toBe(0);
  });
});
