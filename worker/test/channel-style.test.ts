import { describe, expect, test } from "bun:test";
import { channelStylePrompt, sanitizeChannelReply } from "../src/channel-style";

describe("channel style prompts", () => {
  test("telegram and imessage each get plain-text rules", () => {
    expect(channelStylePrompt("telegram")).toContain("Telegram");
    expect(channelStylePrompt("telegram")).toContain("no markdown");
    expect(channelStylePrompt("blooio")).toContain("iMessage");
    expect(channelStylePrompt("blooio")).toContain("no markdown");
  });
});

describe("sanitizeChannelReply", () => {
  test("strips markdown markers", () => {
    expect(
      sanitizeChannelReply(
        "telegram",
        "**Hi** — here is a `list`:\n- one\n- two",
      ),
    ).toBe("Hi — here is a list:\none\ntwo");
  });

  test("removes fenced blocks", () => {
    expect(
      sanitizeChannelReply("blooio", 'Hello\n```crepus\nstack\n```\nThere'),
    ).toBe("Hello\n\nThere");
  });
});
