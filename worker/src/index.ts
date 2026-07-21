import { Hono } from "hono";
import { requireAuth } from "./auth";
import routes from "./routes";
import type { AppEnv } from "./types";
import webhooks from "./webhooks";

export const app = new Hono<AppEnv>();

app.get("/health", (context) =>
  context.json({ service: "omi-v4-api", status: "ok" }),
);
app.route("/v1/webhooks", webhooks);
app.use("/v1/*", requireAuth);
app.route("/v1", routes);
app.notFound((context) => context.json({ error: "Not found" }, 404));

export default app;
