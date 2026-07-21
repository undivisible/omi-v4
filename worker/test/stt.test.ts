import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
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

const request = (
  uid: string,
  body: unknown,
  environment: Partial<Bindings> = {},
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
    {
      DB: database,
      STT_ADMISSION: {
        getByName: () => ({
          fetch: async () => Response.json({ admitted: true }),
        }),
      },
      DEEPGRAM_API_KEY: "managed-deepgram-secret",
      STT_MAX_SESSION_SECONDS: "900",
      STT_COST_MICROUSD_PER_MINUTE: "10000",
      ...environment,
    } as Bindings,
  );
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
  const migration = await Bun.file("migrations/0009_managed_stt.sql").text();
  for (const statement of migration.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
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

  test("mints an ephemeral Deepgram token without persisting it", async () => {
    const originalFetch = globalThis.fetch;
    let authorization = "";
    let grantBody: unknown = null;
    globalThis.fetch = async (input, init) => {
      expect(String(input)).toBe("https://api.deepgram.com/v1/auth/grant");
      authorization = new Headers(init?.headers).get("authorization") ?? "";
      grantBody = JSON.parse(String(init?.body));
      return Response.json({ access_token: "x".repeat(64), expires_in: 30 });
    };
    try {
      const response = await request("pro", validRequest);
      expect(response.status).toBe(201);
      expect(response.headers.get("cache-control")).toBe("no-store");
      const body = (await response.json()) as Record<string, unknown>;
      expect(body.accessToken).toBe("x".repeat(64));
      expect(String(body.websocketUrl)).toStartWith(
        "wss://api.deepgram.com/v1/listen?",
      );
      expect(body.maxSessionSeconds).toBe(900);
      expect(authorization).toBe("Token managed-deepgram-secret");
      expect(grantBody).toEqual({ ttl_seconds: 30 });
      const row = await database
        .prepare(
          "SELECT status, reserved_seconds, estimated_cost_microusd, token_expires_at FROM managed_stt_sessions WHERE id = ?1",
        )
        .bind(body.sessionId)
        .first();
      expect(row).toMatchObject({
        status: "issued",
        reserved_seconds: 900,
        estimated_cost_microusd: 150000,
      });
      expect(JSON.stringify(row)).not.toContain("x".repeat(32));
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("requires active Pro before admission or token minting", async () => {
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
    expect(response.headers.get("cache-control")).toBe("no-store");
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

  test("does not mint twice for the same user idempotency key", async () => {
    const response = await request("pro", validRequest);
    expect(response.status).toBe(409);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});
