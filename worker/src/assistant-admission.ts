import type { Bindings } from "./types";

type Limits = {
  windowMs: number;
  uidInFlight: number;
  globalInFlight: number;
  uidTokens: number;
  globalTokens: number;
  uidCostMicrousd: number;
  globalCostMicrousd: number;
};

const positiveInteger = (value: unknown): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

const nonNegativeInteger = (value: unknown): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
};

const limitsFrom = (env: Bindings): Limits => ({
  windowMs:
    positiveInteger(env.MIMO_BUDGET_WINDOW_SECONDS) !== null
      ? (positiveInteger(env.MIMO_BUDGET_WINDOW_SECONDS) as number) * 1000
      : 3_600_000,
  uidInFlight: positiveInteger(env.MIMO_UID_IN_FLIGHT_LIMIT) ?? 2,
  globalInFlight: positiveInteger(env.MIMO_GLOBAL_IN_FLIGHT_LIMIT) ?? 32,
  uidTokens: positiveInteger(env.MIMO_UID_TOKEN_BUDGET) ?? 100_000,
  globalTokens: positiveInteger(env.MIMO_GLOBAL_TOKEN_BUDGET) ?? 2_000_000,
  uidCostMicrousd:
    positiveInteger(env.MIMO_UID_COST_BUDGET_MICROUSD) ?? 1_000_000,
  globalCostMicrousd:
    positiveInteger(env.MIMO_GLOBAL_COST_BUDGET_MICROUSD) ?? 20_000_000,
});

export class AssistantAdmission {
  private tail: Promise<void> = Promise.resolve();

  constructor(
    readonly state: DurableObjectState,
    readonly env: Bindings,
  ) {
    state.blockConcurrencyWhile(async () => {
      state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS reservations (
          request_id TEXT PRIMARY KEY,
          uid TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          token_budget INTEGER NOT NULL,
          cost_budget_microusd INTEGER NOT NULL,
          in_flight INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS reservations_uid_created
        ON reservations(uid, created_at);
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const operation = this.tail.then(() => this.handle(request));
    this.tail = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private async handle(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const body = (await request.json()) as Record<string, unknown>;
    const requestId =
      typeof body.requestId === "string" ? body.requestId : undefined;
    if (!requestId)
      return Response.json({ error: "Invalid request" }, { status: 400 });
    if (url.pathname === "/release") {
      this.state.storage.sql.exec(
        "UPDATE reservations SET in_flight = 0 WHERE request_id = ?",
        requestId,
      );
      return Response.json({ released: true });
    }
    if (url.pathname === "/settle") {
      const tokenBudget = nonNegativeInteger(body.tokenBudget);
      const costBudgetMicrousd = nonNegativeInteger(body.costBudgetMicrousd);
      if (tokenBudget === null || costBudgetMicrousd === null)
        return Response.json({ error: "Invalid request" }, { status: 400 });
      this.state.storage.sql.exec(
        `UPDATE reservations
         SET token_budget = ?, cost_budget_microusd = ?, in_flight = 0
         WHERE request_id = ?`,
        tokenBudget,
        costBudgetMicrousd,
        requestId,
      );
      return Response.json({ settled: true });
    }
    if (url.pathname !== "/admit") return new Response(null, { status: 404 });
    const uid = typeof body.uid === "string" ? body.uid : undefined;
    const tokenBudget = positiveInteger(body.tokenBudget);
    const costBudgetMicrousd = positiveInteger(body.costBudgetMicrousd);
    if (!uid || tokenBudget === null || costBudgetMicrousd === null)
      return Response.json({ error: "Invalid request" }, { status: 400 });
    const limits = limitsFrom(this.env);
    const now = Date.now();
    const sql = this.state.storage.sql;
    sql.exec(
      "DELETE FROM reservations WHERE created_at <= ?",
      now - limits.windowMs,
    );
    const duplicate = sql
      .exec<{ in_flight: number }>(
        "SELECT in_flight FROM reservations WHERE request_id = ?",
        requestId,
      )
      .toArray()[0];
    if (duplicate)
      return Response.json(
        { admitted: duplicate.in_flight === 1, retryAfter: 1 },
        { status: duplicate.in_flight === 1 ? 200 : 429 },
      );
    const usage = sql
      .exec<{
        global_in_flight: number;
        uid_in_flight: number;
        global_tokens: number;
        uid_tokens: number;
        global_cost: number;
        uid_cost: number;
        oldest: number | null;
      }>(
        `SELECT
           COALESCE(SUM(in_flight), 0) AS global_in_flight,
           COALESCE(SUM(CASE WHEN uid = ? THEN in_flight ELSE 0 END), 0) AS uid_in_flight,
           COALESCE(SUM(token_budget), 0) AS global_tokens,
           COALESCE(SUM(CASE WHEN uid = ? THEN token_budget ELSE 0 END), 0) AS uid_tokens,
           COALESCE(SUM(cost_budget_microusd), 0) AS global_cost,
           COALESCE(SUM(CASE WHEN uid = ? THEN cost_budget_microusd ELSE 0 END), 0) AS uid_cost,
           MIN(created_at) AS oldest
         FROM reservations`,
        uid,
        uid,
        uid,
      )
      .one();
    const exceeds =
      usage.global_in_flight >= limits.globalInFlight ||
      usage.uid_in_flight >= limits.uidInFlight ||
      usage.global_tokens + tokenBudget > limits.globalTokens ||
      usage.uid_tokens + tokenBudget > limits.uidTokens ||
      usage.global_cost + costBudgetMicrousd > limits.globalCostMicrousd ||
      usage.uid_cost + costBudgetMicrousd > limits.uidCostMicrousd;
    const retryAfter = Math.max(
      1,
      Math.ceil(((usage.oldest ?? now) + limits.windowMs - now) / 1000),
    );
    const result = exceeds
      ? { admitted: false, retryAfter }
      : { admitted: true, retryAfter: 0 };
    if (result.admitted)
      sql.exec(
        `INSERT INTO reservations
         (request_id, uid, created_at, token_budget, cost_budget_microusd, in_flight)
         VALUES (?, ?, ?, ?, ?, 1)`,
        requestId,
        uid,
        now,
        tokenBudget,
        costBudgetMicrousd,
      );
    return Response.json(result, {
      status: result.admitted ? 200 : 429,
      headers: result.admitted
        ? undefined
        : { "retry-after": String(result.retryAfter) },
    });
  }
}

const coordinator = (env: Bindings) =>
  env.ASSISTANT_ADMISSION.getByName("managed-ai-global");

export const admitAssistantRequest = async (
  env: Bindings,
  requestId: string,
  uid: string,
  tokenBudget: number,
  costBudgetMicrousd: number,
): Promise<Response> =>
  coordinator(env).fetch("https://assistant-admission.internal/admit", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ requestId, uid, tokenBudget, costBudgetMicrousd }),
  });

export const releaseAssistantRequest = async (
  env: Bindings,
  requestId: string,
): Promise<void> => {
  const response = await coordinator(env).fetch(
    "https://assistant-admission.internal/release",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ requestId }),
    },
  );
  if (!response.ok) throw new Error("Assistant admission release failed");
};

export const settleAssistantRequest = async (
  env: Bindings,
  requestId: string,
  tokenBudget: number,
  costBudgetMicrousd: number,
): Promise<void> => {
  const response = await coordinator(env).fetch(
    "https://assistant-admission.internal/settle",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ requestId, tokenBudget, costBudgetMicrousd }),
    },
  );
  if (!response.ok) throw new Error("Assistant admission settlement failed");
};
