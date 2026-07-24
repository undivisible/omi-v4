import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Miniflare } from "miniflare";
import { generateDueDigests, localClock } from "../src/digests";
import { listDailyReviews } from "../src/memory-read";
import type { Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
let env: Bindings;

// A fixed UTC instant whose wall clock lands on the digest hours at offset 0:
// 07:30 UTC is inside the daily window, 21:30 UTC inside the nightly window.
const DAY = "2026-07-20";
const dailyNow = Date.parse(`${DAY}T07:30:00.000Z`);
const nightlyNow = Date.parse(`${DAY}T21:30:00.000Z`);
const dayStartMs = Date.parse(`${DAY}T00:00:00.000Z`);

const seedEvidence = async (uid: string, suffix: string, quote: string) => {
  await database.batch([
    database
      .prepare(
        "INSERT INTO memory_sources (id, uid, kind, external_id, created_at, updated_at) VALUES (?1, ?2, 'conversation', ?1, ?3, ?3)",
      )
      .bind(`${uid}-source-${suffix}`, uid, dayStartMs),
    database
      .prepare(
        "INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, 'hash', '{}', ?4, ?4)",
      )
      .bind(
        `${uid}-revision-${suffix}`,
        `${uid}-source-${suffix}`,
        uid,
        dayStartMs,
      ),
    database
      .prepare(
        "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      )
      .bind(
        `${uid}-evidence-${suffix}`,
        uid,
        `${uid}-revision-${suffix}`,
        quote,
        dayStartMs,
      ),
  ]);
};

const seedClaim = async (
  uid: string,
  suffix: string,
  content: string,
  recordedAt: number,
) => {
  await seedEvidence(uid, suffix, content);
  await database.batch([
    database
      .prepare(
        "INSERT INTO memory_claims (id, uid, content, value, recorded_at, status) VALUES (?1, ?2, ?3, ?3, ?4, 'accepted')",
      )
      .bind(`${uid}-claim-${suffix}`, uid, content, recordedAt),
    database
      .prepare(
        "INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation, confidence_basis_points) VALUES (?1, ?2, ?3, 'supports', 9000)",
      )
      .bind(uid, `${uid}-claim-${suffix}`, `${uid}-evidence-${suffix}`),
  ]);
};

const seedCurrent = async (uid: string, suffix: string, title: string) => {
  await seedEvidence(uid, suffix, title);
  await database
    .prepare(
      `INSERT INTO currents
        (id, uid, evidence_id, title, summary, reason, confidence_basis_points,
         proposed_action, status, surface_at, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, 9000, ?7, 'surfaced', ?8, ?8, ?8)`,
    )
    .bind(
      `${uid}-current-${suffix}`,
      uid,
      `${uid}-evidence-${suffix}`,
      title,
      "Summary line",
      "Because",
      JSON.stringify({ kind: "review", instruction: `Handle ${title}` }),
      dayStartMs,
    )
    .run();
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of readdirSync("migrations").sort()) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    const code = sql
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("--"))
      .join("\n");
    for (const statement of code.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  env = { DB: database } as Bindings;
  // `active` is onboarded and drives the digests. `dormant` never onboarded, so
  // it must be skipped. `linked` also has a channel binding for delivery.
  await database
    .prepare(
      `INSERT INTO users (uid, created_at, updated_at, onboarding_completed_at) VALUES
        ('active', ?1, ?1, ?1), ('linked', ?1, ?1, ?1), ('dormant', ?1, ?1, NULL)`,
    )
    .bind(dayStartMs)
    .run();
});

afterAll(() => miniflare.dispose());

describe("digest local clock", () => {
  test("offset shifts the local wall clock and day boundary", () => {
    // 23:30 UTC + 60 min is 00:30 the next local day.
    const clock = localClock(Date.parse("2026-07-20T23:30:00.000Z"), 60);
    expect(clock.date).toBe("2026-07-21");
    expect(clock.hour).toBe(0);
    expect(clock.dayStartMs).toBe(Date.parse("2026-07-20T23:00:00.000Z"));
  });
});

