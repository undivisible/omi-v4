import { Hono } from "hono";
import { boundedJson } from "./assistant";
import {
  decryptOauthToken,
  encryptOauthToken,
  importOauthTokenKey,
  providerConfig,
} from "./oauth-broker";
import { acquireRefreshLock, releaseRefreshLock } from "./rate-limit";
import type { AppEnv } from "./types";

// Dev-only: these upstream endpoints are undocumented best-effort surfaces,
// and vendor ToS limits subscription auth to personal interactive use.
const proxy = new Hono<AppEnv>();
const refreshLeewayMs = 60_000;
// Fallback TTL applied when a provider's refresh response omits expires_in,
// so proactive refresh keeps firing instead of being disabled forever by a
// stored NULL expiry.
const defaultRefreshTtlMs = 55 * 60 * 1000;
const openaiUpstream = "https://chatgpt.com/backend-api/codex/responses";
const xaiUpstream = "https://cli-chat-proxy.grok.com/v1/chat/completions";

proxy.post("/:provider/chat/completions", async (context) => {
  const provider = context.req.param("provider");
  if (provider !== "openai" && provider !== "xai")
    return context.json({ error: "Not connected" }, 404);
  const body = await boundedJson(context.req.raw);
  if (!body) return context.json({ error: "Invalid request" }, 400);
  const tokenKey = context.env.OAUTH_TOKEN_KEY
    ? await importOauthTokenKey(context.env.OAUTH_TOKEN_KEY)
    : null;
  if (!tokenKey) return context.json({ error: "Not connected" }, 503);
  const uid = context.get("auth").uid;
  const connection = await context.env.DB.prepare(
    "SELECT access_token, refresh_token, account_id, expires_at FROM oauth_connections WHERE uid = ?1 AND provider = ?2",
  )
    .bind(uid, provider)
    .first<{
      access_token: string;
      refresh_token: string | null;
      account_id: string | null;
      expires_at: number | null;
    }>();
  if (!connection) return context.json({ error: "Not connected" }, 404);
  let accessToken = await decryptOauthToken(tokenKey, connection.access_token);
  if (accessToken === null)
    return context.json({ error: "Reconnect required" }, 401);
  const now = Date.now();
  if (
    connection.expires_at !== null &&
    connection.expires_at <= now + refreshLeewayMs
  ) {
    const config = connection.refresh_token
      ? await providerConfig(provider, context.env)
      : null;
    if (!config || !connection.refresh_token)
      return context.json({ error: "Reconnect required" }, 401);
    const refreshToken = await decryptOauthToken(
      tokenKey,
      connection.refresh_token,
    );
    if (refreshToken === null)
      return context.json({ error: "Reconnect required" }, 401);
    // Serialize concurrent refreshes for the same (uid, provider): firing
    // the provider's refresh endpoint twice with the same refresh token can
    // trigger reuse-detection revocation on strict providers.
    const lockKey = `oauth-refresh:${uid}:${provider}`;
    const acquired = await acquireRefreshLock(context.env, lockKey);
    if (!acquired)
      return context.json({ error: "Refresh in progress, retry" }, 409);
    try {
      let refreshed: Record<string, unknown> | null = null;
      try {
        const response = await fetch(config.tokenEndpoint, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            client_id: config.clientId,
            grant_type: "refresh_token",
            refresh_token: refreshToken,
          }),
        });
        if (response.ok)
          refreshed = (await response.json()) as Record<string, unknown>;
      } catch {}
      if (!refreshed || typeof refreshed.access_token !== "string")
        return context.json({ error: "Reconnect required" }, 401);
      accessToken = refreshed.access_token;
      const rotatedRefresh =
        typeof refreshed.refresh_token === "string"
          ? await encryptOauthToken(tokenKey, refreshed.refresh_token)
          : connection.refresh_token;
      const expiresAt =
        typeof refreshed.expires_in === "number"
          ? now + refreshed.expires_in * 1000
          : now + defaultRefreshTtlMs;
      const rotation = await context.env.DB.prepare(
        "UPDATE oauth_connections SET access_token = ?1, refresh_token = ?2, expires_at = ?3, updated_at = ?4 WHERE uid = ?5 AND provider = ?6 AND refresh_token = ?7",
      )
        .bind(
          await encryptOauthToken(tokenKey, accessToken),
          rotatedRefresh,
          expiresAt,
          now,
          uid,
          provider,
          connection.refresh_token,
        )
        .run();
      if (rotation.meta.changes === 0) {
        const winner = await context.env.DB.prepare(
          "SELECT access_token FROM oauth_connections WHERE uid = ?1 AND provider = ?2",
        )
          .bind(uid, provider)
          .first<{ access_token: string }>();
        const winnerToken = winner
          ? await decryptOauthToken(tokenKey, winner.access_token)
          : null;
        if (winnerToken === null)
          return context.json({ error: "Reconnect required" }, 401);
        accessToken = winnerToken;
      }
    } finally {
      await releaseRefreshLock(context.env, lockKey);
    }
  }
  const headers: Record<string, string> = {
    authorization: `Bearer ${accessToken}`,
    "content-type": "application/json",
  };
  if (provider === "openai") {
    headers.originator = "omi";
    if (connection.account_id)
      headers["chatgpt-account-id"] = connection.account_id;
  }
  let upstream: Response;
  try {
    upstream = await fetch(
      provider === "openai" ? openaiUpstream : xaiUpstream,
      {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      },
    );
  } catch {
    return context.json({ error: "Provider unavailable" }, 502);
  }
  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "cache-control": "no-store",
      "content-type":
        upstream.headers.get("content-type") ?? "application/json",
      "x-content-type-options": "nosniff",
    },
  });
});

export default proxy;
