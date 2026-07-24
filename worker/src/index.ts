import { Hono } from "hono";
import { requireAuth } from "./auth";
import desktopAuth from "./desktop-auth";
import { reconcileManagedAssistantRequests } from "./assistant";
import { deliverDueChannelMessages } from "./delivery";
import { respondToStaleInboxItems } from "./inbox-fallback";
import mcp from "./mcp";
import { backfillClaimVectors, drainPendingEmbeddings } from "./memory-vectors";
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

// Better Stack heartbeat. Unset in development, so the ping simply does not
// happen rather than failing.
const pingHeartbeat = async (env: AppEnv["Bindings"]): Promise<void> => {
  const url = env.HEARTBEAT_URL?.trim();
  if (!url || !url.startsWith("https://")) return;
  try {
    await fetch(url, {
      method: "POST",
      signal: AbortSignal.timeout(5_000),
    });
  } catch {}
};

export default {
  fetch: app.fetch,
  scheduled(
    _controller: ScheduledController,
    env: AppEnv["Bindings"],
    context: ExecutionContext,
  ) {
    context.waitUntil(
      Promise.all([
        deliverDueChannelMessages(env),
        respondToStaleInboxItems(env).catch(() => undefined),
        reconcileManagedAssistantRequests(env),
        // A Stripe webhook that never arrives would otherwise leave a paying
        // customer with nothing, silently and permanently. This re-reads a
        // bounded handful of stale subscriptions per tick.
        reconcileStripeSubscriptions(env).catch(() => undefined),
        backfillClaimVectors(env)
          .then(() => drainPendingEmbeddings(env))
          .catch(() => undefined),
        // The heartbeat is what turns Better Stack's monitoring from "the API
        // answers" into "the cron is still running". It is fire-and-forget:
        // a monitoring outage must never fail the scheduled work it watches.
        pingHeartbeat(env),
      ]).then(() => undefined),
    );
  },
};
