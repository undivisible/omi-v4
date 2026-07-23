import { describe, expect, test } from "bun:test";
import {
  imessageChannel,
  parseSendblueInbound,
  sendblueRequest,
  verifySendblueWebhook,
} from "../src/sendblue";
import type { AppEnv } from "../src/types";

const bindings = () =>
  ({
    SENDBLUE_API_KEY_ID: "key-id",
    SENDBLUE_API_KEY_SECRET: "key-secret",
    SENDBLUE_NUMBER: "+15122164639",
    SENDBLUE_WEBHOOK_SIGNING_SECRET: "webhook-secret-value",
    SENDBLUE_WEBHOOK_PATH_TOKEN: "path-token-value",
  }) as unknown as AppEnv["Bindings"];

const inboundPayload = {
  content: "Hello!",
  is_outbound: false,
  status: "RECEIVED",
  message_handle: "99DCC379-DD76-4712-BA65-11EFB33B8CD6",
  from_number: "+19998887777",
  number: "+19998887777",
  to_number: "+15122164639",
  media_url: "",
  group_id: "",
  service: "iMessage",
};

describe("Sendblue channel identity", () => {
  test("keeps the stored channel identifier so existing bindings survive", () => {
    expect(imessageChannel).toBe("blooio");
  });
});

describe("Sendblue outbound send", () => {
  test("targets the documented endpoint with the documented shape", () => {
    const request = sendblueRequest(bindings(), "+19998887777", "Hi");
    expect(request?.url).toBe("https://api.sendblue.com/api/send-message");
    const headers = request?.init.headers as Record<string, string>;
    expect(headers["sb-api-key-id"]).toBe("key-id");
    expect(headers["sb-api-secret-key"]).toBe("key-secret");
    expect(JSON.parse(String(request?.init.body))).toEqual({
      number: "+19998887777",
      from_number: "+15122164639",
      content: "Hi",
    });
  });

  test("declines when the provider is not fully configured", () => {
    for (const missing of [
      "SENDBLUE_API_KEY_ID",
      "SENDBLUE_API_KEY_SECRET",
      "SENDBLUE_NUMBER",
    ] as const) {
      const environment = bindings();
      environment[missing] = undefined;
      expect(sendblueRequest(environment, "+19998887777", "Hi")).toBeNull();
    }
  });
});

describe("Sendblue webhook authentication", () => {
  test("accepts only when both the path token and the secret match", () => {
    const environment = bindings();
    expect(
      verifySendblueWebhook(
        environment,
        "path-token-value",
        "webhook-secret-value",
      ),
    ).toBe(true);
    expect(
      verifySendblueWebhook(environment, "wrong", "webhook-secret-value"),
    ).toBe(false);
    expect(
      verifySendblueWebhook(environment, "path-token-value", "wrong"),
    ).toBe(false);
    expect(
      verifySendblueWebhook(environment, "path-token-value", undefined),
    ).toBe(false);
  });

  test("refuses everything when either secret is unset", () => {
    for (const missing of [
      "SENDBLUE_WEBHOOK_SIGNING_SECRET",
      "SENDBLUE_WEBHOOK_PATH_TOKEN",
    ] as const) {
      const environment = bindings();
      environment[missing] = undefined;
      expect(
        verifySendblueWebhook(
          environment,
          "path-token-value",
          "webhook-secret-value",
        ),
      ).toBe(false);
    }
  });
});

describe("Sendblue inbound parsing", () => {
  test("reads the documented receive payload", () => {
    expect(parseSendblueInbound(inboundPayload)).toEqual({
      messageHandle: "99DCC379-DD76-4712-BA65-11EFB33B8CD6",
      sender: "+19998887777",
      chatId: "+19998887777",
      text: "Hello!",
      mediaUrl: null,
    });
  });

  test("threads a group message on its group id", () => {
    expect(
      parseSendblueInbound({ ...inboundPayload, group_id: "group-1" })?.chatId,
    ).toBe("group-1");
  });

  test("keeps a media-only message and carries its url", () => {
    const parsed = parseSendblueInbound({
      ...inboundPayload,
      content: "",
      media_url: "https://cdn.example/note.caf",
    });
    expect(parsed?.text).toBe("");
    expect(parsed?.mediaUrl).toBe("https://cdn.example/note.caf");
  });

  test("drops outbound echoes, empty and oversized payloads", () => {
    for (const payload of [
      null,
      "nope",
      { ...inboundPayload, is_outbound: true },
      { ...inboundPayload, content: "   ", media_url: "" },
      { ...inboundPayload, message_handle: "" },
      { ...inboundPayload, from_number: 42 },
      { ...inboundPayload, content: "x".repeat(20_001) },
    ])
      expect(parseSendblueInbound(payload)).toBeNull();
  });
});
