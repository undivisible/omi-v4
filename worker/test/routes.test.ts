import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import routes from "../src/routes";
import {
  DeliveryCoordinator,
  dispatchChannelMessage,
  deliverDueChannelMessages,
} from "../src/delivery";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
const coordinators = new Map<string, DeliveryCoordinator>();

const coordinatorNamespace = (environment: Bindings): DurableObjectNamespace =>
  ({
    idFromName: (name: string) => ({ name }),
    get: (id: { name: string }) => {
      let coordinator = coordinators.get(id.name);
      if (!coordinator) {
        coordinator = new DeliveryCoordinator(
          {
            id: {
              equals: (other: { name?: string }) => other.name === id.name,
            },
          } as unknown as DurableObjectState,
          environment,
        );
        coordinators.set(id.name, coordinator);
      } else {
        coordinator.env = environment;
      }
      return {
        fetch: (input: RequestInfo | URL, init?: RequestInit) =>
          coordinator.fetch(new Request(input, init)),
      };
    },
  }) as unknown as DurableObjectNamespace;

const testBindings = (environment: Partial<Bindings> = {}): Bindings => {
  const bindings = {
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    ...environment,
  } as Bindings;
  bindings.DELIVERY_COORDINATOR = coordinatorNamespace(bindings);
  return bindings;
};

