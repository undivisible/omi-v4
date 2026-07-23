import {
  faceTimeBridgeConfigured,
  faceTimeCostMicrousdPerMinute,
  faceTimeMaxSessionSeconds,
  startFaceTimeBridge,
  stopFaceTimeBridge,
} from "./facetime-bridge";
import {
  faceTimeProviderConfigured,
  type FaceTimeOutcome,
  startFaceTimeCall,
} from "./facetime";
import { admitSttSession, releaseSttSession } from "./stt-admission";
import type { Bindings } from "./types";

// Placing a call and bridging its audio is one operation with three
// resources: an admission reservation, a real ringing phone, and a running
// container. Every failure after a resource is taken unwinds the ones already
// held — the reservation is never leaked and the container is never left
// running with no session behind it.

export type FaceTimeSessionOutcome =
  | { kind: "ok"; handle: string; sessionId: string }
  | { kind: "unconfigured" }
  | { kind: "unavailable" }
  | { kind: "rejected"; status: number }
  | { kind: "capacity"; retryAfter: number }
  | { kind: "failed" };

const sessionOutcome = (outcome: FaceTimeOutcome): FaceTimeSessionOutcome =>
  outcome.kind === "ok" ? { kind: "failed" } : outcome;

export const startFaceTimeSession = async (
  env: Bindings,
  uid: string,
  handle: string,
  sessionId: string,
  fetcher: typeof fetch = fetch,
): Promise<FaceTimeSessionOutcome> => {
  if (!faceTimeProviderConfigured(env)) return { kind: "unconfigured" };
  // A call with no bridge behind it would ring a real person and then sit
  // silent, so a missing realtime key is a "not available", not a partial
  // success. Gemini Live needs its own key: OpenRouter cannot carry realtime.
  if (!faceTimeBridgeConfigured(env) || !env.FACETIME_BRIDGE)
    return { kind: "unavailable" };

  const maxSessionSeconds = faceTimeMaxSessionSeconds(env);
  const estimatedCost = Math.ceil(
    (maxSessionSeconds / 60) * faceTimeCostMicrousdPerMinute(env),
  );
  let admission: Response;
  try {
    admission = await admitSttSession(
      env,
      sessionId,
      uid,
      maxSessionSeconds,
      estimatedCost,
    );
  } catch {
    return { kind: "failed" };
  }
  if (!admission.ok)
    return {
      kind: "capacity",
      retryAfter: Number(admission.headers.get("retry-after")) || 60,
    };
  let acquisitionToken = "";
  try {
    const result = (await admission.json()) as Record<string, unknown>;
    if (
      result.admitted !== true ||
      typeof result.acquisitionToken !== "string" ||
      result.acquisitionToken.length < 16
    )
      return { kind: "failed" };
    // A duplicate that we did not re-acquire is someone else's reservation:
    // refuse rather than place a second call against it.
    if (result.duplicate === true && result.reacquired !== true)
      return { kind: "failed" };
    acquisitionToken = result.acquisitionToken;
  } catch {
    return { kind: "failed" };
  }

  const release = () =>
    releaseSttSession(env, sessionId, uid, acquisitionToken).catch(
      () => undefined,
    );

  const now = Date.now();
  try {
    await env.DB.prepare(
      `INSERT INTO managed_ai_requests
       (id, uid, provider, model, status, input_characters, requested_max_output_tokens,
        created_at, updated_at)
     VALUES (?1, ?2, 'facetime-gemini-live', ?3, 'started', 0, 0, ?4, ?4)`,
    )
      .bind(sessionId, uid, env.GEMINI_LIVE_MODEL as string, now)
      .run();
  } catch {
    await release();
    return { kind: "failed" };
  }

  const outcome = await startFaceTimeCall(env, handle, fetcher);
  if (outcome.kind !== "ok") {
    await release();
    return sessionOutcome(outcome);
  }

  const started = await startFaceTimeBridge(env, {
    sessionId,
    uid,
    acquisitionToken,
    handle: outcome.handle,
    agora: outcome.agora,
    maxSessionSeconds,
  });
  if (!started) {
    // The phone is already ringing. Stop the bridge (a no-op if it never
    // came up) and settle the reservation so the failure costs nothing.
    await stopFaceTimeBridge(env, sessionId);
    await release();
    return { kind: "failed" };
  }
  return { kind: "ok", handle: outcome.handle, sessionId };
};
