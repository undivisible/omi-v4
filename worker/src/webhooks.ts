import { Hono } from "hono";
import type { AppEnv, Channel } from "./types";

const webhooks = new Hono<AppEnv>();
const encoder = new TextEncoder();
const toleranceSeconds = 300;

const equal = (left: string, right: string): boolean => {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index++)
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return mismatch === 0;
};

const hmac = async (secret: string, payload: string): Promise<string> => {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
};

const verifyTimestampedSignature = async (
  rawBody: string,
  header: string,
  secret: string,
): Promise<boolean> => {
  const parts = header.split(",").map((part) => part.trim());
  const timestamp = parts.find((part) => part.startsWith("t="))?.slice(2);
  const signatures = parts
    .filter((part) => part.startsWith("v1="))
    .map((part) => part.slice(3).toLowerCase());
  if (!timestamp || !/^\d+$/.test(timestamp) || signatures.length === 0)
    return false;
  const timestampSeconds = Number(timestamp);
  if (!Number.isSafeInteger(timestampSeconds)) return false;
  const age = Math.floor(Date.now() / 1_000) - timestampSeconds;
  if (Math.abs(age) > toleranceSeconds) return false;
  const expected = await hmac(secret, `${timestamp}.${rawBody}`);
  return signatures.some(
    (signature) =>
      /^[a-f0-9]{64}$/.test(signature) && equal(expected, signature),
  );
};

const recordWebhook = async (
  database: D1Database,
  channel: Channel,
  eventId: string,
): Promise<boolean> => {
  const result = await database
    .prepare(
      "INSERT OR IGNORE INTO webhook_events (channel, event_id, received_at) VALUES (?1, ?2, ?3)",
    )
    .bind(channel, eventId, Date.now())
    .run();
  return result.meta.changes === 1;
};

const digest = async (value: string): Promise<string> => {
  const hash = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
};

const bind = async (
  database: D1Database,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  token: string,
): Promise<"linked" | "invalid" | "conflict"> => {
  const existing = await database
    .prepare(
      "SELECT uid FROM channel_bindings WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL",
    )
    .bind(channel, channelUserId)
    .first();
  const now = Date.now();
  const tokenHash = await digest(token);
  const tokenRow = await database
    .prepare(
      `SELECT uid FROM channel_link_tokens
       WHERE token_hash = ?1 AND channel = ?2 AND consumed_at IS NULL AND expires_at > ?3`,
    )
    .bind(tokenHash, channel, now)
    .first();
  if (!tokenRow) return "invalid";
  const uid = String(tokenRow.uid);
  if (existing && existing.uid !== uid) return "conflict";
  const results = await database.batch([
    database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)
         SELECT ?1, ?2, uid, ?3, NULL, ?4 FROM channel_link_tokens
         WHERE token_hash = ?5 AND uid = ?6 AND channel = ?1
           AND consumed_at IS NULL AND expires_at > ?3
         ON CONFLICT(channel, channel_user_id) DO UPDATE SET
           uid = excluded.uid, verified_at = excluded.verified_at,
           revoked_at = NULL, channel_chat_id = excluded.channel_chat_id`,
      )
      .bind(channel, channelUserId, now, channelChatId, tokenHash, uid),
    database
      .prepare(
        `INSERT INTO audit_events
           (id, uid, actor_type, action, target_type, target_id, details, created_at)
         SELECT ?1, uid, 'channel', 'channel.linked', 'channel', ?2, ?3, ?4
         FROM channel_link_tokens
         WHERE token_hash = ?5 AND uid = ?6 AND channel = ?2
           AND consumed_at IS NULL AND expires_at > ?4`,
      )
      .bind(
        crypto.randomUUID(),
        channel,
        JSON.stringify({ channelUserId, channelChatId }),
        now,
        tokenHash,
        uid,
      ),
    database
      .prepare(
        `UPDATE channel_link_tokens SET consumed_at = ?1
         WHERE token_hash = ?2 AND uid = ?3 AND channel = ?4
           AND consumed_at IS NULL AND expires_at > ?1`,
      )
      .bind(now, tokenHash, uid, channel),
  ]);
  return results[0].meta.changes === 1 && results[2].meta.changes === 1
    ? "linked"
    : "invalid";
};

const enqueue = async (
  database: D1Database,
  channel: Channel,
  eventId: string,
  messageId: string,
  channelUserId: string,
  channelChatId: string,
  text: string,
  payload: unknown,
) => {
  const binding = await database
    .prepare(
      `SELECT uid FROM channel_bindings
       WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL`,
    )
    .bind(channel, channelUserId)
    .first();
  if (!binding) return false;
  const uid = String(binding.uid);
  const now = Date.now();
  await database.batch([
    database
      .prepare(
        `INSERT OR IGNORE INTO channel_inbox
           (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
      )
      .bind(
        crypto.randomUUID(),
        uid,
        channel,
        eventId,
        messageId,
        channelUserId,
        channelChatId,
        text,
        JSON.stringify(payload),
        now,
      ),
    database
      .prepare(
        `INSERT INTO audit_events
           (id, uid, actor_type, action, target_type, target_id, details, created_at)
         VALUES (?1, ?2, 'channel', 'channel.message_received', 'message', ?3, ?4, ?5)`,
      )
      .bind(
        crypto.randomUUID(),
        uid,
        messageId,
        JSON.stringify({ channel, channelChatId }),
        now,
      ),
  ]);
  return true;
};

