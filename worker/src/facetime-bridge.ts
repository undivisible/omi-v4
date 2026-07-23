import { releaseSttSession } from "./stt-admission";
import type { AgoraCredentials } from "./facetime";
import type { Bindings } from "./types";

// The FaceTime audio bridge runs in a Cloudflare Container, not in the
// Workers runtime: joining an Agora channel needs Agora's native Server
// Gateway SDK (x86_64 Linux), which cannot be loaded by an isolate. This
// Durable Object is the container's control plane — it starts exactly one
// container per call, hands it the per-call secrets as process environment,
// and releases the admission reservation on every exit path.
//
// The container image is `worker/container/facetime-bridge`. It exposes a
// single HTTP port and speaks the small protocol below.
const bridgePort = 8080;

// The container is handed a bounded start request; nothing here is
// user-authored free text, but the cap keeps an oversized upstream token from
// becoming our payload.
const maximumStartBodyBytes = 16_384;

export type BridgeStart = {
  sessionId: string;
  uid: string;
  acquisitionToken: string;
  handle: string;
  agora: AgoraCredentials;
  maxSessionSeconds: number;
};

type StoredSession = {
  sessionId: string;
  uid: string;
  acquisitionToken: string;
  startedAt: number;
  maxSessionSeconds: number;
};

const positiveInteger = (value: unknown): number | null => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};

export const faceTimeMaxSessionSeconds = (env: Bindings): number =>
  Math.min(
    positiveInteger(env.FACETIME_MAX_SESSION_SECONDS) ?? 600,
    // A realtime session is open-ended and reachable from an inbound message,
    // so it is capped hard regardless of configuration.
    3_600,
  );

export const faceTimeCostMicrousdPerMinute = (env: Bindings): number =>
  positiveInteger(env.FACETIME_COST_MICROUSD_PER_MINUTE) ?? 30_000;

export const faceTimeBridgeConfigured = (env: Bindings): boolean =>
  Boolean(env.GEMINI_API_KEY?.trim() && env.GEMINI_LIVE_MODEL?.trim());

const boundedJson = async (request: Request): Promise<unknown> => {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximumStartBodyBytes)
    return null;
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maximumStartBodyBytes)
    return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};

export class FaceTimeBridge {
  constructor(
    readonly state: DurableObjectState,
    readonly env: Bindings,
  ) {}

  // The alarm is the backstop for the case where the container neither exits
  // nor is stopped: it destroys the container and settles the reservation.
  async alarm(): Promise<void> {
    await this.teardown("timeout");
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") return new Response(null, { status: 405 });
    if (url.pathname === "/start") return this.start(request);
    if (url.pathname === "/stop") {
      await this.teardown("stopped");
      return Response.json({ stopped: true });
    }
    return new Response(null, { status: 404 });
  }

