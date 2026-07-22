import { Hono, type Context } from "hono";
import { hasActivePro } from "./entitlement";
import {
  admitAssistantRequest,
  releaseAssistantRequest,
  settleAssistantRequest,
} from "./assistant-admission";
import type { AppEnv } from "./types";

const assistant = new Hono<AppEnv>();
const maximumBodyBytes = 64 * 1024;
const maximumMessages = 64;
const maximumInputCharacters = 32_000;
const maximumOutputTokens = 4096;
const defaultOutputTokens = 1024;
const requestFramingTokenReserve = 64;
const messageFramingTokenReserve = 16;
const upstreamTimeoutMs = 45_000;
const staleRequestMs = 120_000;
export const xiaomiCompletionEndpoint =
  "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions";
const allowedKeys = new Set([
  "messages",
  "model",
  "stream",
  "max_tokens",
  "temperature",
  "top_p",
  "stream_options",
]);

type Message = { role: "assistant" | "system" | "user"; content: string };
type CompletionRequest = {
  messages: Message[];
  model: string;
  stream: true;
  max_tokens: number;
  temperature?: number;
  top_p?: number;
};

export const validatePinnedEndpoint = (
  endpoint: string,
  pinned: string,
  hostname: string,
): URL | null => {
  try {
    const endpointUrl = new URL(endpoint);
    if (
      endpoint !== pinned ||
      endpointUrl.href !== pinned ||
      endpointUrl.protocol !== "https:" ||
      endpointUrl.username !== "" ||
      endpointUrl.password !== "" ||
      endpointUrl.search !== "" ||
      endpointUrl.hash !== "" ||
      endpointUrl.hostname !== hostname
    )
      return null;
    return endpointUrl;
  } catch {
    return null;
  }
};

export const boundedJson = async (
  request: Request,
  limit = maximumBodyBytes,
): Promise<Record<string, unknown> | null> => {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) return null;
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as unknown;
    return parsed !== null &&
      typeof parsed === "object" &&
      !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
};

const parseRequest = (
  body: Record<string, unknown>,
  model: string,
): CompletionRequest | null => {
  if (Object.keys(body).some((key) => !allowedKeys.has(key))) return null;
  if (body.model !== model || body.stream !== true) return null;
  if (!Array.isArray(body.messages) || body.messages.length > maximumMessages)
    return null;
  const messages: Message[] = [];
  let inputCharacters = 0;
  for (const candidate of body.messages) {
    if (
      candidate === null ||
      typeof candidate !== "object" ||
      Array.isArray(candidate)
    )
      return null;
    const value = candidate as Record<string, unknown>;
    if (
      Object.keys(value).some((key) => key !== "role" && key !== "content") ||
      (value.role !== "assistant" &&
        value.role !== "system" &&
        value.role !== "user") ||
      typeof value.content !== "string" ||
      value.content.length === 0
    )
      return null;
    inputCharacters += value.content.length;
    if (inputCharacters > maximumInputCharacters) return null;
    messages.push({ role: value.role, content: value.content });
  }
  if (messages.length === 0) return null;
  const streamOptions = body.stream_options;
  if (
    streamOptions === null ||
    typeof streamOptions !== "object" ||
    Array.isArray(streamOptions) ||
    Object.keys(streamOptions).length !== 1 ||
    (streamOptions as Record<string, unknown>).include_usage !== true
  )
    return null;
  const maxTokens =
    body.max_tokens === undefined
      ? defaultOutputTokens
      : Number(body.max_tokens);
  if (
    !Number.isSafeInteger(maxTokens) ||
    maxTokens < 1 ||
    maxTokens > maximumOutputTokens
  )
    return null;
  const temperature = body.temperature;
  const topP = body.top_p;
  if (
    (temperature !== undefined &&
      (typeof temperature !== "number" ||
        temperature < 0 ||
        temperature > 2)) ||
    (topP !== undefined && (typeof topP !== "number" || topP <= 0 || topP > 1))
  )
    return null;
  return {
    model,
    messages,
    stream: true,
    max_tokens: maxTokens,
    ...(temperature === undefined ? {} : { temperature }),
    ...(topP === undefined ? {} : { top_p: topP }),
  };
};

