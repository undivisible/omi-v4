// BYOK price negotiation. The user argues their case in a real conversation
// with the model; the model may only *suggest* which of the server-defined
// concessions applies. The price itself is computed here, from
// ./byok-pricing, and written to D1 as an auditable record together with the
// conversation that produced it. No price value is ever read from a request
// body or from model output.

import { Hono } from "hono";
import {
  aiGatewayRoute,
  boundedJson,
  validatePinnedEndpoint,
  xiaomiCompletionEndpoint,
} from "./assistant";
import {
  type Concession,
  type PriceBand,
  concessionFor,
  formatPrice,
  normalizeGrants,
  priceBand,
  priceForGrants,
} from "./byok-pricing";
import { modelForTier } from "./model-tiers";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv, Bindings } from "./types";

const byok = new Hono<AppEnv>();

const maximumBodyBytes = 8 * 1024;
const maximumMessageCharacters = 600;
const maximumTranscriptEntries = 64;
const upstreamTimeoutMs = 20_000;
const sessionStartLimit = { limit: 3, windowMs: 24 * 3600_000 };
const messageLimit = { limit: 24, windowMs: 3600_000 };

export type TranscriptEntry = { role: "user" | "omi"; content: string };

type SessionRow = {
  id: string;
  uid: string;
  status: string;
  turns: number;
  grants: string;
  transcript: string;
};

export type AgreedPrice = {
  priceCents: number;
  outcome: "negotiated" | "standard";
  agreedAt: number;
};

const parseJsonArray = (value: unknown): unknown[] => {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
};

const parseTranscript = (value: unknown): TranscriptEntry[] =>
  parseJsonArray(value).flatMap((entry) => {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry))
      return [];
    const record = entry as Record<string, unknown>;
    return (record.role === "user" || record.role === "omi") &&
      typeof record.content === "string"
      ? [{ role: record.role, content: record.content }]
      : [];
  });

// The recorded price for a user, or null when they have never settled one.
// Read straight from the audit record: the agreement row is the authority,
// not anything the client remembers.
export const agreedByokPrice = async (
  env: Bindings,
  uid: string,
): Promise<AgreedPrice | null> => {
  const row = await env.DB.prepare(
    "SELECT price_cents, outcome, agreed_at FROM byok_price_agreements WHERE uid = ?1",
  )
    .bind(uid)
    .first<{ price_cents: number; outcome: string; agreed_at: number }>();
  if (!row) return null;
  const band = priceBand(env);
  return {
    // Clamp on read as well as on write: a row written under an older, wider
    // band can never undercut the band in force today.
    priceCents: Math.min(
      band.standardCents,
      Math.max(band.floorCents, Number(row.price_cents)),
    ),
    outcome: row.outcome === "negotiated" ? "negotiated" : "standard",
    agreedAt: Number(row.agreed_at),
  };
};

const planPayload = (
  band: PriceBand,
  agreement: AgreedPrice | null,
  now: number,
) => ({
  standardPriceCents: band.standardCents,
  floorPriceCents: band.floorCents,
  priceCents: agreement?.priceCents ?? band.standardCents,
  outcome: agreement?.outcome ?? null,
  agreedAt: agreement?.agreedAt ?? null,
  negotiable: agreement === null || now >= agreement.agreedAt + band.cooldownMs,
  renegotiableAt:
    agreement === null ? null : agreement.agreedAt + band.cooldownMs,
});

const upsertAgreement = async (
  env: Bindings,
  uid: string,
  values: {
    sessionId: string | null;
    outcome: "negotiated" | "standard";
    priceCents: number;
    band: PriceBand;
    grants: readonly string[];
    transcript: TranscriptEntry[];
  },
  now: number,
): Promise<void> => {
  await env.DB.prepare(
    `INSERT INTO byok_price_agreements
       (uid, session_id, outcome, price_cents, standard_price_cents, floor_price_cents,
        grants, transcript, agreed_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9)
     ON CONFLICT(uid) DO UPDATE SET
       session_id = excluded.session_id,
       outcome = excluded.outcome,
       price_cents = excluded.price_cents,
       standard_price_cents = excluded.standard_price_cents,
       floor_price_cents = excluded.floor_price_cents,
       grants = excluded.grants,
       transcript = excluded.transcript,
       agreed_at = excluded.agreed_at,
       updated_at = excluded.updated_at`,
  )
    .bind(
      uid,
      values.sessionId,
      values.outcome,
      values.priceCents,
      values.band.standardCents,
      values.band.floorCents,
      JSON.stringify(values.grants),
      JSON.stringify(values.transcript),
      now,
    )
    .run();
};

const systemPrompt = (band: PriceBand, granted: readonly string[]): string => {
  const available = band.concessions.filter(
    (concession) => !granted.includes(concession.code),
  );
  return [
    "You are Omi, negotiating your own subscription price with a user who has",
    "just connected their own AI provider key. Be warm, brief (two sentences",
    "at most), and honest. Never invent urgency, deadlines or scarcity.",
    "",
    "You do not set prices. You may only suggest at most one concession per",
    "reply, chosen from this list, when the user has genuinely made that case:",
    available.length === 0
      ? "(none left; you have nothing further to offer)"
      : available
          .map((concession) => `- ${concession.code}: ${concession.label}`)
          .join("\n"),
    "",
    "Never state a number, a price or a percentage; the app shows the price.",
    'Reply with JSON only: {"reply": string, "concession": string or null}.',
  ].join("\n");
};

