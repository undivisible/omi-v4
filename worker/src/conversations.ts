import { Hono } from "hono";
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
