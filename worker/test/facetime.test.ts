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

const bindings = () =>
  ({
    BLOOIO_API_KEY: "blooio-secret",
    RATE_LIMITER: allowingRateLimiter,
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

const ok = () =>
  Response.json({
    success: true,
    link: "https://facetime.apple.com/join#v=1&p=abc",
    handle: "+15551234567",
  });

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
      bindings(),
      "alpha",
      "+15551234567",
      "token-abcdefgh",
      fetcher,
    );
    expect(outcome).toEqual({
      kind: "ok",
      link: "https://facetime.apple.com/join#v=1&p=abc",
      handle: "+15551234567",
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://api.blooio.com/v2/api/facetime/calls");
    expect(calls[0].init.method).toBe("POST");
    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer blooio-secret");
    expect(headers["content-type"]).toBe("application/json");
    expect(headers["idempotency-key"]).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.parse(String(calls[0].init.body))).toEqual({
      handle: "+15551234567",
    });
  });

  test("derives a stable idempotency key per uid and token", async () => {
    const first = recorder(ok);
    const second = recorder(ok);
    const third = recorder(ok);
    await startFaceTimeCall(
      bindings(),
      "alpha",
      "+15551234567",
      "token-abcdefgh",
      first.fetcher,
    );
    await startFaceTimeCall(
      bindings(),
      "alpha",
      "+15551234567",
      "token-abcdefgh",
      second.fetcher,
    );
    await startFaceTimeCall(
      bindings(),
      "beta",
      "+15551234567",
      "token-abcdefgh",
      third.fetcher,
    );
    const keyOf = (capture: Capture) =>
      (capture.init.headers as Record<string, string>)["idempotency-key"];
    expect(keyOf(first.calls[0])).toBe(keyOf(second.calls[0]));
    expect(keyOf(first.calls[0])).not.toBe(keyOf(third.calls[0]));
  });

  test("reports the disabled upstream distinctly from a failure", async () => {
    const { fetcher } = recorder(
      () => new Response("Coming Soon", { status: 501 }),
    );
    expect(
      await startFaceTimeCall(
        bindings(),
        "alpha",
        "+15551234567",
        "token",
        fetcher,
      ),
    ).toEqual({ kind: "unavailable" });
  });

  test("maps upstream rejections, faults and unconfigured secrets", async () => {
    const rejected = recorder(() => new Response(null, { status: 422 }));
    expect(
      await startFaceTimeCall(
        bindings(),
        "alpha",
        "person@example.com",
        "token",
        rejected.fetcher,
      ),
    ).toEqual({ kind: "rejected", status: 422 });
    const broken = recorder(() => new Response(null, { status: 500 }));
    expect(
      await startFaceTimeCall(
        bindings(),
        "alpha",
        "person@example.com",
        "token",
        broken.fetcher,
      ),
    ).toEqual({ kind: "failed" });
    const lying = recorder(() => Response.json({ success: false }));
    expect(
      await startFaceTimeCall(
        bindings(),
        "alpha",
        "person@example.com",
        "token",
        lying.fetcher,
      ),
    ).toEqual({ kind: "failed" });
    const unset = recorder(ok);
    expect(
      await startFaceTimeCall(
        {} as AppEnv["Bindings"],
        "alpha",
        "person@example.com",
        "token",
        unset.fetcher,
      ),
    ).toEqual({ kind: "unconfigured" });
    expect(unset.calls).toHaveLength(0);
  });

  test("treats a network fault as a failure rather than throwing", async () => {
    const fetcher = (async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;
    expect(
      await startFaceTimeCall(
        bindings(),
        "alpha",
        "+15551234567",
        "token",
        fetcher,
      ),
    ).toEqual({ kind: "failed" });
  });
});

describe("FaceTime operation", () => {
  test("returns the call link on success", async () => {
    const { fetcher } = recorder(ok);
    expect(
      await startFaceTimeOperation(
        bindings(),
        "alpha",
        { handle: "+15551234567" },
        fetcher,
      ),
    ).toEqual({
      status: 201,
      body: {
        call: {
          handle: "+15551234567",
          link: "https://facetime.apple.com/join#v=1&p=abc",
        },
      },
    });
  });

  test("rejects an invalid handle without contacting the provider", async () => {
    const { calls, fetcher } = recorder(ok);
    for (const handle of ["not-a-handle", "5551234567", ""]) {
      expect(
        await startFaceTimeOperation(bindings(), "alpha", { handle }, fetcher),
      ).toEqual({ status: 400, body: { error: "Invalid FaceTime handle" } });
    }
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

  test("surfaces the disabled upstream as a named, non-retryable error", async () => {
    const { fetcher } = recorder(
      () => new Response("Coming Soon", { status: 501 }),
    );
    expect(
      await startFaceTimeOperation(
        bindings(),
        "alpha",
        { handle: "person@example.com" },
        fetcher,
      ),
    ).toEqual({
      status: 503,
      body: {
        error: "FaceTime calling is not yet available from Blooio",
        code: "facetime_unavailable",
      },
    });
  });

  test("distinguishes a provider rejection from a provider fault", async () => {
    const rejected = recorder(() => new Response(null, { status: 400 }));
    expect(
      (
        await startFaceTimeOperation(
          bindings(),
          "alpha",
          { handle: "person@example.com" },
          rejected.fetcher,
        )
      ).status,
    ).toBe(400);
    const broken = recorder(() => new Response(null, { status: 503 }));
    expect(
      (
        await startFaceTimeOperation(
          bindings(),
          "alpha",
          { handle: "person@example.com" },
          broken.fetcher,
        )
      ).status,
    ).toBe(502);
  });
});
