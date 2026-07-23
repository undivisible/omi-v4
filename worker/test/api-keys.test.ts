import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import apiKeyRoutes, {
  digest,
  mintApiKey,
  timingSafeEqual,
  verifyApiKey,
} from "../src/api-keys";
import publicApi from "../src/public-api";
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

const bindings = () =>
  ({
    DB: database,
    RATE_LIMITER: allowingRateLimiter,
    FIREBASE_PROJECT_ID: "test",
  }) as unknown as AppEnv["Bindings"];

// Management routes sit behind Firebase auth in production; the suite injects
// the resolved identity the same way the other route suites do.
const manage = (uid: string, path: string, init?: RequestInit) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/api-keys", apiKeyRoutes);
  return app.request(`/api-keys${path}`, init, bindings());
};

const publicRequest = (headers: Record<string, string>, path: string) => {
  const app = new Hono<AppEnv>();
  app.route("/api/v1", publicApi);
  return app.request(`/api/v1${path}`, { headers }, bindings());
};

const mint = async (uid: string, body: Record<string, unknown>) => {
  const response = await manage(uid, "", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: (await response.json()) as {
      key?: string;
      apiKey?: { id: string; prefix: string; scopes: string[] };
      error?: string;
    },
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
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('alpha', 'alpha@example.test', ?1, ?1), ('beta', 'beta@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(() => miniflare.dispose());

describe("API key minting", () => {
  test("returns the plaintext key once and stores only its digest", async () => {
    const created = await mint("alpha", {
      name: "sdk",
      scopes: ["memory:read", "currents:read"],
    });
    expect(created.status).toBe(201);
    expect(created.body.key).toMatch(/^omi_sk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$/);
    expect(created.body.apiKey?.scopes).toEqual([
      "memory:read",
      "currents:read",
    ]);
    const stored = await database
      .prepare("SELECT key_hash FROM api_keys WHERE id = ?1")
      .bind(created.body.apiKey?.id)
      .first<{ key_hash: string }>();
    expect(stored?.key_hash).toBe(await digest(created.body.key as string));
    expect(stored?.key_hash).not.toContain(created.body.key as string);
  });

  test("rejects unknown scopes and empty scope lists", async () => {
    expect(
      (await mint("alpha", { name: "bad", scopes: ["root"] })).status,
    ).toBe(400);
    expect((await mint("alpha", { name: "bad", scopes: [] })).status).toBe(400);
    expect((await mint("alpha", { scopes: ["memory:read"] })).status).toBe(400);
  });

  test("rejects an expiry that is already in the past", async () => {
    expect(
      (
        await mint("alpha", {
          name: "stale",
          scopes: ["memory:read"],
          expiresAt: Date.now() - 1,
        })
      ).status,
    ).toBe(400);
  });

  test("lists keys per uid without leaking the secret", async () => {
    const response = await manage("alpha", "");
    const body = (await response.json()) as {
      keys: Array<Record<string, unknown>>;
    };
    expect(body.keys.length).toBeGreaterThan(0);
    for (const key of body.keys) {
      expect(Object.keys(key)).not.toContain("key");
      expect(String(key.prefix)).toMatch(/^omi_sk_[0-9a-f]{8}$/);
    }
    const other = (await (await manage("beta", "")).json()) as {
      keys: unknown[];
    };
    expect(other.keys).toEqual([]);
  });
});

describe("API key verification", () => {
  test("compares digests without early exit", () => {
    expect(timingSafeEqual("abc", "abc")).toBe(true);
    expect(timingSafeEqual("abc", "abd")).toBe(false);
    expect(timingSafeEqual("abc", "abcd")).toBe(false);
  });

  test("resolves the owning uid and scopes", async () => {
    const created = await mint("beta", {
      name: "beta key",
      scopes: ["memory:read"],
    });
    const verified = await verifyApiKey(
      database,
      created.body.key as string,
      Date.now(),
    );
    expect(verified?.uid).toBe("beta");
    expect(verified?.email).toBe("beta@example.test");
    expect(verified?.key.scopes).toEqual(["memory:read"]);
  });

  test("rejects a key with a valid prefix but a forged secret", async () => {
    const created = await mint("alpha", {
      name: "forge target",
      scopes: ["memory:read"],
    });
    const key = created.body.key as string;
    const forged = `${key.slice(0, -1)}${key.endsWith("A") ? "B" : "A"}`;
    expect(await verifyApiKey(database, forged, Date.now())).toBeNull();
  });

  test("rejects malformed and unknown keys", async () => {
    expect(await verifyApiKey(database, "not-a-key", Date.now())).toBeNull();
    const orphan = await mintApiKey();
    expect(await verifyApiKey(database, orphan.key, Date.now())).toBeNull();
  });

  test("rejects an expired key", async () => {
    const created = await mint("alpha", {
      name: "short lived",
      scopes: ["memory:read"],
      expiresAt: Date.now() + 60_000,
    });
    const key = created.body.key as string;
    expect(await verifyApiKey(database, key, Date.now())).not.toBeNull();
    expect(await verifyApiKey(database, key, Date.now() + 120_000)).toBeNull();
  });

  test("rejects a revoked key and revocation is scoped to the owner", async () => {
    const created = await mint("alpha", {
      name: "revoke me",
      scopes: ["memory:read"],
    });
    const id = created.body.apiKey?.id as string;
    expect((await manage("beta", `/${id}`, { method: "DELETE" })).status).toBe(
      404,
    );
    expect(
      await verifyApiKey(database, created.body.key as string, Date.now()),
    ).not.toBeNull();
    expect((await manage("alpha", `/${id}`, { method: "DELETE" })).status).toBe(
      204,
    );
    expect(
      await verifyApiKey(database, created.body.key as string, Date.now()),
    ).toBeNull();
    expect((await manage("alpha", `/${id}`, { method: "DELETE" })).status).toBe(
      404,
    );
  });

  test("records last use at minute resolution", async () => {
    const created = await mint("alpha", {
      name: "used",
      scopes: ["memory:read"],
    });
    const now = Date.now();
    await verifyApiKey(database, created.body.key as string, now);
    const row = await database
      .prepare("SELECT last_used_at FROM api_keys WHERE id = ?1")
      .bind(created.body.apiKey?.id)
      .first<{ last_used_at: number }>();
    expect(row?.last_used_at).toBe(now);
  });
});

describe("public API authentication", () => {
  test("refuses a request with no credential", async () => {
    expect((await publicRequest({}, "/me")).status).toBe(401);
  });

  test("refuses an unknown API key", async () => {
    const orphan = await mintApiKey();
    const response = await publicRequest(
      { authorization: `Bearer ${orphan.key}` },
      "/me",
    );
    expect(response.status).toBe(401);
  });

  test("accepts a key in either the bearer or x-api-key header", async () => {
    const created = await mint("alpha", {
      name: "headers",
      scopes: ["memory:read"],
    });
    const key = created.body.key as string;
    for (const headers of [
      { authorization: `Bearer ${key}` },
      { "x-api-key": key },
    ]) {
      const response = await publicRequest(headers, "/me");
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        uid: "alpha",
        auth: "api_key",
        scopes: ["memory:read"],
      });
    }
  });

  test("enforces scopes per route", async () => {
    const created = await mint("alpha", {
      name: "read only",
      scopes: ["memory:read"],
    });
    const headers = { authorization: `Bearer ${created.body.key}` };
    expect((await publicRequest(headers, "/memories")).status).toBe(200);
    const denied = await publicRequest(headers, "/currents");
    expect(denied.status).toBe(403);
    expect(await denied.json()).toEqual({
      error: "Missing scope",
      scope: "currents:read",
    });
  });

  test("serves only the key owner's data", async () => {
    const created = await mint("beta", {
      name: "beta reader",
      scopes: ["memory:read"],
    });
    const response = await publicRequest(
      { authorization: `Bearer ${created.body.key}` },
      "/me",
    );
    expect(await response.json()).toMatchObject({ uid: "beta" });
  });
});
