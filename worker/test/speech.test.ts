import { readdirSync } from "node:fs";
import { beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { Miniflare } from "miniflare";
import { dispatch, tools } from "../src/mcp";
import {
  maximumSpeakCharacters,
  parseSegments,
  speakTextOperation,
  transcribeAudioOperation,
} from "../src/speech";
import type { Bindings } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

const allowingRateLimiter = {
  getByName: () => ({
    fetch: async (url: string | URL) =>
      new URL(String(url)).pathname === "/consume"
        ? Response.json({ allowed: true, retryAfter: 0 })
        : new Response(null, { status: 404 }),
  }),
} as unknown as DurableObjectNamespace;

const denyingRateLimiter = {
  getByName: () => ({
    fetch: async () => Response.json({ allowed: false, retryAfter: 42 }),
  }),
} as unknown as DurableObjectNamespace;

type AdmissionCall = { path: string; body: Record<string, unknown> };

const admission = (
  calls: AdmissionCall[],
  admit: (call: AdmissionCall) => Response,
) =>
  ({
    getByName: () => ({
      fetch: async (url: string | URL, init?: RequestInit) => {
        const call = {
          path: new URL(String(url)).pathname,
          body: JSON.parse(String(init?.body ?? "{}")) as Record<
            string,
            unknown
          >,
        };
        calls.push(call);
        if (call.path === "/claim") return Response.json({ claimed: true });
        if (call.path === "/release") return Response.json({ released: true });
        return admit(call);
      },
    }),
  }) as unknown as DurableObjectNamespace;

const admitting = (calls: AdmissionCall[]) =>
  admission(calls, () =>
    Response.json({
      admitted: true,
      acquisitionToken: "speech-acquisition-token",
    }),
  );

const denying = () =>
  admission([], () =>
    Response.json(
      { admitted: false, retryAfter: 17 },
      { status: 429, headers: { "retry-after": "17" } },
    ),
  );

const environment = (overrides: Partial<Bindings> = {}) =>
  ({
    DB: database,
    RATE_LIMITER: allowingRateLimiter,
    STT_ADMISSION: admitting([]),
    DEV_FAKE_PRO: "true",
    OPENROUTER_API_KEY: "openrouter-secret",
    ...overrides,
  }) as unknown as Bindings;

type Capture = { url: string; init: RequestInit };

const recorder = (response: () => Response) => {
  const calls: Capture[] = [];
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return response();
  }) as unknown as typeof fetch;
  return { calls, fetcher };
};

const transcriptReply = (segments: unknown = undefined) =>
  Response.json({
    choices: [
      {
        message: {
          content: JSON.stringify({
            segments: segments ?? [
              { start: 0, end: 1.5, text: "hello there" },
              { start: 1.5, end: 3, text: "second line" },
            ],
          }),
        },
      },
    ],
  });

const audioReply = (data = "QUJD") =>
  Response.json({ choices: [{ message: { audio: { data } } }] });

const audio = (seconds = 1) => "A".repeat(4_000 * seconds * 2);

