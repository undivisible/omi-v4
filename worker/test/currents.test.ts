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
    "0015_currents_generation.sql",
    "0016_zkr_sync.sql",
    "0017_zkr_read_projection.sql",
    "0018_praefectus_approval_receipts.sql",
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
      "INSERT INTO users (uid, created_at, updated_at) VALUES ('alpha', ?1, ?1), ('beta', ?1, ?1), ('gamma', ?1, ?1)",
    )
    .bind(now)
    .run();
  for (const uid of ["alpha", "beta", "gamma"]) {
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
      database
        .prepare(
          "INSERT INTO memory_claims (id, uid, content, value, recorded_at) VALUES (?1, ?2, 'Finish the release', 'Finish the release', ?3)",
        )
        .bind(`${uid}-claim`, uid, now),
      database
        .prepare(
          "INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation, confidence_basis_points) VALUES (?1, ?2, ?3, 'supports', 9000)",
        )
        .bind(uid, `${uid}-claim`, `${uid}-evidence`),
      database
        .prepare(
          "INSERT INTO memory_profile_entries (id, uid, claim_id, profile_kind, profile_key, profile_value, created_at, updated_at) VALUES (?1, ?2, ?3, 'current', 'priority', 'Finish the release', ?4, ?4)",
        )
        .bind(`${uid}-profile`, uid, `${uid}-claim`, now),
    ]);
  }
});

afterAll(() => miniflare.dispose());