type Suggestion = { reply: string; concession: Concession | null };

const parseSuggestion = (
  band: PriceBand,
  granted: readonly string[],
  raw: string,
): Suggestion | null => {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.slice(start, end + 1)) as unknown;
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
    return null;
  const value = parsed as Record<string, unknown>;
  if (typeof value.reply !== "string" || value.reply.trim().length === 0)
    return null;
  const concession = concessionFor(band, value.concession);
  return {
    reply: value.reply.trim().slice(0, maximumMessageCharacters),
    // A concession already granted in this session cannot be granted twice,
    // whatever the model repeats.
    concession:
      concession && !granted.includes(concession.code) ? concession : null,
  };
};

// The model is told not to quote numbers, but "told not to" is not a control.
// Any currency or percentage figure that survives is replaced with the price
// the server computed, so the text can never disagree with the record.
export const sanitizeReply = (reply: string, priceCents: number): string =>
  reply
    .replace(/\$\s?\d+(?:[.,]\d+)?/g, formatPrice(priceCents))
    .replace(/\d+(?:\.\d+)?\s?%/g, "a bit");

const callModel = async (
  env: Bindings,
  band: PriceBand,
  granted: readonly string[],
  transcript: readonly TranscriptEntry[],
): Promise<string | null> => {
  const endpoint = env.MIMO_CHAT_COMPLETIONS_URL;
  const secret = env.MIMO_API_KEY;
  if (!endpoint || !secret) return null;
  const endpointUrl = validatePinnedEndpoint(
    endpoint,
    xiaomiCompletionEndpoint,
    "token-plan-sgp.xiaomimimo.com",
  );
  if (!endpointUrl) return null;
  const gateway = aiGatewayRoute(env);
  try {
    const upstream = await fetch(gateway?.url ?? endpointUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${secret}`,
        "content-type": "application/json",
        ...gateway?.headers,
      },
      signal: AbortSignal.timeout(upstreamTimeoutMs),
      body: JSON.stringify({
        model: modelForTier(env, "balanced"),
        stream: false,
        max_tokens: 400,
        temperature: 0.7,
        messages: [
          { role: "system", content: systemPrompt(band, granted) },
          ...transcript.map((entry) => ({
            role: entry.role === "user" ? "user" : "assistant",
            content: entry.content,
          })),
        ],
      }),
    });
    if (!upstream.ok) return null;
    const completion = (await upstream.json()) as {
      choices?: Array<{ message?: { content?: unknown } }>;
    };
    const content = completion.choices?.[0]?.message?.content;
    return typeof content === "string" ? content : null;
  } catch {
    return null;
  }
};

const loadSession = async (
  env: Bindings,
  uid: string,
  id: string,
): Promise<SessionRow | null> => {
  const row = await env.DB.prepare(
    "SELECT id, uid, status, turns, grants, transcript FROM byok_negotiation_sessions WHERE id = ?1 AND uid = ?2",
  )
    .bind(id, uid)
    .first<SessionRow>();
  return row ?? null;
};

byok.get("/plan", async (context) => {
  const band = priceBand(context.env);
  const agreement = await agreedByokPrice(context.env, context.get("auth").uid);
  return context.json(planPayload(band, agreement, Date.now()));
});

// Taking the standard price is always available and is recorded like any
// other outcome, so skipping is a first-class path rather than a dead end.
byok.post("/plan/standard", async (context) => {
  const band = priceBand(context.env);
  const uid = context.get("auth").uid;
  const now = Date.now();
  await upsertAgreement(
    context.env,
    uid,
    {
      sessionId: null,
      outcome: "standard",
      priceCents: band.standardCents,
      band,
      grants: [],
      transcript: [],
    },
    now,
  );
  return context.json(
    planPayload(band, await agreedByokPrice(context.env, uid), now),
    201,
  );
});

byok.post("/negotiation", async (context) => {
  const band = priceBand(context.env);
  const uid = context.get("auth").uid;
  const now = Date.now();
  const agreement = await agreedByokPrice(context.env, uid);
  // Renegotiation is bounded twice: by the recorded agreement's cooldown and
  // by a rate limiter, so repeat attempts cannot be farmed for a lower price.
  if (agreement && now < agreement.agreedAt + band.cooldownMs)
    return context.json(
      { error: "Price already agreed", ...planPayload(band, agreement, now) },
      409,
    );
  const limit = await consumeRateLimit(
    context.env,
    `byok-negotiation-start:${uid}`,
    sessionStartLimit.limit,
    sessionStartLimit.windowMs,
  );
  if (!limit.allowed)
    return context.json({ error: "Too many negotiations" }, 429, {
      "retry-after": String(limit.retryAfter),
    });
  if (!context.env.MIMO_API_KEY || !context.env.MIMO_CHAT_COMPLETIONS_URL)
    return context.json({ error: "Negotiation unavailable" }, 503);
  const id = crypto.randomUUID();
  const opening: TranscriptEntry = {
    role: "omi",
    content:
      `Standard with your own key is ${formatPrice(band.standardCents)} a month. ` +
      "If that is not right for you, tell me why and I will see what I can do.",
  };
  await context.env.DB.prepare(
    `INSERT INTO byok_negotiation_sessions
       (id, uid, status, turns, standard_price_cents, floor_price_cents, price_cents,
        grants, transcript, created_at, updated_at)
     VALUES (?1, ?2, 'open', 0, ?3, ?4, ?3, '[]', ?5, ?6, ?6)`,
  )
    .bind(
      id,
      uid,
      band.standardCents,
      band.floorCents,
      JSON.stringify([opening]),
      now,
    )
    .run();
  return context.json(
    {
      sessionId: id,
      priceCents: band.standardCents,
      standardPriceCents: band.standardCents,
      turnsRemaining: band.maxTurns,
      transcript: [opening],
    },
    201,
  );
});

byok.post("/negotiation/:id/message", async (context) => {
  const band = priceBand(context.env);
  const uid = context.get("auth").uid;
  const session = await loadSession(context.env, uid, context.req.param("id"));
  if (!session) return context.json({ error: "Unknown negotiation" }, 404);
  if (session.status !== "open")
    return context.json({ error: "Negotiation closed" }, 409);
  const body = await boundedJson(context.req.raw, maximumBodyBytes);
  const message =
    typeof body?.message === "string" ? body.message.trim() : null;
  if (!message || message.length > maximumMessageCharacters)
    return context.json({ error: "Invalid request" }, 400);
  const limit = await consumeRateLimit(
    context.env,
    `byok-negotiation-message:${uid}`,
    messageLimit.limit,
    messageLimit.windowMs,
  );
  if (!limit.allowed)
    return context.json({ error: "Too many messages" }, 429, {
      "retry-after": String(limit.retryAfter),
    });
  if (session.turns >= band.maxTurns)
    return context.json({ error: "Negotiation closed" }, 409);
  const granted = normalizeGrants(band, parseJsonArray(session.grants));
  const transcript = parseTranscript(session.transcript).slice(
    -maximumTranscriptEntries,
  );
  transcript.push({ role: "user", content: message });
  const raw = await callModel(context.env, band, granted, transcript);
  const suggestion = raw === null ? null : parseSuggestion(band, granted, raw);
  if (!suggestion)
    return context.json({ error: "Negotiation unavailable" }, 502);
  const grants = suggestion.concession
    ? [...granted, suggestion.concession.code]
    : granted;
  const priceCents = priceForGrants(band, grants);
  const reply = sanitizeReply(suggestion.reply, priceCents);
  transcript.push({ role: "omi", content: reply });
  const turns = session.turns + 1;
  const now = Date.now();
  await context.env.DB.prepare(
    `UPDATE byok_negotiation_sessions
       SET turns = ?1, grants = ?2, transcript = ?3, price_cents = ?4, updated_at = ?5
     WHERE id = ?6 AND uid = ?7`,
  )
    .bind(
      turns,
      JSON.stringify(grants),
      JSON.stringify(transcript),
      priceCents,
      now,
      session.id,
      uid,
    )
    .run();
  return context.json({
    reply,
    priceCents,
    standardPriceCents: band.standardCents,
    turnsRemaining: Math.max(0, band.maxTurns - turns),
    conceded: suggestion.concession !== null,
  });
});

// Accepting recomputes the price from the stored grants rather than trusting
// anything in the request, so a replayed or edited accept settles at exactly
// the same figure the conversation earned.
byok.post("/negotiation/:id/accept", async (context) => {
  const band = priceBand(context.env);
  const uid = context.get("auth").uid;
  const session = await loadSession(context.env, uid, context.req.param("id"));
  if (!session) return context.json({ error: "Unknown negotiation" }, 404);
  const now = Date.now();
  if (session.status === "agreed")
    return context.json(
      planPayload(band, await agreedByokPrice(context.env, uid), now),
      200,
    );
  if (session.status !== "open")
    return context.json({ error: "Negotiation closed" }, 409);
  const grants = normalizeGrants(band, parseJsonArray(session.grants));
  const priceCents = priceForGrants(band, grants);
  await context.env.DB.prepare(
    "UPDATE byok_negotiation_sessions SET status = 'agreed', price_cents = ?1, updated_at = ?2 WHERE id = ?3 AND uid = ?4",
  )
    .bind(priceCents, now, session.id, uid)
    .run();
  await upsertAgreement(
    context.env,
    uid,
    {
      sessionId: session.id,
      outcome: priceCents < band.standardCents ? "negotiated" : "standard",
      priceCents,
      band,
      grants,
      transcript: parseTranscript(session.transcript),
    },
    now,
  );
  return context.json(
    planPayload(band, await agreedByokPrice(context.env, uid), now),
    201,
  );
});

export default byok;
