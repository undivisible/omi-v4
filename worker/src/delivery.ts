import type { Bindings, Channel } from "./types";

type Delivery = {
  id: string;
  uid: string;
  channel: Channel;
  channel_chat_id: string;
  text: string;
  attempts: number;
  idempotency_key: string;
  lease_token: string;
};

const maxAttempts = 5;
const leaseMs = 30_000;

const coordinatorName = (uid: string, channel: Channel): string =>
  `${uid}\u0000${channel}`;

export const dispatchChannelMessage = async (
  env: Bindings,
  id: string,
  uid: string,
  channel: Channel,
  now = Date.now(),
): Promise<void> => {
  const stub = env.DELIVERY_COORDINATOR.get(
    env.DELIVERY_COORDINATOR.idFromName(coordinatorName(uid, channel)),
  );
  const response = await stub.fetch("https://delivery.internal/deliver", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id, uid, channel, now }),
  });
  if (!response.ok) throw new Error("Delivery coordinator unavailable");
};

const unlinkChannel = async (
  env: Bindings,
  uid: string,
  channel: Channel,
  now = Date.now(),
): Promise<number> => {
  const [bindings] = await env.DB.batch([
    env.DB.prepare(
      "UPDATE channel_bindings SET revoked_at = ?1 WHERE uid = ?2 AND channel = ?3 AND revoked_at IS NULL",
    ).bind(now, uid, channel),
    env.DB.prepare(
      "UPDATE channel_link_tokens SET consumed_at = ?1 WHERE uid = ?2 AND channel = ?3 AND consumed_at IS NULL",
    ).bind(now, uid, channel),
    env.DB.prepare(
      `UPDATE channel_deliveries
       SET state = 'cancelled', lease_until = NULL, lease_token = NULL,
           last_error = 'Channel unlinked', updated_at = ?1
       WHERE uid = ?2 AND channel = ?3 AND state NOT IN ('sent', 'cancelled')`,
    ).bind(now, uid, channel),
  ]);
  if (bindings.meta.changes > 0)
    await env.DB.prepare(
      "INSERT INTO audit_events (id, uid, actor_type, action, target_type, target_id, details, created_at) VALUES (?1, ?2, 'owner', 'channel.unlinked', 'channel', ?3, ?4, ?5)",
    )
      .bind(
        crypto.randomUUID(),
        uid,
        channel,
        JSON.stringify({ revokedBindings: bindings.meta.changes }),
        now,
      )
      .run();
  return bindings.meta.changes;
};

export const dispatchChannelUnlink = async (
  env: Bindings,
  uid: string,
  channel: Channel,
): Promise<void> => {
  const stub = env.DELIVERY_COORDINATOR.get(
    env.DELIVERY_COORDINATOR.idFromName(coordinatorName(uid, channel)),
  );
  const response = await stub.fetch("https://delivery.internal/unlink", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ uid, channel }),
  });
  if (!response.ok) throw new Error("Delivery coordinator unavailable");
};

const dispatchOrphanCancellation = async (
  env: Bindings,
  uid: string,
  channel: Channel,
  now: number,
): Promise<void> => {
  const stub = env.DELIVERY_COORDINATOR.get(
    env.DELIVERY_COORDINATOR.idFromName(coordinatorName(uid, channel)),
  );
  const response = await stub.fetch(
    "https://delivery.internal/cancel-orphans",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ uid, channel, now }),
    },
  );
  if (!response.ok) throw new Error("Delivery coordinator unavailable");
};

const cancelOrphanDeliveries = async (
  env: Bindings,
  uid: string,
  channel: Channel,
  now: number,
): Promise<void> => {
  await env.DB.prepare(
    `UPDATE channel_deliveries SET state = 'cancelled', lease_until = NULL, lease_token = NULL,
       last_error = 'Channel unlinked', updated_at = ?1
     WHERE uid = ?2 AND channel = ?3 AND state NOT IN ('sent', 'cancelled') AND NOT EXISTS (
       SELECT 1 FROM channel_bindings b
       WHERE b.uid = channel_deliveries.uid AND b.channel = channel_deliveries.channel
         AND b.revoked_at IS NULL
         AND COALESCE(b.channel_chat_id, b.channel_user_id) = channel_deliveries.channel_chat_id
     )`,
  )
    .bind(now, uid, channel)
    .run();
};

const responseMessageId = async (
  response: Response,
): Promise<string | null> => {
  try {
    const body = (await response.json()) as Record<string, unknown>;
    const telegram = body.result as Record<string, unknown> | undefined;
    const value = telegram?.message_id ?? body.message_id ?? body.id;
    return typeof value === "string" || typeof value === "number"
      ? String(value)
      : null;
  } catch {
    return null;
  }
};

