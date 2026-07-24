import { openrouterCompletionEndpoint } from "./assistant";
import { createCurrent, generateOneCurrent, listCurrents } from "./currents";
import { modelForTier } from "./model-tiers";
import type { Bindings } from "./types";

export const minCheckIntervalMs = 15 * 60 * 1000;
export const minRegenerateIntervalMs = 4 * 60 * 60 * 1000;
export const staleCurrentAgeMs = 6 * 60 * 60 * 1000;
export const refreshBatchSize = 5;
const completionTimeoutMs = 20_000;

export type CurrentContentKind = "agent_action" | "human_action" | "awareness";

export const normalizeContentKind = (value: unknown): CurrentContentKind => {
  if (value === "agent_action" || value === "human_action" || value === "awareness")
    return value;
  return "human_action";
};

export type RefreshContext = {
  surfacedCount: number;
  newestUpdatedAt: number | null;
  memoryWatermark: number;
  existingTitles: string[];
  memoryLines: MemoryLine[];
};

type MemoryLine = {
  evidenceId: string;
  sourceKind: string | null;
  quote: string;
  content: string;
  recordedAt: number;
};

type RefreshState = {
  last_checked_at: number;
  last_regenerated_at: number;
  memory_watermark: number;
};

type GeneratedDraft = {
  contentKind: CurrentContentKind;
  title: string;
  summary: string;
  reason: string;
  instruction: string;
  evidenceId: string;
  tool?: string;
};

const collapse = (value: string) =>
  value.split(/\s+/).filter(Boolean).join(" ");

const readState = async (
  env: Bindings,
  uid: string,
): Promise<RefreshState> => {
  const row = await env.DB.prepare(
    "SELECT last_checked_at, last_regenerated_at, memory_watermark FROM currents_refresh_state WHERE uid = ?1",
  )
    .bind(uid)
    .first<RefreshState>();
  return (
    row ?? {
      last_checked_at: 0,
      last_regenerated_at: 0,
      memory_watermark: 0,
    }
  );
};

const writeState = async (
  env: Bindings,
  uid: string,
  patch: Partial<RefreshState>,
) => {
  const current = await readState(env, uid);
  await env.DB.prepare(
    `INSERT INTO currents_refresh_state
      (uid, last_checked_at, last_regenerated_at, memory_watermark)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(uid) DO UPDATE SET
       last_checked_at = excluded.last_checked_at,
       last_regenerated_at = excluded.last_regenerated_at,
       memory_watermark = excluded.memory_watermark`,
  )
    .bind(
      uid,
      patch.last_checked_at ?? current.last_checked_at,
      patch.last_regenerated_at ?? current.last_regenerated_at,
      patch.memory_watermark ?? current.memory_watermark,
    )
    .run();
};

export const gatherRefreshContext = async (
  env: Bindings,
  uid: string,
  now = Date.now(),
): Promise<RefreshContext> => {
  const surfaced = await env.DB.prepare(
    `SELECT title, updated_at FROM currents
     WHERE uid = ?1 AND status IN ('surfaced', 'accepted')
     ORDER BY updated_at DESC LIMIT 20`,
  )
    .bind(uid)
    .all<{ title: string; updated_at: number }>();
  const surfacedRows = surfaced.results ?? [];
  const memory = await env.DB.prepare(
    `SELECT e.id AS evidence_id, s.kind AS source_kind, e.quote, c.content, c.recorded_at
     FROM memory_claims c
     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
       AND ce.relation = 'supports'
     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL
       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
       AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL
     ORDER BY c.recorded_at DESC, c.id ASC
     LIMIT 24`,
  )
    .bind(uid)
    .all<Record<string, unknown>>();
  const memoryLines = (memory.results ?? []).map((row) => ({
    evidenceId: String(row.evidence_id),
    sourceKind: row.source_kind == null ? null : String(row.source_kind),
    quote: String(row.quote),
    content: String(row.content),
    recordedAt: Number(row.recorded_at),
  }));
  const watermark = memoryLines.reduce(
    (max, line) => Math.max(max, line.recordedAt),
    0,
  );
  return {
    surfacedCount: surfacedRows.length,
    newestUpdatedAt:
      surfacedRows.length === 0
        ? null
        : Math.max(...surfacedRows.map((row) => Number(row.updated_at))),
    memoryWatermark: watermark,
    existingTitles: surfacedRows.map((row) => String(row.title)),
    memoryLines,
  };
};

