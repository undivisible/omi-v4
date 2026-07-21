import { Hono } from "hono";
import { verifyFirebaseToken } from "./auth";
import type { AppEnv } from "./types";

const desktopAuth = new Hono<AppEnv>();
const encoder = new TextEncoder();
const sessionPattern = /^[A-Za-z0-9_-]{32,128}$/;
const confirmationPattern = /^[0-9]{6}$/;
const lifetimeMs = 5 * 60 * 1000;

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

const value = (input: unknown): string | null =>
  typeof input === "string" && sessionPattern.test(input) ? input : null;

const base64Url = (input: Uint8Array | string): string => {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

const verifierChallenge = async (verifier: string): Promise<string> =>
  base64Url(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(verifier)),
    ),
  );

const validPublicOrigin = (source: string): URL | null => {
  try {
    const url = new URL(source);
    const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    if (
      (url.protocol !== "https:" && !(loopback && url.protocol === "http:")) ||
      url.username ||
      url.password ||
      url.hash ||
      url.search ||
      (url.pathname !== "" && url.pathname !== "/")
    )
      return null;
    return url;
  } catch {
    return null;
  }
};

export const bindDesktopSession = async (
  db: D1Database,
  sessionId: string,
  uid: string,
  confirmationCode: string,
  now = Date.now(),
): Promise<boolean> => {
  const confirmation = await verifierChallenge(confirmationCode);
  const row = await db
    .prepare(
      `UPDATE desktop_auth_sessions
       SET uid = CASE WHEN confirmation_challenge = ?3 THEN ?1 ELSE uid END,
           confirmation_attempts = confirmation_attempts + CASE WHEN confirmation_challenge = ?3 THEN 0 ELSE 1 END,
           confirmation_locked_at = CASE
             WHEN confirmation_challenge != ?3 AND confirmation_attempts + 1 >= 5 THEN ?4
             ELSE confirmation_locked_at
           END
       WHERE id = ?2 AND uid IS NULL AND consumed_at IS NULL AND expires_at > ?4
         AND confirmation_locked_at IS NULL AND confirmation_attempts < 5
       RETURNING uid, confirmation_attempts, confirmation_locked_at`,
    )
    .bind(uid, sessionId, confirmation, now)
    .first<{ uid: string | null }>();
  return row?.uid === uid;
};

const privateKeyBytes = (pem: string): Uint8Array | null => {
  try {
    const normalized = pem
      .replaceAll("\\n", "\n")
      .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
    return Uint8Array.from(atob(normalized), (character) =>
      character.charCodeAt(0),
    );
  } catch {
    return null;
  }
};

export const createFirebaseCustomToken = async (
  uid: string,
  serviceAccountEmail: string,
  privateKeyPem: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> => {
  const bytes = privateKeyBytes(privateKeyPem);
  if (!bytes) throw new Error("Firebase signing key invalid");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    bytes.buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(
    JSON.stringify({
      iss: serviceAccountEmail,
      sub: serviceAccountEmail,
      aud: "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
      iat: nowSeconds,
      exp: nowSeconds + 3600,
      uid,
    }),
  );
  const unsigned = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    encoder.encode(unsigned),
  );
  return `${unsigned}.${base64Url(new Uint8Array(signature))}`;
};

