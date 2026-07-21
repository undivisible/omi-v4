import { afterEach, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";

const instances: Miniflare[] = [];
const tokens = new Map<
  Miniflare,
  Map<string, { acquisitionToken: string; uid: string }>
>();
const responses: Response[] = [];

const dispatch = async (
  instance: Miniflare,
  path: "admit" | "claim" | "release",
  body: Record<string, unknown>,
) => {
  const response = await instance.dispatchFetch(
    `https://admission.test/${path}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  responses.push(response);
  return response;
};

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
      STT_CLAIM_DEADLINE_SECONDS: "60",
      ...vars,
    },
  });
  instances.push(instance);
  tokens.set(instance, new Map());
  return instance;
};

const admit = async (instance: Miniflare, body: Record<string, unknown>) => {
  const response = await dispatch(instance, "admit", body);
  if (response.ok) {
    const result = (await response.clone().json()) as {
      acquisitionToken?: string;
    };
    if (result.acquisitionToken)
      tokens.get(instance)?.set(String(body.sessionId), {
        acquisitionToken: result.acquisitionToken,
        uid: String(body.uid),
      });
  }
  return response;
};

const release = (
  instance: Miniflare,
  sessionId: string,
  uid: string,
  acquisitionToken = tokens.get(instance)?.get(sessionId)?.acquisitionToken,
) => dispatch(instance, "release", { sessionId, uid, acquisitionToken });

const claim = (
  instance: Miniflare,
  sessionId: string,
  uid: string,
  acquisitionToken = tokens.get(instance)?.get(sessionId)?.acquisitionToken,
) => dispatch(instance, "claim", { sessionId, uid, acquisitionToken });

afterEach(async () => {
  await Promise.all(
    instances.flatMap((instance) =>
      Array.from(tokens.get(instance)?.entries() ?? []).map(
        ([sessionId, { acquisitionToken, uid }]) =>
          release(instance, sessionId, uid, acquisitionToken),
      ),
    ),
  );
  await Promise.all(
    responses
      .splice(0)
      .map((response) =>
        response.bodyUsed ? Promise.resolve() : response.arrayBuffer(),
      ),
  );
  await Promise.all(instances.map((instance) => instance.dispose()));
  instances.length = 0;
  tokens.clear();
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

  test("releases in-flight capacity idempotently while retaining budget", async () => {
    const instance = await createAdmission({ STT_UID_IN_FLIGHT_LIMIT: "1" });
    const body = {
      sessionId: "released",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    };
    expect((await admit(instance, body)).status).toBe(200);
    expect((await release(instance, body.sessionId, "beta")).status).toBe(200);
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "still-blocked",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(429);
    const duplicateReleases = await Promise.all([
      release(instance, body.sessionId, body.uid),
      release(instance, body.sessionId, body.uid),
    ]);
    expect(duplicateReleases.map((response) => response.status)).toEqual([
      200, 200,
    ]);
    const reacquired = await admit(instance, body);
    expect(reacquired.status).toBe(200);
    expect(await reacquired.json()).toMatchObject({
      duplicate: true,
      reacquired: true,
    });
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "blocked-by-reacquired",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(429);
    expect((await release(instance, body.sessionId, body.uid)).status).toBe(
      200,
    );
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "next",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "over-budget",
          reservedSeconds: 900,
        })
      ).status,
    ).toBe(429);
  });

  test("releases an abandoned claim deadline but preserves a claimed session", async () => {
    const instance = await createAdmission({
      STT_UID_IN_FLIGHT_LIMIT: "1",
      STT_CLAIM_DEADLINE_SECONDS: "1",
    });
    const body = {
      sessionId: "abandoned",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    };
    expect((await admit(instance, body)).status).toBe(200);
    await Bun.sleep(1100);
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "after-alarm",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(200);
    expect((await claim(instance, "after-alarm", "alpha")).status).toBe(200);
    await Bun.sleep(1100);
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "still-blocked",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(429);
  }, 5000);

  test("rejects a late claim and ignores a delayed release from an old acquisition", async () => {
    const instance = await createAdmission({
      STT_UID_IN_FLIGHT_LIMIT: "1",
      STT_CLAIM_DEADLINE_SECONDS: "1",
    });
    const body = {
      sessionId: "generation",
      uid: "alpha",
      reservedSeconds: 900,
      costBudgetMicrousd: 75000,
    };
    const first = (await (await admit(instance, body)).json()) as {
      acquisitionToken: string;
    };
    await Bun.sleep(1100);
    const lateClaim = await claim(
      instance,
      body.sessionId,
      body.uid,
      first.acquisitionToken,
    );
    expect(await lateClaim.json()).toEqual({ claimed: false });
    const second = (await (await admit(instance, body)).json()) as {
      acquisitionToken: string;
      reacquired: boolean;
    };
    expect(second.reacquired).toBe(true);
    expect(second.acquisitionToken).not.toBe(first.acquisitionToken);
    await release(instance, body.sessionId, body.uid, first.acquisitionToken);
    expect(
      (
        await admit(instance, {
          ...body,
          sessionId: "still-blocked-by-new-generation",
          reservedSeconds: 1,
          costBudgetMicrousd: 1,
        })
      ).status,
    ).toBe(429);
  }, 5000);
});
