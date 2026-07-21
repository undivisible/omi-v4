import { afterAll, beforeAll, describe, expect, test } from "bun:test";
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
  });
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  const migration = async (path: string) => {
    const sql = (await Bun.file(path).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    for (const statement of sql.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  };
  await migration("migrations/0001_initial.sql");
  await migration("migrations/0002_memory_and_policy.sql");
  await migration("migrations/0003_align_kr_model.sql");
  await migration("migrations/0004_saas_foundations.sql");
  await migration("migrations/0005_memory_search.sql");
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3), (?4, ?5, ?3, ?3)",
    )
    .bind("alpha", "alpha@example.test", now, "beta", "beta@example.test")
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("memory routes", () => {
  test("scope evidence to the Firebase UID and propagate source deletion", async () => {
    const created = await request("alpha", "/memories", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        content: "Alpha prefers concise status reports.",
        source: "conversation",
        evidence: [{ messageId: "message-1" }],
        profileKind: "stable",
      }),
    });
    expect(created.status).toBe(201);
    const identifiers = (await created.json()) as {
      id: string;
      sourceId: string;
      claimId: string;
    };

    const alpha = await request("alpha", "/memories");
    expect(alpha.status).toBe(200);
    const alphaBody = (await alpha.json()) as {
      memories: Array<{ id: string; evidence: Array<{ id: string }> }>;
    };
    expect(alphaBody.memories).toHaveLength(1);
    expect(alphaBody.memories[0]?.id).toBe(identifiers.id);
    expect(alphaBody.memories[0]?.evidence).toHaveLength(1);

    const retrieval = await request("alpha", "/memory/retrieve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "concise status", limit: 3 }),
    });
    expect(retrieval.status).toBe(200);
    expect((await retrieval.json()) as unknown).toEqual({
      query: "concise status",
      items: [
        {
          memory: { kind: "claim", id: identifiers.claimId },
          excerpt: "Alpha prefers concise status reports.",
          relevance_basis_points: 10000,
          evidence_ids: [alphaBody.memories[0]?.evidence[0]?.id],
        },
      ],
      gaps: [],
    });

    const revision = await request(
      "alpha",
      `/memory/sources/${identifiers.sourceId}/revisions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          payload: { content: "Alpha prefers short, numbered status reports." },
        }),
      },
    );
    expect(revision.status).toBe(201);
    expect((await revision.json()) as unknown).toMatchObject({ revision: 2 });

    const review = await request("alpha", "/memory/daily-reviews", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        localDate: "2026-07-21",
        inputRevision: "input-1",
        body: "You established a preference for concise reports.",
        citationIds: [alphaBody.memories[0]?.evidence[0]?.id],
      }),
    });
    expect(review.status).toBe(201);
    const reviews = await request("alpha", "/memory/daily-reviews");
    const reviewsBody = (await reviews.json()) as {
      reviews: Array<{ citations: unknown[] }>;
    };
    expect(reviewsBody.reviews).toHaveLength(1);
    expect(reviewsBody.reviews[0]?.citations).toHaveLength(1);

    const beta = await request("beta", "/memories");
    expect(((await beta.json()) as { memories: unknown[] }).memories).toEqual(
      [],
    );

    const removed = await request(
      "alpha",
      `/memory/sources/${identifiers.sourceId}`,
      { method: "DELETE" },
    );
    expect(removed.status).toBe(204);
    const afterDeletion = await request("alpha", "/memories");
    expect(
      ((await afterDeletion.json()) as { memories: unknown[] }).memories,
    ).toEqual([]);
    const reviewsAfterDeletion = await request(
      "alpha",
      "/memory/daily-reviews",
    );
    expect(
      (
        (await reviewsAfterDeletion.json()) as {
          reviews: unknown[];
        }
      ).reviews,
    ).toEqual([]);
  });
});

describe("settings routes", () => {
  test("enforce revisions, durations, and pre-existing owner confirmation", async () => {
    const changed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 0,
        duration: "persistent",
        patch: { proactiveRecommendations: false },
      }),
    });
    expect(changed.status).toBe(200);
    expect((await changed.json()) as unknown).toEqual({
      settings: {
        approvalMode: "once",
        proactiveRecommendations: false,
      },
      revision: 1,
      duration: "persistent",
      diff: {
        proactiveRecommendations: { from: true, to: false },
      },
      effectivePolicy: {
        approvalMode: "once",
        proactiveRecommendations: false,
      },
      restartRequired: false,
    });

    const stale = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 0,
        duration: "persistent",
        patch: { proactiveRecommendations: true },
      }),
    });
    expect(stale.status).toBe(409);

    const unconfirmed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 1,
        duration: "persistent",
        patch: { approvalMode: "auto" },
      }),
    });
    expect(unconfirmed.status).toBe(403);

    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO owner_confirmation_receipts (id, uid, purpose, value, created_at, expires_at) VALUES ('receipt-1', 'alpha', 'settings.approvalMode', 'auto', ?1, ?2)",
      )
      .bind(now - 1_000, now + 60_000)
      .run();
    const confirmed = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 1,
        duration: "persistent",
        confirmationReceiptId: "receipt-1",
        patch: { approvalMode: "auto" },
      }),
    });
    expect(confirmed.status).toBe(200);
    expect((await confirmed.json()) as unknown).toMatchObject({ revision: 2 });

    const scoped = await request("alpha", "/settings", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        expectedRevision: 2,
        duration: "task",
        taskId: "task-1",
        patch: { proactiveRecommendations: true },
      }),
    });
    expect(scoped.status).toBe(200);
    expect((await scoped.json()) as unknown).toMatchObject({
      revision: 2,
      duration: "task",
      scopeId: "task-1",
      diff: {
        proactiveRecommendations: { from: false, to: true },
      },
      effectivePolicy: {
        approvalMode: "auto",
        proactiveRecommendations: true,
      },
      restartRequired: false,
    });
  });
});

describe("channel routes", () => {
  test("unlink revokes only the current Firebase UID and records an audit", async () => {
    const now = Date.now();
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at)
         VALUES ('telegram', 'alpha-chat', 'alpha', ?1), ('telegram', 'beta-chat', 'beta', ?1)`,
      )
      .bind(now)
      .run();

    const response = await request("alpha", "/channels/telegram/link", {
      method: "DELETE",
    });
    expect(response.status).toBe(204);

    const bindings = await database
      .prepare(
        "SELECT uid, revoked_at FROM channel_bindings WHERE channel = 'telegram' ORDER BY uid",
      )
      .all();
    expect(bindings.results).toHaveLength(2);
    expect(bindings.results[0]?.uid).toBe("alpha");
    expect(bindings.results[0]?.revoked_at).not.toBeNull();
    expect(bindings.results[1]?.uid).toBe("beta");
    expect(bindings.results[1]?.revoked_at).toBeNull();

    const audit = await database
      .prepare(
        "SELECT action, target_id FROM audit_events WHERE uid = 'alpha' ORDER BY created_at DESC LIMIT 1",
      )
      .first();
    expect(audit).toMatchObject({
      action: "channel.unlinked",
      target_id: "telegram",
    });
  });
});