const claim = async (
  db: D1Database,
  id: string,
  now: number,
  uid: string,
  channel: Channel,
): Promise<Delivery | null> => {
  const leaseToken = crypto.randomUUID();
  return db
    .prepare(
      `UPDATE channel_deliveries
       SET state = 'delivering', attempts = attempts + 1, lease_until = ?2, lease_token = ?5, updated_at = ?1
       WHERE id = ?3 AND uid = ?6 AND channel = ?7 AND attempts < ?4
         AND EXISTS (
           SELECT 1 FROM channel_bindings b
           WHERE b.uid = channel_deliveries.uid AND b.channel = channel_deliveries.channel
             AND b.revoked_at IS NULL
             AND COALESCE(b.channel_chat_id, b.channel_user_id) = channel_deliveries.channel_chat_id
         )
         AND NOT EXISTS (
           SELECT 1 FROM channel_deliveries older
           WHERE older.channel = channel_deliveries.channel
             AND older.uid = channel_deliveries.uid
             AND older.channel_chat_id = channel_deliveries.channel_chat_id
             AND older.rowid < channel_deliveries.rowid
             AND older.state IN ('pending', 'retry', 'delivering')
         )
         AND (
           (state IN ('pending', 'retry') AND next_attempt_at <= ?1) OR
           (state = 'delivering' AND lease_until < ?1)
         )
       RETURNING id, uid, channel, channel_chat_id, text, attempts, idempotency_key, lease_token`,
    )
    .bind(now, now + leaseMs, id, maxAttempts, leaseToken, uid, channel)
    .first<Delivery>();
};

const retryDelay = async (
  attempts: number,
  response?: Response,
): Promise<number> => {
  const header = response?.headers.get("retry-after");
  const seconds = Number(header);
  const headerDelay = Number.isFinite(seconds)
    ? seconds * 1000
    : header
      ? Date.parse(header) - Date.now()
      : 0;
  let jsonDelay = 0;
  if (response) {
    try {
      const body = (await response.clone().json()) as Record<string, unknown>;
      const parameters = body.parameters as Record<string, unknown> | undefined;
      const value = parameters?.retry_after ?? body.retry_after;
      if (typeof value === "number" && Number.isFinite(value))
        jsonDelay = value * 1000;
    } catch {}
  }
  const providerDelay = Math.max(headerDelay, jsonDelay);
  if (providerDelay > 0) return Math.min(providerDelay, 60 * 60_000);
  const base = Math.min(2 ** attempts * 1000, 15 * 60_000);
  return Math.floor(base * (0.8 + Math.random() * 0.4));
};

const stableIdempotencyKey = async (delivery: Delivery): Promise<string> => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      `${delivery.uid}\u0000${delivery.channel}\u0000${delivery.idempotency_key}`,
    ),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
};

const requestFor = async (
  delivery: Delivery,
  env: Bindings,
): Promise<{ url: string; init: RequestInit } | null> => {
  if (delivery.channel === "telegram") {
    if (!env.TELEGRAM_BOT_TOKEN) return null;
    return {
      url: `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`,
      init: {
        method: "POST",
        signal: AbortSignal.timeout(15_000),
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: delivery.channel_chat_id,
          text: delivery.text,
        }),
      },
    };
  }
  if (!env.BLOOIO_API_KEY) return null;
  return {
    url: `https://api.blooio.com/v2/api/chats/${encodeURIComponent(delivery.channel_chat_id)}/messages`,
    init: {
      method: "POST",
      signal: AbortSignal.timeout(15_000),
      headers: {
        authorization: `Bearer ${env.BLOOIO_API_KEY}`,
        "content-type": "application/json",
        "idempotency-key": await stableIdempotencyKey(delivery),
      },
      body: JSON.stringify({ text: delivery.text }),
    },
  };
};

const update = async (
  env: Bindings,
  delivery: Delivery,
  sql: string,
  values: unknown[],
): Promise<void> => {
  await env.DB.prepare(sql)
    .bind(...values, delivery.id, delivery.lease_token)
    .run();
};

