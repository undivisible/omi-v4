import { Hono } from "hono";
import type { AppEnv } from "./types";

const currents = new Hono<AppEnv>();

const object = async (request: Request) => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const text = (value: unknown, limit = 500) =>
  typeof value === "string" && value.trim() && value.length <= limit
    ? value.trim()
    : null;

const rowToCurrent = (row: Record<string, unknown>) => ({
  id: String(row.id),
  status: String(row.status),
  title: String(row.title),
  summary: String(row.summary),
  evidence: [{ sourceId: String(row.source_id), reason: String(row.reason) }],
  reason: String(row.reason),
  confidence: Number(row.confidence_basis_points) / 10_000,
  proposedNextStep: String(row.instruction),
  proposedAction: JSON.parse(String(row.proposed_action)),
  timing: {
    surfaceAt: new Date(Number(row.surface_at)).toISOString(),
    expiresAt:
      row.expires_at == null
        ? null
        : new Date(Number(row.expires_at)).toISOString(),
    snoozedUntil:
      row.snoozed_until == null
        ? null
        : new Date(Number(row.snoozed_until)).toISOString(),
  },
  feedbackReference:
    row.feedback_reference == null ? null : String(row.feedback_reference),
  executionReference:
    row.execution_reference == null ? null : String(row.execution_reference),
  createdAt: new Date(Number(row.created_at)).toISOString(),
  updatedAt: new Date(Number(row.updated_at)).toISOString(),
});

const selectCurrent = async (
  env: AppEnv["Bindings"],
  uid: string,
  id: string,
) =>
  env.DB.prepare(
    `SELECT c.*, s.id AS source_id, json_extract(c.proposed_action, '$.instruction') AS instruction
     FROM currents c
     JOIN memory_evidence e ON e.id = c.evidence_id AND e.uid = c.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE c.id = ?1 AND c.uid = ?2 AND s.tombstoned_at IS NULL`,
  )
    .bind(id, uid)
    .first<Record<string, unknown>>();

currents.post("/candidates", async (context) => {
  const body = await object(context.req.raw);
  const evidenceId = text(body?.evidenceId, 200);
  const title = text(body?.title, 120);
  const summary = text(body?.summary, 500);
  const reason = text(body?.reason, 500);
  const instruction = text(body?.proposedNextStep, 500);
  const confidence = body?.confidence;
  const surfaceAt = body?.surfaceAt;
  const expiresAt = body?.expiresAt ?? null;
  if (
    !evidenceId ||
    !title ||
    !summary ||
    !reason ||
    !instruction ||
    typeof confidence !== "number" ||
    !Number.isFinite(confidence) ||
    confidence < 0 ||
    confidence > 1 ||
    typeof surfaceAt !== "number" ||
    !Number.isSafeInteger(surfaceAt) ||
    (expiresAt !== null &&
      (typeof expiresAt !== "number" ||
        !Number.isSafeInteger(expiresAt) ||
        expiresAt <= surfaceAt))
  )
    return context.json({ error: "Invalid Current candidate" }, 400);
  const uid = context.get("auth").uid;
  const evidence = await context.env.DB.prepare(
    `SELECT e.id FROM memory_evidence e
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE e.id = ?1 AND e.uid = ?2 AND s.tombstoned_at IS NULL`,
  )
    .bind(evidenceId, uid)
    .first();
  if (!evidence)
    return context.json({ error: "Cited evidence not found" }, 404);
  const id = crypto.randomUUID();
  const now = Date.now();
  await context.env.DB.prepare(
    `INSERT INTO currents
      (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action,
       status, surface_at, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?11, ?11)`,
  )
    .bind(
      id,
      uid,
      evidenceId,
      title,
      summary,
      reason,
      Math.round(confidence * 10_000),
      JSON.stringify({ kind: "review", instruction }),
      surfaceAt,
      expiresAt,
      now,
    )
    .run();
  return context.json(
    { current: rowToCurrent((await selectCurrent(context.env, uid, id))!) },
    201,
  );
});

