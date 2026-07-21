import { afterEach, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";

const instances: Miniflare[] = [];

const createAdmission = async (vars: Record<string, string> = {}) => {
  const bundle = await Bun.build({
    entrypoints: ["test/fixtures/stt-admission-worker.ts"],
    format: "esm",
    target: "browser",
    write: false,
  });
  if (!bundle.success) throw new Error("STT admission fixture did not bundle");
  const instance = new Miniflare({
    modules: true,
    script: await bundle.outputs[0].text(),
    durableObjects: {
      STT_ADMISSION: { className: "SttAdmission", useSQLite: true },
    },
    bindings: {
      STT_BUDGET_WINDOW_SECONDS: "3600",
      STT_UID_IN_FLIGHT_LIMIT: "2",
      STT_GLOBAL_IN_FLIGHT_LIMIT: "10",
      STT_UID_SECONDS_BUDGET: "1800",
      STT_GLOBAL_SECONDS_BUDGET: "9000",
      STT_UID_COST_BUDGET_MICROUSD: "150000",
      STT_GLOBAL_COST_BUDGET_MICROUSD: "750000",
      ...vars,
    },
  });
  instances.push(instance);
  return instance;
};

const admit = (instance: Miniflare, body: Record<string, unknown>) =>
  instance.dispatchFetch("https://admission.test/admit", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

afterEach(async () => {
  await Promise.all(instances.map((instance) => instance.dispose()));
  instances.length = 0;
});

describe("managed STT admission", () => {
  test("atomically enforces per-user reservations", async () => {
    const instance = await createAdmission({ STT_UID_IN_FLIGHT_LIMIT: "1" });
    const first = await admit(instance, {
      sessionId: "one",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    });
    const second = await admit(instance, {
      sessionId: "two",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    });
    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
    expect(second.headers.get("retry-after")).toBeTruthy();
  });

  test("keeps the full reservation and makes duplicate admission idempotent", async () => {
    const instance = await createAdmission();
    const body = {
      sessionId: "same",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    };
    expect((await admit(instance, body)).status).toBe(200);
    const duplicate = await admit(instance, body);
    expect(duplicate.status).toBe(200);
    expect(await duplicate.json()).toMatchObject({
      admitted: true,
      duplicate: true,
    });
    const next = await admit(instance, { ...body, sessionId: "next" });
    expect(next.status).toBe(200);
    const overBudget = await admit(instance, {
      ...body,
      sessionId: "over",
      uid: "beta",
    });
    expect(overBudget.status).toBe(200);
  });
});