const bodyOf = (capture: Capture) =>
  JSON.parse(String(capture.init.body)) as Record<string, unknown>;

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const name of readdirSync("migrations").sort()) {
    const sql = (await Bun.file(`migrations/${name}`).text()).replace(
      "PRAGMA foreign_keys = ON;",
      "",
    );
    for (const statement of sql.split(";").map((value) => value.trim())) {
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

beforeEach(async () => {
  await database.prepare("DELETE FROM managed_speech_requests").run();
});

describe("transcript parsing", () => {
  test("reads timed segments out of a JSON reply", () => {
    expect(
      parseSegments('{"segments":[{"start":0,"end":2,"text":" hi "}]}', null),
    ).toEqual([{ index: 0, start: 0, end: 2, text: "hi" }]);
  });

  test("unwraps a fenced JSON reply", () => {
    expect(
      parseSegments('```json\n{"segments":[{"text":"hi"}]}\n```', null),
    ).toEqual([{ index: 0, start: null, end: null, text: "hi" }]);
  });

  test("falls back to one untimed segment for a plain-text reply", () => {
    expect(parseSegments("just words", 12)).toEqual([
      { index: 0, start: 0, end: 12, text: "just words" },
    ]);
  });
});

describe("server-side transcription", () => {
  test("returns segments and routes through the AI Gateway", async () => {
    const calls: AdmissionCall[] = [];
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({
        STT_ADMISSION: admitting(calls),
        CF_AI_GATEWAY_ACCOUNT_ID: "0".repeat(32),
        CF_AI_GATEWAY_ID: "omi-gateway",
        CF_AI_GATEWAY_TOKEN: "gateway-token",
      }),
      "alpha",
      {
        audio: audio(),
        format: "mp3",
        clientMessageId: "wal:flush:0001",
        durationSeconds: 3,
      },
      fetcher,
    );
    expect(outcome.status).toBe(200);
    expect(outcome.body.text).toBe("hello there second line");
    expect(outcome.body.segments).toEqual([
      { index: 0, start: 0, end: 1.5, text: "hello there" },
      { index: 1, start: 1.5, end: 3, text: "second line" },
    ]);
    expect(fetches).toHaveLength(1);
    expect(fetches[0].url).toBe(
      `https://gateway.ai.cloudflare.com/v1/${"0".repeat(32)}/omi-gateway/openrouter/v1/chat/completions`,
    );
    const headers = fetches[0].init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer openrouter-secret");
    expect(headers["cf-aig-authorization"]).toBe("Bearer gateway-token");
    expect(bodyOf(fetches[0]).model).toBe("xiaomi/mimo-v2.5");
    expect(calls.map((call) => call.path)).toEqual([
      "/admit",
      "/claim",
      "/release",
    ]);
  });

  test("honours an audio-capable model override", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    await transcribeAudioOperation(
      environment({
        OMI_MODEL_BALANCED: "x-ai/grok-stt-1.0",
        OMI_MODEL_CAPABILITIES: JSON.stringify({
          "x-ai/grok-stt-1.0": ["text", "audioIn"],
        }),
      }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0002" },
      fetcher,
    );
    expect(bodyOf(fetches[0]).model).toBe("x-ai/grok-stt-1.0");
  });

  test("skips a preferred tier whose override cannot take audio", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    await transcribeAudioOperation(
      environment({
        OMI_MODEL_BALANCED: "some/text-only-model",
        OMI_MODEL_CAPABILITIES: JSON.stringify({
          "some/text-only-model": ["text"],
        }),
      }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0003" },
      fetcher,
    );
    expect(bodyOf(fetches[0]).model).toBe("google/gemini-3.5-flash-lite");
  });

  test("refuses to transcribe when no preferred tier declares audio input", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({
        OMI_MODEL_BALANCED: "some/text-only-model",
        OMI_MODEL_TRANSCRIBE: "some/text-only-model",
        OMI_MODEL_MULTIMODAL: "some/text-only-model",
      }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0004" },
      fetcher,
    );
    expect(outcome.status).toBe(503);
    expect(fetches).toHaveLength(0);
  });

  test("replays a retried upload without transcribing or charging again", async () => {
    const calls: AdmissionCall[] = [];
    const environmentWithAdmission = environment({
      STT_ADMISSION: admitting(calls),
    });
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const input = {
      audio: audio(),
      format: "mp3",
      clientMessageId: "wal:flush:0003",
    };
    const first = await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      input,
      fetcher,
    );
    const second = await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      input,
      fetcher,
    );
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body.segments).toEqual(
      first.body.segments as TranscriptSegments,
    );
    expect(second.body.idempotentReplay).toBe(true);
    // One upstream transcription, one reservation: the retry costs nothing.
    expect(fetches).toHaveLength(1);
    expect(calls.filter((call) => call.path === "/admit")).toHaveLength(1);
    const rows = await database
      .prepare(
        "SELECT COUNT(*) AS total FROM managed_speech_requests WHERE uid = 'alpha'",
      )
      .first<{ total: number }>();
    expect(Number(rows?.total)).toBe(1);
  });

  test("rejects a reused id carrying a different payload", async () => {
    const environmentWithAdmission = environment();
    const { fetcher } = recorder(() => transcriptReply());
    await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0004" },
      fetcher,
    );
    const outcome = await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      { audio: audio(2), format: "mp3", clientMessageId: "wal:flush:0004" },
      fetcher,
    );
    expect(outcome).toEqual({
      status: 409,
      body: { error: "Client message ID conflict" },
    });
  });

  test("rejects oversized audio before any upstream call", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment(),
      "alpha",
      {
        audio: "A".repeat(14 * 1024 * 1024),
        format: "mp3",
        clientMessageId: "wal:flush:0005",
      },
      fetcher,
    );
    expect(outcome).toEqual({
      status: 413,
      body: { error: "Audio too large" },
    });
    expect(fetches).toHaveLength(0);
  });

  test("rejects audio longer than the configured ceiling", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ SPEECH_MAX_AUDIO_SECONDS: "60" }),
      "alpha",
      { audio: audio(120), format: "mp3", clientMessageId: "wal:flush:0006" },
      fetcher,
    );
    expect(outcome).toEqual({ status: 413, body: { error: "Audio too long" } });
    expect(fetches).toHaveLength(0);
  });

  test("surfaces an admission denial as 429 with its retry hint", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ STT_ADMISSION: denying() }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0007" },
      fetcher,
    );
    expect(outcome).toEqual({
      status: 429,
      body: { error: "Managed speech capacity exceeded" },
      retryAfter: 17,
    });
    expect(fetches).toHaveLength(0);
  });

  test("surfaces a rate-limit denial", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ RATE_LIMITER: denyingRateLimiter }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0008" },
      fetcher,
    );
    expect(outcome.status).toBe(429);
    expect(outcome.retryAfter).toBe(42);
  });

  test("requires Pro", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ DEV_FAKE_PRO: undefined }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0009" },
      fetcher,
    );
    expect(outcome).toEqual({
      status: 403,
      body: { error: "Managed Pro required" },
    });
  });

  test("rejects malformed requests", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    for (const input of [
      { audio: audio(), format: "mp3", clientMessageId: "short" },
      { audio: audio(), format: "flac", clientMessageId: "wal:flush:0010" },
      { audio: "", format: "mp3", clientMessageId: "wal:flush:0010" },
      {
        audio: "not base64!",
        format: "mp3",
        clientMessageId: "wal:flush:0010",
      },
      { audio: audio(), format: "mp3" },
      {
        audio: audio(),
        format: "mp3",
        clientMessageId: "wal:flush:0010",
        language: "english please",
      },
    ]) {
      const outcome = await transcribeAudioOperation(
        environment(),
        "alpha",
        input,
        fetcher,
      );
      expect(outcome.status).toBe(400);
    }
  });

  test("settles the reservation as failed when the provider errors", async () => {
    const calls: AdmissionCall[] = [];
    const { fetcher } = recorder(() => new Response(null, { status: 500 }));
    const outcome = await transcribeAudioOperation(
      environment({ STT_ADMISSION: admitting(calls) }),
      "alpha",
      { audio: audio(), format: "mp3", clientMessageId: "wal:flush:0011" },
      fetcher,
    );
    expect(outcome.status).toBe(502);
    expect(calls.map((call) => call.path)).toContain("/release");
    const row = await database
      .prepare(
        "SELECT status FROM managed_speech_requests WHERE client_message_id = 'wal:flush:0011'",
      )
      .first<{ status: string }>();
    expect(row?.status).toBe("failed");
  });
});

