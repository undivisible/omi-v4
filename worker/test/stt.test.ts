import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import { app as rootApp } from "../src/index";
import stt, { bridgeSttSockets } from "../src/stt";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

class FakeSocket extends EventTarget {
  readyState = WebSocket.OPEN;
  sent: unknown[] = [];
  throwOnSend = false;

  send(data: unknown) {
    if (this.throwOnSend) throw new Error("send failed");
    this.sent.push(data);
  }

  close() {
    this.readyState = WebSocket.CLOSED;
  }
}

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
        fetch: async () =>
          Response.json({
            admitted: true,
            acquisitionToken: "test-acquisition-token",
          }),
      }),
    },
    DEEPGRAM_API_KEY: "managed-deepgram-secret",
    STT_MAX_SESSION_SECONDS: "900",
    STT_COST_MICROUSD_PER_MINUTE: "10000",
    STT_UPSTREAM_CONNECT_TIMEOUT_MS: "10000",
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

const stream = (
  uid: string,
  sessionId: string,
  overrides: Partial<Bindings> = {},
) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/stt", stt);
  return app.request(
    `/stt/sessions/${sessionId}/stream`,
    { headers: { upgrade: "websocket" } },
    environment(overrides),
  );
};

const admissionTracker = () => {
  let releases = 0;
  const namespace = {
    getByName: () => ({
      fetch: async (input: RequestInfo | URL) => {
        const path = new URL(String(input)).pathname;
        if (path === "/release") releases += 1;
        return Response.json({
          admitted: true,
          acquisitionToken: "test-acquisition-token",
          claimed: true,
          released: true,
        });
      },
    }),
  } as unknown as DurableObjectNamespace;
  return { namespace, releases: () => releases };
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
  await migrate("migrations/0011_stt_acquisition_token.sql");
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
  test("bridges successful sockets and settles terminal races once", async () => {
    const server = new FakeSocket();
    const upstream = new FakeSocket();
    const statuses: string[] = [];
    bridgeSttSockets(
      server as unknown as WebSocket,
      upstream as unknown as WebSocket,
      10_000,
      (status) => statuses.push(status),
    );
    server.dispatchEvent(new MessageEvent("message", { data: "audio" }));
    upstream.dispatchEvent(new MessageEvent("message", { data: "transcript" }));
    expect(upstream.sent).toEqual(["audio"]);
    expect(server.sent).toEqual(["transcript"]);
    server.dispatchEvent(
      new CloseEvent("close", { code: 1000, wasClean: true }),
    );
    upstream.dispatchEvent(new Event("error"));
    expect(statuses).toEqual(["complete"]);

    const abnormalServer = new FakeSocket();
    const abnormalUpstream = new FakeSocket();
    const abnormal: string[] = [];
    bridgeSttSockets(
      abnormalServer as unknown as WebSocket,
      abnormalUpstream as unknown as WebSocket,
      10_000,
      (status) => abnormal.push(status),
    );
    abnormalUpstream.dispatchEvent(
      new CloseEvent("close", { code: 1011, wasClean: false }),
    );
    abnormalUpstream.dispatchEvent(new Event("error"));
    expect(abnormal).toEqual(["failed"]);

    const failingServer = new FakeSocket();
    const failingUpstream = new FakeSocket();
    failingUpstream.throwOnSend = true;
    const failures: string[] = [];
    bridgeSttSockets(
      failingServer as unknown as WebSocket,
      failingUpstream as unknown as WebSocket,
      10_000,
      (status) => failures.push(status),
    );
    failingServer.dispatchEvent(new MessageEvent("message", { data: "audio" }));
    failingServer.dispatchEvent(new Event("error"));
    expect(failures).toEqual(["failed"]);

    const timedServer = new FakeSocket();
    const timedUpstream = new FakeSocket();
    const timed: string[] = [];
    bridgeSttSockets(
      timedServer as unknown as WebSocket,
      timedUpstream as unknown as WebSocket,
      1,
      (status) => timed.push(status),
    );
    await Bun.sleep(5);
    expect(timed).toEqual(["complete"]);
  });

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

  test("releases a new admission when D1 session creation fails", async () => {
    const tracker = admissionTracker();
    const failing = {
      prepare(query: string) {
        if (!query.includes("INSERT INTO managed_stt_sessions"))
          return database.prepare(query);
        return {
          bind: () => ({
            run: async () => {
              throw new Error("simulated D1 write failure");
            },
          }),
        };
      },
    } as unknown as D1Database;
    const response = await request(
      "pro",
      { ...validRequest, idempotencyKey: "desktop:d1-failure:1" },
      { DB: failing, STT_ADMISSION: tracker.namespace },
    );
    expect(response.status).toBe(503);
    expect(tracker.releases()).toBe(1);
  });

  test("bounds upstream connection time and releases failed sessions", async () => {
    for (const failure of ["provider", "timeout"] as const) {
      const tracker = admissionTracker();
      const idempotencyKey = `desktop:${failure}:release`;
      const created = await request(
        "pro",
        { ...validRequest, idempotencyKey },
        { STT_ADMISSION: tracker.namespace },
      );
      const { sessionId } = (await created.json()) as { sessionId: string };
      const originalFetch = globalThis.fetch;
      globalThis.fetch = async (_input, init) => {
        if (failure === "provider") throw new Error("provider unavailable");
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () =>
            reject(init.signal?.reason),
          );
        });
      };
      try {
        const response = await stream("pro", sessionId, {
          STT_ADMISSION: tracker.namespace,
          STT_UPSTREAM_CONNECT_TIMEOUT_MS:
            failure === "timeout" ? "1" : "10000",
        });
        expect(response.status).toBe(502);
        expect(tracker.releases()).toBe(1);
        const row = await database
          .prepare("SELECT status FROM managed_stt_sessions WHERE id = ?1")
          .bind(sessionId)
          .first();
        expect(row?.status).toBe("failed");
      } finally {
        globalThis.fetch = originalFetch;
      }
    }
  });

  test("releases admission when entitlement D1 fails during socket claim", async () => {
    const tracker = admissionTracker();
    const created = await request(
      "pro",
      { ...validRequest, idempotencyKey: "desktop:entitlement-failure" },
      { STT_ADMISSION: tracker.namespace },
    );
    const { sessionId } = (await created.json()) as { sessionId: string };
    const failing = {
      prepare(query: string) {
        if (!query.includes("FROM entitlements"))
          return database.prepare(query);
        return {
          bind: () => ({
            first: async () => {
              throw new Error("simulated entitlement read failure");
            },
          }),
        };
      },
    } as unknown as D1Database;
    const response = await stream("pro", sessionId, {
      DB: failing,
      STT_ADMISSION: tracker.namespace,
    });
    expect(response.status).toBe(503);
    expect(tracker.releases()).toBe(1);
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

  test("accepts only provider-compatible physical Omi audio contracts", async () => {
    for (const body of [
      {
        ...validRequest,
        idempotencyKey: "desktop:codec:pcm8",
        sampleRate: 8000,
      },
      {
        ...validRequest,
        idempotencyKey: "desktop:codec:opus320",
        encoding: "opus",
        sampleRate: 16000,
        channels: 1,
      },
    ]) {
      expect((await request("pro", body)).status).toBe(201);
    }

    for (const body of [
      {
        ...validRequest,
        idempotencyKey: "desktop:codec:opus-stereo",
        encoding: "opus",
        channels: 2,
      },
      {
        ...validRequest,
        idempotencyKey: "desktop:codec:opus48",
        encoding: "opus",
        sampleRate: 48000,
      },
      {
        ...validRequest,
        idempotencyKey: "desktop:codec:pcm44",
        sampleRate: 44100,
      },
    ]) {
      expect((await request("pro", body)).status).toBe(400);
    }
  });
});
