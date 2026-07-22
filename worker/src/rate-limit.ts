import type { Bindings } from "./types";

// Lightweight abuse-prevention primitives backed by a Durable Object per
// key: a fixed-window request counter for rate limiting, and a short-lived
// mutex for serializing concurrent OAuth token refreshes. Not billing
// critical — simple and good enough to stop obvious abuse.
export class RateLimiter {
  constructor(
    readonly state: DurableObjectState,
    readonly env: Bindings,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response(null, { status: 405 });
    if (url.pathname === "/consume") return this.consume(request);
    if (url.pathname === "/acquire-lock") return this.acquireLock(request);
    if (url.pathname === "/release-lock") return this.releaseLock();
    return new Response(null, { status: 404 });
  }

  private async consume(request: Request): Promise<Response> {
    const body = (await request.json()) as {
      limit?: unknown;
      windowMs?: unknown;
    };
    const limit =
      typeof body.limit === "number" && body.limit > 0 ? body.limit : 60;
    const windowMs =
      typeof body.windowMs === "number" && body.windowMs > 0
        ? body.windowMs
        : 60_000;
    const now = Date.now();
    const stored = await this.state.storage.get<{
      count: number;
      windowStart: number;
    }>("window");
    const startNewWindow = !stored || now - stored.windowStart >= windowMs;
    const windowStart = startNewWindow ? now : stored.windowStart;
    const count = startNewWindow ? 1 : stored.count + 1;
    await this.state.storage.put("window", { count, windowStart });
    const allowed = count <= limit;
    const retryAfter = Math.max(
      1,
      Math.ceil((windowStart + windowMs - now) / 1000),
    );
    return Response.json(
      { allowed, retryAfter },
      {
        status: allowed ? 200 : 429,
        headers: allowed ? undefined : { "retry-after": String(retryAfter) },
      },
    );
  }

  private async acquireLock(request: Request): Promise<Response> {
    const body = (await request.json()) as { ttlMs?: unknown };
    const ttlMs =
      typeof body.ttlMs === "number" && body.ttlMs > 0 ? body.ttlMs : 15_000;
    const now = Date.now();
    const lockUntil = await this.state.storage.get<number>("lockUntil");
    if (lockUntil && lockUntil > now)
      return Response.json({ acquired: false }, { status: 409 });
    await this.state.storage.put("lockUntil", now + ttlMs);
    return Response.json({ acquired: true });
  }

  private async releaseLock(): Promise<Response> {
    await this.state.storage.delete("lockUntil");
    return Response.json({ released: true });
  }
}

const stubFor = (env: Bindings, key: string) => env.RATE_LIMITER.getByName(key);

export const consumeRateLimit = async (
  env: Bindings,
  key: string,
  limit: number,
  windowMs: number,
): Promise<{ allowed: boolean; retryAfter: number }> => {
  const response = await stubFor(env, key).fetch(
    "https://rate-limit.internal/consume",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ limit, windowMs }),
    },
  );
  return (await response.json()) as { allowed: boolean; retryAfter: number };
};

export const acquireRefreshLock = async (
  env: Bindings,
  key: string,
  ttlMs = 15_000,
): Promise<boolean> => {
  const response = await stubFor(env, key).fetch(
    "https://rate-limit.internal/acquire-lock",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ttlMs }),
    },
  );
  return response.ok;
};

export const releaseRefreshLock = async (
  env: Bindings,
  key: string,
): Promise<void> => {
  await stubFor(env, key).fetch("https://rate-limit.internal/release-lock", {
    method: "POST",
  });
};
