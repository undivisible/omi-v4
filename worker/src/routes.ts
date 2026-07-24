import { Hono, type Context } from "hono";
import { hasActivePro } from "./entitlement";
import apiKeys from "./api-keys";
import asr from "./asr";
import assistant from "./assistant";
import billing from "./billing";
import byok from "./byok-negotiation";
import currents from "./currents";
import memorySync from "./memory-sync";
import memoryWrite from "./memory-write";
import { readMemoryLog, recordMirrorCursor } from "./memory-log";
import { ensureMemoryProjected } from "./memory-projection";
import {
  listDailyReviews,
  listProfileMemories,
  retrieveCitedMemory,
} from "./memory-read";
import {
  deferVectorWork,
  deleteClaimVectors,
  drainPendingEmbeddings,
  enqueueClaimEmbeddings,
  searchMemoryClaims,
} from "./memory-vectors";
import stt from "./stt";
import voice from "./voice";
import conversations, { appendConversationMessage } from "./conversations";
import { linkConfirmationText } from "./channel-commands";
import { normalizeLinkCode, resolveLinkCode } from "./channel-link";
import { liveChannelAccount } from "./channel-signup";
import {
  dispatchChannelMessage,
  dispatchChannelUnlink,
  sendChannelText,
} from "./delivery";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv, Channel, SettingsDuration, UserSettings } from "./types";

const routes = new Hono<AppEnv>();

routes.use("/memory/*", async (context, next) => {
  await ensureMemoryProjected(context.env.DB, context.get("auth").uid);
  await next();
});
routes.use("/memories", async (context, next) => {
  await ensureMemoryProjected(context.env.DB, context.get("auth").uid);
  await next();
});

routes.route("/", assistant);
routes.route("/api-keys", apiKeys);
routes.route("/asr", asr);
routes.route("/byok", byok);
routes.route("/payments/stripe", billing);
routes.route("/stt", stt);
routes.route("/voice", voice);
routes.route("/currents", currents);
routes.route("/memory/zkr-sync", memorySync);
routes.route("/", memoryWrite);
routes.route("/", conversations);

const text = (value: unknown, limit: number): string | null =>
  typeof value === "string" && value.trim().length > 0 && value.length <= limit
    ? value.trim()
    : null;

const json = async (
  request: Request,
): Promise<Record<string, unknown> | null> => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const parseJson = <T>(value: unknown, fallback: T): T => {
  if (typeof value !== "string") return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
};

const settingsDiff = (from: UserSettings, to: UserSettings) => ({
  ...(from.approvalMode === to.approvalMode
    ? {}
    : { approvalMode: { from: from.approvalMode, to: to.approvalMode } }),
  ...(from.proactiveRecommendations === to.proactiveRecommendations
    ? {}
    : {
        proactiveRecommendations: {
          from: from.proactiveRecommendations,
          to: to.proactiveRecommendations,
        },
      }),
});

const sourceKinds = new Set([
  "conversation",
  "screen",
  "audio",
  "document",
  "integration",
  "user_correction",
]);

const retrieveMemory = async (context: Context<AppEnv>) => {
  const body =
    context.req.method === "POST" ? await json(context.req.raw) : null;
  const query = text(body?.query ?? context.req.query("q"), 500);
  const limit = Number(body?.limit ?? context.req.query("limit") ?? 12);
  if (!query || !Number.isSafeInteger(limit) || limit < 1 || limit > 50)
    return context.json({ error: "Invalid retrieval" }, 400);
  return context.json(
    await retrieveCitedMemory(
      context.env.DB,
      context.get("auth").uid,
      query,
      limit,
    ),
  );
};

routes.get("/memory/retrieve", retrieveMemory);
routes.post("/memory/retrieve", retrieveMemory);

// The authoritative memory log, cursored. Any client can materialize a local
// mirror from this without a Rust hub, which is what makes the web target
// possible; `replica_id` is optional and only reports how far that replica's
// mirror has caught up.
routes.get("/memory/log", async (context) => {
  const after = Number(context.req.query("after") ?? 0);
  const limit = Number(context.req.query("limit") ?? 200);
  const replicaId = text(context.req.query("replica_id"), 200);
  if (
    !Number.isSafeInteger(after) ||
    after < 0 ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > 500
  )
    return context.json({ error: "Invalid memory log cursor" }, 400);
  const uid = context.get("auth").uid;
  const page = await readMemoryLog(context.env.DB, uid, after, limit);
  if (replicaId)
    await recordMirrorCursor(context.env.DB, uid, replicaId, after);
  return context.json(page);
});