const request = (
  uid: string,
  path: string,
  init?: RequestInit,
  environment: Partial<Bindings> = {},
) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/", routes);
  const bindings = testBindings(environment);
  return app.request(path, init, bindings);
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  const migration = async (path: string) => {
    const sql = (await Bun.file(path).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    for (const statement of sql.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  };
  await migration("migrations/0001_initial.sql");
  await migration("migrations/0002_memory_and_policy.sql");
  await migration("migrations/0003_align_kr_model.sql");
  await migration("migrations/0004_saas_foundations.sql");
  await migration("migrations/0005_memory_search.sql");
  await migration("migrations/0007_channel_delivery.sql");
  await migration("migrations/0013_conversations.sql");
  await migration("migrations/0014_channel_inbox_dispatch.sql");
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3), (?4, ?5, ?3, ?3)",
    )
    .bind("alpha", "alpha@example.test", now, "beta", "beta@example.test")
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("setup health", () => {
  test("reports readiness without returning credential values", async () => {
    const response = await request("alpha", "/setup-health", undefined, {
      TELEGRAM_WEBHOOK_SECRET: "telegram-webhook-secret",
      TELEGRAM_BOT_TOKEN: "telegram-bot-secret",
      MIMO_API_KEY: "mimo-secret",
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toEqual({
      worker: true,
      firebase: true,
      memory: true,
      channels: { telegram: true, blooio: false },
      billing: false,
      models: { managedChat: true, managedStt: false },
      desktopAuth: false,
    });
    expect(JSON.stringify(body)).not.toContain("secret");
  });
});

describe("shared conversation routes", () => {
  test("append is UID-scoped, replayable, and conflict-safe", async () => {
    const append = (uid: string, value: string) =>
      request(uid, "/conversations/default/messages", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientMessageId: "app:message-1",
          role: "user",
          source: "app",
          text: value,
        }),
      });
    expect((await append("alpha", "hello from app")).status).toBe(201);
    const replayed = await append("alpha", "hello from app");
    expect(replayed.status).toBe(200);
    expect(
      ((await replayed.json()) as { message: { replayed: boolean } }).message
        .replayed,
    ).toBe(true);
    expect((await append("alpha", "changed")).status).toBe(409);
    expect((await append("beta", "beta message")).status).toBe(201);
    const response = await request(
      "alpha",
      "/conversations/default/messages?after=0",
    );
    const value = (await response.json()) as {
      messages: Array<{ text: string }>;
      nextCursor: number;
    };
    expect(value.messages.map((message) => message.text)).toEqual([
      "hello from app",
    ]);
    expect(value.nextCursor).toBeGreaterThan(0);
  });

  test("replay cursors use optimistic revisions and never move backward", async () => {
    const update = (cursor: number, expectedRevision: number) =>
      request("alpha", "/conversations/default/cursors/app-client", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ cursor, expectedRevision }),
      });
    expect((await update(4, 0)).status).toBe(200);
    expect((await update(5, 0)).status).toBe(409);
    expect((await update(3, 1)).status).toBe(409);
    expect((await update(8, 1)).status).toBe(200);
  });

  test("leases channel prompts in order and atomically queues their replies", async () => {
    const now = Date.now();
    await database.batch([
      database
        .prepare(
          `INSERT INTO channel_bindings
             (channel, channel_user_id, uid, verified_at, channel_chat_id)
           VALUES ('blooio', 'dispatch-alpha', 'alpha', ?1, 'dispatch-alpha')`,
        )
        .bind(now),
      database
        .prepare(
          `INSERT INTO channel_inbox
             (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
           VALUES ('inbox-alpha-1', 'alpha', 'blooio', 'dispatch-alpha-1', 'message-alpha-1', 'dispatch-alpha', 'dispatch-alpha', 'first prompt', '{}', ?1)`,
        )
        .bind(now - 20),
      database
        .prepare(
          `INSERT INTO channel_inbox
             (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
           VALUES ('inbox-alpha-2', 'alpha', 'blooio', 'dispatch-alpha-2', 'message-alpha-2', 'dispatch-alpha', 'dispatch-alpha', 'second prompt', '{}', ?1)`,
        )
        .bind(now - 10),
      database
        .prepare(
          `INSERT INTO channel_inbox
             (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
           VALUES ('inbox-beta-1', 'beta', 'telegram', 'dispatch-beta-1', 'message-beta-1', 'dispatch-beta', 'dispatch-beta', 'beta prompt', '{}', ?1)`,
        )
        .bind(now - 30),
    ]);
    const claim = (uid: string) =>
      request(uid, "/conversations/default/inbox/claim", { method: "POST" });
    const first = (await (await claim("alpha")).json()) as {
      item: { id: string; attempt: number; leaseToken: string } | null;
    };
    expect(first.item).toMatchObject({ id: "inbox-alpha-1", attempt: 1 });
    expect(await (await claim("alpha")).json()).toEqual({ item: null });
    expect(await (await claim("beta")).json()).toMatchObject({
      item: { id: "inbox-beta-1" },
    });
    expect(
      (
        await request(
          "beta",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: first.item?.leaseToken,
              outcome: "done",
              responseText: "cross-tenant reply",
            }),
          },
        )
      ).status,
    ).toBe(409);
    const retry = await request(
      "alpha",
      "/conversations/default/inbox/inbox-alpha-1/complete",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          leaseToken: first.item?.leaseToken,
          outcome: "retry",
          error: "desktop restarted",
        }),
      },
    );
    expect(await retry.json()).toEqual({ status: "pending" });
    expect(
      await (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: first.item?.leaseToken,
              outcome: "retry",
              error: "desktop restarted",
            }),
          },
        )
      ).json(),
    ).toEqual({ status: "pending" });
    const second = (await (await claim("alpha")).json()) as {
      item: { id: string; attempt: number; leaseToken: string };
    };
    expect(second.item).toMatchObject({ id: "inbox-alpha-1", attempt: 2 });
    expect(
      await (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: second.item.leaseToken,
              outcome: "retry",
              error: "second desktop restarted",
            }),
          },
        )
      ).json(),
    ).toEqual({ status: "pending" });
    expect(
      await (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: first.item?.leaseToken,
              outcome: "retry",
              error: "desktop restarted",
            }),
          },
        )
      ).json(),
    ).toEqual({ status: "pending" });
    const third = (await (await claim("alpha")).json()) as {
      item: { id: string; attempt: number; leaseToken: string };
    };
    expect(third.item).toMatchObject({ id: "inbox-alpha-1", attempt: 3 });
    expect(
      (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: second.item.leaseToken,
              outcome: "done",
              responseText: "stale reply",
            }),
          },
        )
      ).status,
    ).toBe(409);
    const completed = await request(
      "alpha",
      "/conversations/default/inbox/inbox-alpha-1/complete",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          leaseToken: third.item.leaseToken,
          outcome: "done",
          responseText: "final reply",
        }),
      },
    );
    expect(await completed.json()).toMatchObject({ status: "done" });
    expect(
      await (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-1/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: first.item?.leaseToken,
              outcome: "retry",
              error: "desktop restarted",
            }),
          },
        )
      ).json(),
    ).toEqual({ status: "pending" });
    const duplicate = await request(
      "alpha",
      "/conversations/default/inbox/inbox-alpha-1/complete",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          leaseToken: third.item.leaseToken,
          outcome: "done",
          responseText: "final reply",
        }),
      },
    );
    expect(await duplicate.json()).toMatchObject({ status: "done" });
    await database
      .prepare(
        "UPDATE channel_inbox SET attempts = 4 WHERE id = 'inbox-alpha-2'",
      )
      .run();
    const finalAttempt = (await (await claim("alpha")).json()) as {
      item: { id: string; attempt: number; leaseToken: string };
    };
    expect(finalAttempt.item).toMatchObject({
      id: "inbox-alpha-2",
      attempt: 5,
    });
    expect(
      await (
        await request(
          "alpha",
          "/conversations/default/inbox/inbox-alpha-2/complete",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              leaseToken: finalAttempt.item.leaseToken,
              outcome: "retry",
              error: "retry limit",
            }),
          },
        )
      ).json(),
    ).toEqual({ status: "failed" });
    expect(
      await database
        .prepare(
          `SELECT m.text, d.idempotency_key
           FROM conversation_messages m
           JOIN channel_deliveries d ON d.id = m.delivery_id
           WHERE m.uid = 'alpha' AND m.client_message_id = 'inbox-reply:inbox-alpha-1:3'`,
        )
        .first(),
    ).toEqual({
      text: "final reply",
      idempotency_key: "inbox:inbox-alpha-1:attempt:3",
    });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_deliveries WHERE idempotency_key = 'inbox:inbox-alpha-1:attempt:3'",
        )
        .first(),
    ).toEqual({ count: 1 });
  });
});