const usageFrom = (text: string) => {
  let inputTokens: number | null = null;
  let outputTokens: number | null = null;
  for (const line of text.split("\n")) {
    if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
    try {
      const value = JSON.parse(line.slice(6)) as {
        usage?: { prompt_tokens?: unknown; completion_tokens?: unknown };
      };
      if (
        typeof value.usage?.prompt_tokens === "number" &&
        Number.isSafeInteger(value.usage.prompt_tokens) &&
        value.usage.prompt_tokens >= 0
      )
        inputTokens = value.usage.prompt_tokens;
      if (
        typeof value.usage?.completion_tokens === "number" &&
        Number.isSafeInteger(value.usage.completion_tokens) &&
        value.usage.completion_tokens >= 0
      )
        outputTokens = value.usage.completion_tokens;
    } catch {}
  }
  return { inputTokens, outputTokens };
};

export const price = (value: string | undefined): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

const costFor = (
  inputTokens: number,
  outputTokens: number,
  inputPrice: number,
  outputPrice: number,
): number =>
  Math.ceil(
    (inputTokens * inputPrice + outputTokens * outputPrice) / 1_000_000,
  );

const inputTokenReservation = (messages: Message[]): number => {
  const encoder = new TextEncoder();
  return messages.reduce(
    (total, message) =>
      total +
      messageFramingTokenReserve +
      encoder.encode(message.role).byteLength +
      encoder.encode(message.content).byteLength,
    requestFramingTokenReserve,
  );
};

const cancelBody = async (
  body: ReadableStream<Uint8Array> | null,
  reason?: unknown,
): Promise<void> => {
  try {
    await body?.cancel(reason);
  } catch {}
};

export const finalizeCancelledStream = async (
  cancel: () => Promise<void>,
  finalize: () => Promise<void>,
): Promise<void> => {
  try {
    await cancel();
  } catch {
  } finally {
    await finalize();
  }
};

export const retry = async (operation: () => Promise<void>): Promise<void> => {
  let failure: unknown;
  for (const delay of [0, 25, 100]) {
    if (delay > 0)
      await new Promise<void>((resolve) => setTimeout(resolve, delay));
    try {
      await operation();
      return;
    } catch (error) {
      failure = error;
    }
  }
  throw failure;
};

const defer = (context: Context<AppEnv>, operation: Promise<void>): void => {
  try {
    context.executionCtx.waitUntil(operation);
  } catch {
    void operation.catch(() => undefined);
  }
};

type FinalStatus = "cancelled" | "complete" | "failed" | "timeout";

const releaseDurably = async (
  context: Context<AppEnv>,
  requestId: string,
  usage?: { tokenBudget: number; costBudgetMicrousd: number },
): Promise<void> => {
  const operation = () =>
    usage
      ? settleAssistantRequest(
          context.env,
          requestId,
          usage.tokenBudget,
          usage.costBudgetMicrousd,
        )
      : releaseAssistantRequest(context.env, requestId);
  const markSettled = () =>
    context.env.DB.prepare(
      "UPDATE managed_ai_requests SET admission_settled_at = COALESCE(admission_settled_at, ?1), updated_at = ?1 WHERE id = ?2",
    )
      .bind(Date.now(), requestId)
      .run()
      .then(() => undefined);
  try {
    await retry(operation);
  } catch {
    defer(context, retry(operation).then(markSettled));
    return;
  }
  try {
    await retry(markSettled);
  } catch {
    defer(context, retry(markSettled));
  }
};

const finalizeRequest = async (
  context: Context<AppEnv>,
  requestId: string,
  status: FinalStatus,
  inputTokens: number | null,
  outputTokens: number | null,
  actualCostMicrousd: number | null,
  upstreamStatus: number | null = null,
): Promise<void> => {
  const persist = () =>
    context.env.DB.prepare(
      `UPDATE managed_ai_requests
       SET status = ?1, input_tokens = COALESCE(?2, input_tokens),
           output_tokens = COALESCE(?3, output_tokens),
           actual_cost_microusd = COALESCE(?4, actual_cost_microusd),
           upstream_status = COALESCE(?5, upstream_status),
           finalization_attempts = finalization_attempts + 1,
           finalized_at = COALESCE(finalized_at, ?6), updated_at = ?6
       WHERE id = ?7 AND finalized_at IS NULL`,
    )
      .bind(
        status,
        inputTokens,
        outputTokens,
        actualCostMicrousd,
        upstreamStatus,
        Date.now(),
        requestId,
      )
      .run()
      .then(() => undefined);
  let persisted = true;
  try {
    await retry(persist);
  } catch {
    persisted = false;
    defer(
      context,
      retry(persist).then(() =>
        releaseDurably(
          context,
          requestId,
          inputTokens !== null &&
            outputTokens !== null &&
            actualCostMicrousd !== null
            ? {
                tokenBudget: inputTokens + outputTokens,
                costBudgetMicrousd: actualCostMicrousd,
              }
            : undefined,
        ),
      ),
    );
  }
  if (!persisted) return;
  await releaseDurably(
    context,
    requestId,
    inputTokens !== null && outputTokens !== null && actualCostMicrousd !== null
      ? {
          tokenBudget: inputTokens + outputTokens,
          costBudgetMicrousd: actualCostMicrousd,
        }
      : undefined,
  );
};

