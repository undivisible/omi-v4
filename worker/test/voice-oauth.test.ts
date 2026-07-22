import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import routes from "../src/routes";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
const originalFetch = globalThis.fetch;

const request = (
  uid: string,
  path: string,
  init?: RequestInit,
  environment: Partial<Bindings> = {},
) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/", routes);
  return app.request(path, init, {
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    ...environment,
  } as Bindings);
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  const sql = await Bun.file("migrations/0019_oauth_connections.sql").text();
  for (const statement of sql.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
  }
});

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("gemini live tokens", () => {
  test("503 when the key or model is unconfigured", async () => {
    const response = await request("alpha", "/voice/gemini/token", {
      method: "POST",
    });
    expect(response.status).toBe(503);
  });

  test("mints a model-locked ephemeral token without leaking the key", async () => {
    let upstreamBody: Record<string, unknown> | undefined;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      const url = String(input);
      expect(url).toBe(
        "https://generativelanguage.googleapis.com/v1alpha/auth_tokens",
      );
      upstreamBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Response.json({ name: "auth_tokens/ephemeral-123" });
    }) as typeof fetch;
    const response = await request(
      "alpha",
      "/voice/gemini/token",
      { method: "POST" },
      {
        GEMINI_API_KEY: "gemini-secret",
        GEMINI_LIVE_MODEL: "gemini-3.1-flash-live-preview",
      },
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.token).toBe("auth_tokens/ephemeral-123");
    expect(body.model).toBe("gemini-3.1-flash-live-preview");
    expect(JSON.stringify(body)).not.toContain("gemini-secret");
    expect(upstreamBody?.uses).toBe(1);
    expect(
      (upstreamBody?.liveConnectConstraints as Record<string, unknown>)?.model,
    ).toBe("gemini-3.1-flash-live-preview");
  });
});

describe("oauth broker", () => {
  test("unconfigured providers return 503", async () => {
    const response = await request("alpha", "/oauth/openai/device/start", {
      method: "POST",
    });
    expect(response.status).toBe(503);
  });

  test("device flow stores tokens per uid and reports status", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/device/code")
        return Response.json({
          device_code: "device-1",
          user_code: "ABCD-EFGH",
          verification_uri: "https://auth.openai.com/activate",
          interval: 5,
          expires_in: 900,
        });
      if (url === "https://auth.openai.com/oauth/token")
        return Response.json({
          access_token: "subscription-access",
          refresh_token: "subscription-refresh",
          expires_in: 3600,
        });
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const environment = { OPENAI_OAUTH_CLIENT_ID: "app_test" };

    const start = await request(
      "alpha",
      "/oauth/openai/device/start",
      { method: "POST" },
      environment,
    );
    expect(start.status).toBe(200);
    const startBody = (await start.json()) as Record<string, unknown>;
    expect(startBody.userCode).toBe("ABCD-EFGH");

    const poll = await request(
      "alpha",
      "/oauth/openai/device/poll",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ deviceCode: "device-1" }),
      },
      environment,
    );
    expect(poll.status).toBe(200);
    expect(((await poll.json()) as Record<string, unknown>).connected).toBe(
      true,
    );

    const status = await request(
      "alpha",
      "/oauth/status",
      undefined,
      environment,
    );
    const statusBody = (await status.json()) as {
      connections: Array<{ provider: string }>;
    };
    expect(statusBody.connections.map((row) => row.provider)).toEqual([
      "openai",
    ]);
    expect(JSON.stringify(statusBody)).not.toContain("subscription-access");

    const other = await request(
      "beta",
      "/oauth/status",
      undefined,
      environment,
    );
    expect(
      ((await other.json()) as { connections: unknown[] }).connections,
    ).toEqual([]);

    const disconnect = await request(
      "alpha",
      "/oauth/openai",
      { method: "DELETE" },
      environment,
    );
    expect(disconnect.status).toBe(200);
    const after = await request(
      "alpha",
      "/oauth/status",
      undefined,
      environment,
    );
    expect(
      ((await after.json()) as { connections: unknown[] }).connections,
    ).toEqual([]);
  });

  test("pending authorization surfaces as 202 without storing", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token")
        return Response.json(
          { error: "authorization_pending" },
          { status: 400 },
        );
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const poll = await request(
      "alpha",
      "/oauth/openai/device/poll",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ deviceCode: "device-2" }),
      },
      { OPENAI_OAUTH_CLIENT_ID: "app_test" },
    );
    expect(poll.status).toBe(202);
    expect(((await poll.json()) as Record<string, unknown>).pending).toBe(true);
  });
});
