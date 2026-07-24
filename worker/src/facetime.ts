import { sendblueApiKeyId, sendblueApiKeySecret } from "./sendblue";
import type { Bindings } from "./types";

// Sendblue's FaceTime bridge. Unlike the previous provider it does not hand
// back an `facetime.apple.com` join link — it rings the handle over FaceTime
// Audio and returns Agora WebRTC credentials for the call's audio channel.
// There is no Apple web client and no browser anywhere in this path; the
// audio is joined server-side by the bridge container (`facetime-session.ts`).
const faceTimeEndpoint = "https://api.sendblue.com/facetime/start-call";
const upstreamTimeoutMs = 15_000;

// A handle is either an E.164 phone number or an email address. Anything else
// is rejected here and never forwarded: the upstream call rings a real phone.
const phonePattern = /^\+[1-9]\d{6,14}$/;
const emailPattern = /^[^\s@]{1,64}@[^\s@.]+(?:\.[^\s@.]+)+$/;

export const normalizeHandle = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const handle = value.trim();
  if (handle.length === 0 || handle.length > 254) return null;
  if (phonePattern.test(handle)) return handle;
  return emailPattern.test(handle) ? handle.toLowerCase() : null;
};

export const isDiallableHandle = (handle: string): boolean =>
  phonePattern.test(handle);

// What the bridge needs to join the call's audio channel. `uid` is the Agora
// user id the bridge publishes under; 0 means "let Agora assign one".
export type AgoraCredentials = {
  appId: string;
  channelName: string;
  token: string;
  uid: number;
};

export type FaceTimeOutcome =
  | { kind: "ok"; handle: string; agora: AgoraCredentials }
  | { kind: "unconfigured" }
  // The account has no FaceTime line provisioned (Sendblue gates the route on
  // a purchased FaceTime number). That is an expected product state, not a
  // fault of ours: callers get a clear "not yet available" and nothing is
  // queued for retry.
  | { kind: "unavailable" }
  | { kind: "rejected"; status: number }
  | { kind: "failed" };

const credentialsFrom = (value: unknown): AgoraCredentials | null => {
  if (value === null || typeof value !== "object") return null;
  const agora = value as Record<string, unknown>;
  const { appId, channelName, token } = agora;
  if (typeof appId !== "string" || appId.length === 0) return null;
  if (typeof channelName !== "string" || channelName.length === 0) return null;
  if (typeof token !== "string" || token.length === 0) return null;
  // Bound every field: these are forwarded verbatim into the container's
  // start request, so an oversized upstream value must not become our payload.
  if (appId.length > 128 || channelName.length > 256 || token.length > 4_096)
    return null;
  const uid = Number(agora.uid ?? 0);
  if (!Number.isSafeInteger(uid) || uid < 0 || uid > 0xffff_ffff) return null;
  return { appId, channelName, token, uid };
};

export const faceTimeProviderConfigured = (env: Bindings): boolean =>
  Boolean(
    sendblueApiKeyId(env) &&
      sendblueApiKeySecret(env) &&
      env.SENDBLUE_FACETIME_NUMBER?.trim(),
  );

export const startFaceTimeCall = async (
  env: Bindings,
  handle: string,
  fetcher: typeof fetch = fetch,
): Promise<FaceTimeOutcome> => {
  if (!faceTimeProviderConfigured(env)) return { kind: "unconfigured" };
  // Sendblue dials an E.164 number. An email handle is a valid FaceTime
  // identity but not something this provider can ring, so it is refused
  // before the request rather than failing opaquely upstream.
  if (!isDiallableHandle(handle)) return { kind: "rejected", status: 400 };
  let response: Response;
  try {
    response = await fetcher(faceTimeEndpoint, {
      method: "POST",
      signal: AbortSignal.timeout(upstreamTimeoutMs),
      headers: {
        "sb-api-key-id": sendblueApiKeyId(env),
        "sb-api-secret-key": sendblueApiKeySecret(env),
        "content-type": "application/json",
      },
      body: JSON.stringify({
        phoneNumber: handle,
        fromNumber: (env.SENDBLUE_FACETIME_NUMBER as string).trim(),
      }),
    });
  } catch {
    return { kind: "failed" };
  }
  // 401 is our credentials, not the account's product state, so it reads as
  // "unconfigured". 402/403/404/501 all mean "no FaceTime line on this
  // account" and keep the graceful not-provisioned surface.
  if (response.status === 401) return { kind: "unconfigured" };
  if ([402, 403, 404, 501].includes(response.status))
    return { kind: "unavailable" };
  if (response.status === 400 || response.status === 422)
    return { kind: "rejected", status: response.status };
  if (!response.ok) return { kind: "failed" };
  let body: { status?: unknown; agora?: unknown };
  try {
    body = (await response.json()) as typeof body;
  } catch {
    return { kind: "failed" };
  }
  if (body.status !== "OK") return { kind: "failed" };
  const agora = credentialsFrom(body.agora);
  if (!agora) return { kind: "failed" };
  return { kind: "ok", handle, agora };
};
