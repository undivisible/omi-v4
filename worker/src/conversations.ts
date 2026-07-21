import { Hono } from "hono";
import { dispatchChannelMessage } from "./delivery";
import type { AppEnv, Channel } from "./types";

const conversations = new Hono<AppEnv>();
const encoder = new TextEncoder();

const digest = async (value: string): Promise<string> => {
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
};

export const appendConversationMessage = async (
  database: D1Database,
  message: {
    uid: string;
    clientMessageId: string;
    role: "assistant" | "user";
    source: "app" | "web" | "desktop" | Channel;
    text: string;
    channelMessageId?: string;
    deliveryId?: string;
    createdAt?: number;
  },
  statements: D1PreparedStatement[] = [],
) => {
  const conversationId = message.uid;
  const now = message.createdAt ?? Date.now();
  const payloadHash = await digest(
    JSON.stringify([
      message.role,
      message.source,
      message.text,
      message.channelMessageId ?? null,
      message.deliveryId ?? null,
    ]),
  );
  const id = crypto.randomUUID();
  await database.batch([
    ...statements,
    database
      .prepare(
        "INSERT OR IGNORE INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
      )
      .bind(conversationId, now),
    database
      .prepare(
        `INSERT OR IGNORE INTO conversation_messages
           (id, conversation_id, uid, client_message_id, role, source, text, payload_hash, channel_message_id, delivery_id, created_at)
         VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
      )
      .bind(
        id,
        conversationId,
        message.clientMessageId,
        message.role,
        message.source,
        message.text,
        payloadHash,
        message.channelMessageId ?? null,
        message.deliveryId ?? null,
        now,
      ),
  ]);
  const stored = await database
    .prepare(
      `SELECT cursor, id, client_message_id, role, source, text, channel_message_id, delivery_id, created_at, payload_hash
       FROM conversation_messages WHERE conversation_id = ?1 AND client_message_id = ?2 AND uid = ?1`,
    )
    .bind(conversationId, message.clientMessageId)
    .first<Record<string, unknown>>();
  if (!stored || stored.payload_hash !== payloadHash) return null;
  return {
    cursor: Number(stored.cursor),
    id: String(stored.id),
    clientMessageId: String(stored.client_message_id),
    role: String(stored.role),
    source: String(stored.source),
    text: String(stored.text),
    channelMessageId:
      stored.channel_message_id === null
        ? null
        : String(stored.channel_message_id),
    deliveryId: stored.delivery_id === null ? null : String(stored.delivery_id),
    createdAt: Number(stored.created_at),
    replayed: stored.id !== id,
  };
};

const body = async (request: Request) => {
  try {
    const value = await request.json();
    return value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const leaseMs = 5 * 60_000;
const token = (value: unknown): value is string =>
  typeof value === "string" && /^[A-Za-z0-9-]{8,128}$/.test(value);

conversations.post("/conversations/default/inbox/claim", async (context) => {
  const uid = context.get("auth").uid;
  const now = Date.now();
  await context.env.DB.prepare(
    `UPDATE channel_inbox SET status = 'failed', lease_until = NULL, lease_token = NULL,
       last_error = 'Automatic retry limit reached', completed_at = ?2
     WHERE uid = ?1 AND status = 'processing' AND lease_until <= ?2
       AND attempts >= 5`,
  )
    .bind(uid, now)
    .run();
  const leaseToken = crypto.randomUUID();
  const item = await context.env.DB.prepare(
    `UPDATE channel_inbox
     SET status = 'processing', attempts = attempts + 1, lease_until = ?2,
         lease_token = ?3, last_error = NULL
     WHERE uid = ?1
       AND id = (
         SELECT id FROM channel_inbox
         WHERE uid = ?1 AND status IN ('pending', 'processing')
         ORDER BY received_at, id LIMIT 1
       )
       AND attempts < 5
       AND (status = 'pending' OR (
         status = 'processing' AND lease_until <= ?4
       ))
     RETURNING id, channel, message_id, text, received_at, attempts, lease_token, lease_until`,
  )
    .bind(uid, now + leaseMs, leaseToken, now)
    .first<Record<string, unknown>>();
  return context.json({
    item: item
      ? {
          id: String(item.id),
          channel: String(item.channel),
          text: String(item.text),
          channelMessageId: String(item.message_id),
          receivedAt: Number(item.received_at),
          attempt: Number(item.attempts),
          leaseToken: String(item.lease_token),
          leaseUntil: Number(item.lease_until),
        }
      : null,
  });
});

conversations.post(
  "/conversations/default/inbox/:id/complete",
  async (context) => {
    const value = await body(context.req.raw);
    const leaseToken = value?.leaseToken;
    const outcome = value?.outcome;
    const error = value?.error;
    const responseText = value?.responseText;
    if (
      !token(leaseToken) ||
      (outcome !== "done" && outcome !== "retry") ||
      (outcome === "done" &&
        (typeof responseText !== "string" ||
          responseText.trim().length === 0 ||
          responseText.length > 4_096)) ||
      (outcome === "retry" && responseText !== undefined) ||
      (error !== undefined &&
        (typeof error !== "string" || error.length > 1_000))
    )
      return context.json({ error: "Invalid inbox outcome" }, 400);
    const now = Date.now();
    const id = context.req.param("id");
    const uid = context.get("auth").uid;
    if (outcome === "done") {
      const inbox = await context.env.DB.prepare(
        `SELECT i.channel, i.attempts, i.status, d.id AS delivery_id,
                d.state AS delivery_state, d.attempts AS delivery_attempts,
                d.provider_message_id, d.last_error, d.text AS delivery_text
         FROM channel_inbox i
         LEFT JOIN channel_deliveries d
           ON d.uid = i.uid AND d.channel = i.channel
          AND d.idempotency_key = 'inbox:' || i.id || ':attempt:' || i.attempts
         WHERE i.id = ?1 AND i.uid = ?2 AND i.lease_token = ?3
           AND (i.status = 'done' OR (
             i.status = 'processing' AND i.lease_until > ?4
           ))`,
      )
        .bind(id, uid, leaseToken, now)
        .first<{
          channel: Channel;
          attempts: number;
          status: string;
          delivery_id: string | null;
          delivery_state: string | null;
          delivery_attempts: number | null;
          provider_message_id: string | null;
          last_error: string | null;
          delivery_text: string | null;
        }>();
      if (!inbox) return context.json({ error: "Inbox lease conflict" }, 409);
      const reply = (responseText as string).trim();
      if (inbox.status === "done") {
        if (!inbox.delivery_id || inbox.delivery_text !== reply)
          return context.json({ error: "Inbox completion conflict" }, 409);
        return context.json({
          status: "done",
          delivery: {
            id: inbox.delivery_id,
            state: inbox.delivery_state,
            attempts: inbox.delivery_attempts,
            provider_message_id: inbox.provider_message_id,
            last_error: inbox.last_error,
          },
        });
      }
      const clientMessageId = `inbox-reply:${id}:${inbox.attempts}`;
      const idempotencyKey = `inbox:${id}:attempt:${inbox.attempts}`;
      const deliveryId = `inbox-delivery:${id}:${inbox.attempts}`;
      const conversationMessageId = clientMessageId;
      const payloadHash = await digest(
        JSON.stringify(["assistant", inbox.channel, reply, null, deliveryId]),
      );
      const results = await context.env.DB.batch([
        context.env.DB.prepare(
          "INSERT OR IGNORE INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
        ).bind(uid, now),
        context.env.DB.prepare(
          `INSERT OR IGNORE INTO channel_deliveries
               (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at)
             SELECT ?1, i.uid, i.channel, ?2, i.channel_chat_id, ?3, ?4, ?4, ?4
             FROM channel_inbox i
             WHERE i.id = ?5 AND i.uid = ?6 AND i.status = 'processing'
               AND i.lease_token = ?7 AND i.lease_until > ?4
               AND EXISTS (
                 SELECT 1 FROM channel_bindings b
                 WHERE b.uid = i.uid AND b.channel = i.channel
                   AND b.revoked_at IS NULL
                   AND COALESCE(b.channel_chat_id, b.channel_user_id) = i.channel_chat_id
               )`,
        ).bind(deliveryId, idempotencyKey, reply, now, id, uid, leaseToken),
        context.env.DB.prepare(
          `INSERT OR IGNORE INTO conversation_messages
               (id, conversation_id, uid, client_message_id, role, source, text, payload_hash, channel_message_id, delivery_id, created_at)
             SELECT ?1, i.uid, i.uid, ?2, 'assistant', i.channel, ?3, ?4, NULL, ?5, ?6
             FROM channel_inbox i
             JOIN channel_deliveries d ON d.id = ?5 AND d.uid = i.uid
             WHERE i.id = ?7 AND i.uid = ?8 AND i.status = 'processing'
               AND i.lease_token = ?9 AND i.lease_until > ?6`,
        ).bind(
          conversationMessageId,
          clientMessageId,
          reply,
          payloadHash,
          deliveryId,
          now,
          id,
          uid,
          leaseToken,
        ),
        context.env.DB.prepare(
          `UPDATE channel_inbox
             SET status = 'done', lease_until = NULL,
                 last_error = NULL, completed_at = ?1
             WHERE id = ?2 AND uid = ?3 AND status = 'processing'
               AND lease_token = ?4 AND lease_until > ?1
               AND EXISTS (SELECT 1 FROM channel_deliveries WHERE id = ?5 AND uid = ?3)`,
        ).bind(now, id, uid, leaseToken, deliveryId),
      ]);
      if (
        results[1].meta.changes !== 1 ||
        results[2].meta.changes !== 1 ||
        results[3].meta.changes !== 1
      ) {
        const persisted = await context.env.DB.prepare(
          `SELECT i.status, d.text
           FROM channel_inbox i
           JOIN channel_deliveries d ON d.id = ?1 AND d.uid = i.uid
           WHERE i.id = ?2 AND i.uid = ?3 AND i.lease_token = ?4`,
        )
          .bind(deliveryId, id, uid, leaseToken)
          .first<{ status: string; text: string }>();
        if (persisted?.status !== "done" || persisted.text !== reply)
          return context.json({ error: "Channel is not linked" }, 409);
      }
      try {
        await dispatchChannelMessage(
          context.env,
          deliveryId,
          uid,
          inbox.channel,
        );
      } catch {}
      const delivery = await context.env.DB.prepare(
        "SELECT id, state, attempts, provider_message_id, last_error FROM channel_deliveries WHERE id = ?1 AND uid = ?2",
      )
        .bind(deliveryId, uid)
        .first();
      return context.json({ status: "done", delivery });
    }
    await context.env.DB.batch([
      context.env.DB.prepare(
        `UPDATE channel_inbox SET
         status = CASE
           WHEN attempts < 5 THEN 'pending'
           ELSE 'failed'
         END,
         lease_until = NULL, last_error = ?1,
         completed_at = CASE
           WHEN attempts >= 5 THEN ?2 ELSE NULL
         END
       WHERE id = ?3 AND uid = ?4 AND status = 'processing'
         AND lease_token = ?5 AND lease_until > ?2
       RETURNING status`,
      ).bind(
        typeof error === "string" ? error : null,
        now,
        id,
        uid,
        leaseToken,
      ),
      context.env.DB.prepare(
        `INSERT OR IGNORE INTO channel_inbox_completions
           (inbox_id, uid, attempt, lease_token, outcome, result_status, completed_at)
         SELECT id, uid, attempts, ?1, 'retry', status, ?2
         FROM channel_inbox
         WHERE id = ?3 AND uid = ?4 AND lease_token = ?1
           AND status IN ('pending', 'failed')`,
      ).bind(leaseToken, now, id, uid),
    ]);
    const replay = await context.env.DB.prepare(
      `SELECT result_status FROM channel_inbox_completions
       WHERE inbox_id = ?1 AND uid = ?2 AND lease_token = ?3 AND outcome = 'retry'`,
    )
      .bind(id, uid, leaseToken)
      .first<{ result_status: string }>();
    if (!replay) return context.json({ error: "Inbox lease conflict" }, 409);
    return context.json({ status: replay.result_status });
  },
);

conversations.get("/conversations/default/messages", async (context) => {
  const after = Number(context.req.query("after") ?? 0);
  const limit = Number(context.req.query("limit") ?? 100);
  if (
    !Number.isSafeInteger(after) ||
    after < 0 ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 200
  )
    return context.json({ error: "Invalid replay range" }, 400);
  const uid = context.get("auth").uid;
  const rows = await context.env.DB.prepare(
    `SELECT cursor, id, client_message_id, role, source, text, channel_message_id, delivery_id, created_at
     FROM conversation_messages
     WHERE uid = ?1 AND conversation_id = ?1 AND cursor > ?2
     ORDER BY cursor LIMIT ?3`,
  )
    .bind(uid, after, limit)
    .all();
  const messages = (rows.results ?? []).map((row) => ({
    cursor: Number(row.cursor),
    id: String(row.id),
    clientMessageId: String(row.client_message_id),
    role: String(row.role),
    source: String(row.source),
    text: String(row.text),
    channelMessageId:
      row.channel_message_id === null ? null : String(row.channel_message_id),
    deliveryId: row.delivery_id === null ? null : String(row.delivery_id),
    createdAt: Number(row.created_at),
  }));
  return context.json({
    conversationId: "default",
    messages,
    nextCursor: messages.at(-1)?.cursor ?? after,
  });
});

conversations.post("/conversations/default/messages", async (context) => {
  const value = await body(context.req.raw);
  const clientMessageId = value?.clientMessageId;
  const role = value?.role;
  const source = value?.source;
  const messageText = value?.text;
  if (
    typeof clientMessageId !== "string" ||
    clientMessageId.length < 8 ||
    clientMessageId.length > 128 ||
    !/^[A-Za-z0-9._:-]+$/.test(clientMessageId) ||
    (role !== "user" && role !== "assistant") ||
    (source !== "app" && source !== "web" && source !== "desktop") ||
    typeof messageText !== "string" ||
    messageText.trim().length === 0 ||
    messageText.length > 20_000
  )
    return context.json({ error: "Invalid conversation message" }, 400);
  const message = await appendConversationMessage(context.env.DB, {
    uid: context.get("auth").uid,
    clientMessageId,
    role,
    source,
    text: messageText.trim(),
  });
  if (!message)
    return context.json({ error: "Client message ID conflict" }, 409);
  return context.json(
    { conversationId: "default", message },
    message.replayed ? 200 : 201,
  );
});

conversations.put(
  "/conversations/default/cursors/:clientId",
  async (context) => {
    const clientId = context.req.param("clientId");
    const value = await body(context.req.raw);
    const cursor = Number(value?.cursor);
    const expectedRevision = Number(value?.expectedRevision);
    if (
      !/^[A-Za-z0-9._:-]{8,128}$/.test(clientId) ||
      !Number.isSafeInteger(cursor) ||
      cursor < 0 ||
      !Number.isSafeInteger(expectedRevision) ||
      expectedRevision < 0
    )
      return context.json({ error: "Invalid replay cursor" }, 400);
    const uid = context.get("auth").uid;
    const now = Date.now();
    await context.env.DB.prepare(
      `INSERT INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)
     ON CONFLICT(uid) DO NOTHING`,
    )
      .bind(uid, now)
      .run();
    const result =
      expectedRevision === 0
        ? await context.env.DB.prepare(
            `INSERT OR IGNORE INTO conversation_replay_cursors
             (uid, conversation_id, client_id, cursor, revision, updated_at)
           VALUES (?1, ?1, ?2, ?3, 1, ?4)`,
          )
            .bind(uid, clientId, cursor, now)
            .run()
        : await context.env.DB.prepare(
            `UPDATE conversation_replay_cursors
           SET cursor = ?1, revision = revision + 1, updated_at = ?2
           WHERE uid = ?3 AND conversation_id = ?3 AND client_id = ?4
             AND revision = ?5 AND cursor <= ?1`,
          )
            .bind(cursor, now, uid, clientId, expectedRevision)
            .run();
    if (result.meta.changes !== 1)
      return context.json({ error: "Replay cursor conflict" }, 409);
    const stored = await context.env.DB.prepare(
      "SELECT cursor, revision, updated_at FROM conversation_replay_cursors WHERE uid = ?1 AND conversation_id = ?1 AND client_id = ?2",
    )
      .bind(uid, clientId)
      .first();
    return context.json({
      cursor: Number(stored?.cursor),
      revision: Number(stored?.revision),
      updatedAt: Number(stored?.updated_at),
    });
  },
);

export default conversations;