describe("memory routes", () => {
  test("scope evidence to the Firebase UID and propagate source deletion", async () => {
    const created = await request("alpha", "/memories", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        content: "Alpha prefers concise status reports.",
        source: "conversation",
        evidence: [{ messageId: "message-1" }],
        profileKind: "stable",
      }),
    });
    expect(created.status).toBe(201);
    const identifiers = (await created.json()) as {
      id: string;
      sourceId: string;
      claimId: string;
    };

    const alpha = await request("alpha", "/memories");
    expect(alpha.status).toBe(200);
    const alphaBody = (await alpha.json()) as {
      memories: Array<{ id: string; evidence: Array<{ id: string }> }>;
    };
    expect(alphaBody.memories).toHaveLength(1);
    expect(alphaBody.memories[0]?.id).toBe(identifiers.id);
    expect(alphaBody.memories[0]?.evidence).toHaveLength(1);

    const retrieval = await request("alpha", "/memory/retrieve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "concise status", limit: 3 }),
    });
    expect(retrieval.status).toBe(200);
    expect((await retrieval.json()) as unknown).toEqual({
      query: "concise status",
      items: [
        {
          memory: { kind: "claim", id: identifiers.claimId },
          excerpt: "Alpha prefers concise status reports.",
          relevance_basis_points: 10000,
          evidence_ids: [alphaBody.memories[0]?.evidence[0]?.id],
        },
      ],
      gaps: [],
    });

    const revision = await request(
      "alpha",
      `/memory/sources/${identifiers.sourceId}/revisions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          payload: { content: "Alpha prefers short, numbered status reports." },
        }),
      },
    );
    expect(revision.status).toBe(201);
    expect((await revision.json()) as unknown).toMatchObject({ revision: 2 });

    const review = await request("alpha", "/memory/daily-reviews", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        localDate: "2026-07-21",
        inputRevision: "input-1",
        body: "You established a preference for concise reports.",
        citationIds: [alphaBody.memories[0]?.evidence[0]?.id],
      }),
    });
    expect(review.status).toBe(201);
    const reviews = await request("alpha", "/memory/daily-reviews");
    const reviewsBody = (await reviews.json()) as {
      reviews: Array<{ citations: unknown[] }>;
    };
    expect(reviewsBody.reviews).toHaveLength(1);
    expect(reviewsBody.reviews[0]?.citations).toHaveLength(1);

    const beta = await request("beta", "/memories");
    expect(((await beta.json()) as { memories: unknown[] }).memories).toEqual(
      [],
    );

    const removed = await request(
      "alpha",
      `/memory/sources/${identifiers.sourceId}`,
      { method: "DELETE" },
    );
    expect(removed.status).toBe(204);
    const afterDeletion = await request("alpha", "/memories");
    expect(
      ((await afterDeletion.json()) as { memories: unknown[] }).memories,
    ).toEqual([]);
    const reviewsAfterDeletion = await request(
      "alpha",
      "/memory/daily-reviews",
    );
    expect(
      (
        (await reviewsAfterDeletion.json()) as {
          reviews: unknown[];
        }
      ).reviews,
    ).toEqual([]);
  });
});

describe("settings routes", () => {
  test("enforce revisions, durations, and pre-existing owner confirmation", async () => {
    const changed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 0,
        duration: "persistent",
        patch: { proactiveRecommendations: false },
      }),
    });
    expect(changed.status).toBe(200);
    expect((await changed.json()) as unknown).toEqual({
      settings: {
        approvalMode: "once",
        proactiveRecommendations: false,
      },
      revision: 1,
      duration: "persistent",
      diff: {
        proactiveRecommendations: { from: true, to: false },
      },
      effectivePolicy: {
        approvalMode: "once",
        proactiveRecommendations: false,
      },
      restartRequired: false,
    });

    const stale = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 0,
        duration: "persistent",
        patch: { proactiveRecommendations: true },
      }),
    });
    expect(stale.status).toBe(409);

    const unconfirmed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 1,
        duration: "persistent",
        patch: { approvalMode: "auto" },
      }),
    });
    expect(unconfirmed.status).toBe(403);

    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO owner_confirmation_receipts (id, uid, purpose, value, created_at, expires_at) VALUES ('receipt-1', 'alpha', 'settings.approvalMode', 'auto', ?1, ?2)",
      )
      .bind(now - 1_000, now + 60_000)
      .run();
    const confirmed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 1,
        duration: "persistent",
        confirmationReceiptId: "receipt-1",
        patch: { approvalMode: "auto" },
      }),
    });
    expect(confirmed.status).toBe(200);
    expect((await confirmed.json()) as unknown).toMatchObject({ revision: 2 });

    const scoped = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 2,
        duration: "task",
        taskId: "task-1",
        patch: { proactiveRecommendations: true },
      }),
    });
    expect(scoped.status).toBe(200);
    expect((await scoped.json()) as unknown).toMatchObject({
      revision: 2,
      duration: "task",
      scopeId: "task-1",
      diff: {
        proactiveRecommendations: { from: false, to: true },
      },
      effectivePolicy: {
        approvalMode: "auto",
        proactiveRecommendations: true,
      },
      restartRequired: false,
    });
  });
});

describe("channel routes", () => {
  test("unlink revokes only the current Firebase UID and records an audit", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at)
         VALUES ('telegram', 'alpha-chat', 'alpha', ?1), ('telegram', 'beta-chat', 'beta', ?1)`,
      )
      .bind(now)
      .run();
    await database
      .prepare(
        `INSERT INTO channel_deliveries
           (id, uid, channel, idempotency_key, channel_chat_id, text, state, next_attempt_at, created_at, updated_at)
         VALUES
           ('unlink-delivery', 'alpha', 'telegram', 'unlink:test', 'alpha-chat', 'cancel me', 'pending', ?1, ?1, ?1),
           ('unlink-unknown', 'alpha', 'telegram', 'unlink:unknown', 'alpha-chat', 'maybe sent', 'unknown', ?1, ?1, ?1)`,
      )
      .bind(now)
      .run();

    const response = await request("alpha", "/channels/telegram/link", {
      method: "DELETE",
    });
    expect(response.status).toBe(204);

    const bindings = await database
      .prepare(
        "SELECT uid, revoked_at FROM channel_bindings WHERE channel = 'telegram' ORDER BY uid",
      )
      .all();
    expect(bindings.results).toHaveLength(2);
    expect(bindings.results[0]?.uid).toBe("alpha");
    expect(bindings.results[0]?.revoked_at).not.toBeNull();
    expect(bindings.results[1]?.uid).toBe("beta");
    expect(bindings.results[1]?.revoked_at).toBeNull();

    const audit = await database
      .prepare(
        "SELECT action, target_id FROM audit_events WHERE uid = 'alpha' ORDER BY created_at DESC LIMIT 1",
      )
      .first();
    expect(audit).toMatchObject({
      action: "channel.unlinked",
      target_id: "telegram",
    });
    expect(
      (
        await database
          .prepare(
            "SELECT state, last_error FROM channel_deliveries WHERE id IN ('unlink-delivery', 'unlink-unknown') ORDER BY id",
          )
          .all()
      ).results,
    ).toEqual([
      { state: "cancelled", last_error: "Channel unlinked" },
      { state: "cancelled", last_error: "Channel unlinked" },
    ]);
  });

  test("delivers Blooio messages once with provider authentication", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, channel_chat_id)
       VALUES ('blooio', '+15551234567', 'alpha', ?1, '+15551234567')
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET revoked_at = NULL, channel_chat_id = excluded.channel_chat_id`,
      )
      .bind(now)
      .run();
    const originalFetch = globalThis.fetch;
    const calls: Array<{
      url: string;
      authorization: string | null;
      key: string | null;
    }> = [];
    globalThis.fetch = async (input, init) => {
      const headers = new Headers(init?.headers);
      calls.push({
        url: String(input),
        authorization: headers.get("authorization"),
        key: headers.get("idempotency-key"),
      });
      return Response.json({ message_id: "blooio-message-1" });
    };
    try {
      const send = (textValue = "Remember the meeting") =>
        request(
          "alpha",
          "/channels/blooio/messages",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              text: textValue,
              idempotencyKey: "task:meeting:1",
            }),
          },
          { BLOOIO_API_KEY: "blooio-test-key" },
        );
      expect((await send()).status).toBe(200);
      expect((await send()).status).toBe(200);
      expect((await send("Different text")).status).toBe(409);
      const digest = await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode("alpha\u0000blooio\u0000task:meeting:1"),
      );
      const providerKey = Buffer.from(digest).toString("hex");
      expect(calls).toEqual([
        {
          url: "https://api.blooio.com/v2/api/chats/%2B15551234567/messages",
          authorization: "Bearer blooio-test-key",
          key: providerKey,
        },
      ]);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("fails closed without credentials and bounds transient retries", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)
       VALUES ('telegram', 'alpha-retry-chat', 'alpha', ?1, NULL, 'alpha-retry-chat')
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET revoked_at = NULL, channel_chat_id = excluded.channel_chat_id`,
      )
      .bind(now)
      .run();
    const body = (key: string) =>
      JSON.stringify({
        text: "Retry safely",
        idempotencyKey: key,
      });
    const missing = await request("alpha", "/channels/telegram/messages", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: body("task:missing-auth"),
    });
    expect(missing.status).toBe(503);
    expect((await missing.json()) as unknown).toMatchObject({
      delivery: {
        state: "failed",
        attempts: 1,
        last_error: "Provider credentials unavailable",
      },
    });

    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return new Response("unavailable", { status: 503 });
    };
    try {
      const first = await request(
        "alpha",
        "/channels/telegram/messages",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: body("task:bounded-retry"),
        },
        { TELEGRAM_BOT_TOKEN: "telegram-test-token" },
      );
      expect(first.status).toBe(202);
      for (let attempt = 1; attempt < 5; attempt += 1) {
        await deliverDueChannelMessages(
          testBindings({
            TELEGRAM_BOT_TOKEN: "telegram-test-token",
          }),
          now + attempt * 60 * 60_000,
        );
      }
      await deliverDueChannelMessages(
        testBindings({
          TELEGRAM_BOT_TOKEN: "telegram-test-token",
        }),
        now + 10 * 60 * 60_000,
      );
      const delivery = await database
        .prepare(
          "SELECT state, attempts FROM channel_deliveries WHERE uid = 'alpha' AND idempotency_key = 'task:bounded-retry'",
        )
        .first();
      expect(delivery).toEqual({ state: "failed", attempts: 5 });
      expect(calls).toBe(5);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("keeps Telegram network ambiguity unknown without retrying", async () => {
    const now = Date.now();
    let calls = 0;
    const originalFetch = globalThis.fetch;
    const failure = async () => {
      calls += 1;
      throw new TypeError("network lost");
    };
    globalThis.fetch = failure;
    try {
      const response = await request(
        "alpha",
        "/channels/telegram/messages",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            text: "Ambiguous Telegram result",
            idempotencyKey: "task:telegram-unknown",
          }),
        },
        { TELEGRAM_BOT_TOKEN: "telegram-test-token" },
      );
      expect(response.status).toBe(202);
      expect((await response.json()) as unknown).toMatchObject({
        delivery: { state: "unknown", attempts: 1 },
      });
      await deliverDueChannelMessages(
        testBindings({
          TELEGRAM_BOT_TOKEN: "telegram-test-token",
        }),
        now + 24 * 60 * 60_000,
      );
      expect(calls).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("serializes a destination and honors provider retry-after JSON", async () => {
    const now = Date.now();
    let calls = 0;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      calls += 1;
      return calls === 1
        ? Response.json({ parameters: { retry_after: 120 } }, { status: 429 })
        : Response.json({ message_id: `message-${calls}` });
    };
    try {
      const send = (key: string, message: string) =>
        request(
          "alpha",
          "/channels/blooio/messages",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ text: message, idempotencyKey: key }),
          },
          { BLOOIO_API_KEY: "blooio-test-key" },
        );
      expect((await send("ordered:first", "first")).status).toBe(202);
      expect((await send("ordered:second", "second")).status).toBe(202);
      expect(calls).toBe(1);
      const first = await database
        .prepare(
          "SELECT next_attempt_at, updated_at FROM channel_deliveries WHERE uid = 'alpha' AND idempotency_key = 'ordered:first'",
        )
        .first<{ next_attempt_at: number; updated_at: number }>();
      expect(Number(first?.next_attempt_at) - Number(first?.updated_at)).toBe(
        120_000,
      );
      const env = testBindings({
        BLOOIO_API_KEY: "blooio-test-key",
      });
      await deliverDueChannelMessages(env, now + 3 * 60_000);
      expect(calls).toBe(2);
      await deliverDueChannelMessages(env, now + 3 * 60_000);
      expect(calls).toBe(3);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("does not let another tenant block or claim the same destination", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)
         VALUES ('blooio', 'beta-shared-user', 'beta', ?1, NULL, '+15551234567')
         ON CONFLICT(channel, channel_user_id) DO UPDATE SET uid = excluded.uid, revoked_at = NULL, channel_chat_id = excluded.channel_chat_id`,
      )
      .bind(now)
      .run();
    await database
      .prepare(
        `INSERT INTO channel_deliveries
           (id, uid, channel, idempotency_key, channel_chat_id, text, state, next_attempt_at, created_at, updated_at)
         VALUES
           ('alpha-shared-older', 'alpha', 'blooio', 'shared:alpha', '+15551234567', 'alpha waits', 'retry', ?1, ?1, ?1),
           ('beta-shared-newer', 'beta', 'blooio', 'shared:beta', '+15551234567', 'beta sends', 'pending', ?1, ?1, ?1)`,
      )
      .bind(now)
      .run();
    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return Response.json({ message_id: "beta-shared-sent" });
    };
    try {
      const environment = testBindings({ BLOOIO_API_KEY: "blooio-test-key" });
      await dispatchChannelMessage(
        environment,
        "beta-shared-newer",
        "alpha",
        "blooio",
        now,
      );
      expect(calls).toBe(0);
      await dispatchChannelMessage(
        environment,
        "beta-shared-newer",
        "beta",
        "blooio",
        now,
      );
      expect(calls).toBe(1);
      expect(
        await database
          .prepare(
            "SELECT state, provider_message_id FROM channel_deliveries WHERE id = 'beta-shared-newer'",
          )
          .first(),
      ).toEqual({ state: "sent", provider_message_id: "beta-shared-sent" });
    } finally {
      globalThis.fetch = originalFetch;
      await database
        .prepare(
          "UPDATE channel_deliveries SET state = 'cancelled' WHERE id = 'alpha-shared-older'",
        )
        .run();
    }
  });

  test("fences a stale lease from completing a delivery", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_deliveries
           (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at)
         VALUES ('lease-fence', 'alpha', 'blooio', 'lease:fence', '+15551234567', 'fenced', ?1, ?1, ?1)`,
      )
      .bind(now)
      .run();
    let release: ((response: Response) => void) | undefined;
    let started: (() => void) | undefined;
    const waiting = new Promise<void>((resolve) => {
      started = resolve;
    });
    const provider = new Promise<Response>((resolve) => {
      release = resolve;
    });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      started?.();
      return provider;
    };
    const environment = testBindings({
      BLOOIO_API_KEY: "blooio-test-key",
    });
    const delivery = dispatchChannelMessage(
      environment,
      "lease-fence",
      "alpha",
      "blooio",
      now,
    );
    await waiting;
    await database
      .prepare(
        "UPDATE channel_deliveries SET lease_token = 'replacement-lease' WHERE id = 'lease-fence'",
      )
      .run();
    release?.(Response.json({ message_id: "stale-success" }));
    await delivery;
    globalThis.fetch = originalFetch;
    expect(
      await database
        .prepare(
          "SELECT state, lease_token, provider_message_id FROM channel_deliveries WHERE id = 'lease-fence'",
        )
        .first(),
    ).toEqual({
      state: "delivering",
      lease_token: "replacement-lease",
      provider_message_id: null,
    });
    await database
      .prepare(
        "UPDATE channel_deliveries SET state = 'cancelled', lease_token = NULL, lease_until = NULL WHERE id = 'lease-fence'",
      )
      .run();
  });

  test("unlink waits behind an in-flight send boundary", async () => {
    const originalFetch = globalThis.fetch;
    let providerStarted: (() => void) | undefined;
    let releaseProvider: (() => void) | undefined;
    const started = new Promise<void>((resolve) => {
      providerStarted = resolve;
    });
    const provider = new Promise<void>((resolve) => {
      releaseProvider = resolve;
    });
    globalThis.fetch = async () => {
      providerStarted?.();
      await provider;
      return Response.json({ message_id: "race-sent" });
    };
    try {
      const send = request(
        "alpha",
        "/channels/blooio/messages",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            text: "Finish before unlink",
            idempotencyKey: "race:send-unlink",
          }),
        },
        { BLOOIO_API_KEY: "blooio-test-key" },
      );
      await started;
      let unlinkResolved = false;
      const unlink = request("alpha", "/channels/blooio/link", {
        method: "DELETE",
      }).then((response) => {
        unlinkResolved = true;
        return response;
      });
      await new Promise((resolve) => setTimeout(resolve, 10));
      expect(unlinkResolved).toBe(false);
      releaseProvider?.();
      expect((await send).status).toBe(200);
      expect((await unlink).status).toBe(204);
      expect(
        await database
          .prepare(
            "SELECT state, provider_message_id FROM channel_deliveries WHERE uid = 'alpha' AND idempotency_key = 'race:send-unlink'",
          )
          .first(),
      ).toEqual({ state: "sent", provider_message_id: "race-sent" });
      expect(
        await database
          .prepare(
            "SELECT revoked_at FROM channel_bindings WHERE uid = 'alpha' AND channel = 'blooio' AND channel_user_id = '+15551234567'",
          )
          .first(),
      ).toMatchObject({ revoked_at: expect.any(Number) });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

