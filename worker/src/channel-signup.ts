import { consumeRateLimit } from "./rate-limit";
import type { Bindings, Channel } from "./types";

// A first-contact answer typed on a phone: no punctuation rules, no exact
// syntax. Anything we cannot read confidently comes back as null so the
// caller can ask again rather than guess.
export type SignupAnswer = "has-account" | "needs-account" | null;

const words = (text: string): string =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9\s']/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const hasAccountPhrases = [
  "yes",
  "y",
  "ya",
  "yah",
  "yeah",
  "yep",
  "yup",
  "yes i do",
  "i do",
  "i have",
  "i have one",
  "i have an account",
  "already",
  "already have one",
  "already have an account",
  "existing",
  "existing account",
  "got one",
  "i've got one",
  "sure",
  "link",
  "link it",
  "1",
];

const needsAccountPhrases = [
  "no",
  "n",
  "nope",
  "nah",
  "no i don't",
  "no i dont",
  "i don't",
  "i dont",
  "i do not",
  "don't have one",
  "dont have one",
  "no account",
  "not yet",
  "never",
  "new",
  "i'm new",
  "im new",
  "new here",
  "create one",
  "make one",
  "sign me up",
  "sign up",
  "signup",
  "register",
  "2",
];

export const parseSignupAnswer = (text: string): SignupAnswer => {
  const normalized = words(text);
  if (normalized.length === 0 || normalized.length > 60) return null;
  if (needsAccountPhrases.includes(normalized)) return "needs-account";
  if (hasAccountPhrases.includes(normalized)) return "has-account";
  return null;
};

export type ChannelAccount = {
  uid: string;
  createdAt: number;
  claimedAt: number | null;
};

// The live, unclaimed account this channel identity owns, if any. A claimed or
// retired row is deliberately invisible here: neither may be handed back to
// whoever holds the handle next.
export const liveChannelAccount = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
): Promise<ChannelAccount | null> => {
  const row = await db
    .prepare(
      `SELECT uid, created_at, claimed_at FROM channel_accounts
       WHERE channel = ?1 AND channel_user_id = ?2
         AND claimed_at IS NULL AND retired_at IS NULL`,
    )
    .bind(channel, channelUserId)
    .first<{ uid: string; created_at: number; claimed_at: number | null }>();
  if (!row) return null;
  return {
    uid: String(row.uid),
    createdAt: Number(row.created_at),
    claimedAt: row.claimed_at === null ? null : Number(row.claimed_at),
  };
};

export const isChannelAccount = async (
  db: D1Database,
  uid: string,
): Promise<boolean> =>
  (await db
    .prepare("SELECT uid FROM channel_accounts WHERE uid = ?1")
    .bind(uid)
    .first()) !== null;

// Creating an account from an inbound message is a spam vector, so it is
// capped twice: per sender, and across the whole worker.
const signupAllowed = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
): Promise<boolean> => {
  const perSender = await consumeRateLimit(
    env,
    `channel-signup:${channel}:${channelUserId}`,
    3,
    24 * 60 * 60_000,
  );
  if (!perSender.allowed) return false;
  const global = await consumeRateLimit(
    env,
    "channel-signup:global",
    500,
    60 * 60_000,
  );
  return global.allowed;
};

export type SignupResult =
  | { status: "created" | "existing"; uid: string }
  | { status: "rate-limited" | "conflict" };

