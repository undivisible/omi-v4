import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import { appendMemoryLog, readMemoryLog } from "../src/memory-log";
import routes from "../src/routes";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const routeRequest = (uid: string, path: string) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/", routes);
  return app.request(path, undefined, { DB: database } as AppEnv["Bindings"]);
};

const claim = (id: string, value: string) => ({
  recordKind: "claim",
  recordId: id,
  payload: { id, subject: "Sam", predicate: "employer", value },
  recordedAt: 11,
});

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of [
    "0001_initial.sql",
    "0002_memory_and_policy.sql",
    "0003_align_kr_model.sql",
    "0005_memory_search.sql",
    "0016_zkr_sync.sql",
    "0017_zkr_read_projection.sql",
    "0021_memory_vectors.sql",
    "0029_memory_authority_log.sql",
    "0030_memory_log_projection.sql",
  ]) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    // Comments are stripped before splitting: a semicolon inside a comment
    // would otherwise cut a statement in half.
    const code = sql
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("--"))
      .join("\n");
    for (const statement of code.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1), ('beta', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(() => miniflare.dispose());

describe("authoritative memory log", () => {
  test("the worker assigns sequences in arrival order", async () => {
    const head = await appendMemoryLog(database, "alpha", "desktop", [
      claim("one", "Acme"),
      claim("two", "Beta"),
    ]);
    expect(head).toBe(2);
    const page = await readMemoryLog(database, "alpha", 0, 10);
    expect(page.records.map((record) => record.sequence)).toEqual([1, 2]);
    expect(page.records.map((record) => record.record_id)).toEqual([
      "one",
      "two",
    ]);
    expect(page.complete).toBe(true);
  });

  test("an identical replay is a no-op and does not reorder history", async () => {
    const head = await appendMemoryLog(database, "alpha", "desktop", [
      claim("one", "Acme"),
    ]);
    expect(head).toBe(2);
    const page = await readMemoryLog(database, "alpha", 0, 10);
    expect(page.records.length).toBe(2);
    expect(page.records[0]?.record_id).toBe("one");
  });

  test("a changed payload appends a new revision rather than overwriting", async () => {
    await appendMemoryLog(database, "alpha", "desktop", [
      claim("one", "Gamma"),
    ]);
    const page = await readMemoryLog(database, "alpha", 0, 10);
    expect(page.records.length).toBe(3);
    const revisions = page.records.filter(
      (record) => record.record_id === "one",
    );
    expect(revisions.length).toBe(2);
    expect(revisions[1]?.sequence).toBe(3);
    expect((revisions[0]?.payload as { value: string }).value).toBe("Acme");
    expect((revisions[1]?.payload as { value: string }).value).toBe("Gamma");
  });

  test("replicas share one stream but never merge identities", async () => {
    await appendMemoryLog(database, "alpha", "mobile", [claim("one", "Acme")]);
    const page = await readMemoryLog(database, "alpha", 0, 10);
    expect(page.records.length).toBe(4);
    expect(page.records[3]?.origin_replica).toBe("mobile");
    expect(page.records[3]?.record_id).toBe("one");
  });

  test("unknown record kinds are refused", async () => {
    const head = await appendMemoryLog(database, "alpha", "desktop", [
      { recordKind: "invented", recordId: "x", payload: {}, recordedAt: 1 },
    ]);
    expect(head).toBe(0);
    const page = await readMemoryLog(database, "alpha", 0, 10);
    expect(page.records.length).toBe(4);
  });

  test("the log is cursored and reports the authoritative head", async () => {
    const first = await readMemoryLog(database, "alpha", 0, 2);
    expect(first.records.length).toBe(2);
    expect(first.next_after).toBe(2);
    expect(first.head).toBe(4);
    expect(first.complete).toBe(false);
    const rest = await readMemoryLog(database, "alpha", first.next_after, 10);
    expect(rest.records.map((record) => record.sequence)).toEqual([3, 4]);
    expect(rest.complete).toBe(true);
  });

  test("the log route is scoped to the caller and records mirror cursors", async () => {
    const response = await routeRequest(
      "alpha",
      "/memory/log?after=0&limit=2&replica_id=desktop",
    );
    expect(response.status).toBe(200);
    const page = (await response.json()) as {
      records: unknown[];
      head: number;
    };
    expect(page.records.length).toBe(2);
    expect(page.head).toBe(4);
    const cursor = await database
      .prepare(
        "SELECT mirrored_sequence FROM memory_log_cursors WHERE uid = 'alpha' AND replica_id = 'desktop'",
      )
      .first<{ mirrored_sequence: number }>();
    expect(Number(cursor?.mirrored_sequence)).toBe(0);
    const foreign = await routeRequest("beta", "/memory/log?after=0");
    expect(((await foreign.json()) as { records: unknown[] }).records).toEqual(
      [],
    );
  });

  test("an invalid cursor is refused", async () => {
    expect((await routeRequest("alpha", "/memory/log?after=-1")).status).toBe(
      400,
    );
    expect((await routeRequest("alpha", "/memory/log?limit=5000")).status).toBe(
      400,
    );
  });
});
