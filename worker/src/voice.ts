import { Hono } from "hono";
import type { AppEnv } from "./types";

// Live voice runs over Gemini's Live API. The Worker mints single-use
// ephemeral tokens locked to the configured live model so clients connect
// to Google directly without ever holding the real API key.
const voice = new Hono<AppEnv>();

const tokenEndpoint =
  "https://generativelanguage.googleapis.com/v1alpha/auth_tokens";

voice.post("/gemini/token", async (context) => {
  const key = context.env.GEMINI_API_KEY;
  const model = context.env.GEMINI_LIVE_MODEL;
  if (!key || !model)
    return context.json({ error: "Live voice unavailable" }, 503);
  const expireTime = new Date(Date.now() + 30 * 60 * 1000).toISOString();
  const newSessionExpireTime = new Date(Date.now() + 60 * 1000).toISOString();
  const response = await fetch(tokenEndpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-goog-api-key": key,
    },
    body: JSON.stringify({
      uses: 1,
      expireTime,
      newSessionExpireTime,
      liveConnectConstraints: { model },
    }),
  });
  if (!response.ok)
    return context.json({ error: "Live voice provider unavailable" }, 502);
  const body = (await response.json()) as { name?: unknown };
  if (typeof body.name !== "string")
    return context.json({ error: "Live voice provider unavailable" }, 502);
  return context.json({
    token: body.name,
    model,
    expireTime,
    newSessionExpireTime,
  });
});

export default voice;
