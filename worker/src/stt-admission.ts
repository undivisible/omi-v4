import type { Bindings } from "./types";

type Limits = {
  windowMs: number;
  uidInFlight: number;
  globalInFlight: number;
  uidSeconds: number;
  globalSeconds: number;
  uidCostMicrousd: number;
  globalCostMicrousd: number;
  claimDeadlineMs: number;
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
  claimDeadlineMs:
    Math.min(positiveInteger(env.STT_CLAIM_DEADLINE_SECONDS) ?? 60, 300) * 1000,
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
          in_flight INTEGER NOT NULL,
          claim_by INTEGER,
          acquisition_token TEXT
        );
        CREATE INDEX IF NOT EXISTS reservations_uid_created
        ON reservations(uid, created_at);
      `);
      const columns = state.storage.sql
        .exec<{ name: string }>("PRAGMA table_info(reservations)")
        .toArray();
      if (!columns.some((column) => column.name === "claim_by"))
        state.storage.sql.exec(
          "ALTER TABLE reservations ADD COLUMN claim_by INTEGER",
        );
      if (!columns.some((column) => column.name === "acquisition_token"))
        state.storage.sql.exec(
          "ALTER TABLE reservations ADD COLUMN acquisition_token TEXT",
        );
      state.storage.sql.exec(
        "UPDATE reservations SET acquisition_token = lower(hex(randomblob(16))) WHERE acquisition_token IS NULL",
      );
      await this.scheduleNextAlarm();
    });
  }

  async alarm(): Promise<void> {
    this.state.storage.sql.exec(
      "UPDATE reservations SET in_flight = 0, claim_by = NULL WHERE in_flight = 1 AND claim_by IS NOT NULL AND claim_by <= ?",
      Date.now(),
    );
    await this.scheduleNextAlarm();
  }

  private async scheduleNextAlarm(): Promise<void> {
    const next = this.state.storage.sql
      .exec<{ claim_by: number | null }>(
        "SELECT MIN(claim_by) AS claim_by FROM reservations WHERE in_flight = 1 AND claim_by IS NOT NULL",
      )
      .one().claim_by;
    if (next === null) await this.state.storage.deleteAlarm();
    else await this.state.storage.setAlarm(next);
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
    const url = new URL(request.url);
    if (url.pathname === "/release") {
      const releaseUid = typeof body.uid === "string" ? body.uid : undefined;
      const acquisitionToken =
        typeof body.acquisitionToken === "string"
          ? body.acquisitionToken
          : undefined;
      if (!sessionId || !releaseUid || !acquisitionToken)
        return Response.json({ error: "Invalid request" }, { status: 400 });
      this.state.storage.sql.exec(
        "UPDATE reservations SET in_flight = 0, claim_by = NULL WHERE session_id = ? AND uid = ? AND acquisition_token = ?",
        sessionId,
        releaseUid,
        acquisitionToken,
      );
      await this.scheduleNextAlarm();
      return Response.json({ released: true });
    }
    if (url.pathname === "/claim") {
      const claimUid = typeof body.uid === "string" ? body.uid : undefined;
      const acquisitionToken =
        typeof body.acquisitionToken === "string"
          ? body.acquisitionToken
          : undefined;
      if (!sessionId || !claimUid || !acquisitionToken)
        return Response.json({ error: "Invalid request" }, { status: 400 });
      const now = Date.now();
      const result = this.state.storage.sql.exec(
        "UPDATE reservations SET claim_by = NULL WHERE session_id = ? AND uid = ? AND acquisition_token = ? AND in_flight = 1 AND claim_by IS NOT NULL AND claim_by > ?",
        sessionId,
        claimUid,
        acquisitionToken,
        now,
      );
      if (result.rowsWritten !== 1)
        this.state.storage.sql.exec(
          "UPDATE reservations SET in_flight = 0, claim_by = NULL WHERE session_id = ? AND uid = ? AND acquisition_token = ? AND in_flight = 1 AND claim_by IS NOT NULL AND claim_by <= ?",
          sessionId,
          claimUid,
          acquisitionToken,
          now,
        );
      await this.scheduleNextAlarm();
      return Response.json({ claimed: result.rowsWritten === 1 });
    }
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
      .exec<{
        uid: string;
        reserved_seconds: number;
        cost_budget_microusd: number;
        in_flight: number;
        acquisition_token: string;
      }>(
        "SELECT uid, reserved_seconds, cost_budget_microusd, in_flight, acquisition_token FROM reservations WHERE session_id = ?",
        sessionId,
      )
      .toArray()[0];
    if (
      duplicate &&
      (duplicate.uid !== uid ||
        duplicate.reserved_seconds !== reservedSeconds ||
        duplicate.cost_budget_microusd !== costBudgetMicrousd)
    )
      return Response.json({ error: "Admission conflict" }, { status: 409 });
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
    if (duplicate) {
      if (duplicate.in_flight === 1)
        return Response.json({
          admitted: true,
          duplicate: true,
          acquisitionToken: duplicate.acquisition_token,
        });
      if (
        usage.global_in_flight >= limits.globalInFlight ||
        usage.uid_in_flight >= limits.uidInFlight
      )
        return Response.json(
          { admitted: false, retryAfter },
          { status: 429, headers: { "retry-after": String(retryAfter) } },
        );
      const acquisitionToken = crypto.randomUUID();
      sql.exec(
        "UPDATE reservations SET in_flight = 1, claim_by = ?, acquisition_token = ? WHERE session_id = ? AND uid = ? AND in_flight = 0",
        now + limits.claimDeadlineMs,
        acquisitionToken,
        sessionId,
        uid,
      );
      await this.scheduleNextAlarm();
      return Response.json({
        admitted: true,
        duplicate: true,
        reacquired: true,
        acquisitionToken,
      });
    }
    if (exceeds)
      return Response.json(
        { admitted: false, retryAfter },
        { status: 429, headers: { "retry-after": String(retryAfter) } },
      );
    const acquisitionToken = crypto.randomUUID();
    sql.exec(
      `INSERT INTO reservations
       (session_id, uid, created_at, reserved_seconds, cost_budget_microusd, in_flight, claim_by, acquisition_token)
       VALUES (?, ?, ?, ?, ?, 1, ?, ?)`,
      sessionId,
      uid,
      now,
      reservedSeconds,
      costBudgetMicrousd,
      now + limits.claimDeadlineMs,
      acquisitionToken,
    );
    await this.scheduleNextAlarm();
    return Response.json({ admitted: true, retryAfter: 0, acquisitionToken });
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

export const releaseSttSession = async (
  env: Bindings,
  sessionId: string,
  uid: string,
  acquisitionToken: string,
): Promise<void> => {
  const response = await env.STT_ADMISSION.getByName(
    "managed-stt-global",
  ).fetch("https://stt-admission.internal/release", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId, uid, acquisitionToken }),
  });
  if (!response.ok) throw new Error("STT admission release failed");
};

export const claimSttSession = async (
  env: Bindings,
  sessionId: string,
  uid: string,
  acquisitionToken: string,
): Promise<void> => {
  const response = await env.STT_ADMISSION.getByName(
    "managed-stt-global",
  ).fetch("https://stt-admission.internal/claim", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId, uid, acquisitionToken }),
  });
  const result = response.ok
    ? ((await response.json()) as Record<string, unknown>)
    : null;
  if (result?.claimed !== true) throw new Error("STT admission claim failed");
};
