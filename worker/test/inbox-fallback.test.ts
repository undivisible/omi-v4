import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import conversations from "../src/conversations";
import {
  offlineAcknowledgement,
  respondToStaleInboxItems,
} from "../src/inbox-fallback";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

class FakeVectorIndex {
  vectors = new Map<
    string,
    { id: string; values: number[]; metadata: Record<string, unknown> }
  >();

  async upsert(
    list: { id: string; values: number[]; metadata: Record<string, unknown> }[],
  ) {
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

const fakeAi = {
  run: async (_model: string, inputs: Record<string, unknown>) => ({
    data: (inputs.text as string[]).map((value) => [value.length, 1, 1]),
  }),
};

const admissionCalls: string[] = [];
const admissionNamespace = {
  getByName: () => ({
    fetch: async (input: RequestInfo | URL) => {
      admissionCalls.push(new URL(String(input)).pathname);
      return Response.json({ admitted: true, retryAfter: 0 });
    },
  }),
} as unknown as DurableObjectNamespace;

const dispatchedDeliveries: string[] = [];
const deliveryNamespace = {
  idFromName: (name: string) => ({ name }),
  get: () => ({
    fetch: async (_input: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as { id?: string };
      if (typeof body.id === "string") dispatchedDeliveries.push(body.id);
      return new Response(null, { status: 204 });
    },
  }),
} as unknown as DurableObjectNamespace;

type CapturedCompletion = {
  messages: Array<{ role: string; content: string }>;
};

const completionRequests: CapturedCompletion[] = [];
let completionReply: string | null = "Fallback answer from the worker.";

const fakeFetcher = (async (_input: RequestInfo | URL, init?: RequestInit) => {
  const body = JSON.parse(String(init?.body)) as CapturedCompletion;
  completionRequests.push(body);
  if (completionReply === null)
    return new Response("upstream failed", { status: 500 });
  return Response.json({
    choices: [{ message: { content: completionReply } }],
    usage: { prompt_tokens: 100, completion_tokens: 20 },
  });
}) as typeof fetch;

const testEnv = (overrides: Partial<Bindings> = {}): Bindings =>
  ({
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    MEMORY_VECTORS: fakeIndex as unknown as VectorizeIndex,
    AI: fakeAi,
    ASSISTANT_ADMISSION: admissionNamespace,
    DELIVERY_COORDINATOR: deliveryNamespace,
    MIMO_API_KEY: "mimo-key",
    MIMO_CHAT_COMPLETIONS_URL:
      "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
    MIMO_MODEL: "mimo-v2",
    MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS: "100",
    MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS: "400",
    DEV_FAKE_PRO: "true",
    ...overrides,
  }) as Bindings;

const insertInbox = async (
  id: string,
  uid: string,
  text: string,
  receivedAt: number,
  status = "pending",
) => {
  await database
    .prepare(
      `INSERT INTO channel_inbox
       (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, status, received_at)
       VALUES (?1, ?2, 'telegram', ?1, 'message-' || ?1, ?2 || '-chat', ?2 || '-chat', ?3, '{}', ?4, ?5)`,
    )
    .bind(id, uid, text, status, receivedAt)
    .run();
};

const inboxRow = (id: string) =>
  database
    .prepare(
      "SELECT status, attempts, lease_token, last_error FROM channel_inbox WHERE id = ?1",
    )
    .bind(id)
    .first<{
      status: string;
      attempts: number;
      lease_token: string | null;
      last_error: string | null;
    }>();

const deliveryRow = (inboxId: string, attempt: number) =>
  database
    .prepare("SELECT text, state FROM channel_deliveries WHERE id = ?1")
    .bind(`inbox-delivery:${inboxId}:${attempt}`)
    .first<{ text: string; state: string }>();

const request = (
  uid: string,
  path: string,
  init?: RequestInit,
  env?: Bindings,
) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/", conversations);
  return app.request(path, init, env ?? testEnv());
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  const migration = async (path: string) => {
    const sql = (await Bun.file(path).text()).replace(
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
  for (const file of [
    "migrations/0001_initial.sql",
    "migrations/0002_memory_and_policy.sql",
    "migrations/0003_align_kr_model.sql",
    "migrations/0004_saas_foundations.sql",
    "migrations/0005_memory_search.sql",
    "migrations/0016_zkr_sync.sql",
    "migrations/0017_zkr_read_projection.sql",
    "migrations/0007_channel_delivery.sql",
    "migrations/0008_managed_ai.sql",
    "migrations/0013_conversations.sql",
    "migrations/0014_channel_inbox_dispatch.sql",
    "migrations/0021_memory_vectors.sql",
    "migrations/0022_channel_link_codes.sql",
  ]) {
    await migration(file);
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('alpha', 'alpha@example.test', ?1, ?1), ('basic', 'basic@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
  for (const uid of ["alpha", "basic"]) {
    await database
      .prepare(
        "INSERT INTO channel_bindings (channel, channel_user_id, channel_chat_id, uid, verified_at) VALUES ('telegram', ?1 || '-chat', ?1 || '-chat', ?1, ?2)",
      )
      .bind(uid, now)
      .run();
  }
  await database
    .prepare(
      `INSERT INTO memory_claims (id, uid, content, recorded_at, subject, predicate, status)
       VALUES ('claim-espresso', 'alpha', 'Sam prefers espresso over filter coffee', ?1, 'Sam', 'prefers', 'accepted')`,
    )
    .bind(now)
    .run();
  await fakeIndex.upsert([
    {
      id: "claim-espresso",
      values: [1, 1, 1],
      metadata: { uid: "alpha", claimId: "claim-espresso", kind: "claim" },
    },
  ]);
});

afterAll(async () => {
  await miniflare.dispose();
});

beforeEach(() => {
  completionRequests.length = 0;
  dispatchedDeliveries.length = 0;
  admissionCalls.length = 0;
  completionReply = "Fallback answer from the worker.";
});

describe("channel inbox fallback responder", () => {
  test("answers a stale unclaimed item with memory context injected", async () => {
    const now = Date.now();
    await insertInbox(
      "stale-1",
      "alpha",
      "what coffee do I like?",
      now - 300_000,
    );
    await respondToStaleInboxItems(testEnv(), now, fakeFetcher);
    const row = await inboxRow("stale-1");
    expect(row?.status).toBe("done");
    expect(completionRequests.length).toBe(1);
    const system = completionRequests[0].messages[0];
    expect(system.role).toBe("system");
    expect(system.content).toContain("Sam prefers espresso");
    const last = completionRequests[0].messages.at(-1);
    expect(last).toEqual({ role: "user", content: "what coffee do I like?" });
    const delivery = await deliveryRow("stale-1", 1);
    expect(delivery?.text).toBe("Fallback answer from the worker.");
    expect(dispatchedDeliveries).toContain("inbox-delivery:stale-1:1");
    const stored = await database
      .prepare(
        "SELECT text, role FROM conversation_messages WHERE client_message_id = 'inbox-reply:stale-1:1'",
      )
      .first<{ text: string; role: string }>();
    expect(stored).toEqual({
      text: "Fallback answer from the worker.",
      role: "assistant",
    });
    expect(admissionCalls).toContain("/admit");
    expect(admissionCalls).toContain("/settle");
  });

  test("leaves leased and fresh items untouched", async () => {
    const now = Date.now();
    await insertInbox("fresh-1", "alpha", "fresh message", now - 30_000);
    await insertInbox("leased-1", "alpha", "leased message", now - 300_000);
    await database
      .prepare(
        "UPDATE channel_inbox SET status = 'processing', attempts = 1, lease_until = ?1, lease_token = 'desktop-lease-token' WHERE id = 'leased-1'",
      )
      .bind(now + 240_000)
      .run();
    await respondToStaleInboxItems(testEnv(), now, fakeFetcher);
    expect((await inboxRow("fresh-1"))?.status).toBe("pending");
    const leased = await inboxRow("leased-1");
    expect(leased?.status).toBe("processing");
    expect(leased?.lease_token).toBe("desktop-lease-token");
    expect(completionRequests.length).toBe(0);
    await database
      .prepare("DELETE FROM channel_inbox WHERE id IN ('fresh-1', 'leased-1')")
      .run();
  });

  test("late desktop completion after a worker reply cannot double-send", async () => {
    const now = Date.now();
    await insertInbox("raced-1", "alpha", "raced message", now - 300_000);
    const claimed = await request(
      "alpha",
      "/conversations/default/inbox/claim",
      { method: "POST" },
    );
    const claimBody = (await claimed.json()) as {
      item: { id: string; leaseToken: string } | null;
    };
    expect(claimBody.item?.id).toBe("raced-1");
    const desktopLease = claimBody.item?.leaseToken as string;
    await database
      .prepare(
        "UPDATE channel_inbox SET status = 'pending', lease_until = NULL, lease_token = NULL WHERE id = 'raced-1'",
      )
      .run();
    await respondToStaleInboxItems(testEnv(), now, fakeFetcher);
    expect((await inboxRow("raced-1"))?.status).toBe("done");
    const lateComplete = await request(
      "alpha",
      "/conversations/default/inbox/raced-1/complete",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          leaseToken: desktopLease,
          outcome: "done",
          responseText: "desktop reply",
        }),
      },
    );
    expect(lateComplete.status).toBe(409);
    const deliveries = await database
      .prepare(
        "SELECT COUNT(*) AS total FROM channel_deliveries WHERE idempotency_key LIKE 'inbox:raced-1:%'",
      )
      .first<{ total: number }>();
    expect(Number(deliveries?.total)).toBe(1);
  });

  test("worker lease blocks a concurrent desktop claim", async () => {
    const now = Date.now();
    await insertInbox("held-1", "alpha", "held message", now - 300_000);
    const leaseToken = crypto.randomUUID();
    await database
      .prepare(
        "UPDATE channel_inbox SET status = 'processing', attempts = 1, lease_until = ?1, lease_token = ?2 WHERE id = 'held-1'",
      )
      .bind(now + 120_000, leaseToken)
      .run();
    const claimed = await request(
      "alpha",
      "/conversations/default/inbox/claim",
      { method: "POST" },
    );
    const claimBody = (await claimed.json()) as { item: unknown };
    expect(claimBody.item).toBeNull();
    await database
      .prepare("DELETE FROM channel_inbox WHERE id = 'held-1'")
      .run();
  });

  test("non-Pro users receive the offline acknowledgement without a completion", async () => {
    const now = Date.now();
    await insertInbox("basic-1", "basic", "hello there", now - 300_000);
    await respondToStaleInboxItems(
      testEnv({ DEV_FAKE_PRO: undefined }),
      now,
      fakeFetcher,
    );
    expect((await inboxRow("basic-1"))?.status).toBe("done");
    expect(completionRequests.length).toBe(0);
    expect(admissionCalls.length).toBe(0);
    const delivery = await deliveryRow("basic-1", 1);
    expect(delivery?.text).toBe(offlineAcknowledgement);
  });

  test("failed completions release the lease for retry", async () => {
    const now = Date.now();
    await insertInbox("retry-1", "alpha", "please retry", now - 300_000);
    completionReply = null;
    await respondToStaleInboxItems(testEnv(), now, fakeFetcher);
    const row = await inboxRow("retry-1");
    expect(row?.status).toBe("pending");
    expect(row?.attempts).toBe(1);
    expect(row?.lease_token).toBeNull();
    expect(row?.last_error).toBe("Fallback completion unavailable");
    expect(await deliveryRow("retry-1", 1)).toBeNull();
  });

  test("final failed attempt still acknowledges the sender", async () => {
    const now = Date.now();
    await insertInbox("final-1", "alpha", "last chance", now - 300_000);
    await database
      .prepare("UPDATE channel_inbox SET attempts = 4 WHERE id = 'final-1'")
      .run();
    completionReply = null;
    await respondToStaleInboxItems(testEnv(), now, fakeFetcher);
    expect((await inboxRow("final-1"))?.status).toBe("done");
    const delivery = await deliveryRow("final-1", 5);
    expect(delivery?.text).toBe(offlineAcknowledgement);
  });

  test("the fallback can be disabled by configuration", async () => {
    const now = Date.now();
    await insertInbox("disabled-1", "alpha", "still waiting", now - 300_000);
    await respondToStaleInboxItems(
      testEnv({ CHANNEL_FALLBACK_RESPONDER: "false" }),
      now,
      fakeFetcher,
    );
    expect((await inboxRow("disabled-1"))?.status).toBe("pending");
    expect(completionRequests.length).toBe(0);
    await database
      .prepare("DELETE FROM channel_inbox WHERE id = 'disabled-1'")
      .run();
  });
});