desktopAuth.post("/start", async (context) => {
  const body = await json(context.req.raw);
  const sessionId = value(body?.sessionId);
  const challenge = value(body?.challenge);
  const confirmationChallenge = value(body?.confirmationChallenge);
  const appUrl = context.env.APP_URL;
  if (!sessionId || !challenge || !confirmationChallenge)
    return context.json({ error: "Invalid handoff" }, 400);
  const appOrigin = appUrl ? validPublicOrigin(appUrl) : null;
  if (!appOrigin)
    return context.json({ error: "Desktop handoff unavailable" }, 503);
  const now = Date.now();
  const clientIp = context.req.header("cf-connecting-ip") ?? "unknown";
  await context.env.DB.prepare(
    "DELETE FROM desktop_auth_sessions WHERE expires_at <= ?1 OR consumed_at IS NOT NULL",
  )
    .bind(now)
    .run();
  const recent = await context.env.DB.prepare(
    "SELECT COUNT(*) AS count FROM desktop_auth_sessions WHERE client_ip = ?1 AND created_at > ?2",
  )
    .bind(clientIp, now - 10 * 60 * 1000)
    .first<{ count: number }>();
  if (Number(recent?.count ?? 0) >= 10)
    return context.json({ error: "Too many handoffs" }, 429);
  try {
    await context.env.DB.prepare(
      "INSERT INTO desktop_auth_sessions (id, verifier_challenge, confirmation_challenge, client_ip, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
      .bind(
        sessionId,
        challenge,
        confirmationChallenge,
        clientIp,
        now,
        now + lifetimeMs,
      )
      .run();
  } catch {
    return context.json({ error: "Handoff already exists" }, 409);
  }
  const browser = new URL("/", appOrigin);
  browser.searchParams.set("desktop_auth", sessionId);
  return context.json(
    { browserUrl: browser.toString(), expiresAt: now + lifetimeMs },
    201,
  );
});

desktopAuth.post("/complete", async (context) => {
  const body = await json(context.req.raw);
  const sessionId = value(body?.sessionId);
  const confirmationCode =
    typeof body?.confirmationCode === "string" &&
    confirmationPattern.test(body.confirmationCode)
      ? body.confirmationCode
      : null;
  const projectId = context.env.FIREBASE_PROJECT_ID;
  const authorization = context.req.header("authorization") ?? "";
  if (
    !sessionId ||
    !confirmationCode ||
    !projectId ||
    !authorization.startsWith("Bearer ")
  )
    return context.json({ error: "Authentication required" }, 401);
  let auth;
  try {
    auth = await verifyFirebaseToken(authorization.slice(7).trim(), projectId);
  } catch {
    return context.json({ error: "Authentication service unavailable" }, 503);
  }
  if (!auth) return context.json({ error: "Authentication failed" }, 401);
  const now = Date.now();
  await context.env.DB.prepare(
    `INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)
     ON CONFLICT(uid) DO UPDATE SET email = excluded.email, updated_at = excluded.updated_at`,
  )
    .bind(auth.uid, auth.email, now)
    .run();
  if (
    !(await bindDesktopSession(
      context.env.DB,
      sessionId,
      auth.uid,
      confirmationCode,
      now,
    ))
  )
    return context.json({ error: "Handoff expired or already completed" }, 409);
  return context.json({ completed: true });
});

desktopAuth.post("/exchange", async (context) => {
  const body = await json(context.req.raw);
  const sessionId = value(body?.sessionId);
  const verifier = value(body?.verifier);
  const email = context.env.FIREBASE_SERVICE_ACCOUNT_EMAIL;
  const privateKey = context.env.FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY;
  if (!sessionId || !verifier)
    return context.json({ error: "Invalid handoff" }, 400);
  if (!email || !privateKey)
    return context.json({ error: "Desktop token signing unavailable" }, 503);
  const challenge = await verifierChallenge(verifier);
  const now = Date.now();
  const row = await context.env.DB.prepare(
    "SELECT uid FROM desktop_auth_sessions WHERE id = ?1 AND verifier_challenge = ?2 AND consumed_at IS NULL AND expires_at > ?3",
  )
    .bind(sessionId, challenge, now)
    .first<{ uid: string | null }>();
  if (!row) return context.json({ error: "Handoff expired" }, 410);
  if (!row.uid) return context.json({ status: "pending" }, 409);
  const token = await createFirebaseCustomToken(row.uid, email, privateKey);
  const consumed = await context.env.DB.prepare(
    "UPDATE desktop_auth_sessions SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
  )
    .bind(now, sessionId)
    .run();
  if (consumed.meta.changes !== 1)
    return context.json({ error: "Handoff already consumed" }, 409);
  return context.json({ customToken: token });
});

export default desktopAuth;
