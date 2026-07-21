import { Hono } from "hono";
import type {
  AppEnv,
  Channel,
  Current,
  MemoryEvidence,
  PersonalMemory,
  SettingsDuration,
  UserSettings,
} from "./types";

const routes = new Hono<AppEnv>();

const text = (value: unknown, limit: number): string | null =>
  typeof value === "string" && value.trim().length > 0 && value.length <= limit
    ? value.trim()
    : null;

const json = async (
  request: Request,
): Promise<Record<string, unknown> | null> => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const parseJson = <T>(value: unknown, fallback: T): T => {
  if (typeof value !== "string") return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
};

const settingsDiff = (from: UserSettings, to: UserSettings) => ({
  ...(from.approvalMode === to.approvalMode
    ? {}
    : { approvalMode: { from: from.approvalMode, to: to.approvalMode } }),
  ...(from.proactiveRecommendations === to.proactiveRecommendations
    ? {}
    : {
        proactiveRecommendations: {
          from: from.proactiveRecommendations,
          to: to.proactiveRecommendations,
        },
      }),
});

const sourceKinds = new Set([
  "conversation",
  "screen",
  "audio",
  "document",
  "integration",
  "user_correction",
]);

routes.get("/me", async (context) => {
  const auth = context.get("auth");
  const bindings = await context.env.DB.prepare(
    "SELECT channel, channel_user_id FROM channel_bindings WHERE uid = ?1 AND revoked_at IS NULL",
  )
    .bind(auth.uid)
    .all();
  return context.json({ ...auth, channels: bindings.results ?? [] });
});

routes.get("/memories", async (context) => {
  const rows = await context.env.DB.prepare(
    `SELECT p.id, c.value, c.valid_from, c.valid_to, c.recorded_at, p.updated_at,
            p.profile_kind, p.status, s.kind AS source, e.id AS evidence_id,
            e.source_revision_id, e.quote, e.locator, s.id AS source_id
     FROM memory_profile_entries p
     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid
     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE p.uid = ?1 AND p.status != 'archived' AND c.status = 'accepted' AND c.retracted_at IS NULL AND s.tombstoned_at IS NULL
     ORDER BY p.updated_at DESC LIMIT 500`,
  )
    .bind(context.get("auth").uid)
    .all();
  const indexed = new Map<string, PersonalMemory>();
  for (const row of rows.results ?? []) {
    const id = String(row.id);
    const evidence: MemoryEvidence = {
      id: String(row.evidence_id),
      sourceId: String(row.source_id),
      sourceRevisionId: String(row.source_revision_id),
      quote: String(row.quote),
      locator: parseJson(row.locator, null),
    };
    const existing = indexed.get(id);
    if (existing) {
      existing.evidence.push(evidence);
      continue;
    }
    indexed.set(id, {
      id,
      content: String(row.value),
      source: String(row.source),
      evidence: [evidence],
      profileKind: row.profile_kind as PersonalMemory["profileKind"],
      status: row.status as PersonalMemory["status"],
      validFrom: row.valid_from === null ? null : Number(row.valid_from),
      validTo: row.valid_to === null ? null : Number(row.valid_to),
      createdAt: Number(row.recorded_at),
      updatedAt: Number(row.updated_at),
    });
  }
  const memories = [...indexed.values()].slice(0, 100);
  return context.json({ memories });
});

