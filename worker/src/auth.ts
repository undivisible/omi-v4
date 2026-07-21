import type { MiddlewareHandler } from "hono";
import type { AppEnv, Auth } from "./types";

type FirebaseClaims = {
  aud?: unknown;
  email?: unknown;
  exp?: unknown;
  iat?: unknown;
  iss?: unknown;
  sub?: unknown;
};

type JwtHeader = { alg?: unknown; kid?: unknown };

type FirebaseJwk = JsonWebKey & { kid?: string };

let keys: { expiresAt: number; values: FirebaseJwk[] } | undefined;

const decode = (value: string): Uint8Array => {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(
    normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="),
  );
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
};

const parse = (token: string) => {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    return {
      header: JSON.parse(
        new TextDecoder().decode(decode(parts[0])),
      ) as JwtHeader,
      claims: JSON.parse(
        new TextDecoder().decode(decode(parts[1])),
      ) as FirebaseClaims,
      signature: decode(parts[2]),
      signed: new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    };
  } catch {
    return null;
  }
};

const firebaseKeys = async (): Promise<FirebaseJwk[]> => {
  if (keys && keys.expiresAt > Date.now()) return keys.values;
  const response = await fetch(
    "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com",
  );
  if (!response.ok) throw new Error("Firebase keys unavailable");
  const body = (await response.json()) as { keys?: FirebaseJwk[] };
  if (!Array.isArray(body.keys)) throw new Error("Firebase keys invalid");
  const maxAge = Number(
    /max-age=(\d+)/.exec(response.headers.get("cache-control") ?? "")?.[1] ??
      300,
  );
  keys = { expiresAt: Date.now() + maxAge * 1000, values: body.keys };
  return body.keys;
};

export const verifyFirebaseToken = async (
  token: string,
  projectId: string,
): Promise<Auth | null> => {
  const parsed = parse(token);
  if (parsed?.header.alg !== "RS256" || typeof parsed.header.kid !== "string")
    return null;
  const now = Math.floor(Date.now() / 1000);
  const expectedIssuer = `https://securetoken.google.com/${projectId}`;
  if (
    parsed.claims.aud !== projectId ||
    parsed.claims.iss !== expectedIssuer ||
    typeof parsed.claims.sub !== "string" ||
    parsed.claims.sub.length === 0 ||
    typeof parsed.claims.exp !== "number" ||
    parsed.claims.exp <= now ||
    typeof parsed.claims.iat !== "number" ||
    parsed.claims.iat > now + 60
  )
    return null;
  const jwk = (await firebaseKeys()).find(
    (candidate) => candidate.kid === parsed.header.kid,
  );
  if (!jwk) return null;
  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  if (
    !(await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      parsed.signature.buffer as ArrayBuffer,
      parsed.signed,
    ))
  )
    return null;
  return {
    uid: parsed.claims.sub,
    email: typeof parsed.claims.email === "string" ? parsed.claims.email : null,
  };
};

export const requireAuth: MiddlewareHandler<AppEnv> = async (context, next) => {
  const authorization = context.req.header("authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
  if (!token || !context.env.FIREBASE_PROJECT_ID)
    return context.json({ error: "Authentication required" }, 401);
  try {
    const auth = await verifyFirebaseToken(
      token,
      context.env.FIREBASE_PROJECT_ID,
    );
    if (!auth) return context.json({ error: "Authentication failed" }, 401);
    const now = Date.now();
    await context.env.DB.prepare(
      `INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)
       ON CONFLICT(uid) DO UPDATE SET email = excluded.email, updated_at = excluded.updated_at`,
    )
      .bind(auth.uid, auth.email, now)
      .run();
    context.set("auth", auth);
    await next();
  } catch {
    return context.json({ error: "Authentication unavailable" }, 503);
  }
};
