import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import routes from "../src/routes";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const request = (uid: string, path: string, init?: RequestInit) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/", routes);
  return app.request(path, init, { DB: database } as AppEnv["Bindings"]);
};

const count = async (table: string, uid: string) => {
  const row = await database
    .prepare(`SELECT COUNT(*) AS total FROM ${table} WHERE uid = ?1`)
    .bind(uid)
    .first<{ total: number }>();
  return Number(row?.total ?? 0);
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
  for (const uid of ["alpha", "beta"]) {
    await database.batch([
      database
        .prepare(
          "INSERT INTO user_settings (uid, value, revision, updated_at) VALUES (?1, '{}', 1, ?2)",
        )
        .bind(uid, now),
      database
        .prepare(
          "INSERT INTO oauth_connections (uid, provider, access_token, created_at, updated_at) VALUES (?1, 'openai', 'token', ?2, ?2)",
        )
        .bind(uid, now),
      database
        .prepare(
          "INSERT INTO owner_confirmation_receipts (id, uid, purpose, value, created_at, expires_at) VALUES (?1, ?2, 'settings.approvalMode', 'auto', ?3, ?3)",
        )
        .bind(`receipt-${uid}`, uid, now + 60_000),
      database
        .prepare(
          "INSERT INTO managed_ai_requests (id, uid, provider, model, status, input_characters, requested_max_output_tokens, created_at, updated_at) VALUES (?1, ?2, 'worker', 'model', 'complete', 10, 100, ?3, ?3)",
        )
        .bind(`request-${uid}`, uid, now),
      database
        .prepare(
          "INSERT INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
        )
        .bind(`conversation-${uid}`, uid, now),
    ]);
  }
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("onboarding profile", () => {
  test("reports incomplete before completion", async () => {
    const response = await request("alpha", "/profile/onboarding");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      complete: false,
      completedAt: null,
    });
  });

  test("rejects invalid completion payloads", async () => {
    const response = await request("alpha", "/profile/onboarding", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ complete: false }),
    });
    expect(response.status).toBe(400);
  });

  test("persists completion per uid and stays idempotent", async () => {
    const first = await request("alpha", "/profile/onboarding", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ complete: true }),
    });
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as { completedAt: number };
    expect(firstBody.completedAt).toBeGreaterThan(0);

    const again = await request("alpha", "/profile/onboarding", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ complete: true }),
    });
    expect(again.status).toBe(200);
    expect(((await again.json()) as { completedAt: number }).completedAt).toBe(
      firstBody.completedAt,
    );

    const read = await request("alpha", "/profile/onboarding");
    expect(await read.json()).toEqual({
      complete: true,
      completedAt: firstBody.completedAt,
    });

    const other = await request("beta", "/profile/onboarding");
    expect(await other.json()).toEqual({ complete: false, completedAt: null });
  });

  test("creates the user row when missing", async () => {
    const response = await request("gamma", "/profile/onboarding", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ complete: true }),
    });
    expect(response.status).toBe(200);
    const read = await request("gamma", "/profile/onboarding");
    expect(((await read.json()) as { complete: boolean }).complete).toBe(true);
  });
});

describe("account deletion", () => {
  test("removes only the caller's rows across uid-scoped tables", async () => {
    const tables = [
      "users",
      "user_settings",
      "oauth_connections",
      "owner_confirmation_receipts",
      "managed_ai_requests",
      "conversations",
    ];
    for (const table of tables) {
      expect(await count(table, "alpha")).toBeGreaterThan(0);
    }

    const response = await request("alpha", "/account", { method: "DELETE" });
    expect(response.status).toBe(204);

    for (const table of tables) {
      expect(await count(table, "alpha")).toBe(0);
      expect(await count(table, "beta")).toBeGreaterThan(0);
    }
  });

  test("is idempotent for an already-deleted account", async () => {
    const response = await request("alpha", "/account", { method: "DELETE" });
    expect(response.status).toBe(204);
  });
});
