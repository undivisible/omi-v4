import { afterEach, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";

const instances: Miniflare[] = [];

const createAdmission = async (bindings: Record<string, string>) => {
  const bundle = await Bun.build({
    entrypoints: ["test/fixtures/admission-worker.ts"],
    format: "esm",
    target: "browser",
    write: false,
  });
  if (!bundle.success) throw new Error("Admission fixture did not bundle");
  const instance = new Miniflare({
    modules: true,
    script: await bundle.outputs[0].text(),
    durableObjects: {
      ASSISTANT_ADMISSION: {
        className: "AssistantAdmission",
        useSQLite: true,
      },
    },
    bindings: {
      MIMO_BUDGET_WINDOW_SECONDS: "3600",
      MIMO_UID_IN_FLIGHT_LIMIT: "2",
      MIMO_GLOBAL_IN_FLIGHT_LIMIT: "10",
      MIMO_UID_TOKEN_BUDGET: "100000",
      MIMO_GLOBAL_TOKEN_BUDGET: "1000000",
      MIMO_UID_COST_BUDGET_MICROUSD: "100000",
      MIMO_GLOBAL_COST_BUDGET_MICROUSD: "1000000",
      ...bindings,
    },
  });
  instances.push(instance);
  return instance;
};

const command = (
  instance: Miniflare,
  path: "admit" | "release" | "settle",
  body: Record<string, unknown>,
) =>
  instance.dispatchFetch(`https://admission.test/${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

afterEach(async () => {
  await Promise.all(instances.splice(0).map((instance) => instance.dispose()));
});

describe("managed assistant admission", () => {
  test("atomically enforces simultaneous per-UID and global in-flight limits", async () => {
    const perUid = await createAdmission({ MIMO_UID_IN_FLIGHT_LIMIT: "2" });
    const uidResponses = await Promise.all(
      Array.from({ length: 24 }, (_, index) =>
        command(perUid, "admit", {
          requestId: `uid-${index}`,
          uid: "same-user",
          tokenBudget: 1,
          costBudgetMicrousd: 1,
        }),
      ),
    );
    expect(
      uidResponses.filter((response) => response.status === 200),
    ).toHaveLength(2);
    expect(
      uidResponses.filter((response) => response.status === 429),
    ).toHaveLength(22);

    const global = await createAdmission({
      MIMO_UID_IN_FLIGHT_LIMIT: "10",
      MIMO_GLOBAL_IN_FLIGHT_LIMIT: "3",
    });
    const globalResponses = await Promise.all(
      Array.from({ length: 24 }, (_, index) =>
        command(global, "admit", {
          requestId: `global-${index}`,
          uid: `user-${index}`,
          tokenBudget: 1,
          costBudgetMicrousd: 1,
        }),
      ),
    );
    expect(
      globalResponses.filter((response) => response.status === 200),
    ).toHaveLength(3);
    expect(
      globalResponses.filter((response) => response.status === 429),
    ).toHaveLength(21);
  });

  test("makes duplicate release idempotent and rolls budgets after the configured window", async () => {
    const instance = await createAdmission({
      MIMO_BUDGET_WINDOW_SECONDS: "1",
      MIMO_UID_TOKEN_BUDGET: "2",
    });
    const body = {
      requestId: "duplicate",
      uid: "user",
      tokenBudget: 2,
      costBudgetMicrousd: 1,
    };
    expect((await command(instance, "admit", body)).status).toBe(200);
    expect((await command(instance, "admit", body)).status).toBe(200);
    expect(
      (await command(instance, "release", { requestId: "duplicate" })).status,
    ).toBe(200);
    expect(
      (await command(instance, "release", { requestId: "duplicate" })).status,
    ).toBe(200);
    expect((await command(instance, "admit", body)).status).toBe(429);
    await Bun.sleep(1100);
    expect((await command(instance, "admit", body)).status).toBe(200);
  });

  test("settles atomically to actual overrun and blocks later dense traffic", async () => {
    const instance = await createAdmission({
      MIMO_UID_IN_FLIGHT_LIMIT: "100",
      MIMO_GLOBAL_IN_FLIGHT_LIMIT: "100",
      MIMO_UID_TOKEN_BUDGET: "12",
      MIMO_GLOBAL_TOKEN_BUDGET: "12",
      MIMO_UID_COST_BUDGET_MICROUSD: "12",
      MIMO_GLOBAL_COST_BUDGET_MICROUSD: "12",
    });
    expect(
      (
        await command(instance, "admit", {
          requestId: "overrun",
          uid: "user",
          tokenBudget: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await command(instance, "settle", {
          requestId: "overrun",
          tokenBudget: 12,
          costBudgetMicrousd: 12,
        })
      ).status,
    ).toBe(200);
    const responses = await Promise.all(
      Array.from({ length: 12 }, (_, index) =>
        command(instance, "admit", {
          requestId: `dense-${index}`,
          uid: "user",
          tokenBudget: 1,
          costBudgetMicrousd: 1,
        }),
      ),
    );
    expect(responses.every((response) => response.status === 429)).toBeTrue();
  });
});
