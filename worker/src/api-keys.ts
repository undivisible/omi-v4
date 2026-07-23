import { Hono, type MiddlewareHandler } from "hono";
import { requireAuth } from "./auth";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv, ApiKeyContext, ApiKeyScope } from "./types";

const apiKeys = new Hono<AppEnv>();
const encoder = new TextEncoder();

// Programmatic clients (SDKs, MCP hosts, cron jobs) cannot hold a Firebase ID
// token: those are minted by an interactive sign-in and expire in an hour. An
// API key is the long-lived, per-uid, revocable alternative. Only the SHA-256
// digest is stored, so a database read cannot recover a usable credential.
export const apiKeyPrefix = "omi_sk_";
const keyPattern = /^omi_sk_([0-9a-f]{8})_([A-Za-z0-9_-]{43})$/;
const maximumKeysPerUid = 25;
const lastUsedResolutionMs = 60_000;

export const allScopes: readonly ApiKeyScope[] = [
  "memory:read",
  "currents:read",
  "currents:write",
  "conversations:read",
  "assistant:write",
  "facetime:write",
];

const scopeSet = new Set<string>(allScopes);

const hex = (bytes: Uint8Array) =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

export const digest = async (value: string): Promise<string> =>
  hex(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  );

// Compares two same-length hex digests without leaking, through timing, how
// many leading characters matched. Length is not secret (both are SHA-256).
export const timingSafeEqual = (left: string, right: string): boolean => {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1)
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
};

const base64url = (bytes: Uint8Array) => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

export const mintApiKey = async (): Promise<{
  key: string;
  prefix: string;
  hash: string;
}> => {
  const prefix = hex(crypto.getRandomValues(new Uint8Array(4)));
  const secret = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const key = `${apiKeyPrefix}${prefix}_${secret}`;
  return { key, prefix, hash: await digest(key) };
};

const parseScopes = (value: unknown): ApiKeyScope[] => {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed)
      ? (parsed.filter((scope) =>
          scopeSet.has(scope as string),
        ) as ApiKeyScope[])
      : [];
  } catch {
    return [];
  }
};

type KeyRow = {
  id: string;
  uid: string;
  key_hash: string;
  scopes: string;
  email: string | null;
};

export const verifyApiKey = async (
  database: D1Database,
  token: string,
  now: number,
): Promise<{
  uid: string;
  email: string | null;
  key: ApiKeyContext;
} | null> => {
  const parsed = keyPattern.exec(token);
  if (!parsed) return null;
  const candidates = await database
    .prepare(
      `SELECT k.id, k.uid, k.key_hash, k.scopes, u.email
       FROM api_keys k JOIN users u ON u.uid = k.uid
       WHERE k.prefix = ?1 AND k.revoked_at IS NULL
         AND (k.expires_at IS NULL OR k.expires_at > ?2)`,
    )
    .bind(parsed[1], now)
    .all<KeyRow>();
  const presented = await digest(token);
  // Every candidate is compared: no early exit, so a partial prefix collision
  // cannot be distinguished from a miss by response time.
  let matched: KeyRow | null = null;
  for (const row of candidates.results ?? [])
    if (timingSafeEqual(presented, String(row.key_hash))) matched = row;
  if (!matched) return null;
  await database
    .prepare(
      `UPDATE api_keys SET last_used_at = ?1
       WHERE id = ?2 AND (last_used_at IS NULL OR last_used_at < ?3)`,
    )
    .bind(now, matched.id, now - lastUsedResolutionMs)
    .run()
    .catch(() => undefined);
  return {
    uid: String(matched.uid),
    email: matched.email === null ? null : String(matched.email),
    key: { id: String(matched.id), scopes: parseScopes(matched.scopes) },
  };
};

// Accepts either credential on the programmatic surface: an `omi_sk_` API key
// or, unchanged, a Firebase ID token. Firebase-authenticated callers are the
// account owner in person and carry every scope; API keys carry only the
// scopes they were minted with.
export const requireApiAccess: MiddlewareHandler<AppEnv> = async (
  context,
  next,
) => {
  const authorization = context.req.header("authorization") ?? "";
  const bearer = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
  const token = bearer || (context.req.header("x-api-key") ?? "").trim();
  if (!token.startsWith(apiKeyPrefix)) return requireAuth(context, next);
  let verified: Awaited<ReturnType<typeof verifyApiKey>>;
  try {
    verified = await verifyApiKey(context.env.DB, token, Date.now());
  } catch {
    return context.json({ error: "Authentication unavailable" }, 503);
  }
  if (!verified) return context.json({ error: "Authentication failed" }, 401);
  context.set("auth", { uid: verified.uid, email: verified.email });
  context.set("apiKey", verified.key);
  await next();
};

