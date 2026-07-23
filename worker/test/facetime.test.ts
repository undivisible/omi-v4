import { describe, expect, test } from "bun:test";
import { normalizeHandle, startFaceTimeCall } from "../src/facetime";
import { startFaceTimeOperation } from "../src/public-api";
import type { AppEnv } from "../src/types";

const allowingRateLimiter = {
  getByName: () => ({
    fetch: async (url: string | URL) =>
      new URL(String(url)).pathname === "/consume"
        ? Response.json({ allowed: true, retryAfter: 0 })
        : new Response(null, { status: 404 }),
  }),
} as unknown as DurableObjectNamespace;

const admittingAdmission = {
  getByName: () => ({
    fetch: async () =>
      Response.json({
        admitted: true,
        retryAfter: 0,
        acquisitionToken: "0123456789abcdef0123456789abcdef",
      }),
  }),
} as unknown as DurableObjectNamespace;

const startingBridge = {
  getByName: () => ({ fetch: async () => Response.json({ started: true }) }),
} as unknown as DurableObjectNamespace;

const database = {
  prepare: () => ({
    bind: () => ({ run: async () => ({ meta: { changes: 1 } }) }),
  }),
} as unknown as D1Database;

const providerBindings = () =>
  ({
    SENDBLUE_API_KEY_ID: "key-id",
    SENDBLUE_API_KEY_SECRET: "key-secret",
    SENDBLUE_FACETIME_NUMBER: "+18885550199",
  }) as unknown as AppEnv["Bindings"];

const bindings = () =>
  ({
    ...providerBindings(),
    GEMINI_API_KEY: "gemini-secret",
    GEMINI_LIVE_MODEL: "gemini-live",
    APP_URL: "https://app.example",
    DB: database,
    RATE_LIMITER: allowingRateLimiter,
    STT_ADMISSION: admittingAdmission,
    FACETIME_BRIDGE: startingBridge,
  }) as unknown as AppEnv["Bindings"];

type Capture = { url: string; init: RequestInit };

const recorder = (response: () => Response) => {
  const calls: Capture[] = [];
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return response();
  }) as unknown as typeof fetch;
  return { calls, fetcher };
};

const agora = {
  appId: "a1b2c3d4e5f6789012345678abcdef90",
  channelName: "ft_call_9f8e7d6c5b4a3210",
  token: "007eJxTYDhw4MCBAwcOHDhw4MCB",
  uid: 0,
};

const ok = () =>
  Response.json({ status: "OK", message: "Call started", agora });

describe("FaceTime handle validation", () => {
  test("accepts E.164 phone numbers", () => {
    expect(normalizeHandle("+15551234567")).toBe("+15551234567");
    expect(normalizeHandle("  +442071234567 ")).toBe("+442071234567");
  });

  test("accepts and lowercases email addresses", () => {
    expect(normalizeHandle("Person@Example.com")).toBe("person@example.com");
  });

  test("rejects anything that is neither", () => {
    for (const handle of [
      "",
      "5551234567",
      "+0555123",
      "+1234",
      "+1555123456789012",
      "person@example",
      "person @example.com",
      "tel:+15551234567",
      "'; DROP TABLE users; --",
      42,
      null,
      undefined,
      `+1${"5".repeat(300)}`,
    ])
      expect(normalizeHandle(handle)).toBeNull();
  });
});

describe("FaceTime upstream request", () => {
  test("sends the documented shape to the documented endpoint", async () => {
    const { calls, fetcher } = recorder(ok);
    const outcome = await startFaceTimeCall(
      providerBindings(),
      "+15551234567",
      fetcher,
    );
    expect(outcome).toEqual({ kind: "ok", handle: "+15551234567", agora });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://api.sendblue.com/facetime/start-call");
    expect(calls[0].init.method).toBe("POST");
    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["sb-api-key-id"]).toBe("key-id");
    expect(headers["sb-api-secret-key"]).toBe("key-secret");
    expect(headers["content-type"]).toBe("application/json");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({
      phoneNumber: "+15551234567",
      fromNumber: "+18885550199",
    });
  });

  test("never puts the API secret in the request body", async () => {
    const { calls, fetcher } = recorder(ok);
    await startFaceTimeCall(providerBindings(), "+15551234567", fetcher);
    expect(String(calls[0].init.body)).not.toContain("key-secret");
  });

  test("refuses an email handle without contacting the provider", async () => {
    const { calls, fetcher } = recorder(ok);
    expect(
      await startFaceTimeCall(
        providerBindings(),
        "person@example.com",
        fetcher,
      ),
    ).toEqual({ kind: "rejected", status: 400 });
    expect(calls).toHaveLength(0);
  });

  test("reports an unconfigured provider without contacting it", async () => {
    const { calls, fetcher } = recorder(ok);
    expect(
      await startFaceTimeCall(
        {} as AppEnv["Bindings"],
        "+15551234567",
        fetcher,
      ),
    ).toEqual({ kind: "unconfigured" });
    expect(calls).toHaveLength(0);
  });

  test("maps a missing FaceTime line to the graceful unavailable state", async () => {
    for (const status of [402, 403, 404, 501]) {
      const { fetcher } = recorder(() => new Response(null, { status }));
      expect(
        await startFaceTimeCall(providerBindings(), "+15551234567", fetcher),
      ).toEqual({ kind: "unavailable" });
    }
  });

  test("maps bad credentials to unconfigured", async () => {
    const { fetcher } = recorder(() => new Response(null, { status: 401 }));
    expect(
      await startFaceTimeCall(providerBindings(), "+15551234567", fetcher),
    ).toEqual({ kind: "unconfigured" });
  });

  test("maps a rejected handle to a client error", async () => {
    for (const status of [400, 422]) {
      const { fetcher } = recorder(() => new Response(null, { status }));
      expect(
        await startFaceTimeCall(providerBindings(), "+15551234567", fetcher),
      ).toEqual({ kind: "rejected", status });
    }
  });

  test("fails on a malformed or oversized credential set", async () => {
    for (const body of [
      { status: "ERROR" },
      { status: "OK" },
      { status: "OK", agora: { appId: "a", channelName: "c" } },
      { status: "OK", agora: { ...agora, token: "x".repeat(5_000) } },
      { status: "OK", agora: { ...agora, uid: -1 } },
    ]) {
      const { fetcher } = recorder(() => Response.json(body));
      expect(
        await startFaceTimeCall(providerBindings(), "+15551234567", fetcher),
      ).toEqual({ kind: "failed" });
    }
  });

  test("treats a network fault as a failure rather than throwing", async () => {
    const fetcher = (async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;
    expect(
      await startFaceTimeCall(providerBindings(), "+15551234567", fetcher),
    ).toEqual({ kind: "failed" });
  });
});

