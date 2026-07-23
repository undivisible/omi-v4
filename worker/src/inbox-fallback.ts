import { type ManagedMessage, runManagedInboxCompletion } from "./assistant";
import { channelCommandPrompt } from "./channel-commands";
import { completeInboxItemDone } from "./conversations";
import { hasActivePro } from "./entitlement";
import { memoryContextFor } from "./memory-vectors";
import type { Bindings } from "./types";

export const fallbackClaimDelayMs = 2 * 60_000;
export const offlineAcknowledgement =
  "Got it — I'll answer when your desktop is back online.";

const fallbackLeaseMs = 2 * 60_000;
const maxItemsPerRun = 5;
const maxAttempts = 5;
const historyLimit = 12;
const maxReplyCharacters = 4_096;

export const systemPrompt =
  "You are Omi, the user's personal assistant, replying over a messaging " +
  "channel while their desktop is offline. Answer the user's latest message " +
  `directly and concisely in plain text.\n\n${channelCommandPrompt}`;

type StaleRow = { id: string; uid: string };

type ClaimedItem = {
  id: string;
  channel: string;
  text: string;
  attempts: number;
};

const recentHistory = async (
  db: D1Database,
  uid: string,
  channel: string,
): Promise<ManagedMessage[]> => {
  const rows = await db
    .prepare(
      `SELECT role, text FROM conversation_messages
       WHERE uid = ?1 AND conversation_id = ?1
         AND cursor > COALESCE(
           (SELECT MAX(conversation_reset_cursor) FROM channel_bindings
            WHERE uid = ?1 AND channel = ?3 AND revoked_at IS NULL),
           0)
       ORDER BY cursor DESC LIMIT ?2`,
    )
    .bind(uid, historyLimit, channel)
    .all<{ role: string; text: string }>();
  return (rows.results ?? [])
    .reverse()
    .filter((row) => row.role === "user" || row.role === "assistant")
    .map((row) => ({
      role: row.role as "user" | "assistant",
      content: String(row.text),
    }));
};

const buildMessages = (
  memoryContext: string | null,
  history: ManagedMessage[],
  inbound: string,
): ManagedMessage[] => [
  {
    role: "system",
    content:
      memoryContext === null
        ? systemPrompt
        : `${systemPrompt}\n\n${memoryContext}`,
  },
  ...history,
  { role: "user", content: inbound },
];

const releaseForRetry = async (
  env: Bindings,
  item: ClaimedItem,
  uid: string,
  leaseToken: string,
  error: string,
): Promise<void> => {
  await env.DB.prepare(
    `UPDATE channel_inbox
     SET status = CASE WHEN attempts < ?1 THEN 'pending' ELSE 'failed' END,
         lease_until = NULL, lease_token = NULL, last_error = ?2,
         completed_at = CASE WHEN attempts >= ?1 THEN ?3 ELSE NULL END
     WHERE id = ?4 AND uid = ?5 AND status = 'processing' AND lease_token = ?6`,
  )
    .bind(maxAttempts, error, Date.now(), item.id, uid, leaseToken)
    .run();
};

const respondToItem = async (
  env: Bindings,
  row: StaleRow,
  now: number,
  fetcher: typeof fetch,
): Promise<void> => {
  const leaseToken = crypto.randomUUID();
  const item = await env.DB.prepare(
    `UPDATE channel_inbox
     SET status = 'processing', attempts = attempts + 1, lease_until = ?3,
         lease_token = ?4, last_error = NULL
     WHERE id = ?1 AND uid = ?2 AND status = 'pending' AND attempts < ?5
       AND received_at <= ?6
     RETURNING id, channel, text, attempts`,
  )
    .bind(
      row.id,
      row.uid,
      now + fallbackLeaseMs,
      leaseToken,
      maxAttempts,
      now - fallbackClaimDelayMs,
    )
    .first<ClaimedItem>();
  if (!item) return;
  let reply: string;
  if (await hasActivePro(env, row.uid)) {
    const memoryContext = await memoryContextFor(
      env,
      row.uid,
      String(item.text),
    );
    const history = await recentHistory(env.DB, row.uid, String(item.channel));
    const completion = await runManagedInboxCompletion(
      env,
      row.uid,
      buildMessages(memoryContext, history, String(item.text)),
      fetcher,
    );
    if (completion === null) {
      if (Number(item.attempts) < maxAttempts) {
        await releaseForRetry(
          env,
          item,
          row.uid,
          leaseToken,
          "Fallback completion unavailable",
        );
        return;
      }
      reply = offlineAcknowledgement;
    } else {
      reply = completion;
    }
  } else {
    reply = offlineAcknowledgement;
  }
  reply = reply.trim().slice(0, maxReplyCharacters);
  if (reply.length === 0) reply = offlineAcknowledgement;
  const result = await completeInboxItemDone(
    env,
    row.uid,
    item.id,
    leaseToken,
    reply,
    Date.now(),
  );
  if (!result.ok)
    await releaseForRetry(env, item, row.uid, leaseToken, result.error);
};

export const respondToStaleInboxItems = async (
  env: Bindings,
  now = Date.now(),
  fetcher: typeof fetch = fetch,
): Promise<void> => {
  if (env.CHANNEL_FALLBACK_RESPONDER === "false") return;
  const stale = await env.DB.prepare(
    `SELECT id, uid FROM channel_inbox
     WHERE status = 'pending' AND attempts < ?1 AND received_at <= ?2
     ORDER BY received_at, id LIMIT ?3`,
  )
    .bind(maxAttempts, now - fallbackClaimDelayMs, maxItemsPerRun)
    .all<StaleRow>();
  for (const row of stale.results ?? []) {
    try {
      await respondToItem(env, row, now, fetcher);
    } catch {}
  }
};
