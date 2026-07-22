import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import assistant, {
  finalizeCancelledStream,
  price,
  reconcileManagedAssistantRequests,
} from "../src/assistant";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

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
  app.route("/", assistant);
  return app.request(
    "/chat/completions",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    {
      DB: database,
      ASSISTANT_ADMISSION: {
        getByName: () => ({
          fetch: async (input: RequestInfo | URL) =>
            new URL(String(input)).pathname === "/admit"
              ? Response.json({ admitted: true, retryAfter: 0 })
              : Response.json({ released: true }),
        }),
      },
      MIMO_API_KEY: "managed-secret",
      MIMO_CHAT_COMPLETIONS_URL:
        "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      MIMO_MODEL: "mimo-v2.5-pro",
      MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS: "1000000",
      MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS: "1000000",
      ...environment,
    } as Bindings,
  );
};

const validRequest = {
  model: "mimo-v2.5-pro",
  messages: [{ role: "user", content: "Remember this safely." }],
  stream: true,
  max_tokens: 256,
  stream_options: { include_usage: true },
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
  const migration = await Bun.file("migrations/0008_managed_ai.sql").text();
  for (const statement of migration.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users VALUES ('pro', 'pro@example.test', ?1, ?1), ('expired', 'expired@example.test', ?1, ?1), ('byok', 'byok@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
  await database
    .prepare(
      "INSERT INTO entitlements VALUES ('pro', 'pro', 'active', NULL), ('expired', 'pro', 'active', ?1), ('byok', 'byok', 'active', NULL)",
    )
    .bind(now - 1)
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("managed assistant", () => {
  test("accepts the captured rs_ai 0.2.21 streaming request shape", async () => {
    const originalFetch = globalThis.fetch;
    let upstreamBody: Record<string, unknown> | null = null;
    globalThis.fetch = async (_input, init) => {
      upstreamBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return new Response(
        'data: {"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\ndata: [DONE]\n\n',
      );
    };
    try {
      const response = await request("pro", {
        model: "mimo-v2.5-pro",
        messages: [{ role: "user", content: "hello" }],
        stream: true,
        stream_options: { include_usage: true },
      });
      expect(response.status).toBe(200);
      await response.text();
      expect(upstreamBody).toMatchObject({
        max_tokens: 1024,
        stream_options: { include_usage: true },
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("validates configured planning prices and Wrangler defaults", async () => {
    const config = JSON.parse(
      await Bun.file("wrangler.jsonc").text(),
    ) as Record<string, unknown>;
    const variables = config.vars as Record<string, string>;
    expect(variables.MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS).toBe("435000");
    expect(variables.MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS).toBe("870000");
    expect(price("435000")).toBe(435000);
    for (const invalid of [undefined, "", "0", "-1", "1.5", "NaN"])
      expect(price(invalid)).toBeNull();
  });

  test("reserves framing overhead for 64 adversarial tiny messages", async () => {
    const originalFetch = globalThis.fetch;
    let admittedTokens: number | null = null;
    globalThis.fetch = async () =>
      new Response(
        'data: {"usage":{"prompt_tokens":64,"completion_tokens":1}}\n\ndata: [DONE]\n\n',
      );
    try {
      const response = await request(
        "pro",
        {
          model: "mimo-v2.5-pro",
          messages: Array.from({ length: 64 }, () => ({
            role: "user",
            content: "x",
          })),
          stream: true,
          max_tokens: 1,
          stream_options: { include_usage: true },
        },
        {
          ASSISTANT_ADMISSION: {
            getByName: () => ({
              fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
                const path = new URL(String(input)).pathname;
                if (path === "/admit") {
                  const body = JSON.parse(String(init?.body)) as {
                    tokenBudget: number;
                  };
                  admittedTokens = body.tokenBudget;
                }
                return Response.json({ admitted: true, released: true });
              },
            }),
          } as DurableObjectNamespace,
        },
      );
      expect(response.status).toBe(200);
      await response.text();
      expect(admittedTokens).toBe(1409);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("streams MiMo through the managed key and records bounded usage", async () => {
    const originalFetch = globalThis.fetch;
    let authorization = "";
    let upstreamBody: Record<string, unknown> | null = null;
    globalThis.fetch = async (_input, init) => {
      authorization = new Headers(init?.headers).get("authorization") ?? "";
      upstreamBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return new Response(
        'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: {"usage":{"prompt_tokens":7,"completion_tokens":2}}\n\ndata: [DONE]\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    };
    try {
      const response = await request("pro", validRequest, {
        MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS: "1000000",
      });
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toContain(
        "text/event-stream",
      );
      expect(response.headers.get("x-omi-request-id")).toBeTruthy();
      expect(await response.text()).toContain("hello");
      expect(authorization).toBe("Bearer managed-secret");
      expect(upstreamBody).toMatchObject({
        model: "mimo-v2.5-pro",
        max_tokens: 256,
        stream: true,
        stream_options: { include_usage: true },
      });
      const audit = await database
        .prepare(
          "SELECT uid, provider, model, status, input_tokens, output_tokens, estimated_cost_microusd, actual_cost_microusd FROM managed_ai_requests ORDER BY created_at DESC LIMIT 1",
        )
        .first();
      expect(audit).toMatchObject({
        uid: "pro",
        provider: "mimo",
        model: "mimo-v2.5-pro",
        status: "complete",
        input_tokens: 7,
        output_tokens: 2,
        estimated_cost_microusd: 361,
        actual_cost_microusd: 9,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("rejects expired Pro and BYOK users before contacting MiMo", async () => {
    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return new Response();
    };
    try {
      expect((await request("expired", validRequest)).status).toBe(403);
      expect((await request("byok", validRequest)).status).toBe(403);
      expect(calls).toBe(0);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("rejects BYOK fields, unknown models, non-streaming, and token excess", async () => {
    for (const body of [
      { ...validRequest, api_key: "user-key" },
      { ...validRequest, base_url: "https://user.example" },
      { ...validRequest, model: "other" },
      { ...validRequest, stream: false },
      { ...validRequest, max_tokens: 4097 },
      { ...validRequest, stream_options: { include_usage: false } },
      { ...validRequest, stream_options: { include_usage: true, extra: true } },
      { ...validRequest, messages: [{ role: "tool", content: "unsafe" }] },
    ]) {
      expect((await request("pro", body)).status).toBe(400);
    }
  });

  test("does not leak upstream errors or secrets", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async () =>
      new Response("provider leaked managed-secret internals", { status: 429 });
    try {
      const response = await request("pro", validRequest);
      expect(response.status).toBe(502);
      const responseBody = await response.text();
      expect(responseBody).not.toContain("managed-secret");
      expect(responseBody).not.toContain("provider leaked");
      expect(responseBody).toContain("Managed AI unavailable");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("rejects non-canonical Xiaomi endpoints before contacting upstream", async () => {
    for (const endpoint of [
      "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions?debug=1",
      "https://user@token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      "https://127.0.0.1/v1/chat/completions",
      "https://token-plan-sgp.xiaomimimo.com.evil.test/v1/chat/completions",
    ]) {
      expect(
        (
          await request("pro", validRequest, {
            MIMO_CHAT_COMPLETIONS_URL: endpoint,
          })
        ).status,
      ).toBe(503);
    }
  });

  test("returns 429 with retry guidance when atomic admission refuses", async () => {
    const response = await request("pro", validRequest, {
      ASSISTANT_ADMISSION: {
        getByName: () => ({
          fetch: async () =>
            Response.json(
              { admitted: false, retryAfter: 17 },
              { status: 429, headers: { "retry-after": "17" } },
            ),
        }),
      } as DurableObjectNamespace,
    });
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("17");
  });

  test("retries transient D1 failures while reconciling stale requests", async () => {
    let updateAttempts = 0;
    let releases = 0;
    const staleDatabase = new Proxy(database, {
      get(target, property, receiver) {
        if (property !== "prepare")
          return Reflect.get(target, property, receiver);
        return (query: string) => {
          if (query.includes("FROM managed_ai_requests"))
            return {
              bind: () => ({
                all: async () => ({
                  results: [
                    {
                      id: "stale",
                      finalized_at: null,
                      input_tokens: null,
                      output_tokens: null,
                      actual_cost_microusd: null,
                    },
                  ],
                }),
              }),
            };
          const statement = target.prepare(query);
          if (!query.includes("SET status = 'failed'")) return statement;
          return new Proxy(statement, {
            get(statementTarget, statementProperty, statementReceiver) {
              if (statementProperty !== "bind")
                return Reflect.get(
                  statementTarget,
                  statementProperty,
                  statementReceiver,
                );
              return (...values: unknown[]) => {
                const bound = statementTarget.bind(...values);
                return new Proxy(bound, {
                  get(boundTarget, boundProperty, boundReceiver) {
                    if (boundProperty !== "run")
                      return Reflect.get(
                        boundTarget,
                        boundProperty,
                        boundReceiver,
                      );
                    return async () => {
                      updateAttempts += 1;
                      if (updateAttempts < 3) throw new Error("transient D1");
                      return boundTarget.run();
                    };
                  },
                });
              };
            },
          });
        };
      },
    });
    await reconcileManagedAssistantRequests(
      {
        DB: staleDatabase,
        ASSISTANT_ADMISSION: {
          getByName: () => ({
            fetch: async () => {
              releases += 1;
              return Response.json({ released: true });
            },
          }),
        },
      } as Bindings,
      Date.now(),
    );
    expect(updateAttempts).toBe(3);
    expect(releases).toBe(1);
  });

  test("releases admission when D1 cannot enter streaming state", async () => {
    const originalFetch = globalThis.fetch;
    let releases = 0;
    const failingDatabase = new Proxy(database, {
      get(target, property, receiver) {
        if (property !== "prepare")
          return Reflect.get(target, property, receiver);
        return (query: string) => {
          const statement = target.prepare(query);
          if (!query.includes("SET status = 'streaming'")) return statement;
          return new Proxy(statement, {
            get(statementTarget, statementProperty, statementReceiver) {
              if (statementProperty !== "bind")
                return Reflect.get(
                  statementTarget,
                  statementProperty,
                  statementReceiver,
                );
              return (...values: unknown[]) => {
                const bound = statementTarget.bind(...values);
                return new Proxy(bound, {
                  get(boundTarget, boundProperty, boundReceiver) {
                    if (boundProperty === "run")
                      return async () => {
                        throw new Error("D1 unavailable");
                      };
                    return Reflect.get(
                      boundTarget,
                      boundProperty,
                      boundReceiver,
                    );
                  },
                });
              };
            },
          });
        };
      },
    });
    globalThis.fetch = async () =>
      new Response("data: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    try {
      const response = await request("pro", validRequest, {
        DB: failingDatabase,
        ASSISTANT_ADMISSION: {
          getByName: () => ({
            fetch: async (input: RequestInfo | URL) => {
              if (new URL(String(input)).pathname === "/release") releases += 1;
              return Response.json({ admitted: true, released: true });
            },
          }),
        } as DurableObjectNamespace,
      });
      expect(response.status).toBe(503);
      expect(releases).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("finalizes cancellation when the upstream cancel hook fails", async () => {
    let finalized = 0;
    await finalizeCancelledStream(
      async () => {
        throw new Error("upstream cancel failed");
      },
      async () => {
        finalized += 1;
      },
    );
    expect(finalized).toBe(1);
  });
});
