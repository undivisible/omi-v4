import { Hono } from "hono";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv } from "./types";

// Device-code OAuth broker for subscription sign-in (xAI Grok, OpenAI
// ChatGPT). Dev/testing only: both vendors license subscription auth for
// personal interactive use, and the ChatGPT authorize redirect is pinned to
// a loopback, so the broker uses the device-code grant exclusively.
const broker = new Hono<AppEnv>();

export type ProviderConfig = {
  clientId: string;
  deviceEndpoint: string;
  tokenEndpoint: string;
  scope: string;
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const fromBase64 = (value: string): Uint8Array | null => {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1)
      bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
};

const toBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
};

export const importOauthTokenKey = async (
  secret: string,
): Promise<CryptoKey | null> => {
  const raw = fromBase64(secret);
  if (!raw || raw.length !== 32) return null;
  try {
    return await crypto.subtle.importKey("raw", raw, "AES-GCM", false, [
      "encrypt",
      "decrypt",
    ]);
  } catch {
    return null;
  }
};

export const encryptOauthToken = async (
  key: CryptoKey,
  plaintext: string,
): Promise<string> => {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      encoder.encode(plaintext),
    ),
  );
  const combined = new Uint8Array(iv.length + ciphertext.length);
  combined.set(iv);
  combined.set(ciphertext, iv.length);
  return toBase64(combined);
};

export const decryptOauthToken = async (
  key: CryptoKey,
  stored: string,
): Promise<string | null> => {
  const combined = fromBase64(stored);
  if (!combined || combined.length <= 12) return null;
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: combined.slice(0, 12) },
      key,
      combined.slice(12),
    );
    return decoder.decode(plaintext);
  } catch {
    return null;
  }
};

const validXaiEndpoint = (value: unknown): value is string => {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      (url.hostname === "x.ai" || url.hostname.endsWith(".x.ai"))
    );
  } catch {
    return false;
  }
};

type XaiEndpoints = { deviceEndpoint: string; tokenEndpoint: string };

let xaiDiscovery: Promise<XaiEndpoints | null> | null = null;

const discoverXaiEndpoints = async (): Promise<XaiEndpoints | null> => {
  try {
    const discovery = await fetch(
      "https://auth.x.ai/.well-known/openid-configuration",
    );
    if (!discovery.ok) return null;
    const document = (await discovery.json()) as {
      device_authorization_endpoint?: unknown;
      token_endpoint?: unknown;
    };
    if (
      !validXaiEndpoint(document.device_authorization_endpoint) ||
      !validXaiEndpoint(document.token_endpoint)
    )
      return null;
    return {
      deviceEndpoint: document.device_authorization_endpoint,
      tokenEndpoint: document.token_endpoint,
    };
  } catch {
    return null;
  }
};

export const providerConfig = async (
  provider: string,
  env: AppEnv["Bindings"],
): Promise<ProviderConfig | null> => {
  if (provider === "openai") {
    const clientId = env.OPENAI_OAUTH_CLIENT_ID;
    if (!clientId) return null;
    return {
      clientId,
      deviceEndpoint: "https://auth.openai.com/oauth/device/code",
      tokenEndpoint: "https://auth.openai.com/oauth/token",
      scope: "openid profile email offline_access",
    };
  }
  if (provider === "xai") {
    const clientId = env.XAI_OAUTH_CLIENT_ID;
    if (!clientId) return null;
    if (!xaiDiscovery)
      xaiDiscovery = discoverXaiEndpoints().then((endpoints) => {
        if (!endpoints) xaiDiscovery = null;
        return endpoints;
      });
    const endpoints = await xaiDiscovery;
    if (!endpoints) return null;
    return {
      clientId,
      deviceEndpoint: endpoints.deviceEndpoint,
      tokenEndpoint: endpoints.tokenEndpoint,
      scope: "openid profile offline_access",
    };
  }
  return null;
};

