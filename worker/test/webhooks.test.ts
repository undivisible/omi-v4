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
    "migrations/0033_rename_blooio_to_imessage.sql",
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
    // Channel-only signup is retired — "no" gets app guidance, not a chan_ row.
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_accounts WHERE channel_user_id = '909'",
        )
        .first(),
    ).toMatchObject({ count: 0 });
    const replay = await send(102, "nope");
    expect(await replay.json()).toEqual({ accepted: true, duplicate: true });
    await database
      .prepare("DELETE FROM channel_inbox WHERE channel_user_id = '909'")
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
    const sendblueBody = JSON.stringify({
      content: "\n\t",
      is_outbound: false,
      status: "RECEIVED",
      message_handle: "sb-msg-blank",
      from_number: "+15551234567",
      number: "+15551234567",
      to_number: "+15122164639",
      media_url: "",
      group_id: "",
      service: "iMessage",
    });
    const sendblue = await app.request(
      "/v1/webhooks/sendblue/path-token-value",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "sb-signing-secret": "webhook-secret-value",
        },
        body: sendblueBody,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        SENDBLUE_WEBHOOK_SIGNING_SECRET: "webhook-secret-value",
        SENDBLUE_WEBHOOK_PATH_TOKEN: "path-token-value",
      },
    );

    expect(await telegram.json()).toEqual({ accepted: true, queued: false });
    expect(await sendblue.json()).toEqual({ accepted: true, queued: false });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM channel_inbox WHERE event_id IN ('40', 'message.received:sb-msg-blank')",
        )
        .first(),
    ).toEqual({ count: 0 });
  });

  test("rejects oversized Sendblue text before storage", async () => {
    const messageHandle = "sb-msg-oversized";
    const body = JSON.stringify({
      content: "x".repeat(20_001),
      is_outbound: false,
      status: "RECEIVED",
      message_handle: messageHandle,
      from_number: "+15551234567",
      number: "+15551234567",
      to_number: "+15122164639",
      media_url: "",
      group_id: "",
      service: "iMessage",
    });
    const response = await app.request(
      "/v1/webhooks/sendblue/path-token-value",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "sb-signing-secret": "webhook-secret-value",
        },
        body,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        SENDBLUE_WEBHOOK_SIGNING_SECRET: "webhook-secret-value",
        SENDBLUE_WEBHOOK_PATH_TOKEN: "path-token-value",
      },
    );

    expect(await response.json()).toEqual({ accepted: true, queued: false });
    expect(
      await database
        .prepare(
          "SELECT COUNT(*) AS count FROM conversation_messages WHERE channel_message_id = ?1",
        )
        .bind(messageHandle)
        .first(),
    ).toMatchObject({ count: 0 });
  });

  test("accepts a Sendblue inbound message when path token and secret match", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings
           (channel, channel_user_id, uid, verified_at, channel_chat_id)
         VALUES ('imessage', '+19998887777', 'alpha', ?1, '+19998887777')`,
      )
      .bind(now)
      .run();
    const body = JSON.stringify({
      content: "Remember this",
      is_outbound: false,
      status: "RECEIVED",
      message_handle: "sb-msg-001",
      from_number: "+19998887777",
      number: "+19998887777",
      to_number: "+15122164639",
      media_url: "",
      group_id: "",
      service: "iMessage",
    });
    const send = async () =>
      app.request(
        "/v1/webhooks/sendblue/path-token-value",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "sb-signing-secret": "webhook-secret-value",
          },
          body,
        },
        {
          DB: database,
          FIREBASE_PROJECT_ID: "test",
          SENDBLUE_WEBHOOK_SIGNING_SECRET: "webhook-secret-value",
          SENDBLUE_WEBHOOK_PATH_TOKEN: "path-token-value",
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
  });

  test("rejects Sendblue group link tokens with an explanation", async () => {
    const body = JSON.stringify({
      content: "0".repeat(48),
      is_outbound: false,
      status: "RECEIVED",
      message_handle: "sb-msg-group-link",
      from_number: "+19998887777",
      number: "+19998887777",
      to_number: "+15122164639",
      media_url: "",
      group_id: "group-99",
      service: "iMessage",
    });
    const response = await app.request(
      "/v1/webhooks/sendblue/path-token-value",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "sb-signing-secret": "webhook-secret-value",
        },
        body,
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        SENDBLUE_WEBHOOK_SIGNING_SECRET: "webhook-secret-value",
        SENDBLUE_WEBHOOK_PATH_TOKEN: "path-token-value",
        SENDBLUE_API_KEY_ID: "key-id",
        SENDBLUE_API_KEY_SECRET: "key-secret",
        SENDBLUE_NUMBER: "+15122164639",
      },
    );
    expect(await response.json()).toMatchObject({
      accepted: true,
      linked: false,
    });
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