export const requireScope =
  (scope: ApiKeyScope): MiddlewareHandler<AppEnv> =>
  async (context, next) => {
    const key = context.get("apiKey");
    if (key && !key.scopes.includes(scope))
      return context.json({ error: "Missing scope", scope }, 403);
    await next();
  };

const object = async (request: Request) => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const rowToKey = (row: Record<string, unknown>) => ({
  id: String(row.id),
  name: String(row.name),
  prefix: `${apiKeyPrefix}${String(row.prefix)}`,
  scopes: parseScopes(row.scopes),
  createdAt: Number(row.created_at),
  lastUsedAt: row.last_used_at === null ? null : Number(row.last_used_at),
  expiresAt: row.expires_at === null ? null : Number(row.expires_at),
  revokedAt: row.revoked_at === null ? null : Number(row.revoked_at),
});

apiKeys.get("/", async (context) => {
  const rows = await context.env.DB.prepare(
    `SELECT id, name, prefix, scopes, created_at, last_used_at, expires_at, revoked_at
     FROM api_keys WHERE uid = ?1 ORDER BY created_at DESC LIMIT 100`,
  )
    .bind(context.get("auth").uid)
    .all<Record<string, unknown>>();
  return context.json({ keys: (rows.results ?? []).map(rowToKey) });
});

apiKeys.post("/", async (context) => {
  const body = await object(context.req.raw);
  const name =
    typeof body?.name === "string" &&
    body.name.trim().length > 0 &&
    body.name.length <= 120
      ? body.name.trim()
      : null;
  const requested = body?.scopes === undefined ? [...allScopes] : body.scopes;
  const expiresAt =
    body?.expiresAt === undefined || body.expiresAt === null
      ? null
      : Number(body.expiresAt);
  const now = Date.now();
  if (
    !name ||
    !Array.isArray(requested) ||
    requested.length === 0 ||
    requested.some((scope) => !scopeSet.has(scope as string)) ||
    (expiresAt !== null &&
      (!Number.isSafeInteger(expiresAt) || expiresAt <= now))
  )
    return context.json({ error: "Invalid API key request" }, 400);
  const uid = context.get("auth").uid;
  const limit = await consumeRateLimit(
    context.env,
    `api-key-mint:${uid}`,
    10,
    60 * 60_000,
  );
  if (!limit.allowed)
    return context.json({ error: "Too many requests" }, 429, {
      "retry-after": String(limit.retryAfter),
    });
  const live = await context.env.DB.prepare(
    "SELECT COUNT(*) AS total FROM api_keys WHERE uid = ?1 AND revoked_at IS NULL",
  )
    .bind(uid)
    .first<{ total: number }>();
  if (Number(live?.total ?? 0) >= maximumKeysPerUid)
    return context.json({ error: "API key limit reached" }, 409);
  const scopes = [...new Set(requested as ApiKeyScope[])];
  const minted = await mintApiKey();
  const id = crypto.randomUUID();
  await context.env.DB.prepare(
    `INSERT INTO api_keys (id, uid, name, prefix, key_hash, scopes, created_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  )
    .bind(
      id,
      uid,
      name,
      minted.prefix,
      minted.hash,
      JSON.stringify(scopes),
      now,
      expiresAt,
    )
    .run();
  const stored = await context.env.DB.prepare(
    `SELECT id, name, prefix, scopes, created_at, last_used_at, expires_at, revoked_at
     FROM api_keys WHERE id = ?1 AND uid = ?2`,
  )
    .bind(id, uid)
    .first<Record<string, unknown>>();
  // The plaintext key is returned exactly once; only its digest is retained.
  return context.json({ key: minted.key, apiKey: rowToKey(stored!) }, 201);
});

apiKeys.delete("/:id", async (context) => {
  const revoked = await context.env.DB.prepare(
    "UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND uid = ?3 AND revoked_at IS NULL",
  )
    .bind(Date.now(), context.req.param("id"), context.get("auth").uid)
    .run();
  if (revoked.meta.changes !== 1)
    return context.json({ error: "API key not found" }, 404);
  return context.body(null, 204);
});

export default apiKeys;