broker.post("/:provider/device/start", async (context) => {
  const rateLimit = await consumeRateLimit(
    context.env,
    `oauth-device-start:${context.get("auth").uid}`,
    5,
    60_000,
  );
  if (!rateLimit.allowed)
    return context.json({ error: "Too many requests" }, 429, {
      "retry-after": String(rateLimit.retryAfter),
    });
  const config = await providerConfig(
    context.req.param("provider"),
    context.env,
  );
  if (!config) return context.json({ error: "Provider unavailable" }, 503);
  const response = await fetch(config.deviceEndpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.clientId,
      scope: config.scope,
    }),
  });
  if (!response.ok)
    return context.json({ error: "Provider rejected device start" }, 502);
  const body = (await response.json()) as Record<string, unknown>;
  const deviceCode = body.device_code;
  const userCode = body.user_code;
  const verificationUri =
    body.verification_uri_complete ?? body.verification_uri;
  if (typeof deviceCode !== "string" || typeof userCode !== "string")
    return context.json({ error: "Provider rejected device start" }, 502);
  return context.json({
    deviceCode,
    userCode,
    verificationUri: typeof verificationUri === "string" ? verificationUri : "",
    interval: typeof body.interval === "number" ? body.interval : 5,
    expiresIn: typeof body.expires_in === "number" ? body.expires_in : 900,
  });
});

const pollErrorAllowlist = new Set([
  "authorization_pending",
  "slow_down",
  "expired_token",
  "access_denied",
]);
const accountIdPattern = /^[A-Za-z0-9_-]{1,128}$/;

broker.post("/:provider/device/poll", async (context) => {
  const rateLimit = await consumeRateLimit(
    context.env,
    `oauth-device-poll:${context.get("auth").uid}`,
    30,
    60_000,
  );
  if (!rateLimit.allowed)
    return context.json({ error: "Too many requests" }, 429, {
      "retry-after": String(rateLimit.retryAfter),
    });
  const provider = context.req.param("provider");
  const config = await providerConfig(provider, context.env);
  if (!config) return context.json({ error: "Provider unavailable" }, 503);
  const tokenKey = context.env.OAUTH_TOKEN_KEY
    ? await importOauthTokenKey(context.env.OAUTH_TOKEN_KEY)
    : null;
  if (!tokenKey) return context.json({ error: "Provider unavailable" }, 503);
  let deviceCode: unknown;
  try {
    deviceCode = ((await context.req.json()) as Record<string, unknown>)
      .deviceCode;
  } catch {
    deviceCode = null;
  }
  if (typeof deviceCode !== "string" || deviceCode.length > 2048)
    return context.json({ error: "Invalid request" }, 400);
  const response = await fetch(config.tokenEndpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.clientId,
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });
  const body = (await response.json()) as Record<string, unknown>;
  if (!response.ok || typeof body.access_token !== "string") {
    const error =
      typeof body.error === "string" && pollErrorAllowlist.has(body.error)
        ? body.error
        : "failed";
    if (error === "authorization_pending" || error === "slow_down")
      return context.json({ pending: true, error }, 202);
    return context.json({ error }, 400);
  }
  const now = Date.now();
  const expiresAt =
    typeof body.expires_in === "number" ? now + body.expires_in * 1000 : null;
  await context.env.DB.prepare(
    `INSERT INTO oauth_connections
       (uid, provider, access_token, refresh_token, account_id, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
     ON CONFLICT (uid, provider) DO UPDATE SET
       access_token = excluded.access_token,
       refresh_token = excluded.refresh_token,
       account_id = excluded.account_id,
       expires_at = excluded.expires_at,
       updated_at = excluded.updated_at`,
  )
    .bind(
      context.get("auth").uid,
      provider,
      await encryptOauthToken(tokenKey, body.access_token),
      typeof body.refresh_token === "string"
        ? await encryptOauthToken(tokenKey, body.refresh_token)
        : null,
      typeof body.account_id === "string" &&
        accountIdPattern.test(body.account_id)
        ? body.account_id
        : null,
      expiresAt,
      now,
    )
    .run();
  return context.json({ connected: true });
});

broker.get("/status", async (context) => {
  const rows = await context.env.DB.prepare(
    "SELECT provider, expires_at, updated_at FROM oauth_connections WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .all();
  return context.json({
    connections: (rows.results ?? []).map((row) => ({
      provider: row.provider,
      expiresAt: row.expires_at,
      updatedAt: row.updated_at,
    })),
  });
});

broker.delete("/:provider", async (context) => {
  await context.env.DB.prepare(
    "DELETE FROM oauth_connections WHERE uid = ?1 AND provider = ?2",
  )
    .bind(context.get("auth").uid, context.req.param("provider"))
    .run();
  return context.json({ disconnected: true });
});

export default broker;