describe("billing routes", () => {
  test("ties Stripe Checkout and Portal sessions to the Firebase UID", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ url: string; body: URLSearchParams }> = [];
    globalThis.fetch = async (input, init) => {
      requests.push({
        url: String(input),
        body: new URLSearchParams(String(init?.body)),
      });
      return Response.json({
        id: `session-${requests.length}`,
        url: "https://stripe.test/session",
      });
    };
    try {
      const environment = {
        STRIPE_SECRET_KEY: "sk_test",
        STRIPE_PRO_PRICE_ID: "price_pro",
        APP_URL: "https://app.example.test",
      };
      const checkout = await request(
        "alpha",
        "/payments/stripe/checkout",
        { method: "POST" },
        environment,
      );
      expect(checkout.status).toBe(201);
      expect(requests[0]?.body.get("client_reference_id")).toBe("alpha");
      expect(
        requests[0]?.body.get("subscription_data[metadata][firebase_uid]"),
      ).toBe("alpha");
      await database
        .prepare(
          `INSERT INTO entitlements
             (uid, plan, status, stripe_customer_id, updated_at)
           VALUES ('alpha', 'pro', 'active', 'cus_alpha', ?1)`,
        )
        .bind(Date.now())
        .run();
      const portal = await request(
        "alpha",
        "/payments/stripe/portal",
        { method: "POST" },
        environment,
      );
      expect(portal.status).toBe(201);
      expect(requests[1]?.body.get("customer")).toBe("cus_alpha");
      expect(requests[1]?.url).toEndWith("/billing_portal/sessions");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