routes.get("/memory/semantic-search", async (context) => {
  const query = text(context.req.query("q"), 500);
  const limit = Number(context.req.query("limit") ?? 8);
  if (!query || !Number.isSafeInteger(limit) || limit < 1 || limit > 20)
    return context.json({ error: "Invalid retrieval" }, 400);
  const items = await searchMemoryClaims(
    context.env,
    context.get("auth").uid,
    query,
    limit,
  );
  return context.json({ query, items });
});

routes.get("/me", async (context) => {
  const auth = context.get("auth");
  const bindings = await context.env.DB.prepare(
    "SELECT channel, channel_user_id FROM channel_bindings WHERE uid = ?1 AND revoked_at IS NULL",
  )
    .bind(auth.uid)
    .all();
  return context.json({ ...auth, channels: bindings.results ?? [] });
});

routes.get("/setup-health", (context) => {
  const configured = (value: string | undefined) => Boolean(value?.trim());
  return context.json({
    worker: true,
    firebase: configured(context.env.FIREBASE_PROJECT_ID),
    memory: true,
    channels: {
      telegram:
        configured(context.env.TELEGRAM_WEBHOOK_SECRET) &&
        configured(context.env.TELEGRAM_BOT_TOKEN),
      // The iMessage channel, whichever provider is behind it. Sendblue wins
      // when it is configured; Blooio is the retained fallback.
      blooio:
        (configured(context.env.SENDBLUE_API_KEY_ID) &&
          configured(context.env.SENDBLUE_API_KEY_SECRET) &&
          configured(context.env.SENDBLUE_NUMBER) &&
          configured(context.env.SENDBLUE_WEBHOOK_SIGNING_SECRET) &&
          configured(context.env.SENDBLUE_WEBHOOK_PATH_TOKEN)) ||
        (configured(context.env.BLOOIO_WEBHOOK_SIGNING_SECRET) &&
          configured(context.env.BLOOIO_API_KEY)),
    },
    billing:
      configured(context.env.STRIPE_SECRET_KEY) &&
      configured(context.env.STRIPE_PRO_PRICE_ID) &&
      configured(context.env.STRIPE_WEBHOOK_SECRET) &&
      configured(context.env.APP_URL),
    models: {
      managedChat: configured(context.env.MIMO_API_KEY),
      // Legacy Deepgram interactive STT path (`stt.ts`).
      managedStt: configured(context.env.DEEPGRAM_API_KEY),
      // Gemini Live realtime duplex voice (`voice.ts`) — the primary live
      // voice path; reports unconfigured independently of the legacy
      // Deepgram flag above so a missing Gemini key isn't masked by it.
      managedLiveVoice:
        configured(context.env.GEMINI_API_KEY) &&
        configured(context.env.GEMINI_LIVE_MODEL),
      // MiMo batch ASR for long-form/meeting transcription (`asr.ts`),
      // shares MIMO_API_KEY with managed chat.
      managedAsr:
        configured(context.env.MIMO_API_KEY) &&
        configured(context.env.MIMO_CHAT_COMPLETIONS_URL),
    },
    desktopAuth:
      configured(context.env.FIREBASE_SERVICE_ACCOUNT_EMAIL) &&
      configured(context.env.FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY) &&
      configured(context.env.APP_URL),
  });
});

routes.get("/memories", async (context) => {
  const memories = await listProfileMemories(
    context.env.DB,
    context.get("auth").uid,
  );
  return context.json({ memories });
});

routes.get("/memory/daily-reviews", async (context) => {
  const reviews = await listDailyReviews(
    context.env.DB,
    context.get("auth").uid,
  );
  return context.json({ reviews });
});

