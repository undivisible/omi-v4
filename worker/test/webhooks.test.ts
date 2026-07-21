import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";
import { app } from "../src/index";

const secret = "whsec_test";
const encoder = new TextEncoder();
const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const sign = async (timestamp: number, body: string) => {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(`${timestamp}.${body}`),
    ),
  );
  const signature = Array.from(digest, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `t=${timestamp},v1=${signature}`;
};

const request = async (body: string, signature: string, eventId: string) =>
  app.request(
    "/v1/webhooks/blooio",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-blooio-signature": signature,
        "x-webhook-id": eventId,
      },
      body,
    },
    {
      DB: database,
      FIREBASE_PROJECT_ID: "test",
      BLOOIO_WEBHOOK_SIGNING_SECRET: secret,
    },
  );

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  const sql = (await Bun.file("migrations/0001_initial.sql").text()).replace(
    "PRAGMA foreign_keys = ON;",
    "",
  );
  for (const statement of sql.split(";").map((value) => value.trim())) {
    if (statement) await database.prepare(statement).run();
  }
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("Blooio webhook signatures", () => {
  test("accepts a valid signature and keeps event idempotency", async () => {
    const body = JSON.stringify({ event: "message.sent", message_id: "one" });
    const timestamp = Math.floor(Date.now() / 1_000);
    const signature = await sign(timestamp, body);
    const first = await request(body, signature, "event-valid");
    expect(first.status).toBe(200);
    expect((await first.json()) as unknown).toEqual({
      accepted: true,
      duplicate: false,
    });
    const duplicate = await request(body, signature, "event-valid");
    expect((await duplicate.json()) as unknown).toEqual({
      accepted: true,
      duplicate: true,
    });
  });

  test("rejects a malformed signature", async () => {
    const response = await request("{}", "t=nope,v1=bad", "event-invalid");
    expect(response.status).toBe(401);
  });

  test("rejects stale and future timestamps", async () => {
    const body = "{}";
    const now = Math.floor(Date.now() / 1_000);
    const stale = await request(
      body,
      await sign(now - 301, body),
      "event-stale",
    );
    expect(stale.status).toBe(401);
    const future = await request(
      body,
      await sign(now + 301, body),
      "event-future",
    );
    expect(future.status).toBe(401);
  });

  test("rejects a tampered body", async () => {
    const timestamp = Math.floor(Date.now() / 1_000);
    const signature = await sign(timestamp, '{"message_id":"original"}');
    const response = await request(
      '{"message_id":"tampered"}',
      signature,
      "event-tampered",
    );
    expect(response.status).toBe(401);
  });
});
