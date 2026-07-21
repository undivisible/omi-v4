import { Hono, type Context } from "hono";
import type { AppEnv, Channel } from "./types";

const webhooks = new Hono<AppEnv>();
const BLOOIO_SIGNATURE_TOLERANCE_SECONDS = 300;
const encoder = new TextEncoder();

const equal = (left: string, right: string): boolean => {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index++)
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return mismatch === 0;
};

const hex = (bytes: Uint8Array): string =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

const verifyBlooioSignature = async (
  rawBody: string,
  header: string,
  secret: string,
): Promise<boolean> => {
  const parts = header.split(",").map((part) => part.trim());
  const timestamps = parts.filter((part) => part.startsWith("t="));
  const signatures = parts.filter((part) => part.startsWith("v1="));
  if (timestamps.length !== 1 || signatures.length !== 1) return false;
  const timestamp = timestamps[0]?.slice(2) ?? "";
  const supplied = signatures[0]?.slice(3) ?? "";
  if (!/^\d+$/.test(timestamp) || !/^[a-fA-F0-9]{64}$/.test(supplied))
    return false;
  const timestampSeconds = Number(timestamp);
  if (!Number.isSafeInteger(timestampSeconds)) return false;
  const age = Math.floor(Date.now() / 1_000) - timestampSeconds;
  if (
    age > BLOOIO_SIGNATURE_TOLERANCE_SECONDS ||
    age < -BLOOIO_SIGNATURE_TOLERANCE_SECONDS
  )
    return false;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${timestamp}.${rawBody}`),
  );
  return equal(hex(new Uint8Array(digest)), supplied.toLowerCase());
};

const accept = async (
  context: Context<AppEnv>,
  channel: Channel,
  eventId: string | null,
) => {
  if (!eventId) return context.json({ error: "Missing event id" }, 400);
  const now = Date.now();
  const result = await context.env.DB.prepare(
    "INSERT OR IGNORE INTO webhook_events (channel, event_id, received_at) VALUES (?1, ?2, ?3)",
  )
    .bind(channel, eventId, now)
    .run();
  if (result.meta.changes > 0) {
    await context.env.DB.prepare(
      "INSERT INTO audit_events (id, actor_type, action, target_type, target_id, created_at) VALUES (?1, 'channel', ?2, 'webhook', ?3, ?4)",
    )
      .bind(crypto.randomUUID(), `${channel}.received`, eventId, now)
      .run();
  }
  return context.json({ accepted: true, duplicate: result.meta.changes === 0 });
};

webhooks.post("/telegram", async (context) => {
  const secret = context.env.TELEGRAM_WEBHOOK_SECRET;
  const supplied = context.req.header("x-telegram-bot-api-secret-token") ?? "";
  if (!secret || !supplied || !equal(secret, supplied))
    return context.json({ error: "Unauthorized" }, 401);
  const body = (await context.req.json().catch(() => null)) as {
    update_id?: unknown;
  } | null;
  return accept(
    context,
    "telegram",
    typeof body?.update_id === "number" ? String(body.update_id) : null,
  );
});

webhooks.post("/blooio", async (context) => {
  const secret = context.env.BLOOIO_WEBHOOK_SIGNING_SECRET;
  const supplied = context.req.header("x-blooio-signature") ?? "";
  const rawBody = await context.req.text();
  if (!secret || !(await verifyBlooioSignature(rawBody, supplied, secret)))
    return context.json({ error: "Unauthorized" }, 401);
  try {
    JSON.parse(rawBody);
  } catch {
    return context.json({ error: "Invalid body" }, 400);
  }
  return accept(context, "blooio", context.req.header("x-webhook-id") ?? null);
});

export default webhooks;
