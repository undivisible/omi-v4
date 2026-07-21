import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import desktopAuth, { bindDesktopSession } from "../src/desktop-auth";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const migrate = async (path: string) => {
  const sql = (await Bun.file(path).text()).replace(
    "PRAGMA foreign_keys = ON;",
    "",
  );
  for (const statement of sql.split(";").map((item) => item.trim())) {
    if (statement) await database.prepare(statement).run();
  }
};

const pem = (bytes: ArrayBuffer) => {
  const base64 =
    Buffer.from(bytes)
      .toString("base64")
      .match(/.{1,64}/g)
      ?.join("\n") ?? "";
  return `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----`;
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  await migrate("migrations/0001_initial.sql");
  await migrate("migrations/0006_desktop_auth.sql");
});

afterAll(() => miniflare.dispose());

describe("desktop browser auth", () => {
  test("binds the verifier and returns one custom token", async () => {
    const verifier = "v".repeat(43);
    const sessionId = "s".repeat(43);
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(verifier),
    );
    const challenge = Buffer.from(digest).toString("base64url");
    const confirmationCode = "123456";
    const confirmationDigest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(confirmationCode),
    );
    const confirmationChallenge =
      Buffer.from(confirmationDigest).toString("base64url");
    const app = new Hono<AppEnv>();
    app.route("/", desktopAuth);
    const started = await app.request(
      "/start",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ sessionId, challenge, confirmationChallenge }),
      },
      {
        DB: database,
        FIREBASE_PROJECT_ID: "test",
        APP_URL: "https://app.example.test",
      },
    );
    expect(started.status).toBe(201);
    expect((await started.json()) as unknown).toMatchObject({
      browserUrl: `https://app.example.test/?desktop_auth=${sessionId}`,
    });

    const now = Date.now();
    await database
      .prepare(
        "INSERT INTO users (uid, created_at, updated_at) VALUES ('user-1', ?1, ?1)",
      )
      .bind(now)
      .run();
    await database
      .prepare("UPDATE desktop_auth_sessions SET uid = 'user-1' WHERE id = ?1")
      .bind(sessionId)
      .run();
    const keys = (await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const privateKey = pem(
      await crypto.subtle.exportKey("pkcs8", keys.privateKey),
    );
    const environment = {
      DB: database,
      FIREBASE_PROJECT_ID: "test",
      APP_URL: "https://app.example.test",
      FIREBASE_SERVICE_ACCOUNT_EMAIL: "firebase-adminsdk@example.test",
      FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY: privateKey,
    };
    const exchange = () =>
      app.request(
        "/exchange",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ sessionId, verifier }),
        },
        environment,
      );
    const completed = await exchange();
    expect(completed.status).toBe(200);
    const token = ((await completed.json()) as { customToken: string })
      .customToken;
    expect(token.split(".")).toHaveLength(3);
    expect((await exchange()).status).toBe(410);
  });

  test("fails closed without the browser origin", async () => {
    const app = new Hono<AppEnv>();
    app.route("/", desktopAuth);
    const response = await app.request(
      "/start",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          sessionId: "a".repeat(43),
          challenge: "b".repeat(43),
          confirmationChallenge: "c".repeat(43),
        }),
      },
      { DB: database, FIREBASE_PROJECT_ID: "test" },
    );
    expect(response.status).toBe(503);
  });

  test("rejects a forwarded browser session without the desktop code", async () => {
    const sessionId = "z".repeat(43);
    const confirmationCode = "654321";
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(confirmationCode),
    );
    await database
      .prepare(
        "INSERT INTO desktop_auth_sessions (id, verifier_challenge, confirmation_challenge, client_ip, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      )
      .bind(
        sessionId,
        "v".repeat(43),
        Buffer.from(digest).toString("base64url"),
        "test",
        Date.now(),
        Date.now() + 60_000,
      )
      .run();
    expect(
      await bindDesktopSession(database, sessionId, "attacker", "000000"),
    ).toBe(false);
    await database
      .prepare(
        "INSERT INTO users (uid, created_at, updated_at) VALUES ('user-2', ?1, ?1)",
      )
      .bind(Date.now())
      .run();
    expect(
      await bindDesktopSession(database, sessionId, "user-2", confirmationCode),
    ).toBe(true);
  });

  test("atomically locks a session after five wrong confirmation codes", async () => {
    const sessionId = "l".repeat(43);
    const confirmationCode = "246810";
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(confirmationCode),
    );
    await database
      .prepare(
        "INSERT INTO desktop_auth_sessions (id, verifier_challenge, confirmation_challenge, client_ip, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      )
      .bind(
        sessionId,
        "v".repeat(43),
        Buffer.from(digest).toString("base64url"),
        "test",
        Date.now(),
        Date.now() + 60_000,
      )
      .run();
    await database
      .prepare(
        "INSERT INTO users (uid, created_at, updated_at) VALUES ('user-3', ?1, ?1)",
      )
      .bind(Date.now())
      .run();

    for (let attempt = 0; attempt < 5; attempt += 1) {
      expect(
        await bindDesktopSession(database, sessionId, "user-3", "000000"),
      ).toBe(false);
    }
    expect(
      await bindDesktopSession(database, sessionId, "user-3", confirmationCode),
    ).toBe(false);
    const row = await database
      .prepare(
        "SELECT confirmation_attempts, confirmation_locked_at, uid FROM desktop_auth_sessions WHERE id = ?1",
      )
      .bind(sessionId)
      .first<{
        confirmation_attempts: number;
        confirmation_locked_at: number | null;
        uid: string | null;
      }>();
    expect(row?.confirmation_attempts).toBe(5);
    expect(row?.confirmation_locked_at).toBeNumber();
    expect(row?.uid).toBeNull();
  });
});
