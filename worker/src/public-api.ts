import { Hono } from "hono";
import { requireApiAccess, requireScope } from "./api-keys";
import { boundedJson, runManagedInboxCompletion } from "./assistant";
import {
  appendConversationMessage,
  listConversationMessages,
} from "./conversations";
import { createCurrent, listCurrents } from "./currents";
import { hasActivePro } from "./entitlement";
import { normalizeHandle } from "./facetime";
import { startFaceTimeSession } from "./facetime-session";
import { ensureMemoryProjected } from "./memory-projection";
import {
  listDailyReviews,
  listProfileMemories,
  retrieveCitedMemory,
} from "./memory-read";
import { memoryContextFor, searchMemoryClaims } from "./memory-vectors";
import { consumeRateLimit } from "./rate-limit";
import {
  maximumTranscribeBodyBytes,
  speakTextOperation,
  transcribeAudioOperation,
} from "./speech";
import type { AppEnv, Bindings } from "./types";

// The third-party surface. Every route here is a thin adapter over an
// operation function; `mcp.ts` calls the very same functions, so the HTTP API
// and the MCP tools can never drift apart. Operations own their own rate
// limiting so both surfaces are covered by one budget per uid.
const publicApi = new Hono<AppEnv>();

export type OperationResult = {
  status: number;
  body: Record<string, unknown>;
  retryAfter?: number;
};

const readLimit = { limit: 120, windowMs: 60_000 };
const writeLimit = { limit: 60, windowMs: 60_000 };
const assistantLimit = { limit: 20, windowMs: 60_000 };
// A FaceTime call rings a real person, so its budget is far tighter than the
// other write paths.
const faceTimeLimit = { limit: 5, windowMs: 60_000 };
const assistantHistoryLimit = 12;
const assistantReplyCharacters = 4_096;

export const assistantSystemPrompt =
  "You are Omi, the user's personal assistant, answering a request that " +
  "arrived over the public API. Answer directly and concisely in plain text.";

const invalid = (message: string): OperationResult => ({
  status: 400,
  body: { error: message },
});

const gate = async (
  env: Bindings,
  uid: string,
  bucket: string,
  budget: { limit: number; windowMs: number },
): Promise<OperationResult | null> => {
  const outcome = await consumeRateLimit(
    env,
    `${bucket}:${uid}`,
    budget.limit,
    budget.windowMs,
  );
  return outcome.allowed
    ? null
    : {
        status: 429,
        body: { error: "Too many requests" },
        retryAfter: outcome.retryAfter,
      };
};

const positiveInteger = (value: unknown, fallback: number) => {
  const parsed =
    value === undefined || value === null ? fallback : Number(value);
  return Number.isSafeInteger(parsed) ? parsed : Number.NaN;
};

const trimmed = (value: unknown, max: number): string | null =>
  typeof value === "string" && value.trim().length > 0 && value.length <= max
    ? value.trim()
    : null;

export const searchMemoryOperation = async (
  env: Bindings,
  uid: string,
  input: { query?: unknown; limit?: unknown; mode?: unknown },
): Promise<OperationResult> => {
  const query = trimmed(input.query, 500);
  const limit = positiveInteger(input.limit, 12);
  const mode = input.mode === undefined ? "keyword" : input.mode;
  if (
    !query ||
    limit < 1 ||
    limit > 50 ||
    (mode !== "keyword" && mode !== "semantic")
  )
    return invalid("Invalid memory search");
  const limited = await gate(env, uid, "public-read", readLimit);
  if (limited) return limited;
  await ensureMemoryProjected(env.DB, uid);
  if (mode === "semantic") {
    const items = await searchMemoryClaims(
      env,
      uid,
      query,
      Math.min(limit, 20),
    );
    return { status: 200, body: { query, mode, items } };
  }
  return {
    status: 200,
    body: { ...(await retrieveCitedMemory(env.DB, uid, query, limit)), mode },
  };
};

export const listMemoriesOperation = async (
  env: Bindings,
  uid: string,
  input: { limit?: unknown },
): Promise<OperationResult> => {
  const limit = positiveInteger(input.limit, 100);
  if (limit < 1 || limit > 100) return invalid("Invalid memory list");
  const limited = await gate(env, uid, "public-read", readLimit);
  if (limited) return limited;
  await ensureMemoryProjected(env.DB, uid);
  return {
    status: 200,
    body: { memories: await listProfileMemories(env.DB, uid, limit) },
  };
};

