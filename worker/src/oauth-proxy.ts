import { Hono } from "hono";
import { boundedJson } from "./assistant";
import { providerConfig } from "./oauth-broker";
import type { AppEnv } from "./types";

// Dev-only: these upstream endpoints are undocumented best-effort surfaces,
// and vendor ToS limits subscription auth to personal interactive use.
const proxy = new Hono<AppEnv>();
const refreshLeewayMs = 60_000;
const openaiUpstream = "https://chatgpt.com/backend-api/codex/responses";
const xaiUpstream = "https://cli-chat-proxy.grok.com/v1/chat/completions";

proxy.post("/:provider/chat/completions", async (context) => {
  const provider = context.req.param("provider");
  if (provider !== "openai" && provider !== "xai")
    return context.json({ error: "Not connected" }, 404);
  const body = await boundedJson(context.req.raw);
  if (!body) return context.json({ error: "Invalid request" }, 400);
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
  let accessToken = connection.access_token;
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
    let refreshed: Record<string, unknown> | null = null;
    try {
      const response = await fetch(config.tokenEndpoint, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: config.clientId,
          grant_type: "refresh_token",
          refresh_token: connection.refresh_token,
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
        ? refreshed.refresh_token
        : connection.refresh_token;
    const expiresAt =
      typeof refreshed.expires_in === "number"
        ? now + refreshed.expires_in * 1000
        : null;
    await context.env.DB.prepare(
      "UPDATE oauth_connections SET access_token = ?1, refresh_token = ?2, expires_at = ?3, updated_at = ?4 WHERE uid = ?5 AND provider = ?6",
    )
      .bind(accessToken, rotatedRefresh, expiresAt, now, uid, provider)
      .run();
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
