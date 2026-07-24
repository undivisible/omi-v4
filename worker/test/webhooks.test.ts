import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";
import { app } from "../src/index";

const secret = "whsec_test";
const encoder = new TextEncoder();
const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const sign = async (body: string) => {
  const timestamp = Math.floor(Date.now() / 1_000);
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(`${timestamp}.${body}`),
    ),
  );
  const signature = Array.from(digest, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `t=${timestamp},v1=${signature}`;
};

const tokenHash = async (token: string) => {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(token)),
  );
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const migration of [
    "migrations/0001_initial.sql",
    "migrations/0002_memory_and_policy.sql",
    "migrations/0003_align_kr_model.sql",
    "migrations/0004_saas_foundations.sql",
    "migrations/0005_memory_search.sql",
    "migrations/0007_channel_delivery.sql",
    "migrations/0013_conversations.sql",
    "migrations/0014_channel_inbox_dispatch.sql",
    "migrations/0022_channel_link_codes.sql",
    "migrations/0026_channel_accounts.sql",
    "migrations/0028_channel_checkout.sql",
  ]) {
    const sql = (await Bun.file(migration).text()).replace(
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
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('alpha', 'alpha@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

const rateLimiter = {
  getByName: () => ({
    fetch: async () => Response.json({ allowed: true, retryAfter: 0 }),
  }),
} as unknown as DurableObjectNamespace;

describe("channel webhooks", () => {
  test("an unknown sender is greeted once, and a replayed update changes nothing", async () => {
    const send = (updateId: number, text: string) =>
      app.request(
        "/v1/webhooks/telegram",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-telegram-bot-api-secret-token": "telegram-secret",
          },
          body: JSON.stringify({
            update_id: updateId,
            message: {
              message_id: updateId + 500,
              text,
              from: { id: 909 },
              chat: { id: 909 },
            },
          }),
        },
        {
          DB: database,
          FIREBASE_PROJECT_ID: "test",
          TELEGRAM_WEBHOOK_SECRET: "telegram-secret",
          RATE_LIMITER: rateLimiter,
        },
      );
    expect(await (await send(101, "hi")).json()).toEqual({
      accepted: true,
      queued: false,
      replied: true,
    });
    expect(await (await send(102, "nope")).json()).toEqual({
      accepted: true,
      queued: false,
      replied: true,
    });
    const account = await database
      .prepare(
        "SELECT uid FROM channel_accounts WHERE channel = 'telegram' AND channel_user_id = '909'",
      )
      .first<{ uid: string }>();
    expect(account?.uid).toMatch(/^chan_/);
    const replay = await send(102, "nope");
    expect(await replay.json()).toEqual({ accepted: true, duplicate: true });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_accounts WHERE channel_user_id = '909'",
        )
        .first(),
    ).toMatchObject({ count: 1 });
    expect(
      await database
        .prepare("SELECT COUNT(*) AS count FROM users WHERE uid LIKE 'chan_%'")
        .first(),
    ).toMatchObject({ count: 1 });
    await database
      .prepare("DELETE FROM channel_inbox WHERE channel_user_id = '909'")
      .run();
    await database
      .prepare("DELETE FROM conversation_messages WHERE uid LIKE 'chan_%'")
      .run();
  });

  test("links Telegram once and queues later messages for the Firebase UID", async () => {
    const token = "a".repeat(48);
    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO channel_link_tokens (token_hash, uid, channel, expires_at, created_at) VALUES (?1, 'alpha', 'telegram', ?2, ?3)",
      )
      .bind(await tokenHash(token), now + 60_000, now)
      .run();
    const send = (update: unknown) =>
      app.request(
        "/v1/webhooks/telegram",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-telegram-bot-api-secret-token": "telegram-secret",
          },
          body: JSON.stringify(update),
        },
        {
          DB: database,
          FIREBASE_PROJECT_ID: "test",
          TELEGRAM_WEBHOOK_SECRET: "telegram-secret",
        },
      );
    const linked = await send({
      update_id: 1,
      message: {
        message_id: 10,
        text: `/start ${token}`,
        from: { id: 42 },
        chat: { id: 42 },
      },
    });
    expect(await linked.json()).toEqual({ accepted: true, linked: true });
    const reused = await send({
      update_id: 3,
      message: {
        message_id: 12,
        text: `/start ${token}`,
        from: { id: 42 },
        chat: { id: 42 },
      },
    });
    expect(await reused.json()).toEqual({ accepted: true, linked: false });
    const queued = await send({
      update_id: 2,
      message: {
        message_id: 11,
        text: "What should I do next?",
        from: { id: 42 },
        chat: { id: 42 },
      },
    });
    expect(await queued.json()).toEqual({
      accepted: true,
      queued: true,
      replied: false,
    });
    expect(
      await database
        .prepare(
          "SELECT role, source, text, channel_message_id FROM conversation_messages WHERE uid = 'alpha'",
        )
        .first(),
    ).toEqual({
      role: "user",
      source: "telegram",
      text: "What should I do next?",
      channel_message_id: "11",
    });
    expect(
      await database
        .prepare(
          "SELECT uid, text FROM channel_inbox WHERE channel = 'telegram'",
        )
        .first(),
    ).toMatchObject({ uid: "alpha", text: "What should I do next?" });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM audit_events WHERE action = 'channel.linked'",
        )
        .first(),
    ).toMatchObject({ count: 1 });
  });

  test("normalizes a signed Blooio message and deduplicates its provider id", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings
           (channel, channel_user_id, uid, verified_at, channel_chat_id)
         VALUES ('blooio', '+15551234567', 'alpha', ?1, '+15551234567')`,
      )
      .bind(now)
      .run();
    const body = JSON.stringify({
      event: "message.received",
      message_id: "msg_abc123",
      external_id: "+15551234567",
      sender: "+15551234567",
      status: "received",
      protocol: "imessage",
      timestamp: now,
      text: "Remember this",
      is_group: false,
    });
    const send = async () =>
      app.request(
        "/v1/webhooks/blooio",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-blooio-signature": await sign(body),
          },
          body,
        },
        {
          DB: database,
          FIREBASE_PROJECT_ID: "test",
          BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
        },
      );
    const first = await send();
    expect(await first.json()).toEqual({
      accepted: true,
      queued: true,
      replied: false,
    });
    const duplicate = await send();
    expect(await duplicate.json()).toEqual({ accepted: true, duplicate: true });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_inbox WHERE event_id = 'message.received:msg_abc123'",
        )
        .first(),
    ).toEqual({ count: 1 });
  });

  test("repairs a recorded webhook whose durable enqueue was interrupted", async () => {
    const now = Date.now();
    const messageId = "opaque/msg/雪";
    const eventId = `message.received:${messageId}`;
    await database
      .prepare(
        "INSERT INTO webhook_events (channel, event_id, received_at) VALUES ('blooio', ?1, ?2)",
      )
      .bind(eventId, now)
      .run();
    const body = JSON.stringify({
      event: "message.received",
      message_id: messageId,
      external_id: "+15551234567",
      sender: "+15551234567",
      text: "Recover me",
      is_group: false,
    });
    const response = await app.request(
      "/v1/webhooks/blooio",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-blooio-signature": await sign(body),
        },
        body,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
      },
    );

    expect(await response.json()).toEqual({ accepted: true, duplicate: true });
    expect(
      await database
        .prepare(
          `SELECT i.id AS inbox_id, i.text, m.text AS conversation_text
           FROM channel_inbox i
           JOIN conversation_messages m ON m.uid = i.uid AND m.channel_message_id = i.message_id
           WHERE i.event_id = ?1`,
        )
        .bind(eventId)
        .first(),
    ).toEqual({
      inbox_id: expect.stringMatching(/^channel-inbox:[a-f0-9]{64}$/),
      text: "Recover me",
      conversation_text: "Recover me",
    });
  });

  test("fails closed on unsigned Blooio input", async () => {
    const response = await app.request(
      "/v1/webhooks/blooio",
      { method: "POST", body: "{}" },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
      },
    );
    expect(response.status).toBe(401);
  });

  test("does not enqueue blank provider messages", async () => {
    const telegram = await app.request(
      "/v1/webhooks/telegram",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-telegram-bot-api-secret-token": "telegram-secret",
        },
        body: JSON.stringify({
          update_id: 40,
          message: {
            message_id: 40,
            text: "   ",
            from: { id: 42 },
            chat: { id: 42 },
          },
        }),
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        TELEGRAM_WEBHOOK_SECRET: "telegram-secret",
      },
    );
    const blooioBody = JSON.stringify({
      event: "message.received",
      message_id: "msg_blank",
      external_id: "+15551234567",
      sender: "+15551234567",
      text: "\n\t",
      is_group: false,
    });
    const blooio = await app.request(
      "/v1/webhooks/blooio",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-blooio-signature": await sign(blooioBody),
        },
        body: blooioBody,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
      },
    );

    expect(await telegram.json()).toEqual({ accepted: true, queued: false });
    expect(await blooio.json()).toEqual({ accepted: true, queued: false });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_inbox WHERE event_id IN ('40', 'message.received:msg_blank')",
        )
        .first(),
    ).toEqual({ count: 0 });
  });

  test("rejects oversized signed Blooio text before storage", async () => {
    const messageId = "msg_oversized";
    const sender = "+15551234567";
    const body = JSON.stringify({
      event: "message.received",
      message_id: messageId,
      external_id: sender,
      sender,
      text: "x".repeat(20_001),
      is_group: false,
    });
    const response = await app.request(
      "/v1/webhooks/blooio",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-blooio-signature": await sign(body),
        },
        body,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
      },
    );

    expect(await response.json()).toEqual({ accepted: true, queued: false });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM conversation_messages WHERE channel_message_id = ?1",
        )
        .bind(messageId)
        .first(),
    ).toMatchObject({ count: 0 });
  });
});

describe("Stripe webhook", () => {
  test("persists customer and subscription entitlement from a signed event", async () => {
    const eventCreated = Math.floor(Date.now() / 1_000);
    const body = JSON.stringify({
      id: "evt_subscription",
      type: "customer.subscription.updated",
      created: eventCreated,
      data: {
        object: {
          id: "sub_123",
          customer: "cus_123",
          status: "active",
          current_period_end: Math.floor(Date.now() / 1_000) + 3600,
          metadata: { firebase_uid: "alpha" },
          items: { data: [{ price: { id: "price_pro" } }] },
        },
      },
    });
    const response = await app.request(
      "/v1/webhooks/stripe",
      {
        method: "POST",
        headers: { "stripe-signature": await sign(body) },
        body,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        STRIPE_WEBHOOK_SECRET: secret,
      },
    );
    expect(await response.json()).toEqual({
      received: true,
      duplicate: false,
      updated: true,
    });
    expect(
      await database
        .prepare(
          "SELECT plan, status, stripe_customer_id, stripe_subscription_id FROM entitlements WHERE uid = 'alpha'",
        )
        .first(),
    ).toMatchObject({
      plan: "pro",
      status: "active",
      stripe_customer_id: "cus_123",
      stripe_subscription_id: "sub_123",
    });

    const delayed = JSON.stringify({
      id: "evt_delayed",
      type: "customer.subscription.updated",
      created: eventCreated - 1,
      data: {
        object: {
          id: "sub_123",
          customer: "cus_123",
          status: "canceled",
          metadata: { firebase_uid: "alpha" },
        },
      },
    });
    const delayedResponse = await app.request(
      "/v1/webhooks/stripe",
      {
        method: "POST",
        headers: { "stripe-signature": await sign(delayed) },
        body: delayed,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        STRIPE_WEBHOOK_SECRET: secret,
      },
    );
    expect(await delayedResponse.json()).toEqual({
      received: true,
      duplicate: false,
      updated: false,
    });
    expect(
      await database
        .prepare("SELECT status FROM entitlements WHERE uid = 'alpha'")
        .first(),
    ).toMatchObject({ status: "active" });
  });

  // One person, two Omi accounts, one email: Stripe reuses the customer, and
  // `entitlements_stripe_customer` is unique. The second account still has to
  // get what it paid for, and the event must never be able to strand itself
  // by failing before its own receipt is written.
  test("grants the entitlement when Stripe reuses a customer across accounts", async () => {
    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('twin', 'alpha@example.test', ?1, ?1)",
      )
      .bind(now)
      .run();
    const post = async (body: string) =>
      app.request(
        "/v1/webhooks/stripe",
        {
          method: "POST",
          headers: { "stripe-signature": await sign(body) },
          body,
        },
        {
          DB: database,
          FIREBASE_PROJECT_ID: "test",
          STRIPE_WEBHOOK_SECRET: secret,
        },
      );
    const checkout = JSON.stringify({
      id: "evt_twin_checkout",
      type: "checkout.session.completed",
      created: Math.floor(Date.now() / 1_000),
      data: {
        object: {
          id: "cs_twin",
          customer: "cus_123",
          client_reference_id: "twin",
          payment_status: "paid",
        },
      },
    });
    const checkoutResponse = await post(checkout);
    expect(checkoutResponse.status).toBe(200);
    expect(
      (await checkoutResponse.json()) as Record<string, unknown>,
    ).toMatchObject({ received: true, duplicate: false });
    const subscription = JSON.stringify({
      id: "evt_twin_subscription",
      type: "customer.subscription.updated",
      created: Math.floor(Date.now() / 1_000),
      data: {
        object: {
          id: "sub_twin",
          customer: "cus_123",
          status: "active",
          current_period_end: Math.floor(Date.now() / 1_000) + 3600,
          metadata: { firebase_uid: "twin" },
        },
      },
    });
    const subscriptionResponse = await post(subscription);
    expect(subscriptionResponse.status).toBe(200);
    expect(
      await database
        .prepare(
          "SELECT plan, status, stripe_customer_id FROM entitlements WHERE uid = 'twin'",
        )
        .first(),
    ).toMatchObject({
      plan: "pro",
      status: "active",
      // The id stays with the account that claimed it first; the collision
      // costs addressability, not access.
      stripe_customer_id: null,
    });
    // The receipts survived, so Stripe stops redelivering.
    const receipts = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM stripe_events WHERE event_id IN ('evt_twin_checkout', 'evt_twin_subscription')",
      )
      .first<{ count: number }>();
    expect(receipts?.count).toBe(2);
    // A redelivery of either event is recognised rather than reapplied blind.
    expect(
      (await (await post(subscription)).json()) as Record<string, unknown>,
    ).toMatchObject({ received: true, duplicate: true });
  });
});