export const listCurrentsOperation = async (
  env: Bindings,
  uid: string,
): Promise<OperationResult> => {
  const limited = await gate(env, uid, "public-read", readLimit);
  if (limited) return limited;
  await ensureMemoryProjected(env.DB, uid);
  return { status: 200, body: { currents: await listCurrents(env, uid) } };
};

export const createCurrentOperation = async (
  env: Bindings,
  uid: string,
  input: Record<string, unknown>,
): Promise<OperationResult> => {
  const title = trimmed(input.title, 120);
  const summary = trimmed(input.summary, 500);
  const reason = trimmed(input.reason, 500);
  const instruction = trimmed(input.proposedNextStep, 500);
  const evidenceId =
    input.evidenceId === undefined || input.evidenceId === null
      ? null
      : trimmed(input.evidenceId, 200);
  const confidence =
    input.confidence === undefined ? 0.7 : Number(input.confidence);
  const now = Date.now();
  const surfaceAt = positiveInteger(input.surfaceAt, now);
  const expiresAt =
    input.expiresAt === undefined || input.expiresAt === null
      ? null
      : positiveInteger(input.expiresAt, Number.NaN);
  if (
    !title ||
    !summary ||
    !reason ||
    !instruction ||
    (input.evidenceId !== undefined &&
      input.evidenceId !== null &&
      !evidenceId) ||
    !Number.isFinite(confidence) ||
    confidence < 0 ||
    confidence > 1 ||
    !Number.isSafeInteger(surfaceAt) ||
    surfaceAt <= 0 ||
    (expiresAt !== null &&
      (!Number.isSafeInteger(expiresAt) || expiresAt <= surfaceAt))
  )
    return invalid("Invalid Current");
  const limited = await gate(env, uid, "public-write", writeLimit);
  if (limited) return limited;
  await ensureMemoryProjected(env.DB, uid);
  const current = await createCurrent(env, uid, {
    evidenceId,
    title,
    summary,
    reason,
    instruction,
    confidence,
    surfaceAt,
    expiresAt,
    crepus: null,
  });
  return current === null
    ? { status: 404, body: { error: "Cited evidence not found" } }
    : { status: 201, body: { current } };
};

export const listConversationOperation = async (
  env: Bindings,
  uid: string,
  input: { after?: unknown; limit?: unknown },
): Promise<OperationResult> => {
  const after = positiveInteger(input.after, 0);
  const limit = positiveInteger(input.limit, 100);
  if (after < 0 || limit < 1 || limit > 200)
    return invalid("Invalid replay range");
  const limited = await gate(env, uid, "public-read", readLimit);
  if (limited) return limited;
  return {
    status: 200,
    body: await listConversationMessages(env.DB, uid, after, limit),
  };
};

export const listNotesOperation = async (
  env: Bindings,
  uid: string,
  input: { limit?: unknown },
): Promise<OperationResult> => {
  const limit = positiveInteger(input.limit, 50);
  if (limit < 1 || limit > 100) return invalid("Invalid note list");
  const limited = await gate(env, uid, "public-read", readLimit);
  if (limited) return limited;
  await ensureMemoryProjected(env.DB, uid);
  return {
    status: 200,
    body: { notes: await listDailyReviews(env.DB, uid, limit) },
  };
};

const recentHistory = async (database: D1Database, uid: string) => {
  const rows = await database
    .prepare(
      `SELECT role, text FROM conversation_messages
       WHERE uid = ?1 AND conversation_id = ?1
       ORDER BY cursor DESC LIMIT ?2`,
    )
    .bind(uid, assistantHistoryLimit)
    .all<{ role: string; text: string }>();
  return (rows.results ?? [])
    .reverse()
    .filter((row) => row.role === "user" || row.role === "assistant")
    .map((row) => ({
      role: row.role as "user" | "assistant",
      content: String(row.text),
    }));
};

