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
  const auth = context.get("auth");
  const entitlement = await context.env.DB.prepare(
    "SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1",
  )
    .bind(auth.uid)
    .first();
  const now = Date.now();
  if (
    entitlement?.plan !== "pro" ||
    entitlement.status !== "active" ||
    (entitlement.valid_until !== null && Number(entitlement.valid_until) <= now)
  )
    return context.json({ error: "Managed Pro required" }, 403);
  const requestId = crypto.randomUUID();
  try {
    await context.env.DB.prepare(
      `INSERT INTO managed_ai_requests
       (id, uid, provider, model, status, input_characters, requested_max_output_tokens,
        created_at, updated_at)
     VALUES (?1, ?2, 'gemini-live', ?3, 'started', 0, 0, ?4, ?4)`,
    )
      .bind(requestId, auth.uid, model, now)
      .run();
  } catch {
    return context.json({ error: "Live voice unavailable" }, 503);
  }
  const finalize = (
    status: "complete" | "failed",
    upstreamStatus: number | null,
  ) =>
    context.env.DB.prepare(
      `UPDATE managed_ai_requests
       SET status = ?1, upstream_status = ?2, finalization_attempts = finalization_attempts + 1,
           finalized_at = COALESCE(finalized_at, ?3), updated_at = ?3
       WHERE id = ?4 AND finalized_at IS NULL`,
    )
      .bind(status, upstreamStatus, Date.now(), requestId)
      .run()
      .then(() => undefined)
      .catch(() => undefined);
  const expireTime = new Date(now + 10 * 60 * 1000).toISOString();
  const newSessionExpireTime = new Date(now + 60 * 1000).toISOString();
  let response: Response;
  try {
    response = await fetch(tokenEndpoint, {
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
  } catch {
    await finalize("failed", null);
    return context.json({ error: "Live voice provider unavailable" }, 502);
  }
  if (!response.ok) {
    await finalize("failed", response.status);
    return context.json({ error: "Live voice provider unavailable" }, 502);
  }
  const body = (await response.json()) as { name?: unknown };
  if (typeof body.name !== "string") {
    await finalize("failed", response.status);
    return context.json({ error: "Live voice provider unavailable" }, 502);
  }
  await finalize("complete", response.status);
  return context.json({
    token: body.name,
    model,
    expireTime,
    newSessionExpireTime,
  });
});

export default voice;