// A crashed isolate leaves a 'started' row with nothing left to finish it.
// Wedging the caller's id on that row forever would make the audio
// unrecoverable, so a row older than any request could still be running is
// reclaimable — reservation included.
describe("abandoned speech requests", () => {
  // Mirrors the admission object: a reservation stays held until its own
  // token releases it, and only then can it be re-acquired.
  const holdingAdmission = (calls: AdmissionCall[]) => {
    const state = { held: null as string | null };
    const namespace = {
      getByName: () => ({
        fetch: async (url: string | URL, init?: RequestInit) => {
          const path = new URL(String(url)).pathname;
          const body = JSON.parse(String(init?.body ?? "{}")) as Record<
            string,
            unknown
          >;
          calls.push({ path, body });
          if (path === "/claim") return Response.json({ claimed: true });
          if (path === "/release") {
            if (state.held === body.acquisitionToken) state.held = null;
            return Response.json({ released: true });
          }
          if (state.held)
            return Response.json({
              admitted: true,
              duplicate: true,
              acquisitionToken: state.held,
            });
          state.held = `speech-acquisition-${calls.length}`;
          return Response.json({
            admitted: true,
            acquisitionToken: state.held,
          });
        },
      }),
    } as unknown as DurableObjectNamespace;
    return { namespace, state };
  };

  const age = async (clientMessageId: string, updatedAt: number) => {
    await database
      .prepare(
        `UPDATE managed_speech_requests
         SET status = 'started', result = NULL, completed_at = NULL, updated_at = ?1
         WHERE client_message_id = ?2`,
      )
      .bind(updatedAt, clientMessageId)
      .run();
  };

  test("refuses a retry while the request is still in flight", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    const input = {
      audio: audio(),
      format: "mp3",
      clientMessageId: "wal:flush:0020",
    };
    await transcribeAudioOperation(environment(), "alpha", input, fetcher);
    await age("wal:flush:0020", Date.now() - 1_000);
    const outcome = await transcribeAudioOperation(
      environment(),
      "alpha",
      input,
      fetcher,
    );
    expect(outcome.status).toBe(409);
    expect(outcome.body.error).toBe("Speech request in progress");
  });

  test("reclaims a request whose isolate died, releasing its reservation", async () => {
    const calls: AdmissionCall[] = [];
    const { namespace, state } = holdingAdmission(calls);
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const input = {
      audio: audio(),
      format: "mp3",
      clientMessageId: "wal:flush:0021",
    };
    await transcribeAudioOperation(
      environment({ STT_ADMISSION: namespace }),
      "alpha",
      input,
      fetcher,
    );
    // The crash: the row never settled and the reservation was never freed.
    await age("wal:flush:0021", Date.now() - 3_600_000);
    state.held = "leaked-acquisition-token";
    calls.length = 0;
    const outcome = await transcribeAudioOperation(
      environment({ STT_ADMISSION: namespace }),
      "alpha",
      input,
      fetcher,
    );
    expect(outcome.status).toBe(200);
    expect(outcome.body.text).toBe("hello there second line");
    expect(calls.map((call) => call.path)).toEqual([
      "/admit",
      "/release",
      "/admit",
      "/claim",
      "/release",
    ]);
    expect(fetches).toHaveLength(2);
    const row = await database
      .prepare(
        "SELECT status, result FROM managed_speech_requests WHERE client_message_id = 'wal:flush:0021'",
      )
      .first<{ status: string; result: string }>();
    expect(row?.status).toBe("complete");
    expect(JSON.parse(String(row?.result)).text).toBe(
      "hello there second line",
    );
  });

  test("re-runs a completed request whose stored result no longer parses", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    const input = {
      audio: audio(),
      format: "mp3",
      clientMessageId: "wal:flush:0022",
    };
    await transcribeAudioOperation(environment(), "alpha", input, fetcher);
    await database
      .prepare(
        "UPDATE managed_speech_requests SET result = '{not json' WHERE client_message_id = 'wal:flush:0022'",
      )
      .run();
    const outcome = await transcribeAudioOperation(
      environment(),
      "alpha",
      input,
      fetcher,
    );
    expect(outcome.status).toBe(200);
    // The account was charged for the call, so the result it paid for has to
    // be the one that ends up stored.
    const row = await database
      .prepare(
        "SELECT status, result FROM managed_speech_requests WHERE client_message_id = 'wal:flush:0022'",
      )
      .first<{ status: string; result: string }>();
    expect(row?.status).toBe("complete");
    expect(JSON.parse(String(row?.result)).text).toBe(
      "hello there second line",
    );
  });
});

