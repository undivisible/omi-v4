import { Hono } from "hono";
import { requireAuth } from "./auth";
import desktopAuth from "./desktop-auth";
import { reconcileManagedAssistantRequests } from "./assistant";
import { deliverDueChannelMessages } from "./delivery";
export { AssistantAdmission } from "./assistant-admission";
export { DeliveryCoordinator } from "./delivery";
import routes from "./routes";
import type { AppEnv } from "./types";
import webhooks from "./webhooks";

export const app = new Hono<AppEnv>();

app.get("/health", (context) =>
  context.json({ service: "omi-v4-api", status: "ok" }),
);
app.route("/v1/webhooks", webhooks);
app.route("/v1/auth/desktop", desktopAuth);
app.use("/v1/*", requireAuth);
app.route("/v1", routes);
app.notFound((context) => context.json({ error: "Not found" }, 404));

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
        reconcileManagedAssistantRequests(env),
      ]).then(() => undefined),
    );
  },
};