routes.post("/memories", async (context) => {
  const body = await json(context.req.raw);
  const content = text(body?.content, 20_000);
  const source = text(body?.source, 100);
  const subject = text(body?.subject, 200) ?? "person";
  const predicate = text(body?.predicate, 200) ?? "remembers";
  const profileKey = text(body?.profileKey, 200) ?? predicate;
  const profileKind = body?.profileKind ?? "current";
  const validFrom =
    body?.validFrom === undefined ? Date.now() : Number(body.validFrom);
  const validTo =
    body?.validTo === undefined || body.validTo === null
      ? null
      : Number(body.validTo);
  if (
    !content ||
    !source ||
    !sourceKinds.has(source) ||
    (body?.evidence !== undefined && !Array.isArray(body.evidence)) ||
    (profileKind !== "stable" && profileKind !== "current") ||
    !Number.isSafeInteger(validFrom) ||
    validFrom <= 0 ||
    (validTo !== null && !Number.isFinite(validTo)) ||
    (validTo !== null && validTo < validFrom)
  )
    return context.json({ error: "Invalid memory" }, 400);
  const id = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const revisionId = crypto.randomUUID();
  const evidenceId = crypto.randomUUID();
  const claimId = crypto.randomUUID();
  const now = Date.now();
  const uid = context.get("auth").uid;
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(content),
  );
  const contentHash = Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  await context.env.DB.batch([
    context.env.DB.prepare(
      "INSERT INTO memory_sources (id, uid, kind, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)",
    ).bind(sourceId, uid, source, now),
    context.env.DB.prepare(
      "INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?6)",
    ).bind(
      revisionId,
      sourceId,
      uid,
      contentHash,
      JSON.stringify({ content }),
      now,
    ),
    context.env.DB.prepare(
      "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, locator, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    ).bind(
      evidenceId,
      uid,
      revisionId,
      content,
      JSON.stringify(body?.evidence ?? []),
      now,
    ),
    context.env.DB.prepare(
      `INSERT INTO memory_claims
         (id, uid, content, subject, predicate, value, valid_from, valid_to, recorded_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?3, ?6, ?7, ?8)`,
    ).bind(claimId, uid, content, subject, predicate, validFrom, validTo, now),
    context.env.DB.prepare(
      "INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation, confidence_basis_points) VALUES (?1, ?2, ?3, 'supports', 10000)",
    ).bind(uid, claimId, evidenceId),
    context.env.DB.prepare(
      `INSERT INTO memory_profile_entries
         (id, uid, claim_id, profile_kind, profile_key, profile_value, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
    ).bind(id, uid, claimId, profileKind, profileKey, content, now),
  ]);
  return context.json({ id, sourceId, claimId }, 201);
});

routes.post("/memory/sources/:sourceId/revisions", async (context) => {
  const body = await json(context.req.raw);
  const payload =
    body?.payload !== null &&
    typeof body?.payload === "object" &&
    !Array.isArray(body.payload)
      ? body.payload
      : null;
  const observedAt = Number(body?.observedAt ?? Date.now());
  if (!payload || !Number.isSafeInteger(observedAt) || observedAt <= 0)
    return context.json({ error: "Invalid source revision" }, 400);
  const uid = context.get("auth").uid;
  const sourceId = context.req.param("sourceId");
  const source = await context.env.DB.prepare(
    `SELECT s.id, COALESCE(MAX(r.revision), 0) AS revision
     FROM memory_sources s LEFT JOIN memory_source_revisions r ON r.source_id = s.id AND r.uid = s.uid
     WHERE s.id = ?1 AND s.uid = ?2 AND s.tombstoned_at IS NULL GROUP BY s.id`,
  )
    .bind(sourceId, uid)
    .first();
  if (!source) return context.json({ error: "Source not found" }, 404);
  const serialized = JSON.stringify(payload);
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(serialized),
  );
  const contentHash = Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const id = crypto.randomUUID();
  const revision = Number(source.revision) + 1;
  const now = Date.now();
  const inserted = await context.env.DB.prepare(
    `INSERT OR IGNORE INTO memory_source_revisions
       (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
     SELECT ?1, id, uid, ?2, ?3, ?4, ?5, ?6 FROM memory_sources
     WHERE id = ?7 AND uid = ?8 AND tombstoned_at IS NULL`,
  )
    .bind(id, revision, contentHash, serialized, observedAt, now, sourceId, uid)
    .run();
  if (inserted.meta.changes !== 1)
    return context.json({ error: "Source revision conflict" }, 409);
  return context.json({ id, sourceId, revision, contentHash }, 201);
});

routes.delete("/memory/sources/:sourceId", async (context) => {
  const uid = context.get("auth").uid;
  const sourceId = context.req.param("sourceId");
  const now = Date.now();
  const source = await context.env.DB.prepare(
    "UPDATE memory_sources SET tombstoned_at = ?1, updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND tombstoned_at IS NULL",
  )
    .bind(now, sourceId, uid)
    .run();
  if (source.meta.changes !== 1)
    return context.json({ error: "Source not found" }, 404);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `UPDATE memory_claims SET retracted_at = ?1, recorded_until = ?1, status = 'superseded'
       WHERE uid = ?2 AND retracted_at IS NULL
         AND EXISTS (
           SELECT 1 FROM memory_claim_evidence ce
           JOIN memory_evidence e ON e.id = ce.evidence_id
           JOIN memory_source_revisions r ON r.id = e.source_revision_id
           WHERE ce.claim_id = memory_claims.id AND ce.uid = ?2
         )
         AND NOT EXISTS (
           SELECT 1 FROM memory_claim_evidence ce
           JOIN memory_evidence e ON e.id = ce.evidence_id
           JOIN memory_source_revisions r ON r.id = e.source_revision_id
           JOIN memory_sources s ON s.id = r.source_id
           WHERE ce.claim_id = memory_claims.id AND ce.uid = ?2 AND s.tombstoned_at IS NULL
         )`,
    ).bind(now, uid),
    context.env.DB.prepare(
      `UPDATE memory_daily_reviews SET retracted_at = ?1
       WHERE uid = ?2 AND retracted_at IS NULL AND EXISTS (
         SELECT 1 FROM memory_daily_review_citations rc
         JOIN memory_evidence e ON e.id = rc.evidence_id
         JOIN memory_source_revisions r ON r.id = e.source_revision_id
         WHERE rc.review_id = memory_daily_reviews.id AND rc.uid = ?2 AND r.source_id = ?3
       )`,
    ).bind(now, uid, sourceId),
  ]);
  return context.body(null, 204);
});

routes.get("/memory/daily-reviews", async (context) => {
  const rows = await context.env.DB.prepare(
    `SELECT r.id, r.local_date, r.input_revision, r.body, r.created_at, r.updated_at,
            e.id AS evidence_id, e.quote, e.locator, e.source_revision_id, sr.source_id
     FROM memory_daily_reviews r
     LEFT JOIN memory_daily_review_citations rc ON rc.review_id = r.id AND rc.uid = r.uid
     LEFT JOIN memory_evidence e ON e.id = rc.evidence_id AND e.uid = rc.uid
     LEFT JOIN memory_source_revisions sr ON sr.id = e.source_revision_id AND sr.uid = e.uid
     WHERE r.uid = ?1 AND r.retracted_at IS NULL
     ORDER BY r.local_date DESC, r.updated_at DESC LIMIT 300`,
  )
    .bind(context.get("auth").uid)
    .all();
  const reviews = new Map<string, Record<string, unknown>>();
  for (const row of rows.results ?? []) {
    const id = String(row.id);
    const review = reviews.get(id) ?? {
      id,
      localDate: String(row.local_date),
      inputRevision: String(row.input_revision),
      body: String(row.body),
      citations: [],
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    };
    if (row.evidence_id !== null)
      (review.citations as MemoryEvidence[]).push({
        id: String(row.evidence_id),
        sourceId: String(row.source_id),
        sourceRevisionId: String(row.source_revision_id),
        quote: String(row.quote),
        locator: parseJson(row.locator, null),
      });
    reviews.set(id, review);
  }
  return context.json({ reviews: [...reviews.values()].slice(0, 100) });
});

routes.post("/memory/daily-reviews", async (context) => {
  const body = await json(context.req.raw);
  const localDate = text(body?.localDate, 10);
  const inputRevision = text(body?.inputRevision, 200);
  const reviewBody = text(body?.body, 50_000);
  const citationIds = body?.citationIds;
  if (
    !localDate ||
    !/^\d{4}-\d{2}-\d{2}$/.test(localDate) ||
    !inputRevision ||
    !reviewBody ||
    !Array.isArray(citationIds) ||
    citationIds.length === 0 ||
    citationIds.some((value) => !text(value, 100))
  )
    return context.json({ error: "Invalid daily review" }, 400);
  const uid = context.get("auth").uid;
  const existing = await context.env.DB.prepare(
    "SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3",
  )
    .bind(uid, localDate, inputRevision)
    .first();
  const id = existing ? String(existing.id) : crypto.randomUUID();
  const now = Date.now();
  const statements = [
    context.env.DB.prepare(
      `INSERT INTO memory_daily_reviews (id, uid, local_date, input_revision, body, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
       ON CONFLICT(uid, local_date, input_revision) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at, retracted_at = NULL`,
    ).bind(id, uid, localDate, inputRevision, reviewBody, now),
    context.env.DB.prepare(
      `DELETE FROM memory_daily_review_citations
       WHERE uid = ?1 AND review_id = (
         SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3
       )`,
    ).bind(uid, localDate, inputRevision),
    ...citationIds.map((evidenceId) =>
      context.env.DB.prepare(
        `INSERT OR IGNORE INTO memory_daily_review_citations (uid, review_id, evidence_id)
           SELECT ?1, r.id, e.id FROM memory_daily_reviews r, memory_evidence e
           WHERE r.uid = ?1 AND r.local_date = ?2 AND r.input_revision = ?3 AND e.id = ?4 AND e.uid = ?1`,
      ).bind(uid, localDate, inputRevision, evidenceId),
    ),
  ];
  await context.env.DB.batch(statements);
  return context.json({ id }, 201);
});

routes.get("/currents", async (context) => {
  const rows = await context.env.DB.prepare(
    "SELECT id, title, summary, status, created_at, updated_at FROM currents WHERE uid = ?1 ORDER BY updated_at DESC LIMIT 100",
  )
    .bind(context.get("auth").uid)
    .all();
  const currents: Current[] = (rows.results ?? []).map((row) => ({
    id: String(row.id),
    title: String(row.title),
    summary: String(row.summary),
    status: row.status as Current["status"],
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
  }));
  return context.json({ currents });
});

routes.get("/settings", async (context) => {
  const row = await context.env.DB.prepare(
    "SELECT value, revision FROM user_settings WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  const settings = parseJson<UserSettings>(row?.value, {
    approvalMode: "once",
    proactiveRecommendations: true,
  });
  return context.json({
    settings,
    revision: Number(row?.revision ?? 0),
    effectivePolicy: settings,
  });
});

routes.put("/settings", async (context) => {
  const body = await json(context.req.raw);
  const patch =
    body?.patch !== null &&
    typeof body?.patch === "object" &&
    !Array.isArray(body.patch)
      ? (body.patch as Record<string, unknown>)
      : null;
  const expectedRevision = Number(body?.expectedRevision);
  const duration = body?.duration as SettingsDuration;
  const patchKeys = patch ? Object.keys(patch) : [];
  const validApproval =
    patch?.approvalMode === undefined ||
    patch.approvalMode === "ask" ||
    patch.approvalMode === "once" ||
    patch.approvalMode === "auto";
  const validProactive =
    patch?.proactiveRecommendations === undefined ||
    typeof patch.proactiveRecommendations === "boolean";
  if (
    !patch ||
    patchKeys.length === 0 ||
    patchKeys.some(
      (key) => key !== "approvalMode" && key !== "proactiveRecommendations",
    ) ||
    !Number.isSafeInteger(expectedRevision) ||
    expectedRevision < 0 ||
    !["task", "session", "persistent"].includes(duration) ||
    !validApproval ||
    !validProactive
  )
    return context.json({ error: "Invalid settings change" }, 400);
  const uid = context.get("auth").uid;
  const row = await context.env.DB.prepare(
    "SELECT value, revision FROM user_settings WHERE uid = ?1",
  )
    .bind(uid)
    .first();
  const revision = Number(row?.revision ?? 0);
  if (revision !== expectedRevision)
    return context.json({ error: "Settings revision conflict", revision }, 409);
  const previous = parseJson<UserSettings>(row?.value, {
    approvalMode: "once",
    proactiveRecommendations: true,
  });
  const settings: UserSettings = { ...previous, ...patch };
  const diff = settingsDiff(previous, settings);
  const authority = { ask: 0, once: 1, auto: 2 } as const;
  const expandsAuthority =
    patch.approvalMode !== undefined &&
    authority[patch.approvalMode as UserSettings["approvalMode"]] >
      authority[previous.approvalMode];
  const now = Date.now();
  const scopeId =
    duration === "persistent"
      ? null
      : text(duration === "task" ? body?.taskId : body?.sessionId, 200);
  const expiresAt =
    body?.expiresAt === undefined || body.expiresAt === null
      ? null
      : Number(body.expiresAt);
  if (duration !== "persistent" && !scopeId)
    return context.json({ error: `Missing ${duration} id` }, 400);
  if (
    expiresAt !== null &&
    (!Number.isSafeInteger(expiresAt) || expiresAt <= now)
  )
    return context.json({ error: "Invalid settings expiry" }, 400);
  if (expandsAuthority) {
    const receiptId = text(body?.confirmationReceiptId, 100);
    if (!receiptId)
      return context.json({ error: "Owner confirmation required" }, 403);
    const receipt = await context.env.DB.prepare(
      `UPDATE owner_confirmation_receipts SET consumed_at = ?1
       WHERE id = ?2 AND uid = ?3 AND purpose = 'settings.approvalMode' AND value = ?4
         AND created_at < ?1 AND expires_at > ?1 AND consumed_at IS NULL`,
    )
      .bind(now, receiptId, uid, patch.approvalMode)
      .run();
    if (receipt.meta.changes !== 1)
      return context.json({ error: "Owner confirmation invalid" }, 403);
  }
  if (duration !== "persistent") {
    const id = crypto.randomUUID();
    await context.env.DB.prepare(
      `INSERT INTO setting_scopes (id, uid, duration, scope_id, base_revision, patch, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(uid, duration, scope_id) DO UPDATE SET
         base_revision = excluded.base_revision, patch = excluded.patch,
         created_at = excluded.created_at, expires_at = excluded.expires_at`,
    )
      .bind(
        id,
        uid,
        duration,
        scopeId,
        revision,
        JSON.stringify(patch),
        now,
        expiresAt,
      )
      .run();
    return context.json({
      settings,
      revision,
      duration,
      scopeId,
      diff,
      effectivePolicy: settings,
      restartRequired: false,
    });
  }
  const updated = row
    ? await context.env.DB.prepare(
        "UPDATE user_settings SET value = ?1, revision = revision + 1, updated_at = ?2 WHERE uid = ?3 AND revision = ?4",
      )
        .bind(JSON.stringify(settings), now, uid, expectedRevision)
        .run()
    : await context.env.DB.prepare(
        "INSERT OR IGNORE INTO user_settings (uid, value, revision, updated_at) VALUES (?1, ?2, 1, ?3)",
      )
        .bind(uid, JSON.stringify(settings), now)
        .run();
  if (updated.meta.changes !== 1)
    return context.json({ error: "Settings revision conflict" }, 409);
  return context.json({
    settings,
    revision: revision + 1,
    duration,
    diff,
    effectivePolicy: settings,
    restartRequired: false,
  });
});

routes.get("/entitlement", async (context) => {
  const row = await context.env.DB.prepare(
    "SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  const active =
    row?.status === "active" &&
    (row.valid_until === null || Number(row.valid_until) > Date.now());
  return context.json({
    plan: active && row?.plan === "pro" ? "pro" : "byok",
    active,
  });
});

routes.post("/channels/:channel/link", async (context) => {
  const channel = context.req.param("channel") as Channel;
  if (channel !== "telegram" && channel !== "blooio")
    return context.json({ error: "Unknown channel" }, 404);
  const token = Array.from(crypto.getRandomValues(new Uint8Array(24)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  const tokenHash = Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const now = Date.now();
  await context.env.DB.prepare(
    "INSERT INTO channel_link_tokens (token_hash, uid, channel, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
  )
    .bind(tokenHash, context.get("auth").uid, channel, now + 10 * 60_000, now)
    .run();
  return context.json({ channel, token, expiresAt: now + 10 * 60_000 }, 201);
});

routes.delete("/channels/:channel/link", async (context) => {
  const channel = context.req.param("channel") as Channel;
  if (channel !== "telegram" && channel !== "blooio")
    return context.json({ error: "Unknown channel" }, 404);
  const uid = context.get("auth").uid;
  const now = Date.now();
  const [bindings] = await context.env.DB.batch([
    context.env.DB.prepare(
      "UPDATE channel_bindings SET revoked_at = ?1 WHERE uid = ?2 AND channel = ?3 AND revoked_at IS NULL",
    ).bind(now, uid, channel),
    context.env.DB.prepare(
      "UPDATE channel_link_tokens SET consumed_at = ?1 WHERE uid = ?2 AND channel = ?3 AND consumed_at IS NULL",
    ).bind(now, uid, channel),
  ]);
  if (bindings.meta.changes > 0)
    await context.env.DB.prepare(
      "INSERT INTO audit_events (id, uid, actor_type, action, target_type, target_id, details, created_at) VALUES (?1, ?2, 'owner', 'channel.unlinked', 'channel', ?3, ?4, ?5)",
    )
      .bind(
        crypto.randomUUID(),
        uid,
        channel,
        JSON.stringify({ revokedBindings: bindings.meta.changes }),
        now,
      )
      .run();
  return context.body(null, 204);
});

export default routes;