export const reconcileManagedAssistantRequests = async (
  env: AppEnv["Bindings"],
  now = Date.now(),
): Promise<void> => {
  const stale = await env.DB.prepare(
    `SELECT id, finalized_at, input_tokens, output_tokens, actual_cost_microusd
     FROM managed_ai_requests
     WHERE admission_settled_at IS NULL AND (
       finalized_at IS NOT NULL OR
       (status IN ('started', 'streaming') AND updated_at <= ?1)
     ) LIMIT 100`,
  )
    .bind(now - staleRequestMs)
    .all<{
      id: string;
      finalized_at: number | null;
      input_tokens: number | null;
      output_tokens: number | null;
      actual_cost_microusd: number | null;
    }>();
  await Promise.all(
    (stale.results ?? []).map(async (row) => {
      const { id } = row;
      if (row.finalized_at === null)
        await retry(() =>
          env.DB.prepare(
            `UPDATE managed_ai_requests
             SET status = 'failed', finalization_attempts = finalization_attempts + 1,
                 finalized_at = COALESCE(finalized_at, ?1), updated_at = ?1
             WHERE id = ?2 AND finalized_at IS NULL`,
          )
            .bind(now, id)
            .run()
            .then(() => undefined),
        );
      const hasUsage =
        row.input_tokens !== null &&
        row.output_tokens !== null &&
        row.actual_cost_microusd !== null;
      await retry(() =>
        hasUsage
          ? settleAssistantRequest(
              env,
              id,
              row.input_tokens! + row.output_tokens!,
              row.actual_cost_microusd!,
            )
          : releaseAssistantRequest(env, id),
      );
      await retry(() =>
        env.DB.prepare(
          "UPDATE managed_ai_requests SET admission_settled_at = COALESCE(admission_settled_at, ?1), updated_at = ?1 WHERE id = ?2",
        )
          .bind(now, id)
          .run()
          .then(() => undefined),
      );
    }),
  );
};

