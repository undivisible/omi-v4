import { Toucan } from "toucan-js";
import type { Bindings } from "./types";

// Better Stack observability wiring. Better Stack's error product is
// Sentry-SDK-compatible, so we point the standard Workers Sentry client
// (toucan-js) at a Better Stack DSN. Everything here is DSN/token-driven and
// no-ops cleanly when the relevant env var is unset, so local dev and CI
// without tokens run unchanged.

// Minimal context shape Toucan needs to flush in the background. Both an
// ExecutionContext and a DurableObjectState satisfy it via `waitUntil`.
type WaitUntilContext = { waitUntil(promise: Promise<unknown>): void };

function resolveDsn(env: Bindings): string | undefined {
  const dsn = env.BETTERSTACK_SENTRY_DSN ?? env.SENTRY_DSN;
  return dsn && dsn.length > 0 ? dsn : undefined;
}

// Returns a configured Sentry client, or null when no DSN is set. Callers must
// treat null as "reporting disabled" and never construct the client otherwise,
// so an unset DSN installs nothing.
export function createSentry(
  env: Bindings,
  context: WaitUntilContext,
  request?: Request,
): Toucan | null {
  const dsn = resolveDsn(env);
  if (!dsn) return null;
  return new Toucan({
    dsn,
    context,
    request,
    environment: env.ENVIRONMENT ?? "development",
    release: env.SENTRY_RELEASE,
    // Do not ship cookies/auth headers or query strings with events.
    requestDataOptions: {
      allowedHeaders: ["user-agent", "cf-ray"],
      allowedSearchParams: [],
    },
  });
}

// Capture an unhandled error from a Durable Object entrypoint. A DurableObjectState
// exposes `waitUntil`, so it doubles as the flush context.
export function captureDurableObjectError(
  env: Bindings,
  context: WaitUntilContext,
  request: Request,
  error: unknown,
): void {
  createSentry(env, context, request)?.captureException(error);
}

// Ping a Better Stack heartbeat monitor after a successful scheduled run. No-op
// when BETTERSTACK_HEARTBEAT_URL is unset. Failures to reach the heartbeat are
// swallowed — a missed ping is Better Stack's signal, not a worker error.
export async function pingHeartbeat(env: Bindings): Promise<void> {
  const url = env.BETTERSTACK_HEARTBEAT_URL;
  if (!url || url.length === 0) return;
  try {
    await fetch(url, { method: "POST" });
  } catch {
    // Intentionally ignored — the missed heartbeat is the alert.
  }
}

// Ship a batch of tail events to Better Stack Logs (OpenTelemetry-native HTTP
// source). No-op unless BOTH the ingest URL and token are set. This is the
// export path; Workers Observability still captures logs natively, so we do
// not additionally log here.
export async function shipTailEvents(
  env: Bindings,
  events: unknown,
): Promise<void> {
  const url = env.BETTERSTACK_LOGS_URL;
  const token = env.BETTERSTACK_LOGS_TOKEN;
  if (!url || url.length === 0 || !token || token.length === 0) return;
  try {
    await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(events),
    });
  } catch {
    // Never let log export failures affect the worker.
  }
}