  private async start(request: Request): Promise<Response> {
    const container = this.state.container;
    if (!container)
      return Response.json({ error: "Bridge unavailable" }, { status: 503 });
    const body = (await boundedJson(request)) as BridgeStart | null;
    if (
      body === null ||
      typeof body.sessionId !== "string" ||
      typeof body.uid !== "string" ||
      typeof body.acquisitionToken !== "string" ||
      typeof body.handle !== "string" ||
      body.agora === null ||
      typeof body.agora !== "object"
    )
      return Response.json({ error: "Invalid request" }, { status: 400 });
    if (container.running)
      return Response.json({ error: "Session in progress" }, { status: 409 });
    const key = this.env.GEMINI_API_KEY;
    const model = this.env.GEMINI_LIVE_MODEL;
    if (!key || !model)
      return Response.json({ error: "Bridge unavailable" }, { status: 503 });
    const maxSessionSeconds = Math.min(
      positiveInteger(body.maxSessionSeconds) ?? 600,
      3_600,
    );
    const session: StoredSession = {
      sessionId: body.sessionId,
      uid: body.uid,
      acquisitionToken: body.acquisitionToken,
      startedAt: Date.now(),
      maxSessionSeconds,
    };
    await this.state.storage.put("session", session);
    try {
      container.start({
        // The Agora SD-RTN edge is reached over the public internet. Secrets
        // travel as process environment and never touch the image.
        enableInternet: true,
        env: {
          AGORA_APP_ID: body.agora.appId,
          AGORA_CHANNEL_NAME: body.agora.channelName,
          AGORA_TOKEN: body.agora.token,
          AGORA_UID: String(body.agora.uid),
          // Force TCP/TLS 443 for the media path. Agora's automatic mode
          // prefers UDP to arbitrary ports, which is exactly the flow shape
          // that fails on Cloudflare's anycast egress.
          AGORA_CLOUD_PROXY: this.env.AGORA_CLOUD_PROXY ?? "tcp",
          GEMINI_API_KEY: key,
          GEMINI_LIVE_MODEL: model,
          GEMINI_SYSTEM_PROMPT:
            this.env.FACETIME_SYSTEM_PROMPT ?? defaultSystemPrompt,
          MAX_SESSION_SECONDS: String(maxSessionSeconds),
          SESSION_ID: body.sessionId,
        },
      });
      // Belt to the alarm's braces: the instance is reaped even if the Durable
      // Object is evicted before its alarm fires. The bridge process also
      // enforces the same deadline on itself.
      await container.setInactivityTimeout((maxSessionSeconds + 30) * 1000);
    } catch {
      await this.settle("failed");
      return Response.json({ error: "Bridge unavailable" }, { status: 503 });
    }
    await this.state.storage.setAlarm(
      session.startedAt + (maxSessionSeconds + 15) * 1000,
    );
    // `monitor()` resolves whenever the container exits, however it exits —
    // clean end of call, crash, or destroy. Settling from here means no exit
    // path can leak the reservation.
    this.state.waitUntil(
      container.monitor().then(
        () => this.settle("complete"),
        () => this.settle("failed"),
      ),
    );
    let response: Response;
    try {
      response = await container
        .getTcpPort(bridgePort)
        .fetch("http://bridge.internal/start", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ handle: body.handle }),
        });
    } catch {
      await this.teardown("failed");
      return Response.json({ error: "Bridge unavailable" }, { status: 503 });
    }
    if (!response.ok) {
      await this.teardown("failed");
      return Response.json({ error: "Bridge unavailable" }, { status: 503 });
    }
    return Response.json({ started: true });
  }

  private async teardown(
    reason: "stopped" | "timeout" | "failed",
  ): Promise<void> {
    const container = this.state.container;
    if (container?.running) {
      try {
        await container.destroy();
      } catch {}
    }
    await this.settle(reason === "stopped" ? "complete" : "failed");
  }

  // Idempotent: the stored session is deleted first, so a monitor callback
  // and an alarm racing each other release the reservation exactly once.
  private async settle(status: "complete" | "failed"): Promise<void> {
    const session = (await this.state.storage.get(
      "session",
    )) as StoredSession | null;
    if (!session) return;
    await this.state.storage.delete("session");
    await this.state.storage.deleteAlarm().catch(() => undefined);
    await releaseSttSession(
      this.env,
      session.sessionId,
      session.uid,
      session.acquisitionToken,
    ).catch(() => undefined);
    await this.env.DB.prepare(
      `UPDATE managed_ai_requests
       SET status = ?1, finalization_attempts = finalization_attempts + 1,
           finalized_at = COALESCE(finalized_at, ?2), updated_at = ?2
       WHERE id = ?3 AND finalized_at IS NULL`,
    )
      .bind(status, Date.now(), session.sessionId)
      .run()
      .catch(() => undefined);
  }
}

const defaultSystemPrompt =
  "You are Omi, speaking with the user over a FaceTime Audio call. Keep " +
  "replies short and conversational. You cannot see anything: this call " +
  "carries audio only.";

export const startFaceTimeBridge = async (
  env: Bindings,
  start: BridgeStart,
): Promise<boolean> => {
  if (!env.FACETIME_BRIDGE) return false;
  let response: Response;
  try {
    response = await env.FACETIME_BRIDGE.getByName(start.sessionId).fetch(
      "https://facetime-bridge.internal/start",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(start),
      },
    );
  } catch {
    return false;
  }
  return response.ok;
};

export const stopFaceTimeBridge = async (
  env: Bindings,
  sessionId: string,
): Promise<void> => {
  if (!env.FACETIME_BRIDGE) return;
  try {
    await env.FACETIME_BRIDGE.getByName(sessionId).fetch(
      "https://facetime-bridge.internal/stop",
      { method: "POST" },
    );
  } catch {}
};