routes.post("/memory/daily-reviews", async (context) => {
  const body = await json(context.req.raw);
  const localDate = text(body?.localDate, 10);
  const inputRevision = text(body?.inputRevision, 200);
  const reviewBody = text(body?.body, 50_000);
  const citationIds = body?.citationIds;
  if (
    !localDate ||
    !/^\d{4}-\d{2}-\d{2}$/.test(localDate) ||
    !inputRevision ||
    !reviewBody ||
    !Array.isArray(citationIds) ||
    citationIds.length === 0 ||
    citationIds.some((value) => !text(value, 100))
  )
    return context.json({ error: "Invalid daily review" }, 400);
  const uid = context.get("auth").uid;
  const existing = await context.env.DB.prepare(
    "SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3",
  )
    .bind(uid, localDate, inputRevision)
    .first();
  const id = existing ? String(existing.id) : crypto.randomUUID();
  const now = Date.now();
  const statements = [
    context.env.DB.prepare(
      `INSERT INTO memory_daily_reviews (id, uid, local_date, input_revision, body, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
       ON CONFLICT(uid, local_date, input_revision) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at, retracted_at = NULL`,
    ).bind(id, uid, localDate, inputRevision, reviewBody, now),
    context.env.DB.prepare(
      `DELETE FROM memory_daily_review_citations
       WHERE uid = ?1 AND review_id = (
         SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3
       )`,
    ).bind(uid, localDate, inputRevision),
    ...citationIds.map((evidenceId) =>
      context.env.DB.prepare(
        `INSERT OR IGNORE INTO memory_daily_review_citations (uid, review_id, evidence_id)
           SELECT ?1, r.id, e.id FROM memory_daily_reviews r, memory_evidence e
           WHERE r.uid = ?1 AND r.local_date = ?2 AND r.input_revision = ?3 AND e.id = ?4 AND e.uid = ?1`,
      ).bind(uid, localDate, inputRevision, evidenceId),
    ),
  ];
  await context.env.DB.batch(statements);
  return context.json({ id }, 201);
});

routes.get("/settings", async (context) => {
  const row = await context.env.DB.prepare(
    "SELECT value, revision FROM user_settings WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  const settings = parseJson<UserSettings>(row?.value, {
    approvalMode: "once",
    proactiveRecommendations: true,
  });
  return context.json({
    settings,
    revision: Number(row?.revision ?? 0),
    effectivePolicy: settings,
  });
});

routes.put("/settings", async (context) => {
  const body = await json(context.req.raw);
  const patch =
    body?.patch !== null &&
    typeof body?.patch === "object" &&
    !Array.isArray(body.patch)
      ? (body.patch as Record<string, unknown>)
      : null;
  const expectedRevision = Number(body?.expectedRevision);
  const duration = body?.duration as SettingsDuration;
  const patchKeys = patch ? Object.keys(patch) : [];
  const validApproval =
    patch?.approvalMode === undefined ||
    patch.approvalMode === "ask" ||
    patch.approvalMode === "once" ||
    patch.approvalMode === "auto";
  const validProactive =
    patch?.proactiveRecommendations === undefined ||
    typeof patch.proactiveRecommendations === "boolean";
  if (
    !patch ||
    patchKeys.length === 0 ||
    patchKeys.some(
      (key) => key !== "approvalMode" && key !== "proactiveRecommendations",
    ) ||
    !Number.isSafeInteger(expectedRevision) ||
    expectedRevision < 0 ||
    !["task", "session", "persistent"].includes(duration) ||
    !validApproval ||
    !validProactive
  )
    return context.json({ error: "Invalid settings change" }, 400);
  const uid = context.get("auth").uid;
  const row = await context.env.DB.prepare(
    "SELECT value, revision FROM user_settings WHERE uid = ?1",
  )
    .bind(uid)
    .first();
  const revision = Number(row?.revision ?? 0);
  if (revision !== expectedRevision)
    return context.json({ error: "Settings revision conflict", revision }, 409);
  const previous = parseJson<UserSettings>(row?.value, {
    approvalMode: "once",
    proactiveRecommendations: true,
  });
  const settings: UserSettings = { ...previous, ...patch };
  const diff = settingsDiff(previous, settings);
  const authority = { ask: 0, once: 1, auto: 2 } as const;
  const expandsAuthority =
    patch.approvalMode !== undefined &&
    authority[patch.approvalMode as UserSettings["approvalMode"]] >
      authority[previous.approvalMode];
  const now = Date.now();
  const scopeId =
    duration === "persistent"
      ? null
      : text(duration === "task" ? body?.taskId : body?.sessionId, 200);
  const expiresAt =
    body?.expiresAt === undefined || body.expiresAt === null
      ? null
      : Number(body.expiresAt);
  if (duration !== "persistent" && !scopeId)
    return context.json({ error: `Missing ${duration} id` }, 400);
  if (
    expiresAt !== null &&
    (!Number.isSafeInteger(expiresAt) || expiresAt <= now)
  )
    return context.json({ error: "Invalid settings expiry" }, 400);
  if (expandsAuthority) {
    const receiptId = text(body?.confirmationReceiptId, 100);
    if (!receiptId)
      return context.json({ error: "Owner confirmation required" }, 403);
    const receipt = await context.env.DB.prepare(
      `UPDATE owner_confirmation_receipts SET consumed_at = ?1
       WHERE id = ?2 AND uid = ?3 AND purpose = 'settings.approvalMode' AND value = ?4
         AND created_at < ?1 AND expires_at > ?1 AND consumed_at IS NULL`,
    )
      .bind(now, receiptId, uid, patch.approvalMode)
      .run();
    if (receipt.meta.changes !== 1)
      return context.json({ error: "Owner confirmation invalid" }, 403);
  }
  if (duration !== "persistent") {
    const id = crypto.randomUUID();
    await context.env.DB.prepare(
      `INSERT INTO setting_scopes (id, uid, duration, scope_id, base_revision, patch, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(uid, duration, scope_id) DO UPDATE SET
         base_revision = excluded.base_revision, patch = excluded.patch,
         created_at = excluded.created_at, expires_at = excluded.expires_at`,
    )
      .bind(
        id,
        uid,
        duration,
        scopeId,
        revision,
        JSON.stringify(patch),
        now,
        expiresAt,
      )
      .run();
    return context.json({
      settings,
      revision,
      duration,
      scopeId,
      diff,
      effectivePolicy: settings,
      restartRequired: false,
    });
  }
  const updated = row
    ? await context.env.DB.prepare(
        "UPDATE user_settings SET value = ?1, revision = revision + 1, updated_at = ?2 WHERE uid = ?3 AND revision = ?4",
      )
        .bind(JSON.stringify(settings), now, uid, expectedRevision)
        .run()
    : await context.env.DB.prepare(
        "INSERT OR IGNORE INTO user_settings (uid, value, revision, updated_at) VALUES (?1, ?2, 1, ?3)",
      )
        .bind(uid, JSON.stringify(settings), now)
        .run();
  if (updated.meta.changes !== 1)
    return context.json({ error: "Settings revision conflict" }, 409);
  return context.json({
    settings,
    revision: revision + 1,
    duration,
    diff,
    effectivePolicy: settings,
    restartRequired: false,
  });
});