// Programmatic assistant turns are recorded in the same conversation the app
// reads, so a reply asked for over the API is visible in the user's history.
// The conversation source vocabulary predates the public API; API traffic is
// recorded as `web`.
export const askOmiOperation = async (
  env: Bindings,
  uid: string,
  input: { text?: unknown; clientMessageId?: unknown },
  fetcher: typeof fetch = fetch,
): Promise<OperationResult> => {
  const question = trimmed(input.text, 20_000);
  const clientMessageId =
    input.clientMessageId === undefined
      ? `api:${crypto.randomUUID()}`
      : typeof input.clientMessageId === "string" &&
          /^[A-Za-z0-9._:-]{8,120}$/.test(input.clientMessageId)
        ? input.clientMessageId
        : null;
  if (!question || !clientMessageId)
    return invalid("Invalid assistant message");
  const limited = await gate(env, uid, "public-assistant", assistantLimit);
  if (limited) return limited;
  if (!(await hasActivePro(env, uid)))
    return { status: 403, body: { error: "Managed Pro required" } };
  const stored = await appendConversationMessage(env.DB, {
    uid,
    clientMessageId,
    role: "user",
    source: "web",
    text: question,
  });
  if (!stored)
    return { status: 409, body: { error: "Client message ID conflict" } };
  const memoryContext = await memoryContextFor(env, uid, question);
  const history = await recentHistory(env.DB, uid);
  const completion = await runManagedInboxCompletion(
    env,
    uid,
    [
      {
        role: "system",
        content:
          memoryContext === null
            ? assistantSystemPrompt
            : `${assistantSystemPrompt}\n\n${memoryContext}`,
      },
      ...history,
    ],
    fetcher,
  );
  if (completion === null)
    return { status: 502, body: { error: "Managed AI unavailable" } };
  const reply = completion.trim().slice(0, assistantReplyCharacters);
  const answer = await appendConversationMessage(env.DB, {
    uid,
    clientMessageId: `${clientMessageId}:reply`,
    role: "assistant",
    source: "web",
    text: reply,
  });
  return {
    status: 200,
    body: { reply, message: stored, answer },
  };
};

