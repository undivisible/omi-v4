import { Hono } from "hono";
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
    const discovery = await fetch(
      "https://auth.x.ai/.well-known/openid-configuration",
    );
    if (!discovery.ok) return null;
    const document = (await discovery.json()) as {
      device_authorization_endpoint?: unknown;
      token_endpoint?: unknown;
    };
    if (
      typeof document.device_authorization_endpoint !== "string" ||
      typeof document.token_endpoint !== "string"
    )
      return null;
    return {
      clientId,
      deviceEndpoint: document.device_authorization_endpoint,
      tokenEndpoint: document.token_endpoint,
      scope: "openid profile offline_access",
    };
  }
  return null;
};

broker.post("/:provider/device/start", async (context) => {
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

broker.post("/:provider/device/poll", async (context) => {
  const provider = context.req.param("provider");
  const config = await providerConfig(provider, context.env);
  if (!config) return context.json({ error: "Provider unavailable" }, 503);
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
    const error = typeof body.error === "string" ? body.error : "failed";
    if (error === "authorization_pending" || error === "slow_down")
      return context.json({ pending: true, error }, 202);
    return context.json({ error }, 400);
  }
  const now = Date.now();
  const expiresAt =
    typeof body.expires_in === "number" ? now + body.expires_in * 1000 : null;
  await context.env.DB.prepare(
    `INSERT INTO oauth_connections
       (uid, provider, access_token, refresh_token, id_token, account_id, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
     ON CONFLICT (uid, provider) DO UPDATE SET
       access_token = excluded.access_token,
       refresh_token = excluded.refresh_token,
       id_token = excluded.id_token,
       account_id = excluded.account_id,
       expires_at = excluded.expires_at,
       updated_at = excluded.updated_at`,
  )
    .bind(
      context.get("auth").uid,
      provider,
      body.access_token,
      typeof body.refresh_token === "string" ? body.refresh_token : null,
      typeof body.id_token === "string" ? body.id_token : null,
      typeof body.account_id === "string" ? body.account_id : null,
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
