import { describe, expect, test } from "bun:test";
import { app } from "../src/index";

describe("public boundaries", () => {
  test("health is public", async () => {
    const response = await app.request("/health");
    expect(response.status).toBe(200);
    expect((await response.json()) as unknown).toEqual({
      service: "omi-v4-api",
      status: "ok",
    });
  });

  test("user routes require Firebase auth", async () => {
    const response = await app.request(
      "/v1/me",
      {},
      { FIREBASE_PROJECT_ID: "test" },
    );
    expect(response.status).toBe(401);
  });

  test("Telegram webhook fails closed without configuration", async () => {
    const response = await app.request(
      "/v1/webhooks/telegram",
      { method: "POST" },
      {},
    );
    expect(response.status).toBe(401);
  });

  test("Blooio webhook fails closed without configuration", async () => {
    const response = await app.request(
      "/v1/webhooks/blooio",
      { method: "POST" },
      {},
    );
    expect(response.status).toBe(401);
  });
});
