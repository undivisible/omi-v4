import { describe, expect, test } from "bun:test";
import {
  createSentry,
  pingHeartbeat,
  shipTailEvents,
} from "../src/observability";
import type { Bindings } from "../src/types";

const noopContext = { waitUntil: () => undefined };

describe("observability is DSN/token-gated", () => {
  test("createSentry returns null when no DSN is set", () => {
    expect(createSentry({} as Bindings, noopContext)).toBeNull();
  });

  test("createSentry installs a client when a DSN is set", () => {
    const sentry = createSentry(
      {
        BETTERSTACK_SENTRY_DSN:
          "https://public@example.ingest.betterstack.com/1",
      } as Bindings,
      noopContext,
    );
    expect(sentry).not.toBeNull();
  });

  test("createSentry honors the plain SENTRY_DSN fallback", () => {
    const sentry = createSentry(
      {
        SENTRY_DSN: "https://public@example.ingest.betterstack.com/2",
      } as Bindings,
      noopContext,
    );
    expect(sentry).not.toBeNull();
  });

  test("pingHeartbeat is a no-op (no fetch) when the URL is unset", async () => {
    const original = globalThis.fetch;
    let called = false;
    globalThis.fetch = (async () => {
      called = true;
      return new Response(null);
    }) as typeof fetch;
    try {
      await pingHeartbeat({} as Bindings);
    } finally {
      globalThis.fetch = original;
    }
    expect(called).toBe(false);
  });

  test("shipTailEvents is a no-op unless both URL and token are set", async () => {
    const original = globalThis.fetch;
    let called = false;
    globalThis.fetch = (async () => {
      called = true;
      return new Response(null);
    }) as typeof fetch;
    try {
      await shipTailEvents(
        { BETTERSTACK_LOGS_URL: "https://logs" } as Bindings,
        {},
      );
    } finally {
      globalThis.fetch = original;
    }
    expect(called).toBe(false);
  });
});