// Sign a verified channel identity up. The identity the webhook proved is the
// only credential: no password is invented, none is asked for, and an account
// created here is a placeholder a real sign-in claims later.
export const signUpChannelSender = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now = Date.now(),
): Promise<SignupResult> => {
  const existingAccount = await liveChannelAccount(
    env.DB,
    channel,
    channelUserId,
  );
  const binding = await env.DB.prepare(
    `SELECT uid FROM channel_bindings
     WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL`,
  )
    .bind(channel, channelUserId)
    .first<{ uid: string }>();
  // A replayed webhook lands here a second time: the account it already made
  // is returned unchanged, and a chat someone linked to a real account is
  // never taken over.
  if (binding)
    return existingAccount && String(binding.uid) === existingAccount.uid
      ? { status: "existing", uid: existingAccount.uid }
      : { status: "conflict" };
  if (existingAccount) return { status: "existing", uid: existingAccount.uid };
  if (!(await signupAllowed(env, channel, channelUserId)))
    return { status: "rate-limited" };
  const uid = `chan_${Array.from(
    crypto.getRandomValues(new Uint8Array(16)),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("")}`;
  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, NULL, ?2, ?2)",
    ).bind(uid, now),
    env.DB.prepare(
      `INSERT INTO channel_accounts
         (uid, channel, channel_user_id, channel_chat_id, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT DO NOTHING`,
    ).bind(uid, channel, channelUserId, channelChatId, now),
    env.DB.prepare(
      `INSERT INTO channel_bindings
         (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)
       VALUES (?1, ?2, ?3, ?4, NULL, ?5)
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET
         uid = excluded.uid, verified_at = excluded.verified_at,
         revoked_at = NULL, channel_chat_id = excluded.channel_chat_id
       WHERE channel_bindings.revoked_at IS NOT NULL`,
    ).bind(channel, channelUserId, uid, now, channelChatId),
    env.DB.prepare(
      `INSERT INTO audit_events
         (id, uid, actor_type, action, target_type, target_id, details, created_at)
       VALUES (?1, ?2, 'channel', 'channel.account_created', 'channel', ?3, ?4, ?5)`,
    ).bind(
      crypto.randomUUID(),
      uid,
      channel,
      JSON.stringify({ channelUserId, channelChatId }),
      now,
    ),
  ]);
  if (results[1].meta.changes !== 1 || results[2].meta.changes !== 1) {
    await env.DB.prepare("DELETE FROM users WHERE uid = ?1").bind(uid).run();
    const settled = await liveChannelAccount(env.DB, channel, channelUserId);
    return settled
      ? { status: "existing", uid: settled.uid }
      : { status: "conflict" };
  }
  return { status: "created", uid };
};

// Unlinking a channel-created account closes it: the handle is the only way
// in, so the row is retired rather than left for whoever holds that handle
// next.
export const retireChannelAccount = async (
  db: D1Database,
  uid: string,
  now = Date.now(),
): Promise<void> => {
  await db
    .prepare(
      "UPDATE channel_accounts SET retired_at = ?1 WHERE uid = ?2 AND retired_at IS NULL",
    )
    .bind(now, uid)
    .run();
};

// A real sign-in redeeming this chat's link code claims the placeholder, so it
// can never be handed out again.
export const claimChannelAccount = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
  claimedByUid: string,
  now = Date.now(),
): Promise<string | null> => {
  const account = await liveChannelAccount(db, channel, channelUserId);
  if (!account) return null;
  const result = await db
    .prepare(
      `UPDATE channel_accounts SET claimed_at = ?1, claimed_by_uid = ?2
       WHERE uid = ?3 AND claimed_at IS NULL AND retired_at IS NULL`,
    )
    .bind(now, claimedByUid, account.uid)
    .run();
  return result.meta.changes === 1 ? account.uid : null;
};

export type FirstContact = { askedAt: number; answeredAt: number | null };

export const firstContactState = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
): Promise<FirstContact | null> => {
  const row = await db
    .prepare(
      `SELECT asked_at, answered_at FROM channel_first_contact
       WHERE channel = ?1 AND channel_user_id = ?2`,
    )
    .bind(channel, channelUserId)
    .first<{ asked_at: number; answered_at: number | null }>();
  if (!row) return null;
  return {
    askedAt: Number(row.asked_at),
    answeredAt: row.answered_at === null ? null : Number(row.answered_at),
  };
};

export const recordFirstContact = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now = Date.now(),
): Promise<void> => {
  await db
    .prepare(
      `INSERT INTO channel_first_contact
         (channel, channel_user_id, channel_chat_id, asked_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET
         channel_chat_id = excluded.channel_chat_id, asked_at = excluded.asked_at`,
    )
    .bind(channel, channelUserId, channelChatId, now)
    .run();
};

export const markFirstContactAnswered = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
  now = Date.now(),
): Promise<void> => {
  await db
    .prepare(
      `UPDATE channel_first_contact SET answered_at = ?1
       WHERE channel = ?2 AND channel_user_id = ?3 AND answered_at IS NULL`,
    )
    .bind(now, channel, channelUserId)
    .run();
};