currents.get("/", async (context) => {
  const uid = context.get("auth").uid;
  const now = Date.now();
  await context.env.DB.prepare(
    `UPDATE currents SET status = 'expired', updated_at = ?1
     WHERE uid = ?2 AND status IN ('candidate', 'surfaced', 'snoozed') AND expires_at IS NOT NULL AND expires_at <= ?1`,
  )
    .bind(now, uid)
    .run();
  await context.env.DB.prepare(
    `UPDATE currents SET status = 'surfaced', snoozed_until = NULL, updated_at = ?1
     WHERE uid = ?2 AND status = 'snoozed' AND snoozed_until <= ?1`,
  )
    .bind(now, uid)
    .run();
  await context.env.DB.prepare(
    `UPDATE currents SET status = 'surfaced', updated_at = ?1
     WHERE uid = ?2 AND status = 'candidate' AND surface_at <= ?1`,
  )
    .bind(now, uid)
    .run();
  const rows = await context.env.DB.prepare(
    `SELECT c.*, s.id AS source_id, json_extract(c.proposed_action, '$.instruction') AS instruction,
       COALESCE((SELECT SUM(CASE f.kind WHEN 'dismissed' THEN -1000 ELSE -250 END)
                 FROM current_feedback f
                 JOIN currents prior ON prior.id = f.current_id AND prior.uid = f.uid
                 JOIN memory_evidence pe ON pe.id = prior.evidence_id AND pe.uid = prior.uid
                 JOIN memory_source_revisions pr ON pr.id = pe.source_revision_id AND pr.uid = pe.uid
                 JOIN memory_sources ps ON ps.id = pr.source_id AND ps.uid = pr.uid
                 WHERE f.uid = c.uid AND ps.kind = s.kind), 0)
       + COALESCE((SELECT SUM(CASE x.state WHEN 'succeeded' THEN 500 WHEN 'failed' THEN -500 ELSE -250 END)
                   FROM current_executions x
                   JOIN currents prior ON prior.id = x.current_id AND prior.uid = x.uid
                   JOIN memory_evidence pe ON pe.id = prior.evidence_id AND pe.uid = prior.uid
                   JOIN memory_source_revisions pr ON pr.id = pe.source_revision_id AND pr.uid = pe.uid
                   JOIN memory_sources ps ON ps.id = pr.source_id AND ps.uid = pr.uid
                   WHERE x.uid = c.uid AND ps.kind = s.kind
                     AND x.state IN ('succeeded', 'failed', 'outcome_unknown')), 0) AS learned_adjustment
     FROM currents c
     JOIN memory_evidence e ON e.id = c.evidence_id AND e.uid = c.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE c.uid = ?1 AND s.tombstoned_at IS NULL
       AND c.status IN ('surfaced', 'accepted')
     ORDER BY c.confidence_basis_points + learned_adjustment DESC, c.updated_at DESC, c.id ASC LIMIT 100`,
  )
    .bind(uid)
    .all<Record<string, unknown>>();
  return context.json({ currents: (rows.results ?? []).map(rowToCurrent) });
});

currents.post("/:id/feedback", async (context) => {
  const uid = context.get("auth").uid;
  const id = context.req.param("id");
  const body = await object(context.req.raw);
  const kind = body?.kind;
  const snoozedUntil = body?.snoozedUntil ?? null;
  if (
    (kind !== "dismissed" && kind !== "snoozed") ||
    (kind === "snoozed" &&
      (typeof snoozedUntil !== "number" ||
        !Number.isSafeInteger(snoozedUntil) ||
        snoozedUntil <= Date.now()))
  )
    return context.json({ error: "Invalid feedback" }, 400);
  const current = await selectCurrent(context.env, uid, id);
  if (!current) return context.json({ error: "Current not found" }, 404);
  if (current.status !== "surfaced")
    return context.json({ error: "Current cannot receive feedback" }, 409);
  const feedbackId = crypto.randomUUID();
  const now = Date.now();
  const [feedback] = await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO current_feedback (id, uid, current_id, kind, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5 FROM currents
       WHERE id = ?3 AND uid = ?2 AND status = 'surfaced'
         AND (expires_at IS NULL OR expires_at > ?5)`,
    ).bind(feedbackId, uid, id, kind, now),
    context.env.DB.prepare(
      `UPDATE currents SET status = ?1, snoozed_until = ?2, feedback_reference = ?3, updated_at = ?4
       WHERE id = ?5 AND uid = ?6 AND status = 'surfaced'
         AND EXISTS (SELECT 1 FROM current_feedback WHERE id = ?3 AND uid = ?6 AND current_id = ?5)`,
    ).bind(kind, snoozedUntil, feedbackId, now, id, uid),
  ]);
  if (feedback.meta.changes !== 1)
    return context.json({ error: "Current cannot receive feedback" }, 409);
  return context.json({
    current: rowToCurrent((await selectCurrent(context.env, uid, id))!),
  });
});

currents.post("/:id/accept", async (context) => {
  const uid = context.get("auth").uid;
  const id = context.req.param("id");
  const current = await selectCurrent(context.env, uid, id);
  if (!current) return context.json({ error: "Current not found" }, 404);
  if (current.status !== "surfaced")
    return context.json({ error: "Current cannot be accepted" }, 409);
  const executionId = crypto.randomUUID();
  const approvalNonce = crypto.randomUUID();
  const hash = Array.from(
    new Uint8Array(
      await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(approvalNonce),
      ),
    ),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  const now = Date.now();
  const [execution] = await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO current_executions
       (id, uid, current_id, state, action, approval_nonce_hash, created_at, updated_at)
       SELECT ?1, ?2, ?3, 'awaiting_approval', ?4, ?5, ?6, ?6 FROM currents
       WHERE id = ?3 AND uid = ?2 AND status = 'surfaced'
         AND (expires_at IS NULL OR expires_at > ?6)`,
    ).bind(executionId, uid, id, current.proposed_action, hash, now),
    context.env.DB.prepare(
      `UPDATE currents SET status = 'accepted', execution_reference = ?1, updated_at = ?2
       WHERE id = ?3 AND uid = ?4 AND status = 'surfaced'
         AND EXISTS (SELECT 1 FROM current_executions WHERE id = ?1 AND uid = ?4 AND current_id = ?3)`,
    ).bind(executionId, now, id, uid),
  ]);
  if (execution.meta.changes !== 1)
    return context.json({ error: "Current cannot be accepted" }, 409);
  return context.json(
    {
      executionId,
      approvalNonce,
      action: JSON.parse(String(current.proposed_action)),
      state: "awaiting_approval",
    },
    201,
  );
});

