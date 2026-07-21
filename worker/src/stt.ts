import { Hono } from "hono";
import { admitSttSession } from "./stt-admission";
import type { AppEnv } from "./types";

const stt = new Hono<AppEnv>();
const deepgramGrantEndpoint = "https://api.deepgram.com/v1/auth/grant";
const deepgramListenEndpoint = "wss://api.deepgram.com/v1/listen";
const tokenTtlSeconds = 30;
const idempotencyPattern = /^[A-Za-z0-9._:-]{8,128}$/;
const identifierPattern = /^[A-Za-z0-9._:-]{1,128}$/;
const languagePattern = /^(multi|[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$/;

stt.use("*", async (context, next) => {
  context.header("cache-control", "no-store");
  context.header("pragma", "no-cache");
  await next();
});

const positiveInteger = (value: unknown): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

const boundedJson = async (request: Request) => {
  const length = Number(request.headers.get("content-length") ?? 0);
  if (!Number.isSafeInteger(length) || length < 0 || length > 4096) return null;
  try {
    const text = await request.text();
    if (new TextEncoder().encode(text).byteLength > 4096) return null;
    const value = JSON.parse(text);
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const parseRequest = (body: Record<string, unknown>) => {
  const allowed = new Set([
    "idempotencyKey",
    "model",
    "language",
    "encoding",
    "sampleRate",
    "channels",
    "diarize",
    "interimResults",
    "deviceId",
    "sourceId",
  ]);
  if (Object.keys(body).some((key) => !allowed.has(key))) return null;
  const idempotencyKey = body.idempotencyKey;
  const model = body.model;
  const language = body.language;
  const encoding = body.encoding;
  const sampleRate = body.sampleRate;
  const channels = body.channels;
  const deviceId = body.deviceId;
  const sourceId = body.sourceId;
  if (
    typeof idempotencyKey !== "string" ||
    !idempotencyPattern.test(idempotencyKey) ||
    model !== "nova-3" ||
    typeof language !== "string" ||
    !languagePattern.test(language) ||
    encoding !== "linear16" ||
    (sampleRate !== 16_000 && sampleRate !== 48_000) ||
    (channels !== 1 && channels !== 2) ||
    typeof body.diarize !== "boolean" ||
    typeof body.interimResults !== "boolean" ||
    typeof deviceId !== "string" ||
    !identifierPattern.test(deviceId) ||
    typeof sourceId !== "string" ||
    !identifierPattern.test(sourceId)
  )
    return null;
  return {
    idempotencyKey,
    model,
    language,
    encoding,
    sampleRate,
    channels,
    diarize: body.diarize,
    interimResults: body.interimResults,
    deviceId,
    sourceId,
  };
};

stt.post("/sessions", async (context) => {
  const secret = context.env.DEEPGRAM_API_KEY;
  const maxSessionSeconds = positiveInteger(
    context.env.STT_MAX_SESSION_SECONDS,
  );
  const costPerMinute = positiveInteger(
    context.env.STT_COST_MICROUSD_PER_MINUTE,
  );
  if (
    !secret ||
    maxSessionSeconds === null ||
    maxSessionSeconds > 3600 ||
    costPerMinute === null
  )
    return context.json({ error: "Managed STT unavailable" }, 503);
  const body = await boundedJson(context.req.raw);
  const parsed = body ? parseRequest(body) : null;
  if (!parsed) return context.json({ error: "Invalid request" }, 400);
  const auth = context.get("auth");
  const entitlement = await context.env.DB.prepare(
    "SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1",
  )
    .bind(auth.uid)
    .first();
  const now = Date.now();
  if (
    entitlement?.plan !== "pro" ||
    entitlement.status !== "active" ||
    (entitlement.valid_until !== null && Number(entitlement.valid_until) <= now)
  )
    return context.json({ error: "Managed Pro required" }, 403);
  const existing = await context.env.DB.prepare(
    `SELECT id, status FROM managed_stt_sessions
     WHERE uid = ?1 AND idempotency_key = ?2`,
  )
    .bind(auth.uid, parsed.idempotencyKey)
    .first();
  if (existing)
    return context.json(
      { error: "STT session already requested", sessionId: existing.id },
      409,
      { "cache-control": "no-store" },
    );
  const sessionId = crypto.randomUUID();
  const estimatedCost = Math.ceil((maxSessionSeconds * costPerMinute) / 60);
  if (!Number.isSafeInteger(estimatedCost) || estimatedCost <= 0)
    return context.json({ error: "Managed STT unavailable" }, 503);
  let admission: Response;
  try {
    admission = await admitSttSession(
      context.env,
      sessionId,
      auth.uid,
      maxSessionSeconds,
      estimatedCost,
    );
  } catch {
    return context.json({ error: "Managed STT unavailable" }, 503);
  }
  if (!admission.ok)
    return context.json(
      { error: "Managed STT capacity exceeded" },
      429,
      admission.headers.get("retry-after")
        ? { "retry-after": admission.headers.get("retry-after") as string }
        : undefined,
    );
  try {
    await context.env.DB.prepare(
      `INSERT INTO managed_stt_sessions
       (id, uid, idempotency_key, provider, model, language, encoding, sample_rate,
        channels, diarize, interim_results, device_id, source_id, status,
        reserved_seconds, estimated_cost_microusd, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'deepgram', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
        'minting', ?13, ?14, ?15, ?15)`,
    )
      .bind(
        sessionId,
        auth.uid,
        parsed.idempotencyKey,
        parsed.model,
        parsed.language,
        parsed.encoding,
        parsed.sampleRate,
        parsed.channels,
        parsed.diarize ? 1 : 0,
        parsed.interimResults ? 1 : 0,
        parsed.deviceId,
        parsed.sourceId,
        maxSessionSeconds,
        estimatedCost,
        now,
      )
      .run();
  } catch {
    return context.json({ error: "Managed STT unavailable" }, 503);
  }
  let grant: Response;
  try {
    grant = await fetch(deepgramGrantEndpoint, {
      method: "POST",
      headers: {
        authorization: `Token ${secret}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ ttl_seconds: tokenTtlSeconds }),
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    await context.env.DB.prepare(
      "UPDATE managed_stt_sessions SET status = 'failed', updated_at = ?1 WHERE id = ?2",
    )
      .bind(Date.now(), sessionId)
      .run();
    return context.json({ error: "Managed STT unavailable" }, 502);
  }
  const grantBody = (await grant.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (
    !grant.ok ||
    typeof grantBody?.access_token !== "string" ||
    grantBody.access_token.length < 32 ||
    grantBody.expires_in !== tokenTtlSeconds
  ) {
    await context.env.DB.prepare(
      "UPDATE managed_stt_sessions SET status = 'failed', updated_at = ?1 WHERE id = ?2",
    )
      .bind(Date.now(), sessionId)
      .run();
    return context.json({ error: "Managed STT unavailable" }, 502);
  }
  const tokenExpiresAt = Date.now() + tokenTtlSeconds * 1000;
  await context.env.DB.prepare(
    `UPDATE managed_stt_sessions
     SET status = 'issued', token_expires_at = ?1, updated_at = ?2 WHERE id = ?3`,
  )
    .bind(tokenExpiresAt, Date.now(), sessionId)
    .run();
  const parameters = {
    model: parsed.model,
    language: parsed.language,
    encoding: parsed.encoding,
    sample_rate: String(parsed.sampleRate),
    channels: String(parsed.channels),
    diarize: String(parsed.diarize),
    interim_results: String(parsed.interimResults),
  };
  const websocketUrl = new URL(deepgramListenEndpoint);
  for (const [key, value] of Object.entries(parameters))
    websocketUrl.searchParams.set(key, value);
  return context.json(
    {
      sessionId,
      accessToken: grantBody.access_token,
      expiresAt: tokenExpiresAt,
      websocketUrl: websocketUrl.toString(),
      allowedParams: parameters,
      maxSessionSeconds,
    },
    201,
    { "cache-control": "no-store", pragma: "no-cache" },
  );
});

export default stt;