describe("Currents", () => {
  test("generates one cited candidate from production memory", async () => {
    const generated = await Promise.all([
      post("gamma", "/generate", {}),
      post("gamma", "/generate", {}),
    ]);
    expect(generated.map(({ status }) => status).sort()).toEqual([200, 201]);
    const list = (await (await request("gamma", "/")).json()) as {
      currents: Array<{
        title: string;
        evidence: Array<{ sourceId: string }>;
      }>;
    };
    expect(list.currents).toHaveLength(1);
    expect(list.currents[0]?.title).toBe("Revisit: Finish the release");
    expect(list.currents[0]?.evidence[0]?.sourceId).toBe("gamma-source");
    expect(
      await database
        .prepare("SELECT COUNT(*) AS count FROM currents WHERE uid = 'gamma'")
        .first(),
    ).toEqual({ count: 1 });
  });

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
      policyGeneration: number;
    };
    expect(handoff.state).toBe("awaiting_approval");
    expect(handoff.policyGeneration).toBe(0);
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
    const approval = {
      approvalNonce: handoff.approvalNonce,
      operationId: "operation-alpha",
      proposalId: "proposal-alpha",
      actionHash: "a".repeat(64),
      risk: "external",
      generation: 0,
    };
    const approvedResponse = await post(
      "alpha",
      `/executions/${handoff.executionId}/approve`,
      approval,
    );
    expect(approvedResponse.status).toBe(200);
    const approved = (await approvedResponse.json()) as {
      receipt: {
        version: string;
        receiptId: string;
        receiptToken: string;
        subject: string;
        policyGeneration: number;
        operationId: string;
        proposalId: string;
        actionHash: string;
        risk: string;
        issuedAtMs: number;
        expiresAtMs: number;
      };
    };
    expect(approved.receipt).toMatchObject({
      version: "omi-current-authority-v1",
      subject: "alpha",
      policyGeneration: 0,
      operationId: approval.operationId,
      proposalId: approval.proposalId,
      actionHash: approval.actionHash,
      risk: approval.risk,
    });
    expect(approved.receipt.receiptToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(approved.receipt.expiresAtMs).toBeGreaterThan(
      approved.receipt.issuedAtMs,
    );
    expect(
      (
        await post(
          "alpha",
          `/executions/${handoff.executionId}/approve`,
          approval,
        )
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
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/outcome`, {
          state: "succeeded",
          detail: "Too early",
        })
      ).status,
    ).toBe(409);
    const claim = {
      receiptToken: approved.receipt.receiptToken,
      subject: approved.receipt.subject,
      policyGeneration: approved.receipt.policyGeneration,
      operationId: approved.receipt.operationId,
      proposalId: approved.receipt.proposalId,
      actionHash: approved.receipt.actionHash,
      risk: approved.receipt.risk,
    };
    expect(
      (
        await post(
          "beta",
          `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
          claim,
        )
      ).status,
    ).toBe(400);
    expect(
      (
        await post(
          "alpha",
          `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
          { ...claim, actionHash: "b".repeat(64) },
        )
      ).status,
    ).toBe(409);
    const claimedResponse = await post(
      "alpha",
      `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
      claim,
    );
    expect(claimedResponse.status).toBe(200);
    expect((await claimedResponse.json()) as unknown).toMatchObject({
      executionId: handoff.executionId,
      state: "claimed",
      receipt: {
        receiptId: approved.receipt.receiptId,
        subject: "alpha",
        actionHash: approval.actionHash,
      },
    });
    expect(
      (
        await post(
          "alpha",
          `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
          claim,
        )
      ).status,
    ).toBe(409);
    const fallback = await database
      .prepare(
        `SELECT x.state, x.outcome, x.outcome_reported_at, c.status AS current_status
         FROM current_executions x JOIN currents c ON c.id = x.current_id AND c.uid = x.uid
         WHERE x.id = ?1 AND x.uid = 'alpha'`,
      )
      .bind(handoff.executionId)
      .first();
    expect(fallback?.state).toBe("outcome_unknown");
    expect(fallback?.outcome_reported_at).toBeNull();
    expect(fallback?.current_status).toBe("expired");
    expect(JSON.parse(String(fallback?.outcome))).toEqual({
      detail: "Execution authority was claimed, but no outcome was reported",
    });
    const reported = await post(
      "alpha",
      `/executions/${handoff.executionId}/outcome`,
      {
        state: "succeeded",
        detail: "Done",
      },
    );
    expect(reported.status).toBe(200);
    const replayed = await post(
      "alpha",
      `/executions/${handoff.executionId}/outcome`,
      {
        state: "succeeded",
        detail: "Done",
      },
    );
    expect(replayed.status).toBe(200);
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/outcome`, {
          state: "succeeded",
          detail: "Different",
        })
      ).status,
    ).toBe(409);
    expect(
      (
        await post("alpha", `/executions/${handoff.executionId}/outcome`, {
          state: "failed",
          detail: "Done",
        })
      ).status,
    ).toBe(409);
    const execution = await database
      .prepare(
        "SELECT state, outcome, outcome_reported_at, receipt_claimed_at, receipt_token_hash FROM current_executions WHERE id = ?1 AND uid = 'alpha'",
      )
      .bind(handoff.executionId)
      .first();
    expect(execution?.state).toBe("succeeded");
    expect(execution?.outcome_reported_at).toBeNumber();
    expect(execution?.receipt_claimed_at).toBeNumber();
    expect(execution?.receipt_token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(execution?.receipt_token_hash).not.toBe(
      approved.receipt.receiptToken,
    );
    expect(JSON.parse(String(execution?.outcome))).toEqual({ detail: "Done" });
  });

  test("records failure, ambiguous dispatch, cancellation, and expiry before any effect", async () => {
    for (const [index, state] of [
      "failed",
      "outcome_unknown",
      "cancelled_before_effect",
      "expired_before_effect",
    ].entries()) {
      const created = await post("gamma", "/candidates", {
        evidenceId: "gamma-evidence",
        title: `No effect ${index}`,
        summary: "Do not execute",
        reason: "Cited conversation",
        confidence: 0.8,
        proposedNextStep: "Do not execute",
        surfaceAt: Date.now(),
      });
      const candidate = (await created.json()) as { current: { id: string } };
      await request("gamma", "/");
      const accepted = await post(
        "gamma",
        `/${candidate.current.id}/accept`,
        {},
      );
      const handoff = (await accepted.json()) as {
        executionId: string;
        approvalNonce: string;
      };
      expect(
        (
          await post("gamma", `/executions/${handoff.executionId}/approve`, {
            approvalNonce: handoff.approvalNonce,
            operationId: `no-effect-operation-${index}`,
            proposalId: `no-effect-proposal-${index}`,
            actionHash: String(index + 1).repeat(64),
            risk: "destructive",
            generation: 0,
          })
        ).status,
      ).toBe(200);
      const outcome = { state, detail: `No effect ${index}` };
      expect(
        (
          await post(
            "gamma",
            `/executions/${handoff.executionId}/outcome`,
            outcome,
          )
        ).status,
      ).toBe(200);
      expect(
        (
          await post(
            "gamma",
            `/executions/${handoff.executionId}/outcome`,
            outcome,
          )
        ).status,
      ).toBe(200);
      const stored = await database
        .prepare(
          `SELECT x.state, x.receipt_claimed_at, x.outcome_reported_at, c.status AS current_status
           FROM current_executions x JOIN currents c ON c.id = x.current_id AND c.uid = x.uid
           WHERE x.id = ?1 AND x.uid = 'gamma'`,
        )
        .bind(handoff.executionId)
        .first();
      expect(stored?.state).toBe(state);
      expect(stored?.receipt_claimed_at).toBeNull();
      expect(stored?.outcome_reported_at).toBeNumber();
      expect(stored?.current_status).toBe("expired");
    }
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

  test("invalidates unclaimed receipts on server expiry or policy change", async () => {
    const now = Date.now();
    const created = await post("beta", "/candidates", {
      evidenceId: "beta-evidence",
      title: "Bound approval",
      summary: "Check the binding",
      reason: "Cited conversation",
      confidence: 0.8,
      proposedNextStep: "Check the binding",
      surfaceAt: now,
    });
    const candidate = (await created.json()) as { current: { id: string } };
    await request("beta", "/");
    const accepted = await post("beta", `/${candidate.current.id}/accept`, {});
    const handoff = (await accepted.json()) as {
      executionId: string;
      approvalNonce: string;
    };
    expect(
      (
        await post("beta", `/executions/${handoff.executionId}/approve`, {
          approvalNonce: handoff.approvalNonce,
          operationId: "operation-beta",
          proposalId: "proposal-beta",
          actionHash: "c".repeat(64),
          risk: "reversible",
          generation: 0,
          expiresAtMs: Number.MAX_SAFE_INTEGER,
        })
      ).status,
    ).toBe(400);
    const approvedResponse = await post(
      "beta",
      `/executions/${handoff.executionId}/approve`,
      {
        approvalNonce: handoff.approvalNonce,
        operationId: "operation-beta",
        proposalId: "proposal-beta",
        actionHash: "c".repeat(64),
        risk: "reversible",
        generation: 0,
      },
    );
    const approved = (await approvedResponse.json()) as {
      receipt: {
        receiptId: string;
        receiptToken: string;
        subject: string;
        policyGeneration: number;
        operationId: string;
        proposalId: string;
        actionHash: string;
        risk: string;
      };
    };
    const collisionCreated = await post("beta", "/candidates", {
      evidenceId: "beta-evidence",
      title: "Conflicting operation",
      summary: "Do not reuse the operation",
      reason: "Cited conversation",
      confidence: 0.7,
      proposedNextStep: "Do not reuse the operation",
      surfaceAt: Date.now(),
    });
    const collisionCandidate = (await collisionCreated.json()) as {
      current: { id: string };
    };
    await request("beta", "/");
    const collisionAccepted = await post(
      "beta",
      `/${collisionCandidate.current.id}/accept`,
      {},
    );
    const collisionHandoff = (await collisionAccepted.json()) as {
      executionId: string;
      approvalNonce: string;
    };
    expect(
      (
        await post(
          "beta",
          `/executions/${collisionHandoff.executionId}/approve`,
          {
            approvalNonce: collisionHandoff.approvalNonce,
            operationId: "operation-beta",
            proposalId: "proposal-beta-conflict",
            actionHash: "d".repeat(64),
            risk: "destructive",
            generation: 0,
          },
        )
      ).status,
    ).toBe(409);
    await database
      .prepare(
        "INSERT INTO user_settings (uid, value, revision, updated_at) VALUES ('beta', '{}', 1, ?1)",
      )
      .bind(Date.now())
      .run();
    const claim = {
      receiptToken: approved.receipt.receiptToken,
      subject: approved.receipt.subject,
      policyGeneration: approved.receipt.policyGeneration,
      operationId: approved.receipt.operationId,
      proposalId: approved.receipt.proposalId,
      actionHash: approved.receipt.actionHash,
      risk: approved.receipt.risk,
    };
    expect(
      (
        await post(
          "beta",
          `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
          claim,
        )
      ).status,
    ).toBe(409);
    await database
      .prepare("UPDATE user_settings SET revision = 0 WHERE uid = 'beta'")
      .run();
    await database
      .prepare(
        "UPDATE current_executions SET receipt_expires_at = ?1 WHERE id = ?2",
      )
      .bind(Date.now() - 1, handoff.executionId)
      .run();
    expect(
      (
        await post(
          "beta",
          `/executions/${handoff.executionId}/receipts/${approved.receipt.receiptId}/claim`,
          claim,
        )
      ).status,
    ).toBe(409);
  });
});
