import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from "bun:test";
import { Miniflare } from "miniflare";
import {
  completeChannelCheckout,
  issueChannelCheckout,
} from "../src/channel-checkout";
import { handleChannelMessage } from "../src/channel-commands";
import { app } from "../src/index";
import type { Bindings } from "../src/types";

const webhookSecret = "whsec_channel";
const encoder = new TextEncoder();
const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

let rateAllowed = true;
const rateBlocked: string[] = [];
const rateHits: string[] = [];
const rateLimiter = {
  getByName: (name: string) => ({
    fetch: async () => {
      rateHits.push(name);
      const allowed =
        rateAllowed && !rateBlocked.some((key) => name.includes(key));
      return Response.json(
        { allowed, retryAfter: allowed ? 0 : 60 },
        { status: allowed ? 200 : 429 },
      );
    },
  }),
} as unknown as DurableObjectNamespace;

// Every outbound call the checkout path makes: Stripe's API and the chat
// provider. Nothing here talks to the network.
type StripeCall = {
  url: string;
  parameters: URLSearchParams;
  key: string | null;
};
const stripeCalls: StripeCall[] = [];
const sentMessages: Array<{ chatId: string; text: string }> = [];
let sessionCounter = 0;
const realFetch = globalThis.fetch;

const stubFetch = async (
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> => {
  const url = String(input);
  if (url.startsWith("https://api.telegram.org/")) {
    const body = JSON.parse(String(init?.body)) as {
      chat_id: string;
      text: string;
    };
    sentMessages.push({ chatId: body.chat_id, text: body.text });
    return Response.json({ ok: true });
  }
  if (url.endsWith("/v1/prices/price_pro"))
    return Response.json({
      currency: "usd",
      product: "prod_omi",
      unit_amount: 1200,
      recurring: { interval: "month", interval_count: 1 },
    });
  if (url.endsWith("/v1/checkout/sessions")) {
    const headers = new Headers(init?.headers);
    const parameters = new URLSearchParams(String(init?.body));
    stripeCalls.push({
      url,
      parameters,
      key: headers.get("idempotency-key"),
    });
    sessionCounter += 1;
    const id = `cs_test_${sessionCounter}`;
    return Response.json({
      id,
      url: `https://checkout.stripe.com/c/pay/${id}#secret`,
    });
  }
  if (url.includes("/v1/customers?")) return Response.json({ data: [] });
  return Response.json({ error: { message: "unexpected" } }, { status: 404 });
};

const sign = async (body: string) => {
  const timestamp = Math.floor(Date.now() / 1_000);
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(webhookSecret),
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

const env = (): Bindings =>
  ({
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    RATE_LIMITER: rateLimiter,
    TELEGRAM_WEBHOOK_SECRET: "telegram-secret",
    TELEGRAM_BOT_TOKEN: "bot-token",
    BLOOIO_WEBHOOK_SIGNING_SECRET: "blooio-secret",
    STRIPE_SECRET_KEY: "sk_test",
    STRIPE_PRO_PRICE_ID: "price_pro",
    STRIPE_WEBHOOK_SECRET: webhookSecret,
    APP_URL: "https://omi.test",
  }) as Bindings;

const migrate = async (path: string) => {
  const sql = (await Bun.file(path).text()).replace(
    "PRAGMA foreign_keys = ON;",
    "",
  );
  for (const statement of sql.split(";").map((value) => value.trim()))
    if (statement) await database.prepare(statement).run();
};

const signUp = async (channelUserId: string) => {
  await handleChannelMessage(
    env(),
    "telegram",
    channelUserId,
    channelUserId,
    "hi",
  );
  const outcome = await handleChannelMessage(
    env(),
    "telegram",
    channelUserId,
    channelUserId,
    "no",
  );
  const account = await database
    .prepare(
      "SELECT uid FROM channel_accounts WHERE channel = 'telegram' AND channel_user_id = ?1",
    )
    .bind(channelUserId)
    .first<{ uid: string }>();
  return { uid: String(account?.uid), reply: outcome.reply ?? "" };
};

const checkoutEvent = (
  id: string,
  sessionId: string,
  uid: string,
  extra: Record<string, unknown> = {},
) =>
  JSON.stringify({
    id,
    type: "checkout.session.completed",
    created: Math.floor(Date.now() / 1_000),
    data: {
      object: {
        id: sessionId,
        client_reference_id: uid,
        customer: "cus_channel",
        subscription: "sub_channel",
        payment_status: "paid",
        customer_details: { email: "payer@example.test" },
        metadata: { firebase_uid: uid },
        ...extra,
      },
    },
  });

const postStripe = async (body: string) =>
  app.request(
    "/v1/webhooks/stripe",
    { method: "POST", headers: { "stripe-signature": await sign(body) }, body },
    env() as unknown as Record<string, unknown>,
  );

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const file of [
    "migrations/0001_initial.sql",
    "migrations/0002_memory_and_policy.sql",
    "migrations/0003_align_kr_model.sql",
    "migrations/0004_saas_foundations.sql",
    "migrations/0005_memory_search.sql",
    "migrations/0007_channel_delivery.sql",
    "migrations/0013_conversations.sql",
    "migrations/0014_channel_inbox_dispatch.sql",
    "migrations/0022_channel_link_codes.sql",
    "migrations/0025_byok_price_negotiation.sql",
    "migrations/0026_channel_accounts.sql",
    "migrations/0028_channel_checkout.sql",
  ])
    await migrate(file);
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('claimer', 'real@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
  globalThis.fetch = realFetch;
});