const linkToken = (text: string, telegram = false): string | null => {
  const value = telegram
    ? /^\/start(?:@[A-Za-z0-9_]+)? ([a-f0-9]{48})$/.exec(text)?.[1]
    : /^([a-f0-9]{48})$/.exec(text)?.[1];
  return value ?? null;
};

webhooks.post("/telegram", async (context) => {
  const secret = context.env.TELEGRAM_WEBHOOK_SECRET;
  const supplied = context.req.header("x-telegram-bot-api-secret-token") ?? "";
  if (!secret || !supplied || !equal(secret, supplied))
    return context.json({ error: "Unauthorized" }, 401);
  const body = (await context.req.json().catch(() => null)) as {
    update_id?: unknown;
    message?: {
      message_id?: unknown;
      text?: unknown;
      from?: { id?: unknown };
      chat?: { id?: unknown };
    };
  } | null;
  if (!Number.isSafeInteger(body?.update_id))
    return context.json({ error: "Invalid update" }, 400);
  const eventId = String(body?.update_id);
  if (!(await recordWebhook(context.env.DB, "telegram", eventId)))
    return context.json({ accepted: true, duplicate: true });
  const message = body?.message;
  const messageId = message?.message_id;
  const fromId = message?.from?.id;
  const telegramChatId = message?.chat?.id;
  if (
    typeof messageId !== "number" ||
    !Number.isSafeInteger(messageId) ||
    typeof fromId !== "number" ||
    !Number.isSafeInteger(fromId) ||
    typeof telegramChatId !== "number" ||
    !Number.isSafeInteger(telegramChatId) ||
    typeof message?.text !== "string" ||
    message.text.length > 20_000
  )
    return context.json({ accepted: true, queued: false });
  const userId = String(fromId);
  const chatId = String(telegramChatId);
  const token = linkToken(message.text.trim(), true);
  if (token) {
    const linked = await bind(
      context.env.DB,
      "telegram",
      userId,
      chatId,
      token,
    );
    return context.json({ accepted: true, linked: linked === "linked" });
  }
  const queued = await enqueue(
    context.env.DB,
    "telegram",
    eventId,
    String(messageId),
    userId,
    chatId,
    message.text,
    body,
  );
  return context.json({ accepted: queued, queued });
});

type BlooioEvent = {
  event?: unknown;
  message_id?: unknown;
  external_id?: unknown;
  sender?: unknown;
  text?: unknown;
  is_group?: unknown;
  group_id?: unknown;
};

webhooks.post("/blooio", async (context) => {
  const secret = context.env.BLOOIO_WEBHOOK_SIGNING_SECRET;
  const signature = context.req.header("x-blooio-signature") ?? "";
  const rawBody = await context.req.text();
  if (
    !secret ||
    !(await verifyTimestampedSignature(rawBody, signature, secret))
  )
    return context.json({ error: "Unauthorized" }, 401);
  let body: BlooioEvent;
  try {
    body = JSON.parse(rawBody) as BlooioEvent;
  } catch {
    return context.json({ error: "Invalid body" }, 400);
  }
  if (
    body.event !== "message.received" ||
    typeof body.message_id !== "string" ||
    typeof body.external_id !== "string" ||
    typeof body.sender !== "string" ||
    (body.text !== null && typeof body.text !== "string")
  )
    return context.json({ accepted: true, queued: false });
  const eventId = `${body.event}:${body.message_id}`;
  if (!(await recordWebhook(context.env.DB, "blooio", eventId)))
    return context.json({ accepted: true, duplicate: true });
  const chatId =
    body.is_group === true && typeof body.group_id === "string"
      ? body.group_id
      : body.external_id;
  const messageText = body.text ?? "";
  const token = linkToken(messageText.trim());
  if (token) {
    const linked = await bind(
      context.env.DB,
      "blooio",
      body.sender,
      chatId,
      token,
    );
    return context.json({ accepted: true, linked: linked === "linked" });
  }
  const queued = await enqueue(
    context.env.DB,
    "blooio",
    eventId,
    body.message_id,
    body.sender,
    chatId,
    messageText,
    body,
  );
  return context.json({ accepted: queued, queued });
});

