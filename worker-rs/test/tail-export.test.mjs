import { describe, expect, test } from "bun:test";
import { shipTailEvents } from "../tail-export.mjs";

describe("shipTailEvents", () => {
  test("does nothing until both Better Stack settings exist", async () => {
    let called = false;
    await shipTailEvents({ BETTERSTACK_LOGS_URL: "https://logs.example" }, [], async () => {
      called = true;
      return new Response();
    });
    expect(called).toBe(false);
  });

  test("ships the raw Tail batch with bearer authentication", async () => {
    let request;
    const events = [{ outcome: "ok" }];
    await shipTailEvents(
      {
        BETTERSTACK_LOGS_URL: "https://logs.example/ingest",
        BETTERSTACK_LOGS_TOKEN: "token",
      },
      events,
      async (url, init) => {
        request = { url, init };
        return new Response();
      },
    );
    expect(request).toEqual({
      url: "https://logs.example/ingest",
      init: {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer token",
        },
        body: JSON.stringify(events),
      },
    });
  });

  test("swallows exporter failures", async () => {
    await shipTailEvents(
      {
        BETTERSTACK_LOGS_URL: "https://logs.example/ingest",
        BETTERSTACK_LOGS_TOKEN: "token",
      },
      [],
      async () => Promise.reject(new Error("offline")),
    );
  });
});
