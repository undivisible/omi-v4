import { Hono } from "hono";
import { ensureZkrMemoryProjected } from "./memory-projection";
import type { AppEnv } from "./types";

const currents = new Hono<AppEnv>();
const encoder = new TextEncoder();
const approvalLifetimeMs = 5 * 60 * 1000;
const receiptLifetimeMs = 60 * 1000;
const receiptVersion = "omi-current-authority-v1";
const actionHashPattern = /^[0-9a-f]{64}$/;
const receiptTokenPattern = /^[A-Za-z0-9_-]{43}$/;
const unreportedOutcome = JSON.stringify({
  detail: "Execution authority was claimed, but no outcome was reported",
});

currents.use("*", async (context, next) => {
  await ensureZkrMemoryProjected(context.env.DB, context.get("auth").uid);
  await next();
});

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

const bounded = (value: string, limit: number) =>
  Array.from(value).slice(0, limit).join("");

const exactText = (value: unknown, limit: number) =>
  typeof value === "string" &&
  value.length > 0 &&
  value.length <= limit &&
  value.trim() === value
    ? value
    : null;

const onlyKeys = (body: Record<string, unknown>, keys: string[]) =>
  Object.keys(body).every((key) => keys.includes(key));

const sha256 = async (value: string) =>
  Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");

const receiptToken = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

const risk = (value: unknown) =>
  value === "reversible" || value === "external" || value === "destructive"
    ? value
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
     WHERE c.id = ?1 AND c.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL`,
  )
    .bind(id, uid)
    .first<Record<string, unknown>>();

currents.post("/generate", async (context) => {
  const uid = context.get("auth").uid;
  const settings = await context.env.DB.prepare(
    "SELECT value FROM user_settings WHERE uid = ?1",
  )
    .bind(uid)
    .first<{ value: string }>();
  if (settings) {
    try {
      if (JSON.parse(settings.value).proactiveRecommendations === false)
        return context.json({ current: null });
    } catch {
      return context.json({ error: "Invalid settings" }, 500);
    }
  }
  const source = await context.env.DB.prepare(
    `SELECT c.id AS claim_id, c.content, c.value, ce.evidence_id,
            ce.confidence_basis_points, e.quote
     FROM memory_profile_entries p
     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid
     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
       AND ce.relation = 'supports'
     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     LEFT JOIN currents existing ON existing.uid = p.uid
       AND existing.generation_key = 'claim:' || c.id
     WHERE p.uid = ?1 AND p.profile_kind = 'current' AND p.status != 'archived'
       AND c.status = 'accepted' AND c.retracted_at IS NULL
       AND (c.valid_from IS NULL OR c.valid_from <= ?2)
       AND (c.valid_to IS NULL OR c.valid_to > ?2)
       AND (c.recorded_until IS NULL OR c.recorded_until > ?2)
       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
       AND ce.relation = 'supports' AND e.tombstoned_at IS NULL
       AND s.tombstoned_at IS NULL AND existing.id IS NULL
     ORDER BY p.updated_at DESC, ce.confidence_basis_points DESC, c.id, e.id
     LIMIT 1`,
  )
    .bind(uid, Date.now())
    .first<Record<string, unknown>>();
  if (!source) return context.json({ current: null });
  const claimId = String(source.claim_id);
  const value = String(source.value ?? source.content).trim();
  const content = String(source.content).trim();
  const quote = String(source.quote).trim();
  if (!value || !content || !quote)
    return context.json({ error: "Current source is invalid" }, 500);
  const id = crypto.randomUUID();
  const now = Date.now();
  const inserted = await context.env.DB.prepare(
    `INSERT OR IGNORE INTO currents
      (id, uid, evidence_id, title, summary, reason, confidence_basis_points,
       proposed_action, status, surface_at, generation_key, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?9, ?9)`,
  )
    .bind(
      id,
      uid,
      source.evidence_id,
      bounded(`Revisit: ${value}`, 120),
      bounded(content, 500),
      bounded(`Based on: ${quote}`, 500),
      Number(source.confidence_basis_points),
      JSON.stringify({
        kind: "review",
        instruction: bounded(
          `Review this memory and decide the smallest next action: ${value}`,
          500,
        ),
      }),
      now,
      `claim:${claimId}`,
    )
    .run();
  if (inserted.meta.changes === 1) {
    return context.json(
      { current: rowToCurrent((await selectCurrent(context.env, uid, id))!) },
      201,
    );
  }
  const existing = await context.env.DB.prepare(
    "SELECT id FROM currents WHERE uid = ?1 AND generation_key = ?2",
  )
    .bind(uid, `claim:${claimId}`)
    .first<{ id: string }>();
  return context.json({
    current: existing
      ? rowToCurrent((await selectCurrent(context.env, uid, existing.id))!)
      : null,
  });
});

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
     WHERE e.id = ?1 AND e.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL`,
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
       AND e.tombstoned_at IS NULL
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
  const hash = await sha256(approvalNonce);
  const now = Date.now();
  const [execution] = await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO current_executions
       (id, uid, current_id, state, action, approval_nonce_hash, policy_generation, created_at, updated_at)
       SELECT ?1, ?2, ?3, 'awaiting_approval', ?4, ?5,
              COALESCE((SELECT revision FROM user_settings WHERE uid = ?2), 0), ?6, ?6 FROM currents
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
  const stored = await context.env.DB.prepare(
    "SELECT policy_generation FROM current_executions WHERE id = ?1 AND uid = ?2",
  )
    .bind(executionId, uid)
    .first<{ policy_generation: number }>();
  if (!stored)
    return context.json({ error: "Current cannot be accepted" }, 409);
  return context.json(
    {
      executionId,
      approvalNonce,
      policyGeneration: Number(stored.policy_generation),
      action: JSON.parse(String(current.proposed_action)),
      state: "awaiting_approval",
    },
    201,
  );
});