export const heuristicNeedsRefresh = (
  context: RefreshContext,
  state: RefreshState,
  now: number,
  force: boolean,
): { refresh: boolean; reason: string } => {
  if (force) return { refresh: true, reason: "forced" };
  if (context.surfacedCount === 0)
    return { refresh: true, reason: "no_surfaced_currents" };
  if (
    context.newestUpdatedAt != null &&
    now - context.newestUpdatedAt >= staleCurrentAgeMs
  )
    return { refresh: true, reason: "currents_stale" };
  if (context.memoryWatermark > state.memory_watermark)
    return { refresh: true, reason: "new_memory" };
  if (
    state.last_regenerated_at > 0 &&
    now - state.last_regenerated_at >= minRegenerateIntervalMs
  )
    return { refresh: true, reason: "regenerate_ttl" };
  return { refresh: false, reason: "fresh" };
};

const parseJsonObject = (text: string): Record<string, unknown> | null => {
  const trimmed = text.trim();
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)```$/i);
  const candidate = fenced?.[1]?.trim() ?? trimmed;
  try {
    const value = JSON.parse(candidate) as unknown;
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

const speedCompletion = async (
  env: Bindings,
  prompt: string,
  fetcher: typeof fetch = fetch,
): Promise<string | null> => {
  const secret = env.OPENROUTER_API_KEY?.trim();
  const model = modelForTier(env, "speed");
  const endpoint =
    env.OPENROUTER_CHAT_COMPLETIONS_URL ?? openrouterCompletionEndpoint;
  if (!secret || !model) return null;
  try {
    const upstream = await fetcher(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${secret}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: prompt }],
        stream: false,
        max_tokens: 256,
        temperature: 0,
      }),
      signal: AbortSignal.timeout(completionTimeoutMs),
    });
    if (!upstream.ok) return null;
    const value = (await upstream.json()) as {
      choices?: Array<{ message?: { content?: unknown } }>;
    };
    const content = value.choices?.[0]?.message?.content;
    return typeof content === "string" && content.trim() ? content.trim() : null;
  } catch {
    return null;
  }
};

export const aiNeedsRefresh = async (
  env: Bindings,
  context: RefreshContext,
  state: RefreshState,
): Promise<boolean | null> => {
  if (context.memoryLines.length === 0) return null;
  const prompt = [
    "Decide whether proactive task suggestions should refresh.",
    "Reply ONLY with JSON: {\"refresh\":true|false,\"reason\":\"...\"}",
    "",
    `Existing currents (${context.existingTitles.length}):`,
    ...context.existingTitles.slice(0, 8).map((title) => `- ${title}`),
    "",
    `Last regenerated ms: ${state.last_regenerated_at}`,
    `Memory watermark ms: ${state.memory_watermark}; latest memory ms: ${context.memoryWatermark}`,
    "",
    "Recent memory excerpts:",
    ...context.memoryLines.slice(0, 6).map(
      (line) =>
        `- [${line.sourceKind ?? "memory"}] ${collapse(line.content).slice(0, 160)}`,
    ),
  ].join("\n");
  const content = await speedCompletion(env, prompt);
  if (!content) return null;
  const parsed = parseJsonObject(content);
  return parsed?.refresh === true
    ? true
    : parsed?.refresh === false
      ? false
      : null;
};

const inferKind = (line: MemoryLine): CurrentContentKind => {
  const kind = line.sourceKind?.toLowerCase() ?? "";
  const text = `${line.content} ${line.quote}`.toLowerCase();
  if (
    kind.includes("calendar") ||
    kind.includes("meeting") ||
    /\b(meeting|standup|sync|deadline|event|calendar)\b/.test(text)
  )
    return "awareness";
  if (
    kind.includes("integration") ||
    /\b(email|send|schedule|create task|remind|notify)\b/.test(text)
  )
    return "agent_action";
  return "human_action";
};

const heuristicDrafts = (context: RefreshContext): GeneratedDraft[] => {
  const seen = new Set(context.existingTitles.map((title) => title.toLowerCase()));
  const drafts: GeneratedDraft[] = [];
  for (const line of context.memoryLines) {
    const content = collapse(line.content);
    const quote = collapse(line.quote);
    if (!content || !quote) continue;
    const title = collapse(content).slice(0, 120);
    if (seen.has(title.toLowerCase())) continue;
    seen.add(title.toLowerCase());
    const contentKind = inferKind(line);
    drafts.push({
      contentKind,
      title,
      summary: content.slice(0, 500),
      reason: `Based on: ${quote}`.slice(0, 500),
      instruction:
        contentKind === "agent_action"
          ? `Take the smallest automated step toward: ${content}`.slice(0, 500)
          : contentKind === "awareness"
            ? `Keep in mind for today: ${content}`.slice(0, 500)
            : `Do the smallest next step: ${content}`.slice(0, 500),
      evidenceId: line.evidenceId,
      ...(contentKind === "agent_action"
        ? { tool: "assistant" }
        : {}),
    });
    if (drafts.length >= refreshBatchSize) break;
  }
  return drafts;
};

const parseDrafts = (
  content: string,
  allowedEvidence: Set<string>,
): GeneratedDraft[] => {
  const parsed = parseJsonObject(content);
  const items = parsed?.items;
  if (!Array.isArray(items)) return [];
  const drafts: GeneratedDraft[] = [];
  for (const item of items) {
    if (item === null || typeof item !== "object" || Array.isArray(item)) continue;
    const row = item as Record<string, unknown>;
    const evidenceId =
      typeof row.evidenceId === "string" ? row.evidenceId.trim() : "";
    const title = typeof row.title === "string" ? collapse(row.title) : "";
    const summary = typeof row.summary === "string" ? collapse(row.summary) : "";
    const reason = typeof row.reason === "string" ? collapse(row.reason) : "";
    const instruction =
      typeof row.instruction === "string" ? collapse(row.instruction) : "";
    if (
      !allowedEvidence.has(evidenceId) ||
      !title ||
      !summary ||
      !reason ||
      !instruction
    )
      continue;
    drafts.push({
      contentKind: normalizeContentKind(row.contentKind),
      title: title.slice(0, 120),
      summary: summary.slice(0, 500),
      reason: reason.slice(0, 500),
      instruction: instruction.slice(0, 500),
      evidenceId,
      ...(typeof row.tool === "string" && row.tool.trim()
        ? { tool: row.tool.trim().slice(0, 120) }
        : {}),
    });
    if (drafts.length >= refreshBatchSize) break;
  }
  return drafts;
};

const aiDrafts = async (
  env: Bindings,
  context: RefreshContext,
): Promise<GeneratedDraft[]> => {
  if (context.memoryLines.length === 0) return [];
  const allowed = new Set(context.memoryLines.map((line) => line.evidenceId));
  const prompt = [
    "Generate refreshed proactive suggestions ('currents') for the user.",
    "Return ONLY JSON:",
    '{"items":[{"contentKind":"agent_action|human_action|awareness","title":"...","summary":"...","reason":"...","instruction":"...","evidenceId":"...","tool":"optional for agent_action"}]}',
    "",
    "Mix all three kinds:",
    "- agent_action: Omi/automation can execute (include tool when obvious)",
    "- human_action: the user should do",
    "- awareness: meetings, events, deadlines to know about",
    "",
    "Use evidenceId values from this list only:",
    ...context.memoryLines.slice(0, 12).map(
      (line) =>
        `- ${line.evidenceId} [${line.sourceKind ?? "memory"}] ${collapse(line.content).slice(0, 140)}`,
    ),
    "",
    "Avoid repeating these existing titles:",
    ...context.existingTitles.slice(0, 8).map((title) => `- ${title}`),
  ].join("\n");
  const content = await speedCompletion(env, prompt);
  if (!content) return [];
  return parseDrafts(content, allowed);
};

const expireRefreshBatch = async (
  env: Bindings,
  uid: string,
  now: number,
) => {
  await env.DB.prepare(
    `UPDATE currents SET status = 'expired', updated_at = ?1
     WHERE uid = ?2 AND status IN ('candidate', 'surfaced', 'snoozed')
       AND generation_key LIKE 'refresh:%'`,
  )
    .bind(now, uid)
    .run();
};

const insertDraft = async (
  env: Bindings,
  uid: string,
  draft: GeneratedDraft,
  generationKey: string,
  now: number,
) => {
  const proposed = {
    kind: draft.contentKind,
    instruction: draft.instruction,
    ...(draft.tool ? { tool: draft.tool } : {}),
  };
  await createCurrent(env, uid, {
    evidenceId: draft.evidenceId,
    title: draft.title,
    summary: draft.summary,
    reason: draft.reason,
    instruction: draft.instruction,
    confidence: 0.72,
    surfaceAt: now,
    expiresAt: null,
    crepus: null,
    proposedAction: proposed,
    generationKey,
  });
};

export const regenerateCurrents = async (
  env: Bindings,
  uid: string,
  context: RefreshContext,
  now = Date.now(),
): Promise<number> => {
  await expireRefreshBatch(env, uid, now);
  let created = 0;
  for (let i = 0; i < 3; i += 1) {
    const outcome = await generateOneCurrent(env, uid, now);
    if (outcome.status === "created") created += 1;
    else break;
  }
  const ai = await aiDrafts(env, context);
  const drafts = ai.length > 0 ? ai : heuristicDrafts(context);
  const localDate = new Date(now).toISOString().slice(0, 10);
  for (const [index, draft] of drafts.entries()) {
    if (created >= refreshBatchSize) break;
    const generationKey = `refresh:${localDate}:${index}`;
    const existing = await env.DB.prepare(
      "SELECT 1 AS ok FROM currents WHERE uid = ?1 AND generation_key = ?2",
    )
      .bind(uid, generationKey)
      .first();
    if (existing) continue;
    try {
      await insertDraft(env, uid, draft, generationKey, now);
      created += 1;
    } catch {}
  }
  return created;
};

export type RefreshOutcome = {
  refreshed: boolean;
  reason: string;
  checkedAt: number;
  regeneratedAt: number | null;
  currents: Record<string, unknown>[];
};

export const refreshCurrents = async (
  env: Bindings,
  uid: string,
  options: { force?: boolean; now?: number; fetcher?: typeof fetch } = {},
): Promise<RefreshOutcome> => {
  const now = options.now ?? Date.now();
  const force = options.force === true;
  const state = await readState(env, uid);
  const context = await gatherRefreshContext(env, uid, now);
  if (
    !force &&
    state.last_checked_at > 0 &&
    now - state.last_checked_at < minCheckIntervalMs
  ) {
    return {
      refreshed: false,
      reason: "check_ttl",
      checkedAt: state.last_checked_at,
      regeneratedAt:
        state.last_regenerated_at > 0 ? state.last_regenerated_at : null,
      currents: await listCurrents(env, uid),
    };
  }
  const heuristic = heuristicNeedsRefresh(context, state, now, force);
  let shouldRefresh = heuristic.refresh;
  let reason = heuristic.reason;
  if (
    shouldRefresh &&
    !force &&
    heuristic.reason !== "no_surfaced_currents" &&
    heuristic.reason !== "currents_stale"
  ) {
    const ai = await aiNeedsRefresh(env, context, state);
    if (ai === false) {
      shouldRefresh = false;
      reason = "ai_fresh";
    } else if (ai === true) reason = "ai_stale";
  }
  if (
    shouldRefresh &&
    !force &&
    state.last_regenerated_at > 0 &&
    now - state.last_regenerated_at < minRegenerateIntervalMs &&
    heuristic.reason !== "no_surfaced_currents" &&
    heuristic.reason !== "currents_stale" &&
    heuristic.reason !== "new_memory"
  ) {
    shouldRefresh = false;
    reason = "regenerate_ttl";
  }
  let regeneratedAt: number | null =
    state.last_regenerated_at > 0 ? state.last_regenerated_at : null;
  if (shouldRefresh) {
    await regenerateCurrents(env, uid, context, now);
    regeneratedAt = now;
    await writeState(env, uid, {
      last_checked_at: now,
      last_regenerated_at: now,
      memory_watermark: context.memoryWatermark,
    });
  } else {
    await writeState(env, uid, {
      last_checked_at: now,
      memory_watermark: Math.max(state.memory_watermark, context.memoryWatermark),
    });
  }
  return {
    refreshed: shouldRefresh,
    reason,
    checkedAt: now,
    regeneratedAt,
    currents: await listCurrents(env, uid),
  };
};