routes.get("/profile/onboarding", async (context) => {
  const row = await context.env.DB.prepare(
    "SELECT onboarding_completed_at FROM users WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  const completedAt =
    row?.onboarding_completed_at === null ||
    row?.onboarding_completed_at === undefined
      ? null
      : Number(row.onboarding_completed_at);
  return context.json({ complete: completedAt !== null, completedAt });
});

routes.put("/profile/onboarding", async (context) => {
  const body = await json(context.req.raw);
  if (body?.complete !== true)
    return context.json({ error: "Invalid onboarding state" }, 400);
  const auth = context.get("auth");
  const now = Date.now();
  await context.env.DB.prepare(
    `INSERT INTO users (uid, email, created_at, updated_at, onboarding_completed_at)
     VALUES (?1, ?2, ?3, ?3, ?3)
     ON CONFLICT(uid) DO UPDATE SET
       onboarding_completed_at = COALESCE(users.onboarding_completed_at, excluded.onboarding_completed_at),
       updated_at = excluded.updated_at`,
  )
    .bind(auth.uid, auth.email ?? null, now)
    .run();
  const row = await context.env.DB.prepare(
    "SELECT onboarding_completed_at FROM users WHERE uid = ?1",
  )
    .bind(auth.uid)
    .first();
  return context.json({
    complete: true,
    completedAt: Number(row?.onboarding_completed_at ?? now),
  });
});

const uidScopedTables = [
  "pending_embeddings",
  "memory_daily_review_citations",
  "memory_daily_reviews",
  "memory_claim_evidence",
  "memory_profile_entries",
  "memory_claims_fts",
  "memory_claims",
  "memory_evidence",
  "memory_source_revisions",
  "memory_sources",
  "zkr_sync_events",
  "zkr_sync_commits",
  "conversation_replay_cursors",
  "conversation_messages",
  "conversations",
  "channel_inbox_completions",
  "channel_inbox",
  "channel_deliveries",
  "channel_bindings",
  "channel_link_tokens",
  "current_feedback",
  "current_executions",
  "currents",
  "legacy_currents_uncited",
  "managed_ai_requests",
  "managed_stt_sessions",
  "managed_speech_requests",
  "oauth_connections",
  "owner_confirmation_receipts",
  "setting_scopes",
  "user_settings",
  "entitlements",
  "desktop_auth_sessions",
  "audit_events",
  "api_keys",
  "users",
];

routes.delete("/account", async (context) => {
  const uid = context.get("auth").uid;
  const claims = await context.env.DB.prepare(
    "SELECT id FROM memory_claims WHERE uid = ?1",
  )
    .bind(uid)
    .all<{ id: string }>();
  const claimIds = (claims.results ?? []).map((row) => String(row.id));
  await context.env.DB.batch(
    uidScopedTables.map((table) =>
      context.env.DB.prepare(`DELETE FROM ${table} WHERE uid = ?1`).bind(uid),
    ),
  );
  deferVectorWork(
    () => deleteClaimVectors(context.env, claimIds),
    (promise) => context.executionCtx.waitUntil(promise),
  );
  return context.body(null, 204);
});

routes.get("/entitlement", async (context) => {
  const pro = await hasActivePro(context.env, context.get("auth").uid);
  return context.json({ plan: pro ? "pro" : "byok", active: pro });
});

// Reverse linking: the user texts the bot, the bot answers with a short code,
// and the app redeems it here. The chat identity comes from the stored code
// row, never from the request body.
routes.post("/channels/link", async (context) => {
  const uid = context.get("auth").uid;
  const body = await json(context.req.raw);
  const code = normalizeLinkCode(body?.code);
  if (!code) return context.json({ error: "Invalid code" }, 400);
  const limit = await consumeRateLimit(
    context.env,
    `channel-link-redeem:${uid}`,
    10,
    10 * 60_000,
  );
  if (!limit.allowed)
    return context.json({ error: "Too many attempts" }, 429, {
      "retry-after": String(limit.retryAfter),
    });
  const now = Date.now();
  const pending = await resolveLinkCode(context.env.DB, code, now);
  if (!pending) return context.json({ error: "Unknown or expired code" }, 404);
  const existing = await context.env.DB.prepare(
    "SELECT uid FROM channel_bindings WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL",
  )
    .bind(pending.channel, pending.channelUserId)
    .first<{ uid: string }>();
  // A chat that signed itself up holds a placeholder account. Redeeming its
  // code from a real sign-in claims that placeholder — it is retired in the
  // same breath, so the identity can never be handed out twice.
  const placeholder = await liveChannelAccount(
    context.env.DB,
    pending.channel,
    pending.channelUserId,
  );
  if (
    existing &&
    String(existing.uid) !== uid &&
    String(existing.uid) !== placeholder?.uid
  )
    return context.json({ error: "Chat is linked to another account" }, 409);
  // Consuming the code is the first write and it decides the winner on its
  // own: a concurrent redemption that finds the code already spent stops here
  // with nothing claimed and no binding rewritten. Everything that follows is
  // one batch, so a link either lands whole or not at all.
  const consumed = await context.env.DB.prepare(
    "UPDATE channel_link_codes SET consumed_at = ?1 WHERE code_hash = ?2 AND consumed_at IS NULL AND expires_at > ?1",
  )
    .bind(now, pending.codeHash)
    .run();
  if (consumed.meta.changes !== 1)
    return context.json({ error: "Unknown or expired code" }, 404);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `UPDATE channel_accounts SET claimed_at = ?1, claimed_by_uid = ?2
       WHERE uid = ?3 AND claimed_at IS NULL AND retired_at IS NULL`,
    ).bind(now, uid, placeholder?.uid ?? null),
    context.env.DB.prepare(
      `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)
       VALUES (?1, ?2, ?3, ?4, NULL, ?5)
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET
         uid = excluded.uid, verified_at = excluded.verified_at,
         revoked_at = NULL, channel_chat_id = excluded.channel_chat_id`,
    ).bind(
      pending.channel,
      pending.channelUserId,
      uid,
      now,
      pending.channelChatId,
    ),
    context.env.DB.prepare(
      `INSERT INTO audit_events
         (id, uid, actor_type, action, target_type, target_id, details, created_at)
       VALUES (?1, ?2, 'channel', 'channel.linked', 'channel', ?3, ?4, ?5)`,
    ).bind(
      crypto.randomUUID(),
      uid,
      pending.channel,
      JSON.stringify({
        channelUserId: pending.channelUserId,
        channelChatId: pending.channelChatId,
      }),
      now,
    ),
  ]);
  await sendChannelText(
    context.env,
    pending.channel,
    pending.channelChatId,
    linkConfirmationText(context.get("auth").email),
  );
  return context.json({ channel: pending.channel, linked: true }, 201);
});