describe("text to speech", () => {
  test("returns audio and sends the audio modality upstream", async () => {
    const { calls: fetches, fetcher } = recorder(() => audioReply());
    const outcome = await speakTextOperation(
      environment(),
      "alpha",
      { text: "Say this out loud.", clientMessageId: "tts:0001" },
      fetcher,
    );
    expect(outcome.status).toBe(200);
    expect(outcome.body.audio).toBe("QUJD");
    expect(outcome.body.format).toBe("mp3");
    expect(outcome.body.voice).toBe("alloy");
    const sent = bodyOf(fetches[0]);
    expect(sent.model).toBe("openai/gpt-audio-mini");
    expect(sent.modalities).toEqual(["text", "audio"]);
    expect(sent.audio).toEqual({ voice: "alloy", format: "mp3" });
  });

  test("rejects text past the character bound before any upstream call", async () => {
    const { calls: fetches, fetcher } = recorder(() => audioReply());
    const outcome = await speakTextOperation(
      environment(),
      "alpha",
      {
        text: "a".repeat(maximumSpeakCharacters + 1),
        clientMessageId: "tts:0002",
      },
      fetcher,
    );
    expect(outcome).toEqual({ status: 413, body: { error: "Text too long" } });
    expect(fetches).toHaveLength(0);
  });

  test("rejects unknown voices and formats", async () => {
    const { fetcher } = recorder(() => audioReply());
    for (const input of [
      { text: "hi", clientMessageId: "tts:0003", voice: "gandalf" },
      { text: "hi", clientMessageId: "tts:0003", format: "wav" },
      { text: "   ", clientMessageId: "tts:0003" },
      { text: "hi", clientMessageId: "no" },
    ]) {
      const outcome = await speakTextOperation(
        environment(),
        "alpha",
        input,
        fetcher,
      );
      expect(outcome.status).toBe(400);
    }
  });

  test("refuses audio too large to retain for replay", async () => {
    const { fetcher } = recorder(() => audioReply("A".repeat(800_000)));
    const outcome = await speakTextOperation(
      environment(),
      "alpha",
      { text: "long one", clientMessageId: "tts:0004" },
      fetcher,
    );
    expect(outcome).toEqual({
      status: 502,
      body: { error: "Synthesized audio too large" },
    });
  });

  test("replays a retried synthesis without charging again", async () => {
    const calls: AdmissionCall[] = [];
    const shared = environment({ STT_ADMISSION: admitting(calls) });
    const { calls: fetches, fetcher } = recorder(() => audioReply());
    const input = { text: "Say this once.", clientMessageId: "tts:0005" };
    await speakTextOperation(shared, "alpha", input, fetcher);
    const second = await speakTextOperation(shared, "alpha", input, fetcher);
    expect(second.status).toBe(200);
    expect(second.body.audio).toBe("QUJD");
    expect(second.body.idempotentReplay).toBe(true);
    expect(fetches).toHaveLength(1);
    expect(calls.filter((call) => call.path === "/admit")).toHaveLength(1);
  });
});

