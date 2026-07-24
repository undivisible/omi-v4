import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Miniflare } from "miniflare";
import { loadCronCursor, scanOnboardedUsers } from "../src/cron-cursor";
import type { Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;
let env: Bindings;
const now = Date.parse("2026-07-20T07:30:00.000Z");

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
  await database
    .prepare(
      `INSERT INTO users (uid, created_at, updated_at, onboarding_completed_at) VALUES
        ('a-user', ?1, ?1, ?1),
        ('b-user', ?1, ?1, ?1),
        ('c-user', ?1, ?1, ?1),
        ('d-user', ?1, ?1, ?1),
        ('e-user', ?1, ?1, ?1),
        ('z-dormant', ?1, ?1, NULL)`,
    )
    .bind(now)
    .run();
});

afterAll(() => miniflare.dispose());

describe("scanOnboardedUsers cursor rotation", () => {
  test("advances past the first page and wraps after the tail", async () => {
    const first = await scanOnboardedUsers(env, {
      cursorName: "digests",
      limit: 2,
      now,
    });
    expect(first.map((row) => row.uid)).toEqual(["a-user", "b-user"]);
    expect(await loadCronCursor(env, "digests")).toBe("b-user");

    const second = await scanOnboardedUsers(env, {
      cursorName: "digests",
      limit: 2,
      now: now + 1,
    });
    expect(second.map((row) => row.uid)).toEqual(["c-user", "d-user"]);
    expect(await loadCronCursor(env, "digests")).toBe("d-user");

    const third = await scanOnboardedUsers(env, {
      cursorName: "digests",
      limit: 2,
      now: now + 2,
    });
    expect(third.map((row) => row.uid)).toEqual(["e-user"]);
    expect(await loadCronCursor(env, "digests")).toBe("e-user");

    const wrapped = await scanOnboardedUsers(env, {
      cursorName: "digests",
      limit: 2,
      now: now + 3,
    });
    expect(wrapped.map((row) => row.uid)).toEqual(["a-user", "b-user"]);
    expect(await loadCronCursor(env, "digests")).toBe("b-user");
  });

  test("currents cursor is independent of digests", async () => {
    const page = await scanOnboardedUsers(env, {
      cursorName: "currents",
      limit: 3,
      now: now + 10,
    });
    expect(page.map((row) => row.uid)).toEqual(["a-user", "b-user", "c-user"]);
    expect(await loadCronCursor(env, "currents")).toBe("c-user");
    expect(await loadCronCursor(env, "digests")).toBe("b-user");
  });

  test("wrap with no onboarded users clears the cursor", async () => {
    await database
      .prepare(
        `INSERT INTO cron_cursors (name, last_uid, updated_at)
         VALUES ('empty-scan', 'e-user', ?1)`,
      )
      .bind(now)
      .run();
    await database
      .prepare("UPDATE users SET onboarding_completed_at = NULL")
      .run();

    const rows = await scanOnboardedUsers(env, {
      cursorName: "empty-scan",
      limit: 2,
      now: now + 20,
    });
    expect(rows).toEqual([]);
    expect(await loadCronCursor(env, "empty-scan")).toBe("");

    await database
      .prepare(
        "UPDATE users SET onboarding_completed_at = ?1 WHERE uid != 'z-dormant'",
      )
      .bind(now)
      .run();
  });
});
