import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Miniflare } from "miniflare";
import { retrieveCitedMemory } from "../src/memory-read";
import { searchMemoryClaims } from "../src/memory-vectors";
import type { Bindings } from "../src/types";

// End-to-end recall: store a memory, then ask for it with a query worded
// differently from the stored text, and assert the right claim comes back —
// cited (evidence ids) on the FTS path, and content-matched on the vector path.

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

type StoredVector = {
  id: string;
  values: number[];
  metadata: Record<string, unknown>;
};

// A deterministic stand-in for Vectorize: cosine over the toy embeddings the
// fake AI emits, so a query recalls the nearest stored claim by real distance
// rather than insertion order.
class CosineIndex {
  vectors = new Map<string, StoredVector>();
  async upsert(list: StoredVector[]) {
    for (const vector of list) this.vectors.set(vector.id, vector);
    return { mutationId: "m" };
  }
  async deleteByIds(ids: string[]) {
    for (const id of ids) this.vectors.delete(id);
    return { mutationId: "m" };
  }
  async query(
    vector: number[],
    options: { topK: number; filter?: { uid?: string } },
  ) {
    const dot = (a: number[], b: number[]) =>
      a.reduce((sum, value, index) => sum + value * (b[index] ?? 0), 0);
    const norm = (a: number[]) => Math.sqrt(dot(a, a)) || 1;
    const matches = [...this.vectors.values()]
      .filter((stored) => stored.metadata.uid === options.filter?.uid)
      .map((stored) => ({
        id: stored.id,
        score:
          dot(vector, stored.values) / (norm(vector) * norm(stored.values)),
      }))
      .sort((left, right) => right.score - left.score)
      .slice(0, options.topK);
    return { matches, count: matches.length };
  }
}

// A toy bag-of-words embedding: one dimension per known token, so texts sharing
// words ("matcha", "tea") land close and unrelated ones ("chess") do not.
const vocabulary = [
  "matcha",
  "green",
  "tea",
  "morning",
  "drink",
  "chess",
  "sunday",
];
const embed = (text: string): number[] => {
  const words = text.toLowerCase().split(/\s+/);
  return vocabulary.map((term) => (words.includes(term) ? 1 : 0));
};
const fakeAi = {
  run: async (_model: string, inputs: Record<string, unknown>) => ({
    data: (inputs.text as string[]).map((value) => embed(value)),
  }),
};

const index = new CosineIndex();
let database: D1Database;
let env: Bindings;

const seedClaim = async (
  id: string,
  uid: string,
  content: string,
  vector: number[],
) => {
  const now = Date.now();
  await database.batch([
    database
      .prepare(
        "INSERT INTO memory_sources (id, uid, kind, external_id, created_at, updated_at) VALUES (?1, ?2, 'conversation', ?1, ?3, ?3)",
      )
      .bind(`${id}-source`, uid, now),
    database
      .prepare(
        "INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, 'hash', '{}', ?4, ?4)",
      )
      .bind(`${id}-revision`, `${id}-source`, uid, now),
    database
      .prepare(
        "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      )
      .bind(`${id}-evidence`, uid, `${id}-revision`, content, now),
    database
      .prepare(
        "INSERT INTO memory_claims (id, uid, content, value, recorded_at, status) VALUES (?1, ?2, ?3, ?3, ?4, 'accepted')",
      )
      .bind(id, uid, content, now),
    database
      .prepare(
        "INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation, confidence_basis_points) VALUES (?1, ?2, ?3, 'supports', 9000)",
      )
      .bind(uid, id, `${id}-evidence`),
    database
      .prepare(
        "INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value) VALUES (?1, ?2, ?3, '', '', ?3)",
      )
      .bind(id, uid, content),
  ]);
  await index.upsert([
    { id, values: vector, metadata: { uid, claimId: id, kind: "claim" } },
  ]);
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
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('sam', ?1, ?1), ('mallory', ?1, ?1)",
    )
    .bind(now)
    .run();
  env = {
    DB: database,
    MEMORY_VECTORS: index as unknown as VectorizeIndex,
    AI: fakeAi,
  } as Bindings;
  await seedClaim(
    "claim-matcha",
    "sam",
    "Sam enjoys drinking matcha green tea every morning",
    embed("matcha green tea morning drink"),
  );
  await seedClaim(
    "claim-chess",
    "sam",
    "Sam plays chess on Sunday afternoons",
    embed("chess sunday"),
  );
});

afterAll(() => miniflare.dispose());

describe("recall", () => {
  test("FTS recall returns the right claim, cited, from a differently-worded query", async () => {
    const recalled = await retrieveCitedMemory(
      database,
      "sam",
      "matcha tea",
      5,
    );
    expect(recalled.items.length).toBeGreaterThan(0);
    expect(recalled.items[0]?.memory.id).toBe("claim-matcha");
    expect(recalled.items[0]?.excerpt).toBe(
      "Sam enjoys drinking matcha green tea every morning",
    );
    // The claim comes back cited — its supporting evidence id is attached.
    expect(recalled.items[0]?.evidence_ids).toContain("claim-matcha-evidence");
    expect(recalled.gaps).toEqual([]);
  });

  test("vector recall ranks the semantically-nearest claim first", async () => {
    const matches = await searchMemoryClaims(env, "sam", "what tea do I like");
    expect(matches[0]?.id).toBe("claim-matcha");
    expect(matches[0]?.content).toBe(
      "Sam enjoys drinking matcha green tea every morning",
    );
  });

  test("recall is uid-scoped: another user gets nothing", async () => {
    expect(
      (await retrieveCitedMemory(database, "mallory", "matcha tea", 5)).items,
    ).toEqual([]);
    expect(await searchMemoryClaims(env, "mallory", "matcha tea")).toEqual([]);
  });
});