// The idempotency key decides the session id, so a retry lands on the same
// admission reservation instead of placing a second call.
const faceTimeSessionId = async (
  uid: string,
  token: string,
): Promise<string> => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${uid} facetime ${token}`),
  );
  return Array.from(new Uint8Array(digest).slice(0, 16), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
};

// The custom domain this Worker is deployed on, used when APP_URL is unset.
const defaultAppUrl = "https://omi.tsc.hk";

const faceTimeSessionLink = (env: Bindings, sessionId: string): string =>
  new URL(
    `/facetime/sessions/${sessionId}`,
    env.APP_URL?.trim() || defaultAppUrl,
  ).toString();

export const startFaceTimeOperation = async (
  env: Bindings,
  uid: string,
  input: { handle?: unknown; idempotencyKey?: unknown },
  fetcher: typeof fetch = fetch,
): Promise<OperationResult> => {
  const handle = normalizeHandle(input.handle);
  const token =
    input.idempotencyKey === undefined
      ? crypto.randomUUID()
      : typeof input.idempotencyKey === "string" &&
          /^[A-Za-z0-9._:-]{8,120}$/.test(input.idempotencyKey)
        ? input.idempotencyKey
        : null;
  if (!handle || !token) return invalid("Invalid FaceTime handle");
  const limited = await gate(env, uid, "public-facetime", faceTimeLimit);
  if (limited) return limited;
  const sessionId = await faceTimeSessionId(uid, token);
  const outcome = await startFaceTimeSession(
    env,
    uid,
    handle,
    sessionId,
    fetcher,
  );
  switch (outcome.kind) {
    case "ok":
      return {
        status: 201,
        body: {
          call: {
            handle: outcome.handle,
            sessionId: outcome.sessionId,
            // The provider no longer returns an Apple join link: the call's
            // audio is joined server-side by the bridge. `link` is kept in
            // the contract and points at this session so existing clients
            // keep working.
            link: faceTimeSessionLink(env, outcome.sessionId),
          },
        },
      };
    case "unavailable":
      return {
        status: 503,
        body: {
          error: "FaceTime calling is not provisioned on this account",
          code: "facetime_unavailable",
        },
      };
    case "unconfigured":
      return { status: 503, body: { error: "FaceTime calling unavailable" } };
    case "rejected":
      return { status: 400, body: { error: "Handle rejected by provider" } };
    case "capacity":
      return {
        status: 429,
        body: { error: "FaceTime capacity exceeded" },
        retryAfter: outcome.retryAfter,
      };
    default:
      return { status: 502, body: { error: "FaceTime calling unavailable" } };
  }
};

const respond = (result: OperationResult) =>
  Response.json(result.body, {
    status: result.status,
    headers:
      result.retryAfter === undefined
        ? undefined
        : { "retry-after": String(result.retryAfter) },
  });

publicApi.use("*", requireApiAccess);

publicApi.get("/me", (context) => {
  const auth = context.get("auth");
  const key = context.get("apiKey");
  return context.json({
    uid: auth.uid,
    email: auth.email,
    auth: key ? "api_key" : "firebase",
    keyId: key?.id ?? null,
    scopes: key?.scopes ?? null,
  });
});

publicApi.get("/memory/search", requireScope("memory:read"), async (context) =>
  respond(
    await searchMemoryOperation(context.env, context.get("auth").uid, {
      query: context.req.query("q"),
      limit: context.req.query("limit"),
      mode: context.req.query("mode"),
    }),
  ),
);

publicApi.get("/memories", requireScope("memory:read"), async (context) =>
  respond(
    await listMemoriesOperation(context.env, context.get("auth").uid, {
      limit: context.req.query("limit"),
    }),
  ),
);

publicApi.get("/currents", requireScope("currents:read"), async (context) =>
  respond(await listCurrentsOperation(context.env, context.get("auth").uid)),
);

publicApi.post("/currents", requireScope("currents:write"), async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid Current" }, 400);
  }
  if (body === null || typeof body !== "object" || Array.isArray(body))
    return context.json({ error: "Invalid Current" }, 400);
  return respond(
    await createCurrentOperation(
      context.env,
      context.get("auth").uid,
      body as Record<string, unknown>,
    ),
  );
});

publicApi.get(
  "/conversations/messages",
  requireScope("conversations:read"),
  async (context) =>
    respond(
      await listConversationOperation(context.env, context.get("auth").uid, {
        after: context.req.query("after"),
        limit: context.req.query("limit"),
      }),
    ),
);

publicApi.get("/notes", requireScope("conversations:read"), async (context) =>
  respond(
    await listNotesOperation(context.env, context.get("auth").uid, {
      limit: context.req.query("limit"),
    }),
  ),
);

publicApi.post(
  "/assistant/messages",
  requireScope("assistant:write"),
  async (context) => {
    let body: unknown;
    try {
      body = await context.req.json();
    } catch {
      return context.json({ error: "Invalid assistant message" }, 400);
    }
    if (body === null || typeof body !== "object" || Array.isArray(body))
      return context.json({ error: "Invalid assistant message" }, 400);
    return respond(
      await askOmiOperation(
        context.env,
        context.get("auth").uid,
        body as Record<string, unknown>,
      ),
    );
  },
);

publicApi.post(
  "/facetime/calls",
  requireScope("facetime:write"),
  async (context) => {
    let body: unknown;
    try {
      body = await context.req.json();
    } catch {
      return context.json({ error: "Invalid FaceTime handle" }, 400);
    }
    if (body === null || typeof body !== "object" || Array.isArray(body))
      return context.json({ error: "Invalid FaceTime handle" }, 400);
    return respond(
      await startFaceTimeOperation(
        context.env,
        context.get("auth").uid,
        body as Record<string, unknown>,
      ),
    );
  },
);

// Audio uploads are read through a size-bounded reader rather than
// `req.json()`: the body can be megabytes and an oversized one must be
// refused before it is buffered, not after.
publicApi.post(
  "/speech/transcriptions",
  requireScope("speech:write"),
  async (context) => {
    const declared = Number(context.req.header("content-length"));
    if (Number.isFinite(declared) && declared > maximumTranscribeBodyBytes)
      return context.json({ error: "Audio too large" }, 413);
    const body = await boundedJson(context.req.raw, maximumTranscribeBodyBytes);
    if (!body) return context.json({ error: "Audio too large" }, 413);
    return respond(
      await transcribeAudioOperation(
        context.env,
        context.get("auth").uid,
        body,
      ),
    );
  },
);

publicApi.post(
  "/speech/synthesis",
  requireScope("speech:write"),
  async (context) => {
    let body: unknown;
    try {
      body = await context.req.json();
    } catch {
      return context.json({ error: "Invalid speech request" }, 400);
    }
    if (body === null || typeof body !== "object" || Array.isArray(body))
      return context.json({ error: "Invalid speech request" }, 400);
    return respond(
      await speakTextOperation(
        context.env,
        context.get("auth").uid,
        body as Record<string, unknown>,
      ),
    );
  },
);

export default publicApi;