currents.post("/executions/:id/approve", async (context) => {
  const uid = context.get("auth").uid;
  const body = await object(context.req.raw);
  if (
    !body ||
    !onlyKeys(body, [
      "approvalNonce",
      "operationId",
      "proposalId",
      "actionHash",
      "risk",
      "generation",
    ])
  )
    return context.json({ error: "Invalid approval" }, 400);
  const nonce = exactText(body.approvalNonce, 200);
  const operationId = exactText(body.operationId, 200);
  const proposalId = exactText(body.proposalId, 200);
  const actionHash = exactText(body.actionHash, 64);
  const actionRisk = risk(body.risk);
  const generation = body.generation;
  if (
    !nonce ||
    !operationId ||
    !proposalId ||
    !actionHash ||
    !actionHashPattern.test(actionHash) ||
    !actionRisk ||
    typeof generation !== "number" ||
    !Number.isSafeInteger(generation) ||
    generation < 0
  )
    return context.json({ error: "Invalid approval" }, 400);
  const nonceHash = await sha256(nonce);
  const token = receiptToken();
  const tokenHash = await sha256(token);
  const id = context.req.param("id");
  const receiptId = crypto.randomUUID();
  const now = Date.now();
  const expiresAt = now + receiptLifetimeMs;
  let approved: { policy_generation: number } | null;
  try {
    approved = await context.env.DB.prepare(
      `UPDATE current_executions
       SET state = 'approved', approved_at = ?1, updated_at = ?1,
           operation_id = ?5, proposal_id = ?6, action_hash = ?7, risk = ?8,
           receipt_id = ?9, receipt_token_hash = ?10, receipt_issued_at = ?1,
           receipt_expires_at = ?11
       WHERE id = ?2 AND uid = ?3 AND state = 'awaiting_approval'
         AND approval_nonce_hash = ?4 AND created_at > ?12
         AND policy_generation = ?13
         AND policy_generation = COALESCE((SELECT revision FROM user_settings WHERE uid = ?3), 0)
         AND NOT EXISTS (
           SELECT 1 FROM current_executions existing
           WHERE existing.uid = ?3 AND (existing.operation_id = ?5 OR existing.proposal_id = ?6)
         )
       RETURNING policy_generation`,
    )
      .bind(
        now,
        id,
        uid,
        nonceHash,
        operationId,
        proposalId,
        actionHash,
        actionRisk,
        receiptId,
        tokenHash,
        expiresAt,
        now - approvalLifetimeMs,
        generation,
      )
      .first<{ policy_generation: number }>();
  } catch {
    approved = null;
  }
  if (!approved)
    return context.json(
      { error: "Approval is invalid or already consumed" },
      409,
    );
  return context.json({
    executionId: id,
    state: "approved",
    receipt: {
      version: receiptVersion,
      receiptId,
      receiptToken: token,
      subject: uid,
      policyGeneration: Number(approved.policy_generation),
      operationId,
      proposalId,
      actionHash,
      risk: actionRisk,
      issuedAtMs: now,
      expiresAtMs: expiresAt,
    },
  });
});