const deliverChannelMessage = async (
  env: Bindings,
  id: string,
  fetcher: typeof fetch,
  now: number,
  uid: string,
  channel: Channel,
): Promise<void> => {
  const delivery = await claim(env.DB, id, now, uid, channel);
  if (!delivery) return;
  const request = await requestFor(delivery, env);
  if (!request) {
    await update(
      env,
      delivery,
      "UPDATE channel_deliveries SET state = 'failed', lease_until = NULL, lease_token = NULL, last_error = 'Provider credentials unavailable', updated_at = ?1 WHERE id = ?2 AND state = 'delivering' AND lease_token = ?3",
      [now],
    );
    return;
  }
  try {
    const response = await fetcher(request.url, request.init);
    if (response.ok) {
      await update(
        env,
        delivery,
        "UPDATE channel_deliveries SET state = 'sent', lease_until = NULL, lease_token = NULL, provider_message_id = ?1, last_error = NULL, sent_at = ?2, updated_at = ?2 WHERE id = ?3 AND state = 'delivering' AND lease_token = ?4",
        [await responseMessageId(response), now],
      );
      return;
    }
    const retryable = response.status === 429 || response.status >= 500;
    const exhausted = delivery.attempts >= maxAttempts;
    await update(
      env,
      delivery,
      "UPDATE channel_deliveries SET state = ?1, lease_until = NULL, lease_token = NULL, next_attempt_at = ?2, last_error = ?3, updated_at = ?4 WHERE id = ?5 AND state = 'delivering' AND lease_token = ?6",
      [
        retryable && !exhausted ? "retry" : "failed",
        now + (await retryDelay(delivery.attempts, response)),
        `Provider HTTP ${response.status}`,
        now,
      ],
    );
  } catch {
    const ambiguousTelegram = delivery.channel === "telegram";
    const exhausted = delivery.attempts >= maxAttempts;
    await update(
      env,
      delivery,
      "UPDATE channel_deliveries SET state = ?1, lease_until = NULL, lease_token = NULL, next_attempt_at = ?2, last_error = ?3, updated_at = ?4 WHERE id = ?5 AND state = 'delivering' AND lease_token = ?6",
      [
        ambiguousTelegram ? "unknown" : exhausted ? "failed" : "retry",
        now + (await retryDelay(delivery.attempts)),
        ambiguousTelegram
          ? "Provider outcome unknown"
          : "Provider network failure",
        now,
      ],
    );
  }
};

export const deliverDueChannelMessages = async (
  env: Bindings,
  now = Date.now(),
): Promise<void> => {
  const orphans = await env.DB.prepare(
    `SELECT DISTINCT d.uid, d.channel FROM channel_deliveries d
     WHERE d.state NOT IN ('sent', 'cancelled') AND NOT EXISTS (
       SELECT 1 FROM channel_bindings b
       WHERE b.uid = d.uid AND b.channel = d.channel
         AND b.revoked_at IS NULL
         AND COALESCE(b.channel_chat_id, b.channel_user_id) = d.channel_chat_id
     )`,
  ).all<{ uid: string; channel: Channel }>();
  await Promise.all(
    (orphans.results ?? []).map(({ uid, channel }) =>
      dispatchOrphanCancellation(env, uid, channel, now),
    ),
  );
  const rows = await env.DB.prepare(
    `SELECT d.id, d.uid, d.channel FROM channel_deliveries d
     WHERE d.attempts < ?1 AND (
       (d.state IN ('pending', 'retry') AND d.next_attempt_at <= ?2) OR
       (d.state = 'delivering' AND d.lease_until < ?2)
     ) AND NOT EXISTS (
       SELECT 1 FROM channel_deliveries older
       WHERE older.uid = d.uid AND older.channel = d.channel AND older.channel_chat_id = d.channel_chat_id
         AND older.rowid < d.rowid
         AND older.state IN ('pending', 'retry', 'delivering')
     ) ORDER BY d.next_attempt_at LIMIT 25`,
  )
    .bind(maxAttempts, now)
    .all<{ id: string; uid: string; channel: Channel }>();
  await Promise.all(
    (rows.results ?? []).map(({ id, uid, channel }) =>
      dispatchChannelMessage(env, id, uid, channel, now),
    ),
  );
};

export class DeliveryCoordinator {
  private tail: Promise<void> = Promise.resolve();

  constructor(
    readonly state: DurableObjectState,
    public env: Bindings,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const operation = this.tail.then(async () => {
      const body = (await request.json()) as Record<string, unknown>;
      const path = new URL(request.url).pathname;
      const uid = typeof body.uid === "string" ? body.uid : null;
      const channel =
        body.channel === "telegram" || body.channel === "blooio"
          ? body.channel
          : null;
      const now =
        typeof body.now === "number" && Number.isSafeInteger(body.now)
          ? body.now
          : Date.now();
      if (
        !uid ||
        !channel ||
        !this.state.id.equals(
          this.env.DELIVERY_COORDINATOR.idFromName(
            coordinatorName(uid, channel),
          ),
        )
      )
        throw new Error("Delivery coordinator identity mismatch");
      if (
        path === "/deliver" &&
        typeof body.id === "string" &&
        uid &&
        channel
      ) {
        await deliverChannelMessage(
          this.env,
          body.id,
          fetch,
          now,
          uid,
          channel,
        );
        return;
      }
      if (path === "/unlink" && uid && channel) {
        await unlinkChannel(this.env, uid, channel, now);
        return;
      }
      if (path === "/cancel-orphans" && uid && channel) {
        await cancelOrphanDeliveries(this.env, uid, channel, now);
        return;
      }
      throw new Error("Invalid delivery coordinator request");
    });
    this.tail = operation.catch(() => {});
    try {
      await operation;
      return new Response(null, { status: 204 });
    } catch {
      return Response.json(
        { error: "Delivery coordination failed" },
        { status: 500 },
      );
    }
  }
}
