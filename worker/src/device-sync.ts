import { Hono, type MiddlewareHandler } from "hono";
import { requireAuth } from "./auth";
import { digest, timingSafeEqual } from "./api-keys";
import { consumeRateLimit } from "./rate-limit";
import type { AppEnv } from "./types";

const deviceSync = new Hono<AppEnv>();

export const deviceTokenPrefix = "omi_dev_";
const tokenPattern = /^omi_dev_([0-9a-f]{8})_([A-Za-z0-9_-]{43})$/;
const maximumUploadsPerMinute = 30;
const maximumUploadBytes = 4 * 1024 * 1024;
const maximumRegistersPerHour = 10;

const hex = (bytes: Uint8Array) =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

const base64url = (bytes: Uint8Array) => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

export const mintDeviceToken = async (): Promise<{
  token: string;
  prefix: string;
  hash: string;
}> => {
  const prefix = hex(crypto.getRandomValues(new Uint8Array(4)));
  const secret = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const token = `${deviceTokenPrefix}${prefix}_${secret}`;
  return { token, prefix, hash: await digest(token) };
};

/** Parse a ring startSeq that may arrive as number or decimal string (u64-safe). */
export const parseStartSeq = (value: unknown): string | null => {
  if (typeof value === "bigint") {
    return value >= 0n ? value.toString() : null;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value) || !Number.isInteger(value) || value < 0)
      return null;
    return String(value);
  }
  if (typeof value === "string" && /^\d+$/.test(value)) return value;
  return null;
};

type DeviceTokenRow = {
  id: string;
  device_id: string;
  uid: string;
  token_hash: string;
};

export const verifyDeviceToken = async (
  database: D1Database,
  token: string,
  now: number,
): Promise<{ uid: string; deviceId: string; tokenId: string } | null> => {
  const parsed = tokenPattern.exec(token);
  if (!parsed) return null;
  const candidates = await database
    .prepare(
      `SELECT t.id, t.device_id, t.uid, t.token_hash FROM device_tokens t
       INNER JOIN devices d ON d.id = t.device_id
       WHERE t.prefix = ?1 AND t.revoked_at IS NULL AND d.revoked_at IS NULL`,
    )
    .bind(parsed[1])
    .all<DeviceTokenRow>();
  const presented = await digest(token);
  let matched: DeviceTokenRow | null = null;
  for (const row of candidates.results ?? [])
    if (timingSafeEqual(presented, String(row.token_hash))) matched = row;
  if (!matched) return null;
  await database
    .prepare(`UPDATE device_tokens SET last_used_at = ?1 WHERE id = ?2`)
    .bind(now, matched.id)
    .run()
    .catch(() => undefined);
  await database
    .prepare(`UPDATE devices SET last_seen_at = ?1 WHERE id = ?2`)
    .bind(now, matched.device_id)
    .run()
    .catch(() => undefined);
  return {
    uid: String(matched.uid),
    deviceId: String(matched.device_id),
    tokenId: String(matched.id),
  };
};

export const requireDeviceToken: MiddlewareHandler<AppEnv> = async (
  context,
  next,
) => {
  const authorization = context.req.header("authorization") ?? "";
  const bearer = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
  const token = bearer || (context.req.header("x-device-token") ?? "").trim();
  if (!token.startsWith(deviceTokenPrefix))
    return context.json({ error: "Device token required" }, 401);
  let verified: Awaited<ReturnType<typeof verifyDeviceToken>>;
  try {
    verified = await verifyDeviceToken(context.env.DB, token, Date.now());
  } catch {
    return context.json({ error: "Authentication unavailable" }, 503);
  }
  if (!verified) return context.json({ error: "Authentication failed" }, 401);
  context.set("auth", { uid: verified.uid, email: null });
  context.set("deviceId", verified.deviceId);
  await next();
};

const object = async (request: Request) => {
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
};

/** Firebase auth, or an already-injected `auth` (test harnesses). */
const requireRegisterAuth: MiddlewareHandler<AppEnv> = async (
  context,
  next,
) => {
  try {
    if (context.get("auth")?.uid) {
      await next();
      return;
    }
  } catch {
    /* auth unset */
  }
  return requireAuth(context, next);
};

