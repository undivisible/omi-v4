import { Hono } from "hono";
import { hasActivePro } from "./entitlement";
import {
  boundedJson,
  aiGatewayRoute,
  validatePinnedEndpoint,
  xiaomiCompletionEndpoint,
} from "./assistant";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv } from "./types";

const asr = new Hono<AppEnv>();
const asrModel = "mimo-v2.5-asr";
// Target ceiling on the *decoded* audio payload. Base64 encodes 3 raw bytes
// as 4 characters, so the base64 *character* length allowed must be scaled
// up by 4/3 for real (decoded) audio to be able to reach this size.
const maximumDecodedAudioBytes = 10 * 1024 * 1024;
const maximumAudioBase64Chars = Math.ceil((maximumDecodedAudioBytes * 4) / 3);
const maximumBodyBytes = maximumAudioBase64Chars + 64 * 1024;
const formats = new Set(["wav", "mp3"]);
const languages = new Set(["auto", "zh", "en"]);

asr.post("/transcribe", async (context) => {
  const endpoint = context.env.MIMO_CHAT_COMPLETIONS_URL;
  const secret = context.env.MIMO_API_KEY;
  if (!endpoint || !secret)
    return context.json({ error: "Managed AI unavailable" }, 503);
  const endpointUrl = validatePinnedEndpoint(
    endpoint,
    xiaomiCompletionEndpoint,
    "token-plan-sgp.xiaomimimo.com",
  );
  if (!endpointUrl)
    return context.json({ error: "Managed AI unavailable" }, 503);
  const declared = Number(context.req.raw.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximumBodyBytes)
    return context.json({ error: "Audio too large" }, 413);
  // Reject non-Pro requests before parsing/buffering the (potentially
  // multi-megabyte) body, so ineligible requests are cheap.
  const auth = context.get("auth");
  if (!(await hasActivePro(context.env, auth.uid)))
    return context.json({ error: "Managed Pro required" }, 403);
  const body = await boundedJson(context.req.raw, maximumBodyBytes);
  if (!body) return context.json({ error: "Invalid request" }, 400);
  const audio = body.audio;
  const format = body.format;
  const language = body.language;
  if (typeof audio === "string" && audio.length > maximumAudioBase64Chars)
    return context.json({ error: "Audio too large" }, 413);
  if (
    typeof audio !== "string" ||
    audio.length === 0 ||
    typeof format !== "string" ||
    !formats.has(format) ||
    (language !== undefined &&
      (typeof language !== "string" || !languages.has(language)))
  )
    return context.json({ error: "Invalid request" }, 400);
  const rateLimit = await consumeRateLimit(
    context.env,
    `asr:${auth.uid}`,
    10,
    60_000,
  );
  if (!rateLimit.allowed)
    return context.json({ error: "Too many requests" }, 429, {
      "retry-after": String(rateLimit.retryAfter),
    });
  const now = Date.now();
  const requestId = crypto.randomUUID();
  try {
    await context.env.DB.prepare(
      `INSERT INTO managed_ai_requests
       (id, uid, provider, model, status, input_characters, requested_max_output_tokens,
        created_at, updated_at)
     VALUES (?1, ?2, 'mimo-asr', ?3, 'started', ?4, 0, ?5, ?5)`,
    )
      .bind(requestId, auth.uid, asrModel, audio.length, now)
      .run();
  } catch {
    return context.json({ error: "Managed AI unavailable" }, 503);
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
  const gateway = aiGatewayRoute(context.env);
  let upstream: Response;
  try {
    upstream = await fetch(gateway?.url ?? endpointUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${secret}`,
        "content-type": "application/json",
        ...gateway?.headers,
      },
      body: JSON.stringify({
        model: asrModel,
        messages: [
          {
            role: "user",
            content: [
              { type: "input_audio", input_audio: { data: audio, format } },
            ],
          },
        ],
        ...(language === undefined ? {} : { asr_options: { language } }),
        stream: false,
      }),
    });
  } catch {
    await finalize("failed", null);
    return context.json({ error: "Managed AI unavailable" }, 502);
  }
  if (!upstream.ok) {
    await finalize("failed", upstream.status);
    return context.json({ error: "Managed AI unavailable" }, 502);
  }
  let text: unknown;
  try {
    const completion = (await upstream.json()) as {
      choices?: Array<{ message?: { content?: unknown } }>;
    };
    text = completion.choices?.[0]?.message?.content;
  } catch {
    text = undefined;
  }
  if (typeof text !== "string") {
    await finalize("failed", upstream.status);
    return context.json({ error: "Managed AI unavailable" }, 502);
  }
  await finalize("complete", upstream.status);
  return context.json({ text });
});

export default asr;
