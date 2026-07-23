import type { Bindings, Channel } from "./types";

// Sendblue is the iMessage/SMS/RCS provider that replaces Blooio. The stored
// channel identifier is deliberately left alone: `"blooio"` is baked into
// three D1 CHECK constraints and into `worker-rs`, and rewriting it would
// require rebuilding those tables and shipping both binaries at once. It is
// now just an opaque identifier for "the iMessage channel"; the provider
// behind it is chosen by configuration.
export const imessageChannel: Channel = "blooio";

const sendMessageEndpoint = "https://api.sendblue.com/api/send-message";

export const sendblueConfigured = (env: Bindings): boolean =>
  Boolean(
    env.SENDBLUE_API_KEY_ID?.trim() &&
      env.SENDBLUE_API_KEY_SECRET?.trim() &&
      env.SENDBLUE_NUMBER?.trim(),
  );

export const sendblueHeaders = (env: Bindings): Record<string, string> => ({
  "sb-api-key-id": (env.SENDBLUE_API_KEY_ID ?? "").trim(),
  "sb-api-secret-key": (env.SENDBLUE_API_KEY_SECRET ?? "").trim(),
  "content-type": "application/json",
});

// Sendblue's send endpoint has no idempotency key. The delivery queue's lease
// and status machinery is therefore the only thing preventing a duplicate
// send on retry — see `delivery.ts`. Callers must not retry blindly.
export const sendbluePayload = (
  env: Bindings,
  recipient: string,
  text: string,
): string =>
  JSON.stringify({
    number: recipient,
    from_number: (env.SENDBLUE_NUMBER ?? "").trim(),
    content: text,
  });

export const sendblueRequest = (
  env: Bindings,
  recipient: string,
  text: string,
): { url: string; init: RequestInit } | null => {
  if (!sendblueConfigured(env)) return null;
  return {
    url: sendMessageEndpoint,
    init: {
      method: "POST",
      signal: AbortSignal.timeout(15_000),
      headers: sendblueHeaders(env),
      body: sendbluePayload(env, recipient, text),
    },
  };
};

// Sendblue does not sign webhook bodies. It echoes the shared secret that was
// configured for the endpoint back in an `sb-signing-secret` header — there is
// no HMAC, no timestamp, and therefore no binding between the secret and the
// payload and no replay window. This is materially weaker than the Blooio and
// Stripe paths and cannot be fixed from our side, so it is compensated for:
//
//   1. The comparison below is constant-time, so the secret cannot be
//      recovered by timing the endpoint.
//   2. The webhook path itself carries a second high-entropy segment
//      (`SENDBLUE_WEBHOOK_PATH_TOKEN`), so knowing the header alone is not
//      enough to reach the route. Both must leak together.
//   3. Replay is bounded by `webhook_events`, keyed on the message handle, so
//      a captured request cannot be replayed into a second inbound message.
//
// Rotate the secret through the Sendblue webhooks API on any suspicion of
// exposure; unlike an HMAC scheme, an observed header is a permanent forgery
// capability until it is rotated.
const constantTimeEqual = (left: string, right: string): boolean => {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index++)
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return mismatch === 0;
};

export const verifySendblueWebhook = (
  env: Bindings,
  pathToken: string,
  header: string | undefined,
): boolean => {
  const secret = env.SENDBLUE_WEBHOOK_SIGNING_SECRET?.trim();
  const expectedPathToken = env.SENDBLUE_WEBHOOK_PATH_TOKEN?.trim();
  if (!secret || !expectedPathToken) return false;
  // Both gates are required and both are compared in constant time.
  const pathOk = constantTimeEqual(pathToken, expectedPathToken);
  const secretOk = constantTimeEqual(header ?? "", secret);
  return pathOk && secretOk;
};

export type SendblueInbound = {
  messageHandle: string;
  sender: string;
  chatId: string;
  text: string;
  mediaUrl: string | null;
};

// The `receive` webhook payload. `from_number` is the end user, `number` is
// the same value, `to_number` is our Sendblue line. Group messages carry a
// non-empty `group_id`, which becomes the chat id so a group conversation
// stays one thread.
export const parseSendblueInbound = (body: unknown): SendblueInbound | null => {
  if (body === null || typeof body !== "object") return null;
  const event = body as Record<string, unknown>;
  if (event.is_outbound === true) return null;
  const messageHandle = event.message_handle;
  const sender = event.from_number;
  if (typeof messageHandle !== "string" || messageHandle.length === 0)
    return null;
  if (typeof sender !== "string" || sender.length === 0 || sender.length > 254)
    return null;
  const content = typeof event.content === "string" ? event.content.trim() : "";
  const mediaUrl =
    typeof event.media_url === "string" && event.media_url.length > 0
      ? event.media_url
      : null;
  if (content.length === 0 && mediaUrl === null) return null;
  if (content.length > 20_000) return null;
  const groupId = typeof event.group_id === "string" ? event.group_id : "";
  return {
    messageHandle,
    sender,
    chatId: groupId.length > 0 ? groupId : sender,
    text: content,
    mediaUrl,
  };
};