// Phone-side pairing: Firebase (or API key) authenticated user registers a
// pendant and receives a long-lived device token to provision over BLE.
deviceSync.post("/register", requireRegisterAuth, async (context) => {
  const body = await object(context.req.raw);
  if (!body) return context.json({ error: "Invalid register body" }, 400);
  const deviceUid =
    typeof body.deviceUid === "string" ? body.deviceUid.trim() : "";
  const name = typeof body.name === "string" ? body.name.trim() : null;
  if (!deviceUid || deviceUid.length > 128)
    return context.json({ error: "Invalid deviceUid" }, 400);

  const uid = context.get("auth").uid;
  const limit = await consumeRateLimit(
    context.env,
    `device-register:${uid}`,
    maximumRegistersPerHour,
    60 * 60_000,
  );
  if (!limit.allowed)
    return context.json({ error: "Too many requests" }, 429, {
      "retry-after": String(limit.retryAfter),
    });

  const now = Date.now();
  const existing = await context.env.DB.prepare(
    `SELECT id FROM devices WHERE uid = ?1 AND device_uid = ?2 AND revoked_at IS NULL`,
  )
    .bind(uid, deviceUid)
    .first<{ id: string }>();

  const deviceId = existing?.id ?? crypto.randomUUID();
  if (!existing) {
    await context.env.DB.prepare(
      `INSERT INTO devices (id, uid, device_uid, name, created_at, last_seen_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?5)`,
    )
      .bind(deviceId, uid, deviceUid, name, now)
      .run();
  } else if (name) {
    await context.env.DB.prepare(
      `UPDATE devices SET name = ?1, last_seen_at = ?2 WHERE id = ?3`,
    )
      .bind(name, now, deviceId)
      .run();
  }

  await context.env.DB.prepare(
    `UPDATE device_tokens SET revoked_at = ?1
     WHERE device_id = ?2 AND revoked_at IS NULL`,
  )
    .bind(now, deviceId)
    .run();

  const minted = await mintDeviceToken();
  const tokenId = crypto.randomUUID();
  await context.env.DB.prepare(
    `INSERT INTO device_tokens (id, device_id, uid, prefix, token_hash, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(tokenId, deviceId, uid, minted.prefix, minted.hash, now)
    .run();

  const host =
    context.env.APP_URL?.replace(/\/$/, "") || new URL(context.req.url).origin;

  return context.json({
    deviceId,
    deviceUid,
    token: minted.token,
    uploadHost: host,
    uploadPath: `/api/v1/devices/${deviceId}/audio`,
  });
});

deviceSync.post("/:deviceId/audio", requireDeviceToken, async (context) => {
  const pathDeviceId = context.req.param("deviceId");
  const authDeviceId = context.get("deviceId");
  if (!authDeviceId || authDeviceId !== pathDeviceId)
    return context.json({ error: "Device mismatch" }, 403);

  const declared = Number(context.req.header("content-length"));
  if (Number.isFinite(declared) && declared > maximumUploadBytes + 96)
    return context.json({ error: "Audio too large" }, 413);

  let startSeq: string | null;
  let packetCount: number;
  let audio: Uint8Array;
  if (
    context.req.header("content-type")?.split(";", 1)[0].trim() ===
    "application/octet-stream"
  ) {
    const bytes = new Uint8Array(await context.req.arrayBuffer());
    const preamble = parseHomeUploadPreamble(bytes);
    if (!preamble || preamble.deviceId !== authDeviceId)
      return context.json({ error: "Invalid upload body" }, 400);
    startSeq = preamble.startSeq;
    packetCount = preamble.packetCount;
    audio = bytes.subarray(preamble.headerLen);
    if (
      preamble.packetBytes === 0 ||
      audio.byteLength !== packetCount * preamble.packetBytes
    )
      return context.json({ error: "Invalid upload fields" }, 400);
  } else {
    const body = await object(context.req.raw);
    if (!body) return context.json({ error: "Invalid upload body" }, 400);
    startSeq = parseStartSeq(body.startSeq);
    packetCount = Number(body.packetCount);
    const encoded =
      typeof body.audio === "string"
        ? body.audio
        : typeof body.audioBase64 === "string"
          ? body.audioBase64
          : "";
    try {
      audio = Uint8Array.from(atob(encoded), (value) => value.charCodeAt(0));
    } catch {
      return context.json({ error: "Invalid upload fields" }, 400);
    }
  }
  if (
    startSeq === null ||
    !Number.isFinite(packetCount) ||
    !Number.isInteger(packetCount) ||
    packetCount < 0 ||
    packetCount > 100_000 ||
    audio.byteLength === 0
  )
    return context.json({ error: "Invalid upload fields" }, 400);

  const byteCount = audio.byteLength;
  if (byteCount > maximumUploadBytes)
    return context.json({ error: "Audio too large" }, 413);

  const now = Date.now();
  const recent = await context.env.DB.prepare(
    `SELECT COUNT(*) AS n FROM device_audio_uploads
     WHERE device_id = ?1 AND created_at >= ?2`,
  )
    .bind(authDeviceId, now - 60_000)
    .first<{ n: number }>();
  if ((recent?.n ?? 0) >= maximumUploadsPerMinute)
    return context.json({ error: "Rate limited" }, 429);

  // Metadata receipt only — audio bytes are not persisted yet (home STA stub).
  const uploadId = crypto.randomUUID();
  const storageKey = `${context.get("auth").uid}/${authDeviceId}/${startSeq}-${packetCount}.bin`;
  await context.env.DEVICE_AUDIO.put(storageKey, audio, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  await context.env.DB.prepare(
    `INSERT INTO device_audio_uploads
         (id, device_id, uid, start_seq, packet_count, byte_count, created_at, storage_key)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(device_id, start_seq, packet_count) DO UPDATE SET
         byte_count = excluded.byte_count,
         created_at = excluded.created_at,
         storage_key = excluded.storage_key`,
  )
    .bind(
      uploadId,
      authDeviceId,
      context.get("auth").uid,
      startSeq,
      packetCount,
      byteCount,
      now,
      storageKey,
    )
    .run();

  return context.json({
    uploadId,
    accepted: true,
    persisted: true,
    startSeq,
    packetCount,
    byteCount,
  });
});

export const parseHomeUploadPreamble = (
  bytes: Uint8Array,
): {
  deviceId: string;
  startSeq: string;
  packetCount: number;
  packetBytes: number;
  headerLen: number;
} | null => {
  if (bytes.length < 16) return null;
  if (bytes[0] !== 0xc1 || bytes[1] !== 1) return null;
  const deviceLen = bytes[2];
  if (deviceLen === 0 || 3 + deviceLen + 14 > bytes.length) return null;
  const deviceId = new TextDecoder().decode(bytes.subarray(3, 3 + deviceLen));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const base = 3 + deviceLen;
  const startSeq = view.getBigUint64(base).toString();
  const packetCount = view.getUint32(base + 8);
  const packetBytes = view.getUint16(base + 12);
  return {
    deviceId,
    startSeq,
    packetCount,
    packetBytes,
    headerLen: base + 14,
  };
};

export default deviceSync;