routes.post("/channels/:channel/link", async (context) => {
  const channel = context.req.param("channel") as Channel;
  if (channel !== "telegram" && channel !== "blooio")
    return context.json({ error: "Unknown channel" }, 404);
  const token = Array.from(crypto.getRandomValues(new Uint8Array(24)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  const tokenHash = Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const now = Date.now();
  await context.env.DB.prepare(
    "INSERT INTO channel_link_tokens (token_hash, uid, channel, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
  )
    .bind(tokenHash, context.get("auth").uid, channel, now + 10 * 60_000, now)
    .run();
  return context.json({ channel, token, expiresAt: now + 10 * 60_000 }, 201);
});

routes.post("/channels/:channel/messages", async (context) => {
  const channel = context.req.param("channel") as Channel;
  if (channel !== "telegram" && channel !== "blooio")
    return context.json({ error: "Unknown channel" }, 404);
  const body = await json(context.req.raw);
  const message = text(body?.text, 4096);
  const idempotencyKey = text(body?.idempotencyKey, 128);
  if (
    !message ||
    !idempotencyKey ||
    idempotencyKey.length < 8 ||
    !/^[A-Za-z0-9._:-]+$/.test(idempotencyKey)
  )
    return context.json({ error: "Invalid delivery" }, 400);
  const uid = context.get("auth").uid;
  const binding = await context.env.DB.prepare(
    `SELECT COALESCE(channel_chat_id, channel_user_id) AS channel_chat_id
     FROM channel_bindings
     WHERE uid = ?1 AND channel = ?2 AND revoked_at IS NULL
     ORDER BY verified_at DESC LIMIT 1`,
  )
    .bind(uid, channel)
    .first<{ channel_chat_id: string }>();
  if (!binding?.channel_chat_id)
    return context.json({ error: "Channel is not linked" }, 409);
  const id = crypto.randomUUID();
  const now = Date.now();
  await context.env.DB.prepare(
    `INSERT OR IGNORE INTO channel_deliveries
       (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7)`,
  )
    .bind(
      id,
      uid,
      channel,
      idempotencyKey,
      binding.channel_chat_id,
      message,
      now,
    )
    .run();
  const delivery = await context.env.DB.prepare(
    `SELECT id, channel_chat_id, text, state, attempts, provider_message_id, last_error
     FROM channel_deliveries WHERE uid = ?1 AND channel = ?2 AND idempotency_key = ?3`,
  )
    .bind(uid, channel, idempotencyKey)
    .first<{
      id: string;
      channel_chat_id: string;
      text: string;
      state: string;
      attempts: number;
      provider_message_id: string | null;
      last_error: string | null;
    }>();
  if (
    !delivery ||
    delivery.channel_chat_id !== binding.channel_chat_id ||
    delivery.text !== message
  )
    return context.json({ error: "Idempotency key conflict" }, 409);
  const conversationMessage = await appendConversationMessage(context.env.DB, {
    uid,
    clientMessageId: `delivery:${channel}:${idempotencyKey}`,
    role: "assistant",
    source: channel,
    text: message,
    deliveryId: delivery.id,
  });
  if (!conversationMessage)
    return context.json({ error: "Conversation message conflict" }, 409);
  try {
    await dispatchChannelMessage(context.env, delivery.id, uid, channel);
  } catch {
    return context.json({ error: "Delivery coordination unavailable" }, 503);
  }
  const current = await context.env.DB.prepare(
    "SELECT id, state, attempts, provider_message_id, last_error FROM channel_deliveries WHERE id = ?1 AND uid = ?2",
  )
    .bind(delivery.id, uid)
    .first();
  const status =
    current?.state === "sent"
      ? 200
      : current?.state === "failed" &&
          current.last_error === "Provider credentials unavailable"
        ? 503
        : current?.state === "failed"
          ? 502
          : 202;
  return context.json({ delivery: current }, status);
});

routes.delete("/channels/:channel/link", async (context) => {
  const channel = context.req.param("channel") as Channel;
  if (channel !== "telegram" && channel !== "blooio")
    return context.json({ error: "Unknown channel" }, 404);
  const uid = context.get("auth").uid;
  try {
    await dispatchChannelUnlink(context.env, uid, channel);
  } catch {
    return context.json({ error: "Delivery coordination unavailable" }, 503);
  }
  return context.body(null, 204);
});

export default routes;