assistant.post("/chat/completions", async (context) => {
  const endpoint = context.env.MIMO_CHAT_COMPLETIONS_URL;
  const secret = context.env.MIMO_API_KEY;
  const model = context.env.MIMO_MODEL;
  if (!endpoint || !secret || !model)
    return context.json({ error: "Managed AI unavailable" }, 503);
  const endpointUrl = validatePinnedEndpoint(
    endpoint,
    xiaomiCompletionEndpoint,
    "token-plan-sgp.xiaomimimo.com",
  );
  if (!endpointUrl)
    return context.json({ error: "Managed AI unavailable" }, 503);
  const body = await boundedJson(context.req.raw);
  const parsed = body ? parseRequest(body, model) : null;
  if (!parsed) return context.json({ error: "Invalid request" }, 400);
  const auth = context.get("auth");
  if (!(await hasActivePro(context.env, auth.uid)))
    return context.json({ error: "Managed Pro required" }, 403);
  const now = Date.now();
  const requestId = crypto.randomUUID();
  const inputCharacters = parsed.messages.reduce(
    (total, message) => total + message.content.length,
    0,
  );
  const estimatedInputTokens = inputTokenReservation(parsed.messages);
  const inputPrice = price(context.env.MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS);
  const outputPrice = price(
    context.env.MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS,
  );
  if (inputPrice === null || outputPrice === null)
    return context.json({ error: "Managed AI unavailable" }, 503);
  const estimatedCost = costFor(
    estimatedInputTokens,
    parsed.max_tokens,
    inputPrice,
    outputPrice,
  );
  let admission: Response;
  try {
    admission = await admitAssistantRequest(
      context.env,
      requestId,
      auth.uid,
      estimatedInputTokens + parsed.max_tokens,
      estimatedCost,
    );
  } catch {
    await releaseDurably(context, requestId);
    return context.json({ error: "Managed AI unavailable" }, 503);
  }
  if (!admission.ok)
    return context.json(
      { error: "Managed AI capacity exceeded" },
      429,
      admission.headers.get("retry-after")
        ? { "retry-after": admission.headers.get("retry-after") as string }
        : undefined,
    );
  try {
    await context.env.DB.prepare(
      `INSERT INTO managed_ai_requests
       (id, uid, provider, model, status, input_characters, requested_max_output_tokens,
        estimated_cost_microusd, created_at, updated_at)
     VALUES (?1, ?2, 'mimo', ?3, 'started', ?4, ?5, ?6, ?7, ?7)`,
    )
      .bind(
        requestId,
        auth.uid,
        model,
        inputCharacters,
        parsed.max_tokens,
        estimatedCost,
        now,
      )
      .run();
  } catch {
    await releaseDurably(context, requestId);
    return context.json({ error: "Managed AI unavailable" }, 503);
  }
  const abort = new AbortController();
  const onClientAbort = () => abort.abort();
  context.req.raw.signal.addEventListener("abort", onClientAbort, {
    once: true,
  });
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    abort.abort();
  }, upstreamTimeoutMs);
  let upstream: Response;
  try {
    upstream = await fetch(endpointUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${secret}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        ...parsed,
        stream_options: { include_usage: true },
      }),
      signal: abort.signal,
    });
  } catch {
    clearTimeout(timeout);
    context.req.raw.signal.removeEventListener("abort", onClientAbort);
    await finalizeRequest(
      context,
      requestId,
      timedOut ? "timeout" : "failed",
      null,
      null,
      null,
    );
    return context.json(
      {
        error: timedOut ? "Managed AI timed out" : "Managed AI unavailable",
      },
      timedOut ? 504 : 502,
    );
  }
  if (!upstream.ok || !upstream.body) {
    clearTimeout(timeout);
    context.req.raw.signal.removeEventListener("abort", onClientAbort);
    await cancelBody(upstream.body);
    await finalizeRequest(
      context,
      requestId,
      "failed",
      null,
      null,
      null,
      upstream.status,
    );
    return context.json({ error: "Managed AI unavailable" }, 502);
  }
  try {
    await retry(() =>
      context.env.DB.prepare(
        "UPDATE managed_ai_requests SET status = 'streaming', upstream_status = ?1, updated_at = ?2 WHERE id = ?3",
      )
        .bind(upstream.status, Date.now(), requestId)
        .run()
        .then(() => undefined),
    );
  } catch {
    clearTimeout(timeout);
    context.req.raw.signal.removeEventListener("abort", onClientAbort);
    await cancelBody(upstream.body);
    await finalizeRequest(
      context,
      requestId,
      "failed",
      null,
      null,
      null,
      upstream.status,
    );
    return context.json({ error: "Managed AI unavailable" }, 503);
  }
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let usageTail = "";
  let finalized = false;
  const finalize = async (
    status: "cancelled" | "complete" | "failed" | "timeout",
  ) => {
    if (finalized) return;
    finalized = true;
    clearTimeout(timeout);
    context.req.raw.signal.removeEventListener("abort", onClientAbort);
    const usage = usageFrom(usageTail);
    const actualCost =
      usage.inputTokens !== null && usage.outputTokens !== null
        ? costFor(
            usage.inputTokens,
            usage.outputTokens,
            inputPrice,
            outputPrice,
          )
        : null;
    await finalizeRequest(
      context,
      requestId,
      status,
      usage.inputTokens,
      usage.outputTokens,
      actualCost,
    );
  };
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const chunk = await reader.read();
        if (chunk.done) {
          usageTail += decoder.decode();
          await finalize("complete");
          controller.close();
          return;
        }
        usageTail = (
          usageTail + decoder.decode(chunk.value, { stream: true })
        ).slice(-16_384);
        controller.enqueue(chunk.value);
      } catch {
        await finalize(timedOut ? "timeout" : "failed");
        controller.error(new Error("Managed AI stream interrupted"));
      }
    },
    async cancel(reason) {
      abort.abort();
      await finalizeCancelledStream(
        () => reader.cancel(reason),
        () => finalize("cancelled"),
      );
    },
  });
  return new Response(stream, {
    status: 200,
    headers: {
      "cache-control": "no-store",
      "content-type": "text/event-stream; charset=utf-8",
      "x-omi-request-id": requestId,
      "x-content-type-options": "nosniff",
    },
  });
});

export default assistant;
