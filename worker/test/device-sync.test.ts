import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { Hono } from "hono";
import { Miniflare } from "miniflare";
import deviceSync, {
  mintDeviceToken,
  parseHomeUploadPreamble,
  parseStartSeq,
  deviceTokenPrefix,
  verifyDeviceToken,
} from "../src/device-sync";
import type { AppEnv } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

const allowingRateLimiter = {
  getByName: () => ({
    fetch: async (url: string | URL) =>
      new URL(String(url)).pathname === "/consume"
        ? Response.json({ allowed: true, retryAfter: 0 })
        : new Response(null, { status: 404 }),
  }),
} as unknown as DurableObjectNamespace;

let database: D1Database;
const storedAudio = new Map<string, Uint8Array>();

const bindings = () =>
  ({
    DB: database,
    DEVICE_AUDIO: {
      put: async (key: string, value: Uint8Array) => {
        storedAudio.set(key, value);
        return null;
      },
      delete: async (key: string) => storedAudio.delete(key),
    },
    RATE_LIMITER: allowingRateLimiter,
    FIREBASE_PROJECT_ID: "test",
    APP_URL: "https://example.test",
  }) as unknown as AppEnv["Bindings"];

const register = (uid: string, body: Record<string, unknown>) => {
  const app = new Hono<AppEnv>();
  app.use("*", async (context, next) => {
    context.set("auth", { uid, email: `${uid}@example.test` });
    await next();
  });
  app.route("/api/v1/devices", deviceSync);
  return app.request(
    "/api/v1/devices/register",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    bindings(),
  );
};

const upload = (
  deviceId: string,
  token: string | null,
  body: Record<string, unknown> | string,
  init?: { contentLength?: number },
) => {
  const app = new Hono<AppEnv>();
  app.route("/api/v1/devices", deviceSync);
  const headers: Record<string, string> = {
    "content-type": "application/json",
  };
  if (token) headers.authorization = `Bearer ${token}`;
  if (init?.contentLength !== undefined)
    headers["content-length"] = String(init.contentLength);
  return app.request(
    `/api/v1/devices/${deviceId}/audio`,
    {
      method: "POST",
      headers,
      body: typeof body === "string" ? body : JSON.stringify(body),
    },
    bindings(),
  );
};

