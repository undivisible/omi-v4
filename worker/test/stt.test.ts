import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import { app as rootApp } from "../src/index";
import stt from "../src/stt";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const validRequest = {
  idempotencyKey: "desktop:session:1",
  model: "nova-3",
  language: "en-US",
  encoding: "linear16",
  sampleRate: 16000,
  channels: 1,
  diarize: true,
  interimResults: true,
  deviceId: "desktop-one",
  sourceId: "microphone",
};

const environment = (overrides: Partial<Bindings> = {}) =>
  ({
    DB: database,
    STT_ADMISSION: {
      getByName: () => ({
        fetch: async () => Response.json({ admitted: true }),
      }),
    },
    DEEPGRAM_API_KEY: "managed-deepgram-secret",
    STT_MAX_SESSION_SECONDS: "900",
    STT_COST_MICROUSD_PER_MINUTE: "10000",
    ...overrides,
  }) as Bindings;

const request = (
  uid: string,
  body: unknown,
  overrides: Partial<Bindings> = {},
) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/stt", stt);
  return app.request(
    "/stt/sessions",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    environment(overrides),
  );
};

const migrate = async (path: string) => {
  const migration = await Bun.file(path).text();
  for (const statement of migration.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
  }
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
  await migrate("migrations/0009_managed_stt.sql");
  await migrate("migrations/0010_bound_stt_proxy.sql");
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users VALUES ('pro', 'pro@example.test', ?1, ?1), ('pro-two', 'pro-two@example.test', ?1, ?1), ('byok', 'byok@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
  await database
    .prepare(
      "INSERT INTO entitlements VALUES ('pro', 'pro', 'active', NULL), ('pro-two', 'pro', 'active', NULL), ('byok', 'byok', 'active', NULL)",
    )
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("managed STT sessions", () => {
  test("pins the conservative managed Deepgram reservation price", async () => {
    const config = JSON.parse(
      await Bun.file("wrangler.jsonc").text(),
    ) as Record<string, unknown>;
    const variables = config.vars as Record<string, string>;
    expect(variables.STT_COST_MICROUSD_PER_MINUTE).toBe("10000");
  });

  test("returns only a bounded Worker WebSocket session", async () => {
    const originalFetch = globalThis.fetch;
    let providerCalls = 0;
    globalThis.fetch = async () => {
      providerCalls += 1;
      throw new Error("Provider must not be called during session creation");
    };
    try {
      const response = await request("pro", validRequest);
      expect(response.status).toBe(201);
      expect(response.headers.get("cache-control")).toBe("no-store");
      const body = (await response.json()) as Record<string, unknown>;
      expect(body).not.toHaveProperty("accessToken");
      expect(body).not.toHaveProperty("expiresAt");
      expect(String(body.websocketUrl)).toMatch(
        /^wss?:\/\/localhost\/v1\/stt\/sessions\//,
      );
      expect(String(body.websocketUrl)).toEndWith("/stream");
      expect(body.maxSessionSeconds).toBe(900);
      expect(providerCalls).toBe(0);
      const row = await database
        .prepare(
          "SELECT status, reserved_seconds, estimated_cost_microusd FROM managed_stt_sessions WHERE id = ?1",
        )
        .bind(body.sessionId)
        .first();
      expect(row).toMatchObject({
        status: "ready",
        reserved_seconds: 900,
        estimated_cost_microusd: 150000,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("coalesces concurrent idempotent creation without duplicate sessions", async () => {
    const body = { ...validRequest, idempotencyKey: "desktop:concurrent:1" };
    const [first, second] = await Promise.all([
      request("pro", body),
      request("pro", body),
    ]);
    expect([first.status, second.status].sort()).toEqual([201, 201]);
    const firstBody = (await first.json()) as { sessionId: string };
    const secondBody = (await second.json()) as { sessionId: string };
    expect(firstBody.sessionId).toBe(secondBody.sessionId);
    const count = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM managed_stt_sessions WHERE uid = 'pro' AND idempotency_key = 'desktop:concurrent:1'",
      )
      .first<{ count: number }>();
    expect(count?.count).toBe(1);
  });

  test("scopes the same idempotency key to each Firebase UID", async () => {
    const body = { ...validRequest, idempotencyKey: "desktop:tenant:key" };
    const first = (await (await request("pro", body)).json()) as {
      sessionId: string;
    };
    const second = (await (await request("pro-two", body)).json()) as {
      sessionId: string;
    };
    expect(first.sessionId).not.toBe(second.sessionId);
  });

  test("accepts a signed Firebase user through the production middleware", async () => {
    const keys = (await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const encode = (value: unknown) =>
      Buffer.from(JSON.stringify(value)).toString("base64url");
    const now = Math.floor(Date.now() / 1000);
    const signed = `${encode({ alg: "RS256", kid: "stt-test" })}.${encode({
      aud: "test",
      iss: "https://securetoken.google.com/test",
      sub: "pro",
      exp: now + 3600,
      iat: now,
    })}`;
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      keys.privateKey,
      new TextEncoder().encode(signed),
    );
    const token = `${signed}.${Buffer.from(signature).toString("base64url")}`;
    const jwk = await crypto.subtle.exportKey("jwk", keys.publicKey);
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (input) => {
      expect(String(input)).toContain("googleapis.com");
      return Response.json(
        { keys: [{ ...jwk, kid: "stt-test" }] },
        { headers: { "cache-control": "max-age=300" } },
      );
    };
    try {
      const response = await rootApp.request(
        "/v1/stt/sessions",
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            ...validRequest,
            idempotencyKey: "desktop:firebase:1",
          }),
        },
        { ...environment(), FIREBASE_PROJECT_ID: "test" },
      );
      expect(response.status).toBe(201);
      expect((await response.json()) as unknown).not.toHaveProperty(
        "accessToken",
      );
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("rejects an idempotency key reused with different configuration", async () => {
    const body = { ...validRequest, idempotencyKey: "desktop:conflict:1" };
    expect((await request("pro", body)).status).toBe(201);
    expect((await request("pro", { ...body, language: "de" })).status).toBe(
      409,
    );
  });

  test("requires active Pro before admission or provider access", async () => {
    const response = await request("byok", {
      ...validRequest,
      idempotencyKey: "desktop:byok:1",
    });
    expect(response.status).toBe(403);
  });

  test("fails closed on unsafe server-side reservation configuration", async () => {
    const response = await request(
      "pro",
      { ...validRequest, idempotencyKey: "desktop:unsafe-config" },
      { STT_MAX_SESSION_SECONDS: "3601" },
    );
    expect(response.status).toBe(503);
  });

  test("rejects unknown fields and unsafe audio configuration", async () => {
    expect(
      (
        await request("pro", {
          ...validRequest,
          idempotencyKey: "desktop:invalid:1",
          callback: "https://evil.test",
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await request("pro", {
          ...validRequest,
          idempotencyKey: "desktop:invalid:2",
          sampleRate: 44100,
        })
      ).status,
    ).toBe(400);
  });
});