currents.post("/executions/:id/approve", async (context) => {
  const uid = context.get("auth").uid;
  const body = await object(context.req.raw);
  const nonce = text(body?.approvalNonce, 200);
  if (!nonce) return context.json({ error: "Invalid approval" }, 400);
  const hash = Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(nonce)),
    ),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  const now = Date.now();
  const result = await context.env.DB.prepare(
    "UPDATE current_executions SET state = 'approved', approved_at = ?1, updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND state = 'awaiting_approval' AND approval_nonce_hash = ?4",
  )
    .bind(now, context.req.param("id"), uid, hash)
    .run();
  if (result.meta.changes !== 1)
    return context.json(
      { error: "Approval is invalid or already consumed" },
      409,
    );
  return context.json({
    executionId: context.req.param("id"),
    state: "approved",
  });
});

currents.post("/executions/:id/reject", async (context) => {
  const uid = context.get("auth").uid;
  const body = await object(context.req.raw);
  const nonce = text(body?.approvalNonce, 200);
  if (!nonce) return context.json({ error: "Invalid rejection" }, 400);
  const hash = Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(nonce)),
    ),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  const id = context.req.param("id");
  const now = Date.now();
  const [rejected] = await context.env.DB.batch([
    context.env.DB.prepare(
      "UPDATE current_executions SET state = 'rejected', updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND state = 'awaiting_approval' AND approval_nonce_hash = ?4",
    ).bind(now, id, uid, hash),
    context.env.DB.prepare(
      `UPDATE currents SET status = 'dismissed', updated_at = ?1
       WHERE uid = ?2 AND status = 'accepted' AND id = (
         SELECT current_id FROM current_executions
         WHERE id = ?3 AND uid = ?2 AND state = 'rejected'
           AND approval_nonce_hash = ?4 AND updated_at = ?1
       )`,
    ).bind(now, uid, id, hash),
  ]);
  if (rejected.meta.changes !== 1)
    return context.json(
      { error: "Rejection is invalid or already consumed" },
      409,
    );
  return context.json({ executionId: id, state: "rejected" });
});

currents.post("/executions/:id/outcome", async (context) => {
  const uid = context.get("auth").uid;
  const body = await object(context.req.raw);
  const state = body?.state;
  const detail = text(body?.detail, 1000);
  if (
    !detail ||
    (state !== "succeeded" && state !== "failed" && state !== "outcome_unknown")
  )
    return context.json({ error: "Invalid outcome" }, 400);
  const id = context.req.param("id");
  const now = Date.now();
  const serializedOutcome = JSON.stringify({ detail });
  const [execution] = await context.env.DB.batch([
    context.env.DB.prepare(
      "UPDATE current_executions SET state = ?1, outcome = ?2, updated_at = ?3 WHERE id = ?4 AND uid = ?5 AND state = 'approved'",
    ).bind(state, serializedOutcome, now, id, uid),
    context.env.DB.prepare(
      `UPDATE currents SET status = ?1, updated_at = ?2
       WHERE uid = ?3 AND status = 'accepted' AND id = (
         SELECT current_id FROM current_executions
         WHERE id = ?4 AND uid = ?3 AND state = ?5 AND outcome = ?6 AND updated_at = ?2
       )`,
    ).bind(
      state === "succeeded" ? "completed" : "expired",
      now,
      uid,
      id,
      state,
      serializedOutcome,
    ),
  ]);
  if (execution.meta.changes !== 1)
    return context.json({ error: "Execution is not awaiting an outcome" }, 409);
  return context.json({ executionId: id, state });
});

export default currents;