const binaryUpload = (
  deviceId: string,
  token: string,
  startSeq: bigint,
  packets: Uint8Array[],
) => {
  const app = new Hono<AppEnv>();
  app.route("/api/v1/devices", deviceSync);
  const idBytes = new TextEncoder().encode(deviceId);
  const packetBytes = packets[0]?.byteLength ?? 0;
  const body = new Uint8Array(
    3 + idBytes.byteLength + 14 + packetBytes * packets.length,
  );
  body.set([0xc1, 1, idBytes.byteLength], 0);
  body.set(idBytes, 3);
  const base = 3 + idBytes.byteLength;
  const view = new DataView(body.buffer);
  view.setBigUint64(base, startSeq);
  view.setUint32(base + 8, packets.length);
  view.setUint16(base + 12, packetBytes);
  packets.forEach((packet, index) =>
    body.set(packet, base + 14 + index * packetBytes),
  );
  return app.request(
    `/api/v1/devices/${deviceId}/audio`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/octet-stream",
      },
      body,
    },
    bindings(),
  );
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of readdirSync("migrations").sort()) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    const code = sql
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("--"))
      .join("\n");
    for (const statement of code.split(";").map((value) => value.trim())) {
      if (statement) await database.prepare(statement).run();
    }
  }
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('alpha', 'alpha@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(() => miniflare.dispose());

describe("device-sync unit", () => {
  test("mints omi_dev_ tokens", async () => {
    const minted = await mintDeviceToken();
    expect(minted.token.startsWith(deviceTokenPrefix)).toBe(true);
    expect(minted.hash).toHaveLength(64);
    expect(minted.prefix).toHaveLength(8);
  });

  test("parseStartSeq accepts number and decimal string", () => {
    expect(parseStartSeq(42)).toBe("42");
    expect(parseStartSeq("9007199254740993")).toBe("9007199254740993");
    expect(parseStartSeq(-1)).toBeNull();
    expect(parseStartSeq("1.5")).toBeNull();
  });

  test("parses home upload preamble with string startSeq", () => {
    const deviceId = "dev-1";
    const idBytes = new TextEncoder().encode(deviceId);
    const buf = new Uint8Array(3 + idBytes.length + 14);
    buf[0] = 0xc1;
    buf[1] = 1;
    buf[2] = idBytes.length;
    buf.set(idBytes, 3);
    const view = new DataView(buf.buffer);
    const base = 3 + idBytes.length;
    view.setBigUint64(base, 42n);
    view.setUint32(base + 8, 7);
    view.setUint16(base + 12, 444);
    const parsed = parseHomeUploadPreamble(buf);
    expect(parsed).not.toBeNull();
    expect(parsed?.deviceId).toBe(deviceId);
    expect(parsed?.startSeq).toBe("42");
    expect(parsed?.packetCount).toBe(7);
    expect(parsed?.packetBytes).toBe(444);
  });
});

describe("device-sync register + upload", () => {
  test("register mints a token and rotates on re-register", async () => {
    const first = await register("alpha", {
      deviceUid: "pendant-1",
      name: "Kitchen",
    });
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as {
      deviceId: string;
      token: string;
      uploadHost: string;
      uploadPath: string;
    };
    expect(firstBody.token.startsWith(deviceTokenPrefix)).toBe(true);
    expect(firstBody.uploadHost).toBe("https://example.test");
    expect(firstBody.uploadPath).toBe(
      `/api/v1/devices/${firstBody.deviceId}/audio`,
    );

    const second = await register("alpha", { deviceUid: "pendant-1" });
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as {
      deviceId: string;
      token: string;
    };
    expect(secondBody.deviceId).toBe(firstBody.deviceId);
    expect(secondBody.token).not.toBe(firstBody.token);

    expect(
      await verifyDeviceToken(database, firstBody.token, Date.now()),
    ).toBeNull();
    expect(
      await verifyDeviceToken(database, secondBody.token, Date.now()),
    ).toEqual({
      uid: "alpha",
      deviceId: firstBody.deviceId,
      tokenId: expect.any(String),
    });
  });

  test("verifyDeviceToken rejects a revoked device", async () => {
    const created = await register("alpha", { deviceUid: "pendant-revoked" });
    const body = (await created.json()) as { deviceId: string; token: string };
    await database
      .prepare(`UPDATE devices SET revoked_at = ?1 WHERE id = ?2`)
      .bind(Date.now(), body.deviceId)
      .run();
    expect(
      await verifyDeviceToken(database, body.token, Date.now()),
    ).toBeNull();
  });

  test("upload persists audio without rateKey", async () => {
    const created = await register("alpha", { deviceUid: "pendant-upload" });
    const { deviceId, token } = (await created.json()) as {
      deviceId: string;
      token: string;
    };
    const response = await upload(deviceId, token, {
      startSeq: "100",
      packetCount: 2,
      audio: Buffer.from("abcd").toString("base64"),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.persisted).toBe(true);
    expect(body.accepted).toBe(true);
    expect(body.startSeq).toBe("100");
    expect(Object.keys(body)).not.toContain("rateKey");
    expect(storedAudio.size).toBeGreaterThan(0);
  });

  test("binary firmware upload validates framing and persists packets", async () => {
    const created = await register("alpha", { deviceUid: "pendant-binary" });
    const { deviceId, token } = (await created.json()) as {
      deviceId: string;
      token: string;
    };
    const response = await binaryUpload(deviceId, token, 9007199254740993n, [
      Uint8Array.of(1, 2, 3, 4),
      Uint8Array.of(5, 6, 7, 8),
    ]);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.persisted).toBe(true);
    expect(body.startSeq).toBe("9007199254740993");
    expect(body.byteCount).toBe(8);
    expect(
      [...storedAudio.values()].some((value) => value.byteLength === 8),
    ).toBe(true);
    const storedCount = storedAudio.size;
    const retry = await binaryUpload(deviceId, token, 9007199254740993n, [
      Uint8Array.of(1, 2, 3, 4),
      Uint8Array.of(5, 6, 7, 8),
    ]);
    expect(retry.status).toBe(200);
    expect(storedAudio.size).toBe(storedCount);
  });

  test("upload 401 without token and 403 on device mismatch", async () => {
    const created = await register("alpha", { deviceUid: "pendant-auth" });
    const { deviceId, token } = (await created.json()) as {
      deviceId: string;
      token: string;
    };
    const unauth = await upload(deviceId, null, {
      startSeq: 1,
      packetCount: 1,
      audio: "YQ==",
    });
    expect(unauth.status).toBe(401);

    const mismatch = await upload("other-device", token, {
      startSeq: 1,
      packetCount: 1,
      audio: "YQ==",
    });
    expect(mismatch.status).toBe(403);
  });

  test("upload 413 when content-length exceeds limit", async () => {
    const created = await register("alpha", { deviceUid: "pendant-large" });
    const { deviceId, token } = (await created.json()) as {
      deviceId: string;
      token: string;
    };
    const response = await upload(
      deviceId,
      token,
      { startSeq: 0, packetCount: 1, audio: "YQ==" },
      { contentLength: 5 * 1024 * 1024 },
    );
    expect(response.status).toBe(413);
  });
});
