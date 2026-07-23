import { Hono } from "hono";
import type { AppEnv, Bindings, Channel } from "./types";
import {
  completeChannelCheckout,
  expireChannelCheckout,
} from "./channel-checkout";
import { handleChannelMessage } from "./channel-commands";
import { digest, hmacHex } from "./channel-link";
import { appendConversationMessage } from "./conversations";
import { sendChannelText } from "./delivery";
import {
  applySubscriptionState,
  claimStripeCustomer,
  customerForDispute,
  deactivateForCustomer,
} from "./stripe-entitlement";

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
  const expected = await hmacHex(secret, `${timestamp}.${rawBody}`);
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
  const eventHash = await digest(`${channel}\u0000${eventId}`);
  const message = await appendConversationMessage(
    database,
    {
      uid,
      clientMessageId: `channel:${channel}:${eventHash}`,
      role: "user",
      source: channel,
      text,
      channelMessageId: messageId,
      createdAt: now,
    },
    [
      database
        .prepare(
          `INSERT OR IGNORE INTO channel_inbox
           (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
        )
        .bind(
          `channel-inbox:${eventHash}`,
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
          `INSERT OR IGNORE INTO audit_events
           (id, uid, actor_type, action, target_type, target_id, details, created_at)
         VALUES (?1, ?2, 'channel', 'channel.message_received', 'message', ?3, ?4, ?5)`,
        )
        .bind(
          `channel-message:${eventHash}`,
          uid,
          messageId,
          JSON.stringify({ channel, channelChatId }),
          now,
        ),
    ],
  );
  return message !== null;
};

// Both webhooks are thin transports: they authenticate, parse, and hand the
// message to the one shared command dispatcher, which decides whether the
// sender gets an immediate reply or the message reaches the assistant.
const processChannelMessage = async (
  env: Bindings,
  channel: Channel,
  fresh: boolean,
  eventId: string,
  messageId: string,
  channelUserId: string,
  channelChatId: string,
  text: string,
  payload: unknown,
): Promise<{ queued: boolean; replied: boolean }> => {
  const outcome = await handleChannelMessage(
    env,
    channel,
    channelUserId,
    channelChatId,
    text,
  );
  // A retried webhook re-runs the (idempotent) command, but must not send the
  // sender a second copy of the answer.
  if (fresh && outcome.reply !== null)
    await sendChannelText(env, channel, channelChatId, outcome.reply);
  if (!outcome.enqueue)
    return { queued: false, replied: outcome.reply !== null };
  const queued = await enqueue(
    env.DB,
    channel,
    eventId,
    messageId,
    channelUserId,
    channelChatId,
    text,
    payload,
  );
  return { queued, replied: false };
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
  const fresh = await recordWebhook(context.env.DB, "telegram", eventId);
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
    message.text.trim().length === 0 ||
    message.text.length > 20_000
  )
    return context.json({ accepted: true, queued: false });
  const userId = String(fromId);
  const chatId = String(telegramChatId);
  const messageText = message.text.trim();
  const token = linkToken(messageText, true);
  if (token) {
    if (!fresh) return context.json({ accepted: true, duplicate: true });
    const linked = await bind(
      context.env.DB,
      "telegram",
      userId,
      chatId,
      token,
    );
    return context.json({ accepted: true, linked: linked === "linked" });
  }
  const processed = await processChannelMessage(
    context.env,
    "telegram",
    fresh,
    eventId,
    String(messageId),
    userId,
    chatId,
    messageText,
    body,
  );
  if (!fresh) return context.json({ accepted: true, duplicate: true });
  return context.json({ accepted: true, ...processed });
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
    typeof body.text !== "string" ||
    body.text.trim().length === 0 ||
    body.text.length > 20_000
  )
    return context.json({ accepted: true, queued: false });
  const eventId = `${body.event}:${body.message_id}`;
  const fresh = await recordWebhook(context.env.DB, "blooio", eventId);
  const chatId =
    body.is_group === true && typeof body.group_id === "string"
      ? body.group_id
      : body.external_id;
  const messageText = body.text.trim();
  const token = linkToken(messageText);
  if (token) {
    if (!fresh) return context.json({ accepted: true, duplicate: true });
    const linked = await bind(
      context.env.DB,
      "blooio",
      body.sender,
      chatId,
      token,
    );
    return context.json({ accepted: true, linked: linked === "linked" });
  }
  const processed = await processChannelMessage(
    context.env,
    "blooio",
    fresh,
    eventId,
    body.message_id,
    body.sender,
    chatId,
    messageText,
    body,
  );
  if (!fresh) return context.json({ accepted: true, duplicate: true });
  return context.json({ accepted: true, ...processed });
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
  // The receipt is written on its own, before any entitlement work: folding it
  // into the same batch meant a failing write erased the record that the event
  // ever arrived, so Stripe redelivered it forever into the same failure.
  const receipt = await context.env.DB.prepare(
    "INSERT OR IGNORE INTO stripe_events (event_id, event_type, received_at) VALUES (?1, ?2, ?3)",
  )
    .bind(event.id, event.type, Date.now())
    .run();
  const duplicate = receipt.meta.changes === 0;
  if (!object) return context.json({ received: true, duplicate });
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
  // A session the payer walked away from: release it so the chat can be
  // offered a fresh link. It carries no entitlement change.
  if (event.type === "checkout.session.expired") {
    if (typeof object.id === "string")
      await expireChannelCheckout(context.env, object.id);
    return context.json({ received: true, duplicate, updated: false });
  }
  // Neither a failed invoice nor a chargeback carries our uid, so both revoke
  // against the Stripe customer. Access has to stop in both cases.
  if (
    event.type === "invoice.payment_failed" ||
    event.type === "charge.dispute.created"
  ) {
    const disputed =
      event.type === "charge.dispute.created"
        ? await customerForDispute(context.env, object)
        : typeof object.customer === "string"
          ? object.customer
          : null;
    if (!disputed) {
      return context.json({ received: true, duplicate, updated: false });
    }
    const revoked = await deactivateForCustomer(
      context.env,
      disputed,
      event.created,
    ).run();
    return context.json({
      received: true,
      duplicate,
      updated: revoked.meta.changes > 0,
    });
  }
  const customer = typeof object.customer === "string" ? object.customer : null;
  const subscription =
    typeof object.subscription === "string"
      ? object.subscription
      : typeof object.id === "string" &&
          event.type.startsWith("customer.subscription.")
        ? object.id
        : null;
  if (!uid || !customer)
    return context.json({ received: true, duplicate, updated: false });
  if (event.type === "checkout.session.completed") {
    const provisioned = await claimStripeCustomer(
      context.env,
      uid,
      customer,
    ).run();
    // An account that was signed up inside a chat finishes signing up here:
    // the entitlement is provisioned and the confirmation goes back into the
    // same conversation, with no further step for the payer.
    const completion = await completeChannelCheckout(context.env, {
      sessionId: typeof object.id === "string" ? object.id : null,
      uid,
      customer,
      subscription,
      paid:
        object.payment_status === "paid" ||
        object.payment_status === "no_payment_required",
      email:
        typeof (object.customer_details as { email?: unknown } | undefined)
          ?.email === "string"
          ? (object.customer_details as { email: string }).email
          : null,
      eventCreated: event.created,
    });
    return context.json({
      received: true,
      duplicate,
      updated: provisioned.meta.changes === 1,
      channel: completion.provisioned,
    });
  }
  if (!event.type.startsWith("customer.subscription."))
    return context.json({ received: true, duplicate, updated: false });
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
  const applied = await applySubscriptionState(context.env, {
    uid,
    status: typeof object.status === "string" ? object.status : null,
    validUntil,
    customer,
    subscriptionId: subscription,
    priceId,
    eventCreated: event.created,
  }).run();
  return context.json({
    received: true,
    duplicate,
    updated: applied.meta.changes === 1,
  });
});

export default webhooks;
