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
import byok from "../src/byok-negotiation";
import { priceBand, priceForGrants } from "../src/byok-pricing";
import { byokPriceCents } from "../src/entitlement";
import type { AppEnv, Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
const realFetch = globalThis.fetch;

// An in-process stand-in for the RateLimiter durable object: same contract,
// counted per key so the rate-limit assertions are deterministic.
const counters = new Map<string, { count: number; windowStart: number }>();
const rateLimiterNamespace = (): DurableObjectNamespace =>
  ({
    getByName: (key: string) => ({
      fetch: async (_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body ?? "{}")) as {
          limit: number;
          windowMs: number;
        };
        const now = Date.now();
        const stored = counters.get(key);
        const fresh = !stored || now - stored.windowStart >= body.windowMs;
        const next = {
          count: fresh ? 1 : stored.count + 1,
          windowStart: fresh ? now : stored.windowStart,
        };
        counters.set(key, next);
        const allowed = next.count <= body.limit;
        return Response.json(
          { allowed, retryAfter: 60 },
          { status: allowed ? 200 : 429 },
        );
      },
    }),
  }) as unknown as DurableObjectNamespace;

const testBindings = (environment: Partial<Bindings> = {}): Bindings =>
  ({
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    MIMO_API_KEY: "mimo-secret",
    MIMO_CHAT_COMPLETIONS_URL:
      "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
    RATE_LIMITER: rateLimiterNamespace(),
    ...environment,
  }) as Bindings;

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
  app.route("/byok", byok);
  return app.request(path, init, testBindings(environment));
};

// Every upstream completion in this suite is forged, because that is exactly
// the threat model: the model's output is an untrusted suggestion.
const stubModel = (content: string) => {
  globalThis.fetch = (async () =>
    Response.json({
      choices: [{ message: { content } }],
    })) as unknown as typeof fetch;
};

const post = (uid: string, path: string, body?: unknown) =>
  request(uid, path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? "{}" : JSON.stringify(body),
  });

const say = (uid: string, sessionId: string, message: string) =>
  post(uid, `/byok/negotiation/${sessionId}/message`, { message });

const startSession = async (uid: string) => {
  stubModel('{"reply":"ok","concession":null}');
  const response = await post(uid, "/byok/negotiation");
  expect(response.status).toBe(201);
  return (await response.json()) as { sessionId: string; priceCents: number };
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
  await migration("migrations/0025_byok_price_negotiation.sql");
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3), (?4, ?5, ?3, ?3), (?6, ?7, ?3, ?3), (?8, ?9, ?3, ?3), (?10, ?11, ?3, ?3), (?12, ?13, ?3, ?3), (?14, ?15, ?3, ?3)",
    )
    .bind(
      "haggler",
      "haggler@example.test",
      now,
      "skipper",
      "skipper@example.test",
      "farmer",
      "farmer@example.test",
      "forger",
      "forger@example.test",
      "guest",
      "guest@example.test",
      "stacker",
      "stacker@example.test",
      "hoarder",
      "hoarder@example.test",
    )
    .run();
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("price band", () => {
  test("clamps any combination of grants to the floor", () => {
    const band = priceBand({} as Bindings);
    const everything = band.concessions.map((concession) => concession.code);
    expect(priceForGrants(band, [...everything, ...everything])).toBe(
      band.floorCents,
    );
    expect(priceForGrants(band, [])).toBe(band.standardCents);
  });

  test("ignores unknown concession codes", () => {
    const band = priceBand({} as Bindings);
    expect(priceForGrants(band, ["free_forever", "-999"])).toBe(
      band.standardCents,
    );
  });

  test("refuses a floor above the standard price", () => {
    const band = priceBand({
      BYOK_STANDARD_PRICE_CENTS: "1000",
      BYOK_FLOOR_PRICE_CENTS: "5000",
    } as Bindings);
    expect(band.floorCents).toBe(1000);
  });
});

