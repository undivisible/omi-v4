import type { Bindings } from "./types";

type Limits = {
  windowMs: number;
  uidInFlight: number;
  globalInFlight: number;
  uidSeconds: number;
  globalSeconds: number;
  uidCostMicrousd: number;
  globalCostMicrousd: number;
};

const positiveInteger = (value: unknown): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

const limitsFrom = (env: Bindings): Limits => ({
  windowMs: (positiveInteger(env.STT_BUDGET_WINDOW_SECONDS) ?? 3600) * 1000,
  uidInFlight: positiveInteger(env.STT_UID_IN_FLIGHT_LIMIT) ?? 2,
  globalInFlight: positiveInteger(env.STT_GLOBAL_IN_FLIGHT_LIMIT) ?? 64,
  uidSeconds: positiveInteger(env.STT_UID_SECONDS_BUDGET) ?? 3600,
  globalSeconds: positiveInteger(env.STT_GLOBAL_SECONDS_BUDGET) ?? 115_200,
  uidCostMicrousd: positiveInteger(env.STT_UID_COST_BUDGET_MICROUSD) ?? 300_000,
  globalCostMicrousd:
    positiveInteger(env.STT_GLOBAL_COST_BUDGET_MICROUSD) ?? 9_600_000,
});

export class SttAdmission {
  private tail: Promise<void> = Promise.resolve();

  constructor(
    readonly state: DurableObjectState,
    readonly env: Bindings,
  ) {
    state.blockConcurrencyWhile(async () => {
      state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS reservations (
          session_id TEXT PRIMARY KEY,
          uid TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          reserved_seconds INTEGER NOT NULL,
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
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const body = (await request.json()) as Record<string, unknown>;
    const sessionId =
      typeof body.sessionId === "string" ? body.sessionId : undefined;
    const uid = typeof body.uid === "string" ? body.uid : undefined;
    const reservedSeconds = positiveInteger(body.reservedSeconds);
    const costBudgetMicrousd = positiveInteger(body.costBudgetMicrousd);
    if (
      !sessionId ||
      !uid ||
      reservedSeconds === null ||
      costBudgetMicrousd === null
    )
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
        "SELECT in_flight FROM reservations WHERE session_id = ?",
        sessionId,
      )
      .toArray()[0];
    if (duplicate) return Response.json({ admitted: true, duplicate: true });
    const usage = sql
      .exec<{
        global_in_flight: number;
        uid_in_flight: number;
        global_seconds: number;
        uid_seconds: number;
        global_cost: number;
        uid_cost: number;
        oldest: number | null;
      }>(
        `SELECT
           COALESCE(SUM(in_flight), 0) AS global_in_flight,
           COALESCE(SUM(CASE WHEN uid = ? THEN in_flight ELSE 0 END), 0) AS uid_in_flight,
           COALESCE(SUM(reserved_seconds), 0) AS global_seconds,
           COALESCE(SUM(CASE WHEN uid = ? THEN reserved_seconds ELSE 0 END), 0) AS uid_seconds,
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
      usage.global_seconds + reservedSeconds > limits.globalSeconds ||
      usage.uid_seconds + reservedSeconds > limits.uidSeconds ||
      usage.global_cost + costBudgetMicrousd > limits.globalCostMicrousd ||
      usage.uid_cost + costBudgetMicrousd > limits.uidCostMicrousd;
    const retryAfter = Math.max(
      1,
      Math.ceil(((usage.oldest ?? now) + limits.windowMs - now) / 1000),
    );
    if (exceeds)
      return Response.json(
        { admitted: false, retryAfter },
        { status: 429, headers: { "retry-after": String(retryAfter) } },
      );
    sql.exec(
      `INSERT INTO reservations
       (session_id, uid, created_at, reserved_seconds, cost_budget_microusd, in_flight)
       VALUES (?, ?, ?, ?, ?, 1)`,
      sessionId,
      uid,
      now,
      reservedSeconds,
      costBudgetMicrousd,
    );
    return Response.json({ admitted: true, retryAfter: 0 });
  }
}

export const admitSttSession = (
  env: Bindings,
  sessionId: string,
  uid: string,
  reservedSeconds: number,
  costBudgetMicrousd: number,
): Promise<Response> =>
  env.STT_ADMISSION.getByName("managed-stt-global").fetch(
    "https://stt-admission.internal/admit",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId,
        uid,
        reservedSeconds,
        costBudgetMicrousd,
      }),
    },
  );