beforeEach(async () => {
  globalThis.fetch = stubFetch as unknown as typeof fetch;
  rateAllowed = true;
  rateBlocked.length = 0;
  rateHits.length = 0;
  stripeCalls.length = 0;
  sentMessages.length = 0;
  for (const table of [
    "channel_checkout_sessions",
    "channel_link_codes",
    "channel_bindings",
    "channel_accounts",
    "channel_first_contact",
    "byok_price_agreements",
    "stripe_events",
  ])
    await database.prepare(`DELETE FROM ${table}`).run();
  await database.prepare("DELETE FROM entitlements").run();
  await database.prepare("DELETE FROM users WHERE uid LIKE 'chan_%'").run();
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("checkout links in chat", () => {
  test("signup hands back a Stripe-hosted link bound to that account, and nothing else", async () => {
    const { uid, reply } = await signUp("500");
    expect(reply).toContain("this chat is your Omi account");
    expect(reply).toContain("https://checkout.stripe.com/c/pay/cs_test_");
    // Never a card field, never a price the chat could argue with.
    expect(reply).toContain("never ask you for card details");
    const row = await database
      .prepare(
        "SELECT session_id, uid, price_cents, expires_at, created_at FROM channel_checkout_sessions",
      )
      .first<{
        session_id: string;
        uid: string;
        price_cents: number;
        expires_at: number;
        created_at: number;
      }>();
    expect(row?.uid).toBe(uid);
    expect(Number(row?.price_cents)).toBe(1200);
    // The link expires: Stripe is told when, and so is our row.
    expect(Number(row?.expires_at) - Number(row?.created_at)).toBe(60 * 60_000);
    const created = stripeCalls[0].parameters;
    expect(created.get("client_reference_id")).toBe(uid);
    expect(created.get("expires_at")).not.toBeNull();
    expect(created.get("automatic_tax[enabled]")).toBe("true");
    // No customer and no email: Checkout collects the address itself, which
    // is the only place a chat-created account is ever asked for one.
    expect(created.get("customer_email")).toBeNull();
    expect(stripeCalls[0].key).toContain("channel-checkout:telegram:500");
  });

  test("a second ask reuses the outstanding link instead of selling twice", async () => {
    const first = await signUp("501");
    const url =
      /https:\/\/checkout\.stripe\.com\/\S+/.exec(first.reply)?.[0] ?? "";
    const again = await handleChannelMessage(
      env(),
      "telegram",
      "501",
      "501",
      "/subscribe",
    );
    expect(url).toContain("https://checkout.stripe.com/");
    expect(again.reply).toContain(url);
    expect(stripeCalls).toHaveLength(1);
  });

  test("a negotiated price reaches Stripe as the amount, never the standard one", async () => {
    const { uid } = await signUp("502");
    await database
      .prepare("DELETE FROM channel_checkout_sessions WHERE uid = ?1")
      .bind(uid)
      .run();
    await database
      .prepare(
        `INSERT INTO byok_price_agreements
           (uid, outcome, price_cents, standard_price_cents, floor_price_cents, agreed_at, created_at, updated_at)
         VALUES (?1, 'negotiated', 800, 1200, 700, ?2, ?2, ?2)`,
      )
      .bind(uid, Date.now())
      .run();
    stripeCalls.length = 0;
    const offer = await handleChannelMessage(
      env(),
      "telegram",
      "502",
      "502",
      "/subscribe",
    );
    expect(offer.reply).toContain("$8.00");
    const parameters = stripeCalls[0].parameters;
    expect(parameters.get("line_items[0][price_data][unit_amount]")).toBe(
      "800",
    );
    expect(parameters.get("line_items[0][price]")).toBeNull();
  });

  test("a price agreement below today's floor is re-clamped before Stripe sees it", async () => {
    const { uid } = await signUp("503");
    await database
      .prepare("DELETE FROM channel_checkout_sessions WHERE uid = ?1")
      .bind(uid)
      .run();
    await database
      .prepare(
        `INSERT INTO byok_price_agreements
           (uid, outcome, price_cents, standard_price_cents, floor_price_cents, agreed_at, created_at, updated_at)
         VALUES (?1, 'negotiated', 1, 1200, 700, ?2, ?2, ?2)`,
      )
      .bind(uid, Date.now())
      .run();
    stripeCalls.length = 0;
    await handleChannelMessage(env(), "telegram", "503", "503", "/subscribe");
    expect(
      stripeCalls[0].parameters.get("line_items[0][price_data][unit_amount]"),
    ).toBe("700");
  });

  test("issuance is rate-limited per sender", async () => {
    await signUp("504");
    await database.prepare("DELETE FROM channel_checkout_sessions").run();
    rateBlocked.push("channel-checkout:telegram:504");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "504",
      "504",
      "/subscribe",
    );
    expect(outcome.reply).toBeNull();
    expect(
      await database
        .prepare("SELECT COUNT(*) AS count FROM channel_checkout_sessions")
        .first<{ count: number }>(),
    ).toMatchObject({ count: 0 });
  });

  test("the global cap holds even when the sender is under theirs", async () => {
    await signUp("505");
    await database.prepare("DELETE FROM channel_checkout_sessions").run();
    rateBlocked.push("channel-checkout:global");
    stripeCalls.length = 0;
    await handleChannelMessage(env(), "telegram", "505", "505", "/subscribe");
    expect(stripeCalls).toHaveLength(0);
  });
});

describe("payment completes the signup", () => {
  test("the webhook provisions the account the session was bound to", async () => {
    const { uid } = await signUp("600");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    sentMessages.length = 0;
    const response = await postStripe(
      checkoutEvent("evt_1", String(session?.session_id), uid),
    );
    expect(await response.json()).toMatchObject({ channel: true });
    expect(
      await database
        .prepare("SELECT plan, status FROM entitlements WHERE uid = ?1")
        .bind(uid)
        .first(),
    ).toMatchObject({ plan: "pro", status: "active" });
    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].text).toContain("Payment received");
    // The address Stripe collected is kept for billing only, never promoted
    // to the sign-in identity.
    expect(
      await database
        .prepare("SELECT billing_email FROM channel_accounts WHERE uid = ?1")
        .bind(uid)
        .first(),
    ).toMatchObject({ billing_email: "payer@example.test" });
    expect(
      await database
        .prepare("SELECT email FROM users WHERE uid = ?1")
        .bind(uid)
        .first(),
    ).toMatchObject({ email: null });
  });

  test("a replayed webhook changes nothing and does not confirm twice", async () => {
    const { uid } = await signUp("601");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    const body = checkoutEvent("evt_2", String(session?.session_id), uid);
    await postStripe(body);
    sentMessages.length = 0;
    const replay = await postStripe(body);
    expect(await replay.json()).toMatchObject({
      duplicate: true,
      channel: false,
    });
    expect(sentMessages).toHaveLength(0);
    expect(
      await database
        .prepare("SELECT COUNT(*) AS count FROM entitlements")
        .first<{ count: number }>(),
    ).toMatchObject({ count: 1 });
  });

  test("a forwarded link cannot be pointed at another account", async () => {
    const { uid: mine } = await signUp("602");
    const { uid: theirs } = await signUp("603");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(mine)
      .first<{ session_id: string }>();
    sentMessages.length = 0;
    // The event claims someone else's uid for my session id. The stored
    // binding wins, and the mismatch is refused outright.
    const response = await postStripe(
      checkoutEvent("evt_3", String(session?.session_id), theirs),
    );
    expect(await response.json()).toMatchObject({ channel: false });
    // The generic checkout branch still files the customer id against the uid
    // Stripe named, but nothing is ever activated for it.
    expect(
      await database
        .prepare("SELECT plan, status FROM entitlements WHERE uid = ?1")
        .bind(theirs)
        .first(),
    ).toMatchObject({ plan: "byok", status: "inactive" });
    expect(sentMessages).toHaveLength(0);
  });

  test("an unpaid session provisions nothing", async () => {
    const { uid } = await signUp("604");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    const response = await postStripe(
      checkoutEvent("evt_4", String(session?.session_id), uid, {
        payment_status: "unpaid",
      }),
    );
    expect(await response.json()).toMatchObject({ channel: false });
    expect(
      await database
        .prepare("SELECT plan, status FROM entitlements WHERE uid = ?1")
        .bind(uid)
        .first(),
    ).toMatchObject({ plan: "byok", status: "inactive" });
  });

  test("payment after the account was claimed lands on the claiming account", async () => {
    const { uid } = await signUp("605");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    await database
      .prepare(
        "UPDATE channel_accounts SET claimed_at = ?1, claimed_by_uid = 'claimer' WHERE uid = ?2",
      )
      .bind(Date.now(), uid)
      .run();
    sentMessages.length = 0;
    const completion = await completeChannelCheckout(env(), {
      sessionId: String(session?.session_id),
      uid,
      customer: "cus_channel",
      subscription: "sub_channel",
      paid: true,
      email: "payer@example.test",
      eventCreated: Math.floor(Date.now() / 1_000),
    });
    expect(completion).toMatchObject({ provisioned: true, uid: "claimer" });
    expect(
      await database
        .prepare("SELECT plan, status FROM entitlements WHERE uid = 'claimer'")
        .first(),
    ).toMatchObject({ plan: "pro", status: "active" });
    expect(sentMessages[0].text).toContain("signed-in Omi account");
  });

  test("payment after the account was retired still provisions and says so", async () => {
    const { uid } = await signUp("606");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    await database
      .prepare("UPDATE channel_accounts SET retired_at = ?1 WHERE uid = ?2")
      .bind(Date.now(), uid)
      .run();
    sentMessages.length = 0;
    const completion = await completeChannelCheckout(env(), {
      sessionId: String(session?.session_id),
      uid,
      customer: "cus_channel",
      subscription: "sub_channel",
      paid: true,
      email: null,
      eventCreated: Math.floor(Date.now() / 1_000),
    });
    expect(completion.provisioned).toBe(true);
    expect(sentMessages[0].text).toContain("was closed");
  });

  test("a subscribed account is told so instead of being sold to again", async () => {
    const { uid } = await signUp("607");
    await database.prepare("DELETE FROM channel_checkout_sessions").run();
    await database
      .prepare(
        "INSERT INTO entitlements (uid, plan, status, updated_at) VALUES (?1, 'pro', 'active', ?2)",
      )
      .bind(uid, Date.now())
      .run();
    stripeCalls.length = 0;
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "607",
      "607",
      "/subscribe",
    );
    expect(outcome.reply).toContain("already subscribed");
    expect(stripeCalls).toHaveLength(0);
    const issued = await issueChannelCheckout(
      env(),
      uid,
      "telegram",
      "607",
      "607",
    );
    expect(issued.status).toBe("subscribed");
  });
});