describe("FaceTime operation", () => {
  test("returns the placed call with a session link", async () => {
    const { fetcher } = recorder(ok);
    const result = await startFaceTimeOperation(
      bindings(),
      "alpha",
      { handle: "+15551234567" },
      fetcher,
    );
    expect(result.status).toBe(201);
    const call = (result.body as { call: Record<string, string> }).call;
    expect(call.handle).toBe("+15551234567");
    expect(call.sessionId).toMatch(/^[a-f0-9]{32}$/);
    expect(call.link).toBe(
      `https://app.example/facetime/sessions/${call.sessionId}`,
    );
  });

  test("rejects an invalid handle without contacting the provider", async () => {
    const { calls, fetcher } = recorder(ok);
    for (const handle of ["not-a-handle", "5551234567", ""])
      expect(
        await startFaceTimeOperation(bindings(), "alpha", { handle }, fetcher),
      ).toEqual({ status: 400, body: { error: "Invalid FaceTime handle" } });
    expect(
      await startFaceTimeOperation(
        bindings(),
        "alpha",
        { handle: "+15551234567", idempotencyKey: "short" },
        fetcher,
      ),
    ).toEqual({ status: 400, body: { error: "Invalid FaceTime handle" } });
    expect(calls).toHaveLength(0);
  });

  test("surfaces the unprovisioned state as a named, non-retryable error", async () => {
    const { fetcher } = recorder(() => new Response(null, { status: 403 }));
    expect(
      await startFaceTimeOperation(
        bindings(),
        "alpha",
        { handle: "+15551234567" },
        fetcher,
      ),
    ).toEqual({
      status: 503,
      body: {
        error: "FaceTime calling is not provisioned on this account",
        code: "facetime_unavailable",
      },
    });
  });

  test("never rings the phone when the bridge has no realtime key", async () => {
    const { calls, fetcher } = recorder(ok);
    const environment = bindings();
    environment.GEMINI_API_KEY = undefined;
    const result = await startFaceTimeOperation(
      environment,
      "alpha",
      { handle: "+15551234567" },
      fetcher,
    );
    expect(result.status).toBe(503);
    expect((result.body as { code?: string }).code).toBe(
      "facetime_unavailable",
    );
    expect(calls).toHaveLength(0);
  });

  test("distinguishes a provider rejection from a provider fault", async () => {
    const rejected = recorder(() => new Response(null, { status: 400 }));
    expect(
      (
        await startFaceTimeOperation(
          bindings(),
          "alpha",
          { handle: "+15551234567" },
          rejected.fetcher,
        )
      ).status,
    ).toBe(400);
    const broken = recorder(() => new Response(null, { status: 500 }));
    expect(
      (
        await startFaceTimeOperation(
          bindings(),
          "alpha",
          { handle: "+15551234567" },
          broken.fetcher,
        )
      ).status,
    ).toBe(502);
  });

  test("derives the same session id from the same idempotency key", async () => {
    const { fetcher } = recorder(ok);
    const sessionOf = async (uid: string, key: string) => {
      const result = await startFaceTimeOperation(
        bindings(),
        uid,
        { handle: "+15551234567", idempotencyKey: key },
        fetcher,
      );
      return (result.body.call as { sessionId: string }).sessionId;
    };
    expect(await sessionOf("alpha", "retry-key-1")).toBe(
      await sessionOf("alpha", "retry-key-1"),
    );
    expect(await sessionOf("alpha", "retry-key-1")).not.toBe(
      await sessionOf("beta", "retry-key-1"),
    );
  });
});
