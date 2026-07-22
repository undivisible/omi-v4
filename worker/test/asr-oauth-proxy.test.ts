import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  test,
} from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import {
  decryptOauthToken,
  encryptOauthToken,
  importOauthTokenKey,
} from "../src/oauth-broker";
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

const mimoEnvironment = {
  MIMO_API_KEY: "managed-secret",
  MIMO_CHAT_COMPLETIONS_URL:
    "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
};

const transcribe = (
  uid: string,
  body: unknown,
  environment: Partial<Bindings> = mimoEnvironment,
) =>
  request(
    uid,
    "/asr/transcribe",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    environment,
  );

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
      "INSERT INTO users VALUES ('pro', 'pro@example.test', ?1, ?1), ('byok', 'byok@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
  await database
    .prepare(
      "INSERT INTO entitlements VALUES ('pro', 'pro', 'active', NULL), ('byok', 'byok', 'active', NULL)",
    )
    .run();
});

afterEach(() => {
  globalThis.fetch = originalFetch;
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("asr transcription", () => {
  test("503 when managed AI is unconfigured", async () => {
    const response = await transcribe(
      "pro",
      { audio: "QUJD", format: "wav" },
      {},
    );
    expect(response.status).toBe(503);
  });

  test("413 when the base64 payload exceeds the cap", async () => {
    const response = await transcribe("pro", {
      audio: "A".repeat(10 * 1024 * 1024 + 1),
      format: "wav",
    });
    expect(response.status).toBe(413);
  });

  test("400 on disallowed format", async () => {
    const response = await transcribe("pro", {
      audio: "QUJD",
      format: "flac",
    });
    expect(response.status).toBe(400);
  });

  test("403 without a pro entitlement", async () => {
    const response = await transcribe("byok", {
      audio: "QUJD",
      format: "wav",
    });
    expect(response.status).toBe(403);
  });

  test("proxies audio to the pinned endpoint and returns the transcript", async () => {
    let upstreamUrl = "";
    let upstreamBody: Record<string, unknown> | undefined;
    let upstreamAuth: string | null = null;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      upstreamUrl = String(input);
      upstreamAuth = new Headers(init?.headers).get("authorization");
      upstreamBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Response.json({
        choices: [{ message: { content: "hello 世界" } }],
      });
    }) as typeof fetch;
    const response = await transcribe("pro", {
      audio: "QUJD",
      format: "mp3",
      language: "zh",
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.text).toBe("hello 世界");
    expect(JSON.stringify(body)).not.toContain("managed-secret");
    expect(upstreamUrl).toBe(
      "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
    );
    expect(upstreamAuth).toBe("Bearer managed-secret");
    expect(upstreamBody).toMatchObject({
      model: "mimo-v2.5-asr",
      stream: false,
      asr_options: { language: "zh" },
      messages: [
        {
          role: "user",
          content: [
            {
              type: "input_audio",
              input_audio: { data: "QUJD", format: "mp3" },
            },
          ],
        },
      ],
    });
    const recorded = await database
      .prepare(
        "SELECT provider, model, status FROM managed_ai_requests WHERE uid = 'pro' AND provider = 'mimo-asr'",
      )
      .first();
    expect(recorded?.model).toBe("mimo-v2.5-asr");
    expect(recorded?.status).toBe("complete");
  });

  test("502 when the upstream rejects the request", async () => {
    globalThis.fetch = (async () =>
      new Response("nope", { status: 500 })) as typeof fetch;
    const response = await transcribe("pro", {
      audio: "QUJD",
      format: "wav",
    });
    expect(response.status).toBe(502);
  });
});

describe("oauth subscription chat proxy", () => {
  let cryptoKey: CryptoKey;
  const encrypt = (plaintext: string) =>
    encryptOauthToken(cryptoKey, plaintext);

  beforeAll(async () => {
    const key = await importOauthTokenKey(testTokenKey);
    if (!key) throw new Error("bad test key");
    cryptoKey = key;
  });

  const chat = (
    uid: string,
    provider: string,
    body: unknown = { input: "hi" },
  ) =>
    request(
      uid,
      `/oauth/${provider}/chat/completions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
      {
        OPENAI_OAUTH_CLIENT_ID: "app_test",
        XAI_OAUTH_CLIENT_ID: "xai_test",
        OAUTH_TOKEN_KEY: testTokenKey,
      },
    );

  test("404 for unknown providers and missing connections", async () => {
    expect((await chat("pro", "google")).status).toBe(404);
    const response = await chat("pro", "openai");
    expect(response.status).toBe(404);
    expect(((await response.json()) as Record<string, unknown>).error).toBe(
      "Not connected",
    );
  });

  test("refreshes an expired token, persists rotation, and streams through", async () => {
    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO oauth_connections (uid, provider, access_token, refresh_token, account_id, expires_at, created_at, updated_at) VALUES ('pro', 'openai', ?1, ?2, 'acct-1', ?3, ?4, ?4)",
      )
      .bind(
        await encrypt("stale-access"),
        await encrypt("old-refresh"),
        now - 1000,
        now,
      )
      .run();
    let refreshBody: URLSearchParams | undefined;
    let upstreamHeaders: Headers | undefined;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token") {
        refreshBody = new URLSearchParams(String(init?.body));
        return Response.json({
          access_token: "fresh-access",
          refresh_token: "fresh-refresh",
          expires_in: 3600,
        });
      }
      if (url === "https://chatgpt.com/backend-api/codex/responses") {
        upstreamHeaders = new Headers(init?.headers);
        return new Response('data: {"delta":"hi"}\n\ndata: [DONE]\n\n', {
          status: 200,
          headers: { "content-type": "text/event-stream; charset=utf-8" },
        });
      }
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const response = await chat("pro", "openai");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe(
      "text/event-stream; charset=utf-8",
    );
    expect(await response.text()).toBe(
      'data: {"delta":"hi"}\n\ndata: [DONE]\n\n',
    );
    expect(refreshBody?.get("grant_type")).toBe("refresh_token");
    expect(refreshBody?.get("refresh_token")).toBe("old-refresh");
    expect(upstreamHeaders?.get("authorization")).toBe("Bearer fresh-access");
    expect(upstreamHeaders?.get("chatgpt-account-id")).toBe("acct-1");
    expect(upstreamHeaders?.get("originator")).toBe("omi");
    const row = await database
      .prepare(
        "SELECT access_token, refresh_token, expires_at FROM oauth_connections WHERE uid = 'pro' AND provider = 'openai'",
      )
      .first<{
        access_token: string;
        refresh_token: string;
        expires_at: number;
      }>();
    expect(row?.access_token).not.toBe("fresh-access");
    expect(row?.refresh_token).not.toBe("fresh-refresh");
    if (!row) throw new Error("missing row");
    expect(await decryptOauthToken(cryptoKey, row.access_token)).toBe(
      "fresh-access",
    );
    expect(await decryptOauthToken(cryptoKey, row.refresh_token)).toBe(
      "fresh-refresh",
    );
    expect(Number(row?.expires_at)).toBeGreaterThan(Date.now());
  });

  test("refresh race loser recovers by re-reading the rotated row", async () => {
    const now = Date.now();
    const staleRefresh = await encrypt("race-old-refresh");
    await database
      .prepare(
        "INSERT INTO oauth_connections (uid, provider, access_token, refresh_token, expires_at, created_at, updated_at) VALUES ('pro', 'openai', ?1, ?2, ?3, ?4, ?4) ON CONFLICT (uid, provider) DO UPDATE SET access_token = excluded.access_token, refresh_token = excluded.refresh_token, expires_at = excluded.expires_at",
      )
      .bind(await encrypt("race-stale-access"), staleRefresh, now - 1000, now)
      .run();
    let upstreamAuth: string | null = null;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      const url = String(input);
      if (url === "https://auth.openai.com/oauth/token") {
        await database
          .prepare(
            "UPDATE oauth_connections SET access_token = ?1, refresh_token = ?2, expires_at = ?3 WHERE uid = 'pro' AND provider = 'openai'",
          )
          .bind(
            await encrypt("winner-access"),
            await encrypt("winner-refresh"),
            Date.now() + 3_600_000,
          )
          .run();
        return Response.json({
          access_token: "loser-access",
          refresh_token: "loser-refresh",
          expires_in: 3600,
        });
      }
      if (url === "https://chatgpt.com/backend-api/codex/responses") {
        upstreamAuth = new Headers(init?.headers).get("authorization");
        return Response.json({ ok: true });
      }
      throw new Error(`Unexpected fetch ${url}`);
    }) as typeof fetch;
    const response = await chat("pro", "openai");
    expect(response.status).toBe(200);
    expect(upstreamAuth).toBe("Bearer winner-access");
    const row = await database
      .prepare(
        "SELECT access_token, refresh_token FROM oauth_connections WHERE uid = 'pro' AND provider = 'openai'",
      )
      .first<{ access_token: string; refresh_token: string }>();
    if (!row) throw new Error("missing row");
    expect(await decryptOauthToken(cryptoKey, row.access_token)).toBe(
      "winner-access",
    );
    expect(await decryptOauthToken(cryptoKey, row.refresh_token)).toBe(
      "winner-refresh",
    );
  });

  test("401 reconnect required when the refresh is rejected", async () => {
    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO oauth_connections (uid, provider, access_token, refresh_token, expires_at, created_at, updated_at) VALUES ('byok', 'openai', ?1, ?2, ?3, ?4, ?4)",
      )
      .bind(
        await encrypt("stale-access"),
        await encrypt("bad-refresh"),
        now - 1000,
        now,
      )
      .run();
    globalThis.fetch = (async () =>
      Response.json(
        { error: "invalid_grant" },
        { status: 400 },
      )) as typeof fetch;
    const response = await chat("byok", "openai");
    expect(response.status).toBe(401);
    expect(((await response.json()) as Record<string, unknown>).error).toBe(
      "Reconnect required",
    );
  });

  test("passes upstream status through for a live token", async () => {
    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO oauth_connections (uid, provider, access_token, refresh_token, expires_at, created_at, updated_at) VALUES ('pro', 'xai', ?1, ?2, ?3, ?4, ?4)",
      )
      .bind(
        await encrypt("grok-access"),
        await encrypt("grok-refresh"),
        now + 3_600_000,
        now,
      )
      .run();
    let upstreamUrl = "";
    let upstreamAuth: string | null = null;
    globalThis.fetch = (async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ) => {
      upstreamUrl = String(input);
      upstreamAuth = new Headers(init?.headers).get("authorization");
      return Response.json({ error: "overloaded" }, { status: 429 });
    }) as typeof fetch;
    const response = await chat("pro", "xai");
    expect(response.status).toBe(429);
    expect(upstreamUrl).toBe(
      "https://cli-chat-proxy.grok.com/v1/chat/completions",
    );
    expect(upstreamAuth).toBe("Bearer grok-access");
  });
});
