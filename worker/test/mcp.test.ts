import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import apiKeyRoutes from "../src/api-keys";
import mcp, { protocolVersion, serverInfo, tools } from "../src/mcp";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

const allowingRateLimiter = {
  getByName: () => ({
    fetch: async (url: string | URL) =>
      new URL(String(url)).pathname === "/consume"
        ? Response.json({ allowed: true, retryAfter: 0 })
        : new Response(null, { status: 404 }),
  }),
} as unknown as DurableObjectNamespace;

let database: D1Database;
let fullKey: string;
let readOnlyKey: string;

const bindings = () =>
  ({
    DB: database,
    RATE_LIMITER: allowingRateLimiter,
    FIREBASE_PROJECT_ID: "test",
  }) as unknown as AppEnv["Bindings"];

const mint = async (uid: string, scopes: string[]) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/api-keys", apiKeyRoutes);
  const response = await app.request(
    "/api-keys",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: `${uid}-${scopes.length}`, scopes }),
    },
    bindings(),
  );
  return ((await response.json()) as { key: string }).key;
};

const call = (key: string | null, payload: unknown, method = "POST") => {
  const app = new Hono<AppEnv>();
  app.route("/mcp", mcp);
  return app.request(
    "/mcp",
    {
      method,
      headers: {
        "content-type": "application/json",
        ...(key ? { authorization: `Bearer ${key}` } : {}),
      },
      ...(method === "POST" ? { body: JSON.stringify(payload) } : {}),
    },
    bindings(),
  );
};

const rpc = async (key: string | null, payload: unknown) => {
  const response = await call(key, payload);
  return {
    status: response.status,
    body: response.status === 202 ? null : ((await response.json()) as never),
  };
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of readdirSync("migrations").sort()) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    for (const statement of sql.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1)",
    )
    .bind(now)
    .run();
  fullKey = await mint("alpha", [
    "memory:read",
    "currents:read",
    "currents:write",
    "conversations:read",
    "assistant:write",
    "facetime:write",
  ]);
  readOnlyKey = await mint("alpha", ["memory:read"]);
});

afterAll(() => miniflare.dispose());

describe("MCP transport", () => {
  test("rejects an unauthenticated call", async () => {
    const response = await call(null, {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    });
    expect(response.status).toBe(401);
  });

  test("declines the optional SSE stream and session verbs", async () => {
    expect((await call(fullKey, null, "GET")).status).toBe(405);
    expect((await call(fullKey, null, "DELETE")).status).toBe(405);
  });

  test("initializes with the advertised protocol version", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: "init",
      method: "initialize",
      params: {
        protocolVersion,
        capabilities: {},
        clientInfo: { name: "suite", version: "0" },
      },
    });
    expect(body).toMatchObject({
      jsonrpc: "2.0",
      id: "init",
      result: {
        protocolVersion,
        serverInfo,
        capabilities: { tools: { listChanged: false } },
      },
    });
  });

  test("answers ping and rejects unknown methods", async () => {
    expect(
      (await rpc(fullKey, { jsonrpc: "2.0", id: 2, method: "ping" })).body,
    ).toEqual({ jsonrpc: "2.0", id: 2, result: {} });
    const unknown = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 3,
      method: "resources/list",
    });
    expect(unknown.body).toMatchObject({ error: { code: -32601 } });
  });

  test("accepts notifications with 202 and no body", async () => {
    const response = await rpc(fullKey, {
      jsonrpc: "2.0",
      method: "notifications/initialized",
    });
    expect(response.status).toBe(202);
  });

  test("rejects malformed JSON and non-object payloads", async () => {
    const app = new Hono<AppEnv>();
    app.route("/mcp", mcp);
    const broken = await app.request(
      "/mcp",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${fullKey}`,
        },
        body: "{",
      },
      bindings(),
    );
    expect(broken.status).toBe(400);
    expect((await rpc(fullKey, ["nonsense"])).status).toBe(400);
  });

  test("rejects an oversized batch instead of dispatching it", async () => {
    const batch = Array.from({ length: 65 }, (_, index) => ({
      jsonrpc: "2.0",
      id: index,
      method: "ping",
    }));
    const response = await rpc(fullKey, batch);
    expect(response.status).toBe(413);
    expect(
      (response.body as { error: { message: string } }).error.message,
    ).toContain("Batch too large");
  });

  // A chunked request carries no content-length, so the header cannot be the
  // size guard: the body itself has to be read through a bounded reader.
  test("bounds a chunked body that declares no content-length", async () => {
    const oversized = new TextEncoder().encode(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "ping",
        padding: "x".repeat(300 * 1024),
      }),
    );
    const app = new Hono<AppEnv>();
    app.route("/mcp", mcp);
    const response = await app.request(
      "/mcp",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${fullKey}`,
        },
        body: new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(oversized);
            controller.close();
          },
        }),
        duplex: "half",
      } as RequestInit,
      bindings(),
    );
    expect(response.status).toBe(413);
  });

  test("answers a batch in order", async () => {
    const { body } = await rpc(fullKey, [
      { jsonrpc: "2.0", id: "a", method: "ping" },
      { jsonrpc: "2.0", id: "b", method: "tools/list" },
    ]);
    const responses = body as Array<{ id: string }>;
    expect(responses).toHaveLength(2);
    expect(responses.map((response) => response.id)).toEqual(["a", "b"]);
  });
});