describe("billing routes", () => {
  test("ties Stripe Checkout and Portal sessions to the Firebase UID", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ url: string; body: URLSearchParams }> = [];
    globalThis.fetch = async (input, init) => {
      requests.push({
        url: String(input),
        body: new URLSearchParams(String(init?.body)),
      });
      return Response.json({
        id: `session-${requests.length}`,
        url: "https://stripe.test/session",
      });
    };
    try {
      const environment = {
        STRIPE_SECRET_KEY: "sk_test",
        STRIPE_PRO_PRICE_ID: "price_pro",
        APP_URL: "https://app.example.test",
      };
      const checkout = await request(
        "alpha",
        "/payments/stripe/checkout",
        { method: "POST" },
        environment,
      );
      expect(checkout.status).toBe(201);
      expect(requests[0]?.body.get("client_reference_id")).toBe("alpha");
      expect(
        requests[0]?.body.get("subscription_data[metadata][firebase_uid]"),
      ).toBe("alpha");
      await database
        .prepare(
          `INSERT INTO entitlements
             (uid, plan, status, stripe_customer_id, updated_at)
           VALUES ('alpha', 'pro', 'active', 'cus_alpha', ?1)`,
        )
        .bind(Date.now())
        .run();
      const portal = await request(
        "alpha",
        "/payments/stripe/portal",
        { method: "POST" },
        environment,
      );
      expect(portal.status).toBe(201);
      expect(requests[1]?.body.get("customer")).toBe("cus_alpha");
      expect(requests[1]?.url).toEndWith("/billing_portal/sessions");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