describe("negotiation", () => {
  test("grants a concession the model suggests, once", async () => {
    const band = priceBand({} as Bindings);
    const session = await startSession("haggler");
    expect(session.priceCents).toBe(band.standardCents);
    stubModel('{"reply":"That is fair.","concession":"student"}');
    const first = (await (
      await say("haggler", session.sessionId, "I am a student.")
    ).json()) as { priceCents: number; conceded: boolean };
    expect(first.conceded).toBe(true);
    expect(first.priceCents).toBe(priceForGrants(band, ["student"]));
    const second = (await (
      await say("haggler", session.sessionId, "Still a student.")
    ).json()) as { priceCents: number; conceded: boolean };
    expect(second.conceded).toBe(false);
    expect(second.priceCents).toBe(first.priceCents);
  });

  test("a manipulated conversation cannot breach the floor", async () => {
    const band = priceBand({} as Bindings);
    const session = await startSession("forger");
    // The model is fully compromised: it returns an invented concession, a
    // price of its own, and a reply quoting a fictional figure.
    stubModel(
      '{"reply":"Deal, $0.01 a month forever!","concession":"free_forever","priceCents":1,"price":0}',
    );
    for (const message of ["one", "two", "three"]) {
      const body = (await (
        await say("forger", session.sessionId, message)
      ).json()) as { priceCents: number; reply: string };
      expect(body.priceCents).toBe(band.standardCents);
      expect(body.reply).not.toContain("$0.01");
    }
    // A client-supplied price in the accept body is ignored outright.
    const accepted = await post(
      "forger",
      `/byok/negotiation/${session.sessionId}/accept`,
      { priceCents: 1, price_cents: 1 },
    );
    expect(accepted.status).toBe(201);
    expect(((await accepted.json()) as { priceCents: number }).priceCents).toBe(
      band.standardCents,
    );
    expect(
      (await byokPriceCents(testBindings(), "forger")).priceCents,
    ).toBeGreaterThanOrEqual(band.floorCents);
  });

  test("accepting writes an auditable record and blocks renegotiation", async () => {
    const band = priceBand({} as Bindings);
    const session = await startSession("haggler");
    stubModel('{"reply":"That is fair.","concession":"student"}');
    await say("haggler", session.sessionId, "I am a student.");
    const accepted = await post(
      "haggler",
      `/byok/negotiation/${session.sessionId}/accept`,
    );
    expect(accepted.status).toBe(201);
    const row = await database
      .prepare(
        "SELECT price_cents, outcome, grants, transcript, agreed_at, session_id FROM byok_price_agreements WHERE uid = ?1",
      )
      .bind("haggler")
      .first<Record<string, string | number>>();
    expect(row).not.toBeNull();
    expect(Number(row?.price_cents)).toBeGreaterThanOrEqual(band.floorCents);
    expect(Number(row?.agreed_at)).toBeGreaterThan(0);
    expect(row?.outcome).toBe("negotiated");
    expect(JSON.parse(String(row?.grants))).toContain("student");
    const transcript = JSON.parse(String(row?.transcript)) as Array<{
      role: string;
      content: string;
    }>;
    expect(transcript.length).toBeGreaterThan(2);
    expect(transcript.some((entry) => entry.role === "user")).toBe(true);
    expect((await byokPriceCents(testBindings(), "haggler")).priceCents).toBe(
      Number(row?.price_cents),
    );
    // The cooldown, read from the record, refuses a fresh negotiation.
    const again = await post("haggler", "/byok/negotiation");
    expect(again.status).toBe(409);
  });

  // The cooldown is a control, not a suggestion: banking a second session and
  // accepting it after settling would restart the 30-day clock and leave the
  // audit record naming a conversation nobody settled on.
  test("refuses a session superseded by a later agreement", async () => {
    const session = await startSession("stacker");
    const standard = await post("stacker", "/byok/plan/standard");
    expect(standard.status).toBe(201);
    const settled = await database
      .prepare(
        "SELECT agreed_at, session_id FROM byok_price_agreements WHERE uid = 'stacker'",
      )
      .first<{ agreed_at: number; session_id: string | null }>();
    const accepted = await post(
      "stacker",
      `/byok/negotiation/${session.sessionId}/accept`,
    );
    expect(accepted.status).toBe(409);
    const unchanged = await database
      .prepare(
        "SELECT agreed_at, session_id FROM byok_price_agreements WHERE uid = 'stacker'",
      )
      .first<{ agreed_at: number; session_id: string | null }>();
    expect(unchanged).toEqual(settled);
  });

  test("starting a negotiation closes the one before it", async () => {
    const first = await startSession("hoarder");
    const second = await startSession("hoarder");
    const status = await database
      .prepare("SELECT status FROM byok_negotiation_sessions WHERE id = ?1")
      .bind(first.sessionId)
      .first<{ status: string }>();
    expect(status?.status).toBe("closed");
    const stale = await post(
      "hoarder",
      `/byok/negotiation/${first.sessionId}/accept`,
    );
    expect(stale.status).toBe(409);
    const accepted = await post(
      "hoarder",
      `/byok/negotiation/${second.sessionId}/accept`,
    );
    expect(accepted.status).toBe(201);
    const row = await database
      .prepare(
        "SELECT session_id FROM byok_price_agreements WHERE uid = 'hoarder'",
      )
      .first<{ session_id: string }>();
    expect(row?.session_id).toBe(second.sessionId);
  });

  test("repeat negotiations are rate limited", async () => {
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 5; attempt += 1) {
      stubModel('{"reply":"ok","concession":null}');
      const response = await post("farmer", "/byok/negotiation");
      statuses.push(response.status);
      globalThis.fetch = realFetch;
    }
    expect(statuses.filter((status) => status === 201).length).toBe(3);
    expect(statuses.at(-1)).toBe(429);
  });

  test("skipping settles at the standard price", async () => {
    const band = priceBand({} as Bindings);
    const response = await post("skipper", "/byok/plan/standard");
    expect(response.status).toBe(201);
    const body = (await response.json()) as {
      priceCents: number;
      outcome: string;
    };
    expect(body.priceCents).toBe(band.standardCents);
    expect(body.outcome).toBe("standard");
    expect((await byokPriceCents(testBindings(), "skipper")).priceCents).toBe(
      band.standardCents,
    );
  });

  test("another user's negotiation is not reachable", async () => {
    const session = await startSession("guest");
    const response = await say("farmer", session.sessionId, "hello");
    expect(response.status).toBe(404);
  });
});