describe("MCP tool dispatch", () => {
  test("lists every tool with a precise input schema", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    });
    const listed = (
      body as { result: { tools: Array<Record<string, unknown>> } }
    ).result.tools;
    expect(listed.map((tool) => tool.name).sort()).toEqual(
      [
        "ask_omi",
        "create_current",
        "list_conversation_messages",
        "list_currents",
        "list_meeting_notes",
        "list_memories",
        "search_memory",
        "start_facetime_call",
      ].sort(),
    );
    expect(listed).toHaveLength(tools.length);
    for (const tool of listed) {
      const schema = tool.inputSchema as Record<string, unknown>;
      expect(schema.type).toBe("object");
      expect(schema.additionalProperties).toBe(false);
      expect(typeof tool.description).toBe("string");
      expect(String(tool.description).length).toBeGreaterThan(40);
    }
  });

  test("runs a read tool and returns both text and structured content", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: { name: "list_currents", arguments: {} },
    });
    const result = (
      body as {
        result: {
          isError: boolean;
          structuredContent: { currents: unknown[] };
          content: Array<{ type: string; text: string }>;
        };
      }
    ).result;
    expect(result.isError).toBe(false);
    expect(result.structuredContent.currents).toEqual([]);
    expect(JSON.parse(result.content[0].text)).toEqual({ currents: [] });
  });

  test("creates a Current through the tool and reads it back", async () => {
    const created = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 5,
      method: "tools/call",
      params: {
        name: "create_current",
        arguments: {
          title: "Send the release notes",
          summary: "The release shipped but nobody has been told.",
          reason: "The user said the release was ready yesterday.",
          proposedNextStep: "Draft a two-line note and send it.",
        },
      },
    });
    const result = (
      created.body as {
        result: {
          isError: boolean;
          structuredContent: { current: { title: string; status: string } };
        };
      }
    ).result;
    expect(result.isError).toBe(false);
    expect(result.structuredContent.current.title).toBe(
      "Send the release notes",
    );
    const listed = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 6,
      method: "tools/call",
      params: { name: "list_currents", arguments: {} },
    });
    const currents = (
      listed.body as {
        result: { structuredContent: { currents: Array<{ title: string }> } };
      }
    ).result.structuredContent.currents;
    expect(currents.map((current) => current.title)).toEqual([
      "Send the release notes",
    ]);
  });

  test("reports tool input validation as an error result, not a protocol error", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 7,
      method: "tools/call",
      params: { name: "search_memory", arguments: { query: "" } },
    });
    const result = (
      body as { result: { isError: boolean; structuredContent: unknown } }
    ).result;
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toEqual({
      error: "Invalid memory search",
    });
  });

  test("refuses a tool the key has no scope for", async () => {
    const { body } = await rpc(readOnlyKey, {
      jsonrpc: "2.0",
      id: 8,
      method: "tools/call",
      params: { name: "list_currents", arguments: {} },
    });
    expect(body).toMatchObject({
      error: {
        code: -32000,
        message: "API key is missing the currents:read scope",
      },
    });
  });

  test("allows a scoped tool for the same key", async () => {
    const { body } = await rpc(readOnlyKey, {
      jsonrpc: "2.0",
      id: 9,
      method: "tools/call",
      params: { name: "search_memory", arguments: { query: "release" } },
    });
    expect((body as { result: { isError: boolean } }).result.isError).toBe(
      false,
    );
  });

  test("rejects an unknown tool and non-object arguments", async () => {
    expect(
      (
        await rpc(fullKey, {
          jsonrpc: "2.0",
          id: 10,
          method: "tools/call",
          params: { name: "drop_database", arguments: {} },
        })
      ).body,
    ).toMatchObject({ error: { code: -32602 } });
    expect(
      (
        await rpc(fullKey, {
          jsonrpc: "2.0",
          id: 11,
          method: "tools/call",
          params: { name: "list_currents", arguments: [] },
        })
      ).body,
    ).toMatchObject({ error: { code: -32602 } });
  });

  test("reports the disabled FaceTime provider as a tool error", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 13,
      method: "tools/call",
      params: {
        name: "start_facetime_call",
        arguments: { handle: "+15551234567" },
      },
    });
    const result = (
      body as { result: { isError: boolean; structuredContent: unknown } }
    ).result;
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toEqual({
      error: "FaceTime calling unavailable",
    });
  });

  test("refuses to place a call with a validation error before any dial", async () => {
    const { body } = await rpc(fullKey, {
      jsonrpc: "2.0",
      id: 14,
      method: "tools/call",
      params: {
        name: "start_facetime_call",
        arguments: { handle: "5551234567" },
      },
    });
    expect(
      (body as { result: { structuredContent: unknown } }).result
        .structuredContent,
    ).toEqual({ error: "Invalid FaceTime handle" });
  });

  test("scopes tool results to the calling key's uid", async () => {
    await database
      .prepare(
        "INSERT INTO users (uid, created_at, updated_at) VALUES ('beta', ?1, ?1)",
      )
      .bind(Date.now())
      .run();
    const betaKey = await mint("beta", ["currents:read"]);
    const { body } = await rpc(betaKey, {
      jsonrpc: "2.0",
      id: 12,
      method: "tools/call",
      params: { name: "list_currents", arguments: {} },
    });
    expect(
      (body as { result: { structuredContent: { currents: unknown[] } } })
        .result.structuredContent.currents,
    ).toEqual([]);
  });
});
