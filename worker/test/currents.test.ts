import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import currents from "../src/currents";
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
    context.set("auth", { uid, email: null });
    await next();
  });
  app.route("/currents", currents);
  return app.request(`/currents${path === "/" ? "" : path}`, init, {
    DB: database,
  } as AppEnv["Bindings"]);
};

const post = (uid: string, path: string, body: Record<string, unknown>) =>
  request(uid, path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of [
    "0001_initial.sql",
    "0002_memory_and_policy.sql",
    "0003_align_kr_model.sql",
    "0012_currents.sql",
  ]) {
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
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1), ('beta', ?1, ?1)",
    )
    .bind(now)
    .run();
  for (const uid of ["alpha", "beta"]) {
    await database.batch([
      database
        .prepare(
          "INSERT INTO memory_sources (id, uid, kind, external_id, created_at, updated_at) VALUES (?1, ?2, 'conversation', ?1, ?3, ?3)",
        )
        .bind(`${uid}-source`, uid, now),
      database
        .prepare(
          "INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, 'hash', '{}', ?4, ?4)",
        )
        .bind(`${uid}-revision`, `${uid}-source`, uid, now),
      database
        .prepare(
          "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, created_at) VALUES (?1, ?2, ?3, 'Finish the release', ?4)",
        )
        .bind(`${uid}-evidence`, uid, `${uid}-revision`, now),
    ]);
  }
});

afterAll(() => miniflare.dispose());

describe("Currents", () => {
  test("creates only from UID-scoped live evidence and ranks deterministically", async () => {
    const now = Date.now();
    expect(
      (
        await post("alpha", "/candidates", {
          evidenceId: "beta-evidence",
          title: "Wrong tenant",
          summary: "No",
          reason: "No",
          confidence: 1,
          proposedNextStep: "No",
          surfaceAt: now,
        })
      ).status,
    ).toBe(404);
    for (const [title, confidence] of [
      ["Lower", 0.5],
      ["Higher", 0.9],
    ] as const) {
      expect(
        (
          await post("alpha", "/candidates", {
            evidenceId: "alpha-evidence",
            title,
            summary: `${title} summary`,
            reason: "Cited conversation",
            confidence,
            proposedNextStep: `Review ${title}`,
            surfaceAt: now,
          })
        ).status,
      ).toBe(201);
    }
    const response = await request("alpha", "/");
    const body = (await response.json()) as {
      currents: Array<{
        title: string;
        evidence: Array<{ sourceId: string }>;
        reason: string;
      }>;
    };
    expect(body.currents.map((item) => item.title)).toEqual([
      "Higher",
      "Lower",
    ]);
    expect(body.currents[0]?.evidence[0]?.sourceId).toBe("alpha-source");
    expect(body.currents[0]?.reason).toBe("Cited conversation");
    expect((await request("beta", "/")).json()).resolves.toEqual({
      currents: [],
    });
  });

  test("records feedback and consumes approval exactly once before learning an outcome", async () => {
    const list = (await (await request("alpha", "/")).json()) as {
      currents: Array<{ id: string }>;
    };
    const [first, second] = list.currents;
    const feedback = await Promise.all([
      post("alpha", `/${first!.id}/feedback`, { kind: "dismissed" }),
      post("alpha", `/${first!.id}/feedback`, { kind: "dismissed" }),
    ]);
    expect(feedback.map(({ status }) => status).sort()).toEqual([200, 409]);
    const acceptances = await Promise.all([
      post("alpha", `/${second!.id}/accept`, {}),
      post("alpha", `/${second!.id}/accept`, {}),
    ]);
    expect(acceptances.map(({ status }) => status).sort()).toEqual([201, 409]);
    const accepted = acceptances.find(({ status }) => status === 201)!;
    const handoff = (await accepted.json()) as {
      executionId: string;
      approvalNonce: string;
      state: string;
    };
    expect(handoff.state).toBe("awaiting_approval");
    await database
      .prepare(
        "UPDATE currents SET expires_at = surface_at + 1 WHERE id = ?1 AND uid = 'alpha'",
      )
      .bind(second!.id)
      .run();
    await request("alpha", "/");
    expect(
      (
        await database
          .prepare("SELECT status FROM currents WHERE id = ?1")
          .bind(second!.id)
          .first()
      )?.status,
    ).toBe("accepted");
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/approve`, {
          approvalNonce: handoff.approvalNonce,
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/approve`, {
          approvalNonce: handoff.approvalNonce,
        })
      ).status,
    ).toBe(409);
    expect(
      (
        await post("beta", `/executions/${handoff.executionId}/outcome`, {
          state: "succeeded",
          detail: "Done",
        })
      ).status,
    ).toBe(409);
    const outcomes = await Promise.all([
      post("alpha", `/executions/${handoff.executionId}/outcome`, {
        state: "succeeded",
        detail: "Done",
      }),
      post("alpha", `/executions/${handoff.executionId}/outcome`, {
        state: "succeeded",
        detail: "Done",
      }),
    ]);
    expect(outcomes.map(({ status }) => status).sort()).toEqual([200, 409]);
    const execution = await database
      .prepare(
        "SELECT state, outcome FROM current_executions WHERE id = ?1 AND uid = 'alpha'",
      )
      .bind(handoff.executionId)
      .first();
    expect(execution?.state).toBe("succeeded");
    expect(JSON.parse(String(execution?.outcome))).toEqual({ detail: "Done" });
  });

  test("consumes a rejected handoff once and dismisses its Current", async () => {
    const now = Date.now();
    const created = await post("alpha", "/candidates", {
      evidenceId: "alpha-evidence",
      title: "Reject me",
      summary: "Do not run this",
      reason: "Cited conversation",
      confidence: 0.8,
      proposedNextStep: "Do not run",
      surfaceAt: now,
    });
    const candidate = (await created.json()) as { current: { id: string } };
    await request("alpha", "/");
    const accepted = await post("alpha", `/${candidate.current.id}/accept`, {});
    const handoff = (await accepted.json()) as {
      executionId: string;
      approvalNonce: string;
    };
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/reject`, {
          approvalNonce: handoff.approvalNonce,
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/reject`, {
          approvalNonce: handoff.approvalNonce,
        })
      ).status,
    ).toBe(409);
    const rows = await database
      .prepare(
        "SELECT c.status, x.state FROM currents c JOIN current_executions x ON x.current_id = c.id AND x.uid = c.uid WHERE c.id = ?1 AND c.uid = 'alpha'",
      )
      .bind(candidate.current.id)
      .first();
    expect(rows).toEqual({ status: "dismissed", state: "rejected" });
  });
});
