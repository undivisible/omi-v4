import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import { decryptOauthToken, importOauthTokenKey } from "../src/oauth-broker";
import routes from "../src/routes";
import type { AppEnv, Bindings } from "../src/types";

const testTokenKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
const originalFetch = globalThis.fetch;

// Minimal in-memory stand-in for the RATE_LIMITER durable object namespace:
// always admits, since these tests exercise the routes' own behavior, not
// the rate limiter.
const fakeRateLimiter = () =>
  ({
    getByName: () => ({
      fetch: async (url: string | URL) => {
        const pathname = new URL(String(url)).pathname;
        if (pathname === "/consume")
          return Response.json({ allowed: true, retryAfter: 0 });
        if (pathname === "/acquire-lock")
          return Response.json({ acquired: true });
        if (pathname === "/release-lock")
          return Response.json({ released: true });
        return new Response(null, { status: 404 });
      },
    }),
  }) as unknown as DurableObjectNamespace;

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
    RATE_LIMITER: fakeRateLimiter(),
    ENABLE_DEV_OAUTH_BROKER: "true",
    ...environment,
  } as Bindings);
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  await database
    .prepare(
      "CREATE TABLE users (uid TEXT PRIMARY KEY, email TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    )
    .run();
  await database
    .prepare(
      "CREATE TABLE entitlements (uid TEXT PRIMARY KEY REFERENCES users(uid), plan TEXT NOT NULL, status TEXT NOT NULL, valid_until INTEGER)",
    )
    .run();
  for (const migration of [
    "migrations/0008_managed_ai.sql",
    "migrations/0019_oauth_connections.sql",
  ]) {
    const sql = await Bun.file(migration).text();
    for (const statement of sql.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users VALUES ('alpha', 'alpha@example.test', ?1, ?1), ('beta', 'beta@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
  await database
    .prepare(
      "INSERT INTO entitlements VALUES ('alpha', 'pro', 'active', NULL), ('beta', 'byok', 'active', NULL)",
    )
    .run();
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

  test("DEV_FAKE_PRO stubs the entitlement gate for local testing", async () => {
    globalThis.fetch = (async () =>
      Response.json({ name: "auth_tokens/ephemeral-stub" })) as typeof fetch;
    const response = await request(
      "beta",
      "/voice/gemini/token",
      { method: "POST" },
      {
        GEMINI_API_KEY: "gemini-secret",
        GEMINI_LIVE_MODEL: "gemini-3.1-flash-live-preview",
        DEV_FAKE_PRO: "true",
      },
    );
    expect(response.status).toBe(200);
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
    // Two uses so one automatic resume after an unexpected session death
    // can authenticate with the same token.
    expect(upstreamBody?.uses).toBe(2);
    expect(
      (upstreamBody?.liveConnectConstraints as Record<string, unknown>)?.model,
    ).toBe("gemini-3.1-flash-live-preview");
    expect(
      new Date(String(body.expireTime)).getTime() - Date.now(),
    ).toBeLessThanOrEqual(10 * 60 * 1000);
    const recorded = await database
      .prepare(
        "SELECT provider, model, status FROM managed_ai_requests WHERE uid = 'alpha' AND provider = 'gemini-live'",
      )
      .first();
    expect(recorded?.model).toBe("gemini-3.1-flash-live-preview");
    expect(recorded?.status).toBe("complete");
  });

  test("403 without a pro entitlement", async () => {
    const response = await request(
      "beta",
      "/voice/gemini/token",
      { method: "POST" },
      {
        GEMINI_API_KEY: "gemini-secret",
        GEMINI_LIVE_MODEL: "gemini-3.1-flash-live-preview",
      },
    );
    expect(response.status).toBe(403);
  });
});

describe("oauth broker", () => {
  test("404s when the dev/testing broker flag is not enabled", async () => {
    const response = await request(
      "alpha",
      "/oauth/openai/device/start",
      { method: "POST" },
      { ENABLE_DEV_OAUTH_BROKER: undefined },
    );
    expect(response.status).toBe(404);
  });

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
    const environment = {
      OPENAI_OAUTH_CLIENT_ID: "app_test",
      OAUTH_TOKEN_KEY: testTokenKey,
    };

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
      { OPENAI_OAUTH_CLIENT_ID: "app_test", OAUTH_TOKEN_KEY: testTokenKey },
    );
    expect(poll.status).toBe(202);
    expect(((await poll.json()) as Record<string, unknown>).pending).toBe(true);
  });

  test("503 when the token encryption key is unset", async () => {
    const poll = await request(
      "alpha",
      "/oauth/openai/device/poll",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ deviceCode: "device-1" }),
      },
      { OPENAI_OAUTH_CLIENT_ID: "app_test" },
    );
    expect(poll.status).toBe(503);
  });

  test("stores tokens encrypted at rest and drops the id token", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token")
        return Response.json({
          access_token: "plain-access",
          refresh_token: "plain-refresh",
          id_token: "plain-id-token",
          account_id: "acct-9",
          expires_in: 3600,
        });
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const poll = await request(
      "alpha",
      "/oauth/openai/device/poll",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ deviceCode: "device-3" }),
      },
      { OPENAI_OAUTH_CLIENT_ID: "app_test", OAUTH_TOKEN_KEY: testTokenKey },
    );
    expect(poll.status).toBe(200);
    const row = await database
      .prepare(
        "SELECT access_token, refresh_token, id_token, account_id FROM oauth_connections WHERE uid = 'alpha' AND provider = 'openai'",
      )
      .first<{
        access_token: string;
        refresh_token: string;
        id_token: string | null;
        account_id: string | null;
      }>();
    expect(row?.access_token).not.toBe("plain-access");
    expect(row?.refresh_token).not.toBe("plain-refresh");
    expect(row?.id_token).toBeNull();
    expect(row?.account_id).toBe("acct-9");
    const key = await importOauthTokenKey(testTokenKey);
    if (!key || !row) throw new Error("missing key or row");
    expect(await decryptOauthToken(key, row.access_token)).toBe("plain-access");
    expect(await decryptOauthToken(key, row.refresh_token)).toBe(
      "plain-refresh",
    );
    await database
      .prepare(
        "DELETE FROM oauth_connections WHERE uid = 'alpha' AND provider = 'openai'",
      )
      .run();
  });

  test("rejects malformed account ids at store time", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token")
        return Response.json({
          access_token: "plain-access",
          account_id: "acct 9\r\nx-injected: 1",
          expires_in: 3600,
        });
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const poll = await request(
      "alpha",
      "/oauth/openai/device/poll",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ deviceCode: "device-4" }),
      },
      { OPENAI_OAUTH_CLIENT_ID: "app_test", OAUTH_TOKEN_KEY: testTokenKey },
    );
    expect(poll.status).toBe(200);
    const row = await database
      .prepare(
        "SELECT account_id FROM oauth_connections WHERE uid = 'alpha' AND provider = 'openai'",
      )
      .first<{ account_id: string | null }>();
    expect(row?.account_id).toBeNull();
    await database
      .prepare(
        "DELETE FROM oauth_connections WHERE uid = 'alpha' AND provider = 'openai'",
      )
      .run();
  });

  test("maps unexpected upstream poll errors to failed", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token")
        return Response.json(
          { error: "internal_debug: stack trace at line 42" },
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
        body: JSON.stringify({ deviceCode: "device-5" }),
      },
      { OPENAI_OAUTH_CLIENT_ID: "app_test", OAUTH_TOKEN_KEY: testTokenKey },
    );
    expect(poll.status).toBe(400);
    expect(((await poll.json()) as Record<string, unknown>).error).toBe(
      "failed",
    );
  });

  test("rejects xai discovery documents pointing off x.ai", async () => {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://auth.x.ai/.well-known/openid-configuration")
        return Response.json({
          device_authorization_endpoint: "https://evil.example/device",
          token_endpoint: "https://evil.example/token",
        });
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const start = await request(
      "alpha",
      "/oauth/xai/device/start",
      { method: "POST" },
      { XAI_OAUTH_CLIENT_ID: "xai_test", OAUTH_TOKEN_KEY: testTokenKey },
    );
    expect(start.status).toBe(503);
  });
});