currents.post("/executions/:id/receipts/:receiptId/claim", async (context) => {
  const uid = context.get("auth").uid;
  const body = await object(context.req.raw);
  if (
    !body ||
    !onlyKeys(body, [
      "receiptToken",
      "subject",
      "policyGeneration",
      "operationId",
      "proposalId",
      "actionHash",
      "risk",
    ])
  )
    return context.json({ error: "Invalid receipt claim" }, 400);
  const token = exactText(body.receiptToken, 43);
  const subject = exactText(body.subject, 200);
  const operationId = exactText(body.operationId, 200);
  const proposalId = exactText(body.proposalId, 200);
  const actionHash = exactText(body.actionHash, 64);
  const actionRisk = risk(body.risk);
  const policyGeneration = body.policyGeneration;
  if (
    !token ||
    !receiptTokenPattern.test(token) ||
    subject !== uid ||
    !operationId ||
    !proposalId ||
    !actionHash ||
    !actionHashPattern.test(actionHash) ||
    !actionRisk ||
    typeof policyGeneration !== "number" ||
    !Number.isSafeInteger(policyGeneration) ||
    policyGeneration < 0
  )
    return context.json({ error: "Invalid receipt claim" }, 400);
  const tokenHash = await sha256(token);
  const id = context.req.param("id");
  const receiptId = context.req.param("receiptId");
  const now = Date.now();
  const [claimed] = await context.env.DB.batch([
    context.env.DB.prepare(
      `UPDATE current_executions
       SET receipt_claimed_at = ?1, state = 'outcome_unknown', outcome = ?11, updated_at = ?1
       WHERE id = ?2 AND uid = ?3 AND state = 'approved'
         AND receipt_id = ?4 AND receipt_token_hash = ?5
         AND operation_id = ?6 AND proposal_id = ?7 AND action_hash = ?8 AND risk = ?9
         AND policy_generation = ?10
         AND policy_generation = COALESCE((SELECT revision FROM user_settings WHERE uid = ?3), 0)
         AND receipt_claimed_at IS NULL AND receipt_expires_at > ?1`,
    ).bind(
      now,
      id,
      uid,
      receiptId,
      tokenHash,
      operationId,
      proposalId,
      actionHash,
      actionRisk,
      policyGeneration,
      unreportedOutcome,
    ),
    context.env.DB.prepare(
      `UPDATE currents SET status = 'expired', updated_at = ?1
       WHERE uid = ?2 AND status = 'accepted' AND id = (
         SELECT current_id FROM current_executions
         WHERE id = ?3 AND uid = ?2 AND state = 'outcome_unknown'
           AND outcome = ?4 AND receipt_claimed_at = ?1
       )`,
    ).bind(now, uid, id, unreportedOutcome),
  ]);
  if (claimed.meta.changes !== 1)
    return context.json(
      { error: "Receipt is invalid, expired, or already claimed" },
      409,
    );
  const stored = await context.env.DB.prepare(
    "SELECT receipt_issued_at, receipt_expires_at FROM current_executions WHERE id = ?1 AND uid = ?2 AND receipt_claimed_at = ?3",
  )
    .bind(id, uid, now)
    .first<{ receipt_issued_at: number; receipt_expires_at: number }>();
  if (!stored)
    return context.json({ error: "Claimed receipt could not be loaded" }, 500);
  return context.json({
    executionId: id,
    state: "claimed",
    receipt: {
      version: receiptVersion,
      receiptId,
      subject: uid,
      policyGeneration,
      operationId,
      proposalId,
      actionHash,
      risk: actionRisk,
      issuedAtMs: Number(stored.receipt_issued_at),
      expiresAtMs: Number(stored.receipt_expires_at),
      claimedAtMs: now,
    },
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
  const detail = body ? exactText(body.detail, 1000) : null;
  if (
    !body ||
    !onlyKeys(body, ["state", "detail"]) ||
    !detail ||
    (state !== "succeeded" &&
      state !== "failed" &&
      state !== "outcome_unknown" &&
      state !== "cancelled_before_effect" &&
      state !== "expired_before_effect")
  )
    return context.json({ error: "Invalid outcome" }, 400);
  const id = context.req.param("id");
  const now = Date.now();
  const serializedOutcome = JSON.stringify({ detail });
  const [execution] = await context.env.DB.batch([
    context.env.DB.prepare(
      `UPDATE current_executions
       SET state = ?1, outcome = ?2, outcome_reported_at = ?3, updated_at = ?3
       WHERE id = ?4 AND uid = ?5 AND outcome_reported_at IS NULL
         AND ((state = 'approved' AND receipt_claimed_at IS NULL
               AND ?1 IN ('failed', 'outcome_unknown', 'cancelled_before_effect', 'expired_before_effect'))
              OR (state = 'outcome_unknown' AND receipt_claimed_at IS NOT NULL))`,
    ).bind(state, serializedOutcome, now, id, uid),
    context.env.DB.prepare(
      `UPDATE currents SET status = ?1, updated_at = ?2
       WHERE uid = ?3 AND status IN ('accepted', 'expired') AND id = (
         SELECT current_id FROM current_executions
         WHERE id = ?4 AND uid = ?3 AND state = ?5 AND outcome = ?6
           AND outcome_reported_at = ?2 AND updated_at = ?2
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
  if (execution.meta.changes !== 1) {
    const stored = await context.env.DB.prepare(
      "SELECT state, outcome, outcome_reported_at FROM current_executions WHERE id = ?1 AND uid = ?2",
    )
      .bind(id, uid)
      .first<{
        state: string;
        outcome: string | null;
        outcome_reported_at: number | null;
      }>();
    if (
      stored?.outcome_reported_at == null ||
      stored.state !== state ||
      stored.outcome !== serializedOutcome
    )
      return context.json(
        { error: "Execution is not awaiting this outcome" },
        409,
      );
  }
  return context.json({ executionId: id, state });
});

export default currents;