type StripeEvent = {
  id?: unknown;
  type?: unknown;
  created?: unknown;
  data?: { object?: Record<string, unknown> };
};

webhooks.post("/stripe", async (context) => {
  const secret = context.env.STRIPE_WEBHOOK_SECRET;
  const signature = context.req.header("stripe-signature") ?? "";
  const rawBody = await context.req.text();
  if (
    !secret ||
    !(await verifyTimestampedSignature(rawBody, signature, secret))
  )
    return context.json({ error: "Unauthorized" }, 401);
  let event: StripeEvent;
  try {
    event = JSON.parse(rawBody) as StripeEvent;
  } catch {
    return context.json({ error: "Invalid body" }, 400);
  }
  if (typeof event.id !== "string" || typeof event.type !== "string")
    return context.json({ error: "Invalid event" }, 400);
  if (typeof event.created !== "number" || !Number.isSafeInteger(event.created))
    return context.json({ error: "Invalid event" }, 400);
  const object = event.data?.object;
  const receipt = context.env.DB.prepare(
    "INSERT OR IGNORE INTO stripe_events (event_id, event_type, received_at) VALUES (?1, ?2, ?3)",
  ).bind(event.id, event.type, Date.now());
  if (!object) {
    const inserted = await receipt.run();
    return context.json({
      received: true,
      duplicate: inserted.meta.changes === 0,
    });
  }
  const metadata =
    object.metadata !== null && typeof object.metadata === "object"
      ? (object.metadata as Record<string, unknown>)
      : {};
  const uid =
    typeof object.client_reference_id === "string"
      ? object.client_reference_id
      : typeof metadata.firebase_uid === "string"
        ? metadata.firebase_uid
        : null;
  const customer = typeof object.customer === "string" ? object.customer : null;
  const subscription =
    typeof object.subscription === "string"
      ? object.subscription
      : typeof object.id === "string" &&
          event.type.startsWith("customer.subscription.")
        ? object.id
        : null;
  if (!uid || !customer) {
    const inserted = await receipt.run();
    return context.json({
      received: true,
      duplicate: inserted.meta.changes === 0,
      updated: false,
    });
  }
  if (event.type === "checkout.session.completed") {
    const results = await context.env.DB.batch([
      receipt,
      context.env.DB.prepare(
        `INSERT INTO entitlements (uid, plan, status, stripe_customer_id, updated_at)
           SELECT uid, 'byok', 'inactive', ?1, ?2 FROM users WHERE uid = ?3
           ON CONFLICT(uid) DO UPDATE SET stripe_customer_id = excluded.stripe_customer_id,
             updated_at = excluded.updated_at`,
      ).bind(customer, Date.now(), uid),
    ]);
    return context.json({
      received: true,
      duplicate: results[0].meta.changes === 0,
      updated: results[1].meta.changes === 1,
    });
  }
  if (!event.type.startsWith("customer.subscription.")) {
    const inserted = await receipt.run();
    return context.json({
      received: true,
      duplicate: inserted.meta.changes === 0,
      updated: false,
    });
  }
  const active = object.status === "active" || object.status === "trialing";
  const validUntil =
    typeof object.current_period_end === "number" &&
    Number.isSafeInteger(object.current_period_end)
      ? object.current_period_end * 1_000
      : null;
  const price = object.items as
    | { data?: Array<{ price?: { id?: unknown } }> }
    | undefined;
  const priceId =
    typeof price?.data?.[0]?.price?.id === "string"
      ? price.data[0].price.id
      : null;
  const results = await context.env.DB.batch([
    receipt,
    context.env.DB.prepare(
      `INSERT INTO entitlements
           (uid, plan, status, valid_until, stripe_customer_id, updated_at, stripe_subscription_id, stripe_price_id, stripe_event_created)
         SELECT uid, 'pro', ?1, ?2, ?3, ?4, ?5, ?6, ?7 FROM users WHERE uid = ?8
         ON CONFLICT(uid) DO UPDATE SET
           plan = 'pro', status = excluded.status, valid_until = excluded.valid_until,
           stripe_customer_id = excluded.stripe_customer_id,
           stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, entitlements.stripe_subscription_id),
           stripe_price_id = COALESCE(excluded.stripe_price_id, entitlements.stripe_price_id),
           stripe_event_created = excluded.stripe_event_created,
           updated_at = excluded.updated_at
         WHERE excluded.stripe_event_created >= entitlements.stripe_event_created`,
    ).bind(
      active ? "active" : "inactive",
      validUntil,
      customer,
      Date.now(),
      subscription,
      priceId,
      event.created,
      uid,
    ),
  ]);
  return context.json({
    received: true,
    duplicate: results[0].meta.changes === 0,
    updated: results[1].meta.changes === 1,
  });
});

export default webhooks;
