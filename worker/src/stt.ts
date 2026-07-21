import { Hono, type Context } from "hono";
import { admitSttSession } from "./stt-admission";
import type { AppEnv } from "./types";

const stt = new Hono<AppEnv>();
const deepgramListenEndpoint = "https://api.deepgram.com/v1/listen";
const idempotencyPattern = /^[A-Za-z0-9._:-]{8,128}$/;
const identifierPattern = /^[A-Za-z0-9._:-]{1,128}$/;
const languagePattern = /^(multi|[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$/;
const sessionPattern = /^[a-f0-9]{64}$/;

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

const activePro = async (context: Context<AppEnv>): Promise<boolean> => {
  const entitlement = await context.env.DB.prepare(
    "SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  return (
    entitlement?.plan === "pro" &&
    entitlement.status === "active" &&
    (entitlement.valid_until === null ||
      Number(entitlement.valid_until) > Date.now())
  );
};

const sessionIdFor = async (uid: string, idempotencyKey: string) => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${uid}\u0000${idempotencyKey}`),
  );
  return [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
};

const websocketUrl = (requestUrl: string, sessionId: string) => {
  const url = new URL(`/v1/stt/sessions/${sessionId}/stream`, requestUrl);
  url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
  return url.toString();
};

stt.post("/sessions", async (context) => {
  const maxSessionSeconds = positiveInteger(
    context.env.STT_MAX_SESSION_SECONDS,
  );
  const costPerMinute = positiveInteger(
    context.env.STT_COST_MICROUSD_PER_MINUTE,
  );
  if (
    !context.env.DEEPGRAM_API_KEY ||
    maxSessionSeconds === null ||
    maxSessionSeconds > 3600 ||
    costPerMinute === null
  )
    return context.json({ error: "Managed STT unavailable" }, 503);
  const body = await boundedJson(context.req.raw);
  const parsed = body ? parseRequest(body) : null;
  if (!parsed) return context.json({ error: "Invalid request" }, 400);
  if (!(await activePro(context)))
    return context.json({ error: "Managed Pro required" }, 403);
  const auth = context.get("auth");
  const sessionId = await sessionIdFor(auth.uid, parsed.idempotencyKey);
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
  const now = Date.now();
  try {
    await context.env.DB.prepare(
      `INSERT INTO managed_stt_sessions
       (id, uid, idempotency_key, provider, model, language, encoding, sample_rate,
        channels, diarize, interim_results, device_id, source_id, status,
        reserved_seconds, estimated_cost_microusd, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'deepgram', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
        'ready', ?13, ?14, ?15, ?15)
       ON CONFLICT(uid, idempotency_key) DO NOTHING`,
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
  const row = await context.env.DB.prepare(
    `SELECT id, model, language, encoding, sample_rate, channels, diarize,
            interim_results, device_id, source_id, status, reserved_seconds
     FROM managed_stt_sessions WHERE uid = ?1 AND idempotency_key = ?2`,
  )
    .bind(auth.uid, parsed.idempotencyKey)
    .first();
  if (
    row?.id !== sessionId ||
    row.model !== parsed.model ||
    row.language !== parsed.language ||
    row.encoding !== parsed.encoding ||
    Number(row.sample_rate) !== parsed.sampleRate ||
    Number(row.channels) !== parsed.channels ||
    Number(row.diarize) !== (parsed.diarize ? 1 : 0) ||
    Number(row.interim_results) !== (parsed.interimResults ? 1 : 0) ||
    row.device_id !== parsed.deviceId ||
    row.source_id !== parsed.sourceId ||
    Number(row.reserved_seconds) !== maxSessionSeconds
  )
    return context.json({ error: "Idempotency conflict" }, 409);
  return context.json(
    {
      sessionId,
      websocketUrl: websocketUrl(context.req.url, sessionId),
      maxSessionSeconds,
      state: row.status,
    },
    row.status === "ready" ? 201 : 200,
  );
});

stt.get("/sessions/:sessionId/stream", async (context) => {
  const sessionId = context.req.param("sessionId");
  const secret = context.env.DEEPGRAM_API_KEY;
  const maxSessionSeconds = positiveInteger(
    context.env.STT_MAX_SESSION_SECONDS,
  );
  if (
    !sessionPattern.test(sessionId) ||
    !secret ||
    maxSessionSeconds === null ||
    maxSessionSeconds > 3600 ||
    context.req.header("upgrade")?.toLowerCase() !== "websocket"
  )
    return context.json({ error: "Managed STT unavailable" }, 503);
  if (!(await activePro(context)))
    return context.json({ error: "Managed Pro required" }, 403);
  const auth = context.get("auth");
  const claimed = await context.env.DB.prepare(
    `UPDATE managed_stt_sessions
     SET status = 'streaming', claimed_at = ?1, updated_at = ?1
     WHERE id = ?2 AND uid = ?3 AND status = 'ready'`,
  )
    .bind(Date.now(), sessionId, auth.uid)
    .run();
  if (claimed.meta.changes !== 1)
    return context.json({ error: "STT session unavailable" }, 409);
  const row = await context.env.DB.prepare(
    `SELECT model, language, encoding, sample_rate, channels, diarize,
            interim_results, reserved_seconds
     FROM managed_stt_sessions WHERE id = ?1 AND uid = ?2`,
  )
    .bind(sessionId, auth.uid)
    .first();
  const sessionSeconds = positiveInteger(row?.reserved_seconds);
  if (!row || sessionSeconds === null || sessionSeconds > maxSessionSeconds)
    return context.json({ error: "STT session unavailable" }, 409);
  const upstreamUrl = new URL(deepgramListenEndpoint);
  for (const [key, value] of Object.entries({
    model: String(row.model),
    language: String(row.language),
    encoding: String(row.encoding),
    sample_rate: String(row.sample_rate),
    channels: String(row.channels),
    diarize: String(Number(row.diarize) === 1),
    interim_results: String(Number(row.interim_results) === 1),
  }))
    upstreamUrl.searchParams.set(key, value);
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(upstreamUrl, {
      headers: { Upgrade: "websocket", Authorization: `Token ${secret}` },
    });
  } catch {
    await context.env.DB.prepare(
      "UPDATE managed_stt_sessions SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND uid = ?3",
    )
      .bind(Date.now(), sessionId, auth.uid)
      .run();
    return context.json({ error: "Managed STT unavailable" }, 502);
  }
  const upstream = upstreamResponse.webSocket;
  if (!upstream || upstreamResponse.status !== 101) {
    await context.env.DB.prepare(
      "UPDATE managed_stt_sessions SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND uid = ?3",
    )
      .bind(Date.now(), sessionId, auth.uid)
      .run();
    return context.json({ error: "Managed STT unavailable" }, 502);
  }
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.binaryType = "arraybuffer";
  upstream.binaryType = "arraybuffer";
  server.accept();
  upstream.accept();
  let closed = false;
  const finish = (
    status: "complete" | "failed",
    code: number,
    reason: string,
  ) => {
    if (closed) return;
    closed = true;
    clearTimeout(timeout);
    if (server.readyState < WebSocket.CLOSING) server.close(code, reason);
    if (upstream.readyState < WebSocket.CLOSING) upstream.close(code, reason);
    void context.env.DB.prepare(
      "UPDATE managed_stt_sessions SET status = ?1, completed_at = ?2, updated_at = ?2 WHERE id = ?3 AND uid = ?4 AND status = 'streaming'",
    )
      .bind(status, Date.now(), sessionId, auth.uid)
      .run()
      .catch(() => undefined);
  };
  const timeout = setTimeout(
    () => finish("complete", 1000, "Session duration reached"),
    sessionSeconds * 1000,
  );
  server.addEventListener("message", (event) => {
    const size =
      typeof event.data === "string"
        ? new TextEncoder().encode(event.data).byteLength
        : event.data instanceof ArrayBuffer
          ? event.data.byteLength
          : Number.MAX_SAFE_INTEGER;
    if (size > 65_536) {
      finish("failed", 1009, "Frame too large");
      return;
    }
    if (upstream.readyState === WebSocket.OPEN) upstream.send(event.data);
  });
  upstream.addEventListener("message", (event) => {
    if (server.readyState === WebSocket.OPEN) server.send(event.data);
  });
  server.addEventListener("close", () =>
    finish("complete", 1000, "Client closed"),
  );
  server.addEventListener("error", () =>
    finish("failed", 1011, "Client stream failed"),
  );
  upstream.addEventListener("close", () =>
    finish("complete", 1000, "Provider closed"),
  );
  upstream.addEventListener("error", () =>
    finish("failed", 1011, "Provider stream failed"),
  );
  return new Response(null, { status: 101, webSocket: client });
});

export default stt;