describe("nightly digest — what you did", () => {
  test("summarizes the day's captured claims once, idempotently", async () => {
    await seedClaim(
      "active",
      "n1",
      "Shipped the Alpenglow build",
      dayStartMs + 3_600_000,
    );
    await seedClaim(
      "active",
      "n2",
      "Reviewed the launch checklist",
      dayStartMs + 7_200_000,
    );
    // Outside the local day: must not appear in the recap.
    await seedClaim("active", "n0", "Yesterday's leftover", dayStartMs - 1);

    await generateDueDigests(env, nightlyNow);
    await generateDueDigests(env, nightlyNow);

    const reviews = await listDailyReviews(database, "active");
    const nightly = reviews.filter((review) => review.kind === "nightly");
    expect(nightly).toHaveLength(1);
    expect(String(nightly[0]?.body)).toContain("What you did today");
    expect(String(nightly[0]?.body)).toContain("Shipped the Alpenglow build");
    expect(String(nightly[0]?.body)).toContain("Reviewed the launch checklist");
    expect(String(nightly[0]?.body)).not.toContain("Yesterday's leftover");
    expect((nightly[0]?.citations as unknown[]).length).toBe(2);
    expect(nightly[0]?.localDate).toBe(DAY);
  });

  test("does not fire outside the evening window", async () => {
    await seedClaim(
      "linked",
      "n1",
      "Something at noon",
      dayStartMs + 3_600_000,
    );
    await generateDueDigests(env, Date.parse(`${DAY}T12:00:00.000Z`));
    const reviews = await listDailyReviews(database, "linked");
    expect(reviews.filter((review) => review.kind === "nightly")).toHaveLength(
      0,
    );
  });
});

describe("daily digest — what you need to do", () => {
  test("briefs surfaced currents, most important first, and skips the dormant user", async () => {
    await seedCurrent("active", "c1", "Reply to the launch email");

    await generateDueDigests(env, dailyNow);
    await generateDueDigests(env, dailyNow);

    const reviews = await listDailyReviews(database, "active");
    const daily = reviews.filter((review) => review.kind === "daily");
    expect(daily).toHaveLength(1);
    expect(String(daily[0]?.body)).toContain("What you need to do today");
    expect(String(daily[0]?.body)).toContain("Reply to the launch email");
    expect(String(daily[0]?.body)).toContain(
      "Handle Reply to the launch email",
    );
    expect((daily[0]?.citations as unknown[]).length).toBe(1);

    const dormant = await listDailyReviews(database, "dormant");
    expect(dormant).toHaveLength(0);
  });
});

describe("digest delivery", () => {
  test("a linked channel gets one queued delivery per digest", async () => {
    await database
      .prepare(
        `INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, channel_chat_id)
         VALUES ('telegram', 'tg-linked', 'linked', ?1, 'chat-linked')`,
      )
      .bind(dayStartMs)
      .run();
    await seedCurrent("linked", "c1", "Confirm the deploy window");

    await generateDueDigests(env, dailyNow);
    await generateDueDigests(env, dailyNow);

    const deliveries = await database
      .prepare(
        "SELECT id, channel_chat_id, text FROM channel_deliveries WHERE uid = 'linked'",
      )
      .all<{ id: string; channel_chat_id: string; text: string }>();
    expect(deliveries.results).toHaveLength(1);
    expect(deliveries.results?.[0]?.id).toBe(`digest:daily:linked:${DAY}`);
    expect(deliveries.results?.[0]?.channel_chat_id).toBe("chat-linked");
    expect(String(deliveries.results?.[0]?.text)).toContain(
      "Confirm the deploy window",
    );
  });

  test("no delivery is queued for a user without a linked channel", async () => {
    const deliveries = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM channel_deliveries WHERE uid = 'active'",
      )
      .first<{ count: number }>();
    expect(Number(deliveries?.count)).toBe(0);
  });
});
