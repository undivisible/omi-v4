import { describe, expect, test } from "bun:test";
import {
  mintDeviceToken,
  parseHomeUploadPreamble,
  deviceTokenPrefix,
} from "../src/device-sync";

describe("device-sync", () => {
  test("mints omi_dev_ tokens", async () => {
    const minted = await mintDeviceToken();
    expect(minted.token.startsWith(deviceTokenPrefix)).toBe(true);
    expect(minted.hash).toHaveLength(64);
    expect(minted.prefix).toHaveLength(8);
  });

  test("parses home upload preamble", () => {
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
    expect(parsed?.startSeq).toBe(42);
    expect(parsed?.packetCount).toBe(7);
    expect(parsed?.packetBytes).toBe(444);
  });
});
