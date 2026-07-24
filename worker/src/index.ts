import { Hono } from "hono";
import { requireAuth } from "./auth";
import desktopAuth from "./desktop-auth";
import { reconcileManagedAssistantRequests } from "./assistant";
import { deliverDueChannelMessages } from "./delivery";
import { generateDueDigests } from "./digests";
import { respondToStaleInboxItems } from "./inbox-fallback";
import mcp from "./mcp";
import { backfillClaimVectors, drainPendingEmbeddings } from "./memory-vectors";
import { createSentry, pingHeartbeat, shipTailEvents } from "./observability";
import publicApi from "./public-api";
export { AssistantAdmission } from "./assistant-admission";
export { SttAdmission } from "./stt-admission";
export { DeliveryCoordinator } from "./delivery";
export { FaceTimeBridge } from "./facetime-bridge";
export { RateLimiter } from "./rate-limit";
import routes from "./routes";
import { reconcileStripeSubscriptions } from "./stripe-sync";
import type { AppEnv } from "./types";
import webhooks from "./webhooks";

export const app = new Hono<AppEnv>();

app.get("/health", (context) =>
  context.json({ service: "omi-v4-api", status: "ok" }),
);
// Every "Open Omi" and "API login" link on the site points at
// api.omi.tsc.hk/portal, which is the signed-in hub web app (public/portal/,
// built by scripts/build-portal.sh) under a stable name — not the seeded demo
// at /hub/. Static assets are served ahead of the Worker, so in production
// this handler is reached only when the asset layer does not canonicalise the
// directory itself; either way the app is what answers, and the fragment
// (#api-keys) is preserved by the browser across the redirect.
app.get("/portal", (context) => context.redirect("/portal/", 302));
app.route("/v1/webhooks", webhooks);
app.route("/v1/auth/desktop", desktopAuth);
app.use("/v1/*", requireAuth);
app.route("/v1", routes);
// Third-party surfaces. They live outside `/v1/*` so the Firebase-only
// middleware above cannot be widened by accident; each carries its own
// middleware accepting an API key or a Firebase ID token.
app.route("/api/v1", publicApi);
app.route("/mcp", mcp);
app.notFound((context) => context.json({ error: "Not found" }, 404));
// Report unhandled request errors to Better Stack (Sentry-compatible) when a
// DSN is configured, then rethrow so the runtime's default 500 behavior is
// unchanged. With no DSN, createSentry returns null and this is a plain rethrow.
app.onError((error, context) => {
  createSentry(
    context.env,
    context.executionCtx,
    context.req.raw,
  )?.captureException(error);
  throw error;
});

export default {
  fetch: app.fetch,
  scheduled(
    _controller: ScheduledController,
    env: AppEnv["Bindings"],
    context: ExecutionContext,
  ) {
    context.waitUntil(
      Promise.all([
        // Digests are generated before deliveries drain, so a digest that
        // enters the queue this tick can be picked up in the same batch.
        generateDueDigests(env)
          .then(() => deliverDueChannelMessages(env))
          .catch(() => undefined),
        respondToStaleInboxItems(env).catch(() => undefined),
        reconcileManagedAssistantRequests(env),
        // A Stripe webhook that never arrives would otherwise leave a paying
        // customer with nothing, silently and permanently. This re-reads a
        // bounded handful of stale subscriptions per tick.
        reconcileStripeSubscriptions(env).catch(() => undefined),
        backfillClaimVectors(env)
          .then(() => drainPendingEmbeddings(env))
          .catch(() => undefined),
      ])
        // Ping the Better Stack heartbeat only when the whole cron batch
        // resolves; a rejection skips the ping so Better Stack alerts on the
        // missed beat. No-op when BETTERSTACK_HEARTBEAT_URL is unset.
        .then(() => pingHeartbeat(env))
        .catch((error) => {
          createSentry(env, context)?.captureException(error);
        }),
    );
  },
  // Tail consumer: export invocation logs to Better Stack Logs. No-op unless
  // BETTERSTACK_LOGS_URL + BETTERSTACK_LOGS_TOKEN are set. See
  // docs/ai-and-observability.md for the Logpush alternative (dashboard-configured).
  tail(events: unknown, env: AppEnv["Bindings"], context: ExecutionContext) {
    context.waitUntil(shipTailEvents(env, events));
  },
};