describe("MCP surface", () => {
  test("exposes both speech tools under the speech:write scope", () => {
    const speech = tools.filter((tool) => tool.scope === "speech:write");
    expect(speech.map((tool) => tool.name).sort()).toEqual([
      "speak_text",
      "transcribe_audio",
    ]);
  });

  test("refuses a key without the speech:write scope", async () => {
    const response = await dispatch(environment(), "alpha", ["memory:read"], {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "speak_text", arguments: { text: "hi" } },
    });
    expect(response?.error).toEqual({
      code: -32000,
      message: "API key is missing the speech:write scope",
    });
  });
});

type TranscriptSegments = ReturnType<typeof parseSegments>;

describe("pendant capture uploads", () => {
  // The write-ahead log ships the pendant's own audio: 16 kHz mono Opus at a
  // fixed 32 000 bps, Ogg-encapsulated on the phone because bare Opus packets
  // are not a container the model can be handed.
  // 10 664 base64 characters decode to 7 998 bytes, which at 4 000 bytes per
  // second of Opus is two seconds of pendant audio.
  const oggSeconds = 2;
  const oggAudio = "A".repeat(10_664);

  test("reserves Opus seconds from the pendant's bitrate", async () => {
    const calls: AdmissionCall[] = [];
    const { fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ STT_ADMISSION: admitting(calls) }),
      "alpha",
      {
        audio: oggAudio,
        format: "ogg",
        clientMessageId: "wal:flush:ogg-0001",
      },
      fetcher,
    );
    expect(outcome.status).toBe(200);
    const admit = calls.find((call) => call.path === "/admit");
    expect(admit?.body.reservedSeconds).toBe(oggSeconds);
  });

  test("normalises an 'opus' payload to its Ogg container upstream", async () => {
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment(),
      "alpha",
      {
        audio: oggAudio,
        format: "opus",
        clientMessageId: "wal:flush:ogg-0002",
      },
      fetcher,
    );
    expect(outcome.status).toBe(200);
    expect(outcome.body.format).toBe("ogg");
    const content = (
      bodyOf(fetches[0]).messages as [{ content: [unknown, unknown] }]
    )[0].content[1];
    expect(content).toEqual({
      type: "input_audio",
      input_audio: { data: oggAudio, format: "ogg" },
    });
  });

  test("persists capture provenance and replays it on a retry", async () => {
    const environmentWithAdmission = environment();
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const input = {
      audio: oggAudio,
      format: "ogg",
      clientMessageId: "wal:flush:ogg-0003",
      audioStreamId: "omi-AA:BB:CC-1712345678901234",
      deviceId: "f".repeat(64),
      startedAt: "2026-07-23T09:15:00.000Z",
      gapBefore: true,
    };
    const first = await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      input,
      fetcher,
    );
    expect(first.status).toBe(200);
    expect(first.body.audioStreamId).toBe(input.audioStreamId);
    expect(first.body.deviceId).toBe(input.deviceId);
    expect(first.body.startedAt).toBe(input.startedAt);
    expect(first.body.gapBefore).toBe(true);
    const row = await database
      .prepare(
        "SELECT result FROM managed_speech_requests WHERE client_message_id = 'wal:flush:ogg-0003'",
      )
      .first<{ result: string }>();
    expect(JSON.parse(String(row?.result)).audioStreamId).toBe(
      input.audioStreamId,
    );
    const second = await transcribeAudioOperation(
      environmentWithAdmission,
      "alpha",
      input,
      fetcher,
    );
    expect(second.body.idempotentReplay).toBe(true);
    expect(second.body.gapBefore).toBe(true);
    expect(fetches).toHaveLength(1);
  });

  test("refuses malformed provenance before reserving anything", async () => {
    const calls: AdmissionCall[] = [];
    const { calls: fetches, fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment({ STT_ADMISSION: admitting(calls) }),
      "alpha",
      {
        audio: oggAudio,
        format: "ogg",
        clientMessageId: "wal:flush:ogg-0004",
        gapBefore: "yes",
      },
      fetcher,
    );
    expect(outcome.status).toBe(400);
    expect(calls).toHaveLength(0);
    expect(fetches).toHaveLength(0);
  });

  test("still refuses a container it has no duration estimate for", async () => {
    const { fetcher } = recorder(() => transcriptReply());
    const outcome = await transcribeAudioOperation(
      environment(),
      "alpha",
      {
        audio: oggAudio,
        format: "flac",
        clientMessageId: "wal:flush:ogg-0005",
      },
      fetcher,
    );
    expect(outcome.status).toBe(400);
  });
});
