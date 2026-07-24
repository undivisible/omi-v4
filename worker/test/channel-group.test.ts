import { describe, expect, test } from "bun:test";
import { isGroupChannelChat } from "../src/channel-group";

describe("channel group detection", () => {
  test("detects telegram supergroups by negative chat id", () => {
    expect(isGroupChannelChat("telegram", "42", "42")).toBe(false);
    expect(isGroupChannelChat("telegram", "42", "-999")).toBe(true);
  });

  test("detects imessage groups by chat id", () => {
    expect(isGroupChannelChat("imessage", "+1555", "+1555")).toBe(false);
    expect(isGroupChannelChat("imessage", "+1555", "group-1")).toBe(true);
  });
});