describe("revocation events", () => {
  test("a failed invoice deactivates the entitlement it belongs to", async () => {
    const { uid } = await signUp("700");
    await database
      .prepare(
        "INSERT INTO entitlements (uid, plan, status, stripe_customer_id, updated_at) VALUES (?1, 'pro', 'active', 'cus_fail', ?2)",
      )
      .bind(uid, Date.now())
      .run();
    const body = JSON.stringify({
      id: "evt_failed",
      type: "invoice.payment_failed",
      created: Math.floor(Date.now() / 1_000),
      data: { object: { id: "in_1", customer: "cus_fail" } },
    });
    const response = await postStripe(body);
    expect(await response.json()).toMatchObject({ updated: true });
    expect(
      await database
        .prepare("SELECT status FROM entitlements WHERE uid = ?1")
        .bind(uid)
        .first(),
    ).toMatchObject({ status: "inactive" });
  });

  test("an expired session frees the account to be offered a fresh link", async () => {
    const { uid } = await signUp("701");
    const session = await database
      .prepare(
        "SELECT session_id FROM channel_checkout_sessions WHERE uid = ?1",
      )
      .bind(uid)
      .first<{ session_id: string }>();
    const body = JSON.stringify({
      id: "evt_expired",
      type: "checkout.session.expired",
      created: Math.floor(Date.now() / 1_000),
      data: { object: { id: String(session?.session_id) } },
    });
    await postStripe(body);
    stripeCalls.length = 0;
    await handleChannelMessage(env(), "telegram", "701", "701", "/subscribe");
    expect(stripeCalls).toHaveLength(1);
  });
});
