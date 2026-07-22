# Realtime Voice Session Abstraction

*Research pass and design proposal, 2026-07-22. Grounded in public provider documentation as of this date and in the existing hub trait style (`app/native/hub/src/transcription.rs` `LiveSttProvider`, `app/native/hub/src/runtime.rs` `AssistantProvider`). Nothing here is implemented yet; this document defines the target abstraction so Gemini Live can ship first and OpenAI GPT-Live-1 / Realtime GA and NVIDIA Nemotron/PersonaPlex can plug in without reshaping the hub.*

## 1. Provider landscape

### 1.1 What each provider actually is

- **Google Gemini Live API** — bidirectional WebSocket (`BidiGenerateContent`). Fully documented, available today. This is the launch target.
- **OpenAI Realtime API (GA, `gpt-realtime-2.1`)** — WebSocket or WebRTC, half-duplex turn-based with server/semantic VAD. Fully documented, available today. Best public proxy for what GPT-Live-1's API will look like.
- **OpenAI GPT-Live-1** — full-duplex voice model announced 2026-07-08, ChatGPT-only at launch; API "coming soon" (sign-up form only, no published surface). It listens and speaks simultaneously, backchannels ("mhmm"), pauses while the user thinks, and continues while background tasks run. No event schema is public.
- **NVIDIA Nemotron Speech NIM** — self/cloud-hosted microservices. The realtime endpoints are *component* APIs (streaming ASR; realtime TTS over a WebSocket event protocol closely modeled on OpenAI's naming: `synthesize_session.update`, `input_text.append/commit`, `conversation.item.speech.data`). A full voice agent is assembled from ASR + LLM + TTS (see the `nemotron-voice-agent` blueprint, Pipecat-based) — there is no single speech-to-speech session endpoint today.
- **NVIDIA PersonaPlex** — open 7B full-duplex speech-to-speech model (Jan 2026), built on Kyutai's Moshi framework. 24 kHz audio, voice prompt (audio embedding) + text role prompt. It is a *model*, not a hosted API; serving is whatever the Moshi-style server exposes (continuous duplex audio streams), typically self-hosted over a WebSocket carrying opus/PCM frames.

### 1.2 Session model comparison

| Dimension | Gemini Live | OpenAI Realtime GA | GPT-Live-1 | Nemotron NIM (composed) | PersonaPlex (self-hosted) |
|---|---|---|---|---|---|
| Transport | WebSocket (`BidiGenerateContent`) | WebSocket or WebRTC | unknown (WebRTC likely for duplex) | gRPC (ASR) + WebSocket (TTS), glued by an agent framework | WebSocket to a Moshi-style server |
| Auth | API key or ephemeral token | API key; ephemeral client secrets (`/v1/realtime/client_secrets`) for client-side | unknown | self-hosted (NGC key to pull; local auth optional) | self-hosted, none by default |
| Setup message | `setup` (model, generationConfig, tools, system instruction) | `session.update` | unknown | `synthesize_session.update` + ASR config per stream | voice embedding + text role prompt at session start |
| Audio in | PCM16 16 kHz | PCM16 24 kHz (also g711) | unknown | PCM16 (ASR-dependent rates) | 24 kHz continuous |
| Audio out | PCM16 24 kHz | PCM16 24 kHz | unknown | LINEAR_PCM or OGG_OPUS | 24 kHz continuous |
| Turn model | half-duplex, server VAD (configurable), barge-in interrupts generation | half-duplex, server VAD or semantic VAD; `response.cancel` / truncation on barge-in | **full duplex** — no explicit turns; model self-manages overlap, backchannels | app-managed: ASR endpointing decides turns; TTS is fire-and-forget per reply | full duplex, model-managed |
| Barge-in signal | `serverContent.interrupted` | `input_audio_buffer.speech_started` + cancel/truncate | implicit (model just stops/yields) | app must stop TTS itself | implicit |
| Tool calling | `toolCall` / client `toolResponse`; async function calling | `response.function_call_arguments.*` + submit item, then `response.create` | unknown | at the LLM layer, outside the audio session | none native (role prompt only) |
| Transcripts | input/output transcription config; text in `serverContent` | `conversation.item.input_audio_transcription.*`, `response.output_audio_transcript.delta` | unknown | ASR partial/final results are the transcript | Moshi emits text tokens alongside audio |
| Session limits / resume | ~10 min connection, session resumption handles + `goAway` warning; context window compression for long sessions | long-lived sessions (tens of minutes); no server-side resumption handle — reconnect re-sends state | unknown ("continues while deeper tasks run" suggests durable sessions) | self-managed | self-managed |

The composed nature of Nemotron and the duplex nature of GPT-Live-1/PersonaPlex are the two stress tests: the abstraction must not assume one WebSocket, and must not assume explicit turns.

## 2. Proposed hub abstraction

Placement: a new `app/native/hub/src/voice.rs` alongside `transcription.rs`. Style follows the existing crate: `pub(crate)` traits, `mpsc::Receiver<Result<_, String>>` event streams, `CancellationToken` for teardown, plain `String` errors, `Send` bounds matching how the trait objects are held (`LiveSttProvider: Send`, `AssistantProvider: Send + Sync`).

```rust
#[derive(Clone)]
pub(crate) struct VoiceSessionConfig {
    pub(crate) provider: VoiceProviderKind,
    pub(crate) model: String,
    pub(crate) credential: VoiceCredential,
    pub(crate) endpoint: Option<String>,
    pub(crate) system_instruction: Option<String>,
    pub(crate) voice: Option<String>,
    pub(crate) tools: Vec<VoiceToolDeclaration>,
    pub(crate) input_format: AudioFormat,
    pub(crate) resume: Option<SessionResumeHandle>,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum VoiceProviderKind {
    GeminiLive,
    OpenAiRealtime,
    OpenAiGptLive,
    Nemotron,
    PersonaPlex,
}

#[derive(Clone)]
pub(crate) enum VoiceCredential {
    ApiKey(String),
    EphemeralToken { token: String, expires_at_ms: i64 },
    None,
}

#[derive(Clone, Copy)]
pub(crate) struct AudioFormat {
    pub(crate) sample_rate_hz: u32,
    pub(crate) channels: u8,
    pub(crate) encoding: crate::signals::AudioEncoding,
}

#[derive(Clone)]
pub(crate) struct SessionResumeHandle {
    pub(crate) provider: VoiceProviderKind,
    pub(crate) token: String,
}

pub(crate) enum VoiceSessionEvent {
    Ready { negotiated_output: AudioFormat },
    InputTranscriptDelta { text: String, final_segment: bool },
    OutputTranscriptDelta { text: String, final_segment: bool },
    AudioOut { bytes: Vec<u8> },
    Interrupted,
    TurnComplete,
    ToolCall {
        call_id: String,
        name: String,
        arguments_json: String,
    },
    ResumeHandle(SessionResumeHandle),
    GoingAway { deadline_ms: Option<i64> },
    Closed { reason: Option<String> },
}

pub(crate) trait VoiceSessionProvider: Send {
    fn open(
        &mut self,
        config: VoiceSessionConfig,
        cancellation: CancellationToken,
    ) -> Result<mpsc::Receiver<Result<VoiceSessionEvent, String>>, String>;
    fn send_audio(&mut self, bytes: &[u8]) -> Result<(), String>;
    fn send_text(&mut self, text: String) -> Result<(), String>;
    fn send_tool_result(&mut self, call_id: String, result_json: String) -> Result<(), String>;
    fn interrupt(&mut self) -> Result<(), String>;
    fn finish_input(&mut self) -> Result<(), String>;
    fn close(&mut self);
}
```

Design decisions, in order of consequence:

1. **Events flow out on one channel; commands flow in through the trait.** This mirrors `AssistantProvider::dispatch` returning an `mpsc::Receiver<Result<_, String>>` and lets `receive_provider_event`-style `tokio::select!` loops in `runtime.rs` consume voice sessions the same way they consume chat streams.
2. **No explicit turn API.** `finish_input` is a *hint* (maps to Gemini `audioStreamEnd`/`turnComplete`, OpenAI `input_audio_buffer.commit` + `response.create` when VAD is off). Providers with server VAD or full duplex ignore it. Duplex providers simply never emit `TurnComplete` between overlapping speech — consumers must treat `TurnComplete` as advisory, not as a state machine gate.
3. **`interrupt` is client-initiated barge-in; `Interrupted` is server-detected barge-in.** For Gemini, `Interrupted` arrives unprompted; for OpenAI Realtime, `interrupt` sends `response.cancel` (+ `conversation.item.truncate` for played-back audio); for duplex models both are near no-ops because the model handles overlap itself.
4. **Resumption is a first-class event, not a method.** Gemini pushes `sessionResumptionUpdate` handles and `goAway` warnings; the handle is stored and passed back in `VoiceSessionConfig::resume`. Providers without resumption never emit `ResumeHandle` and treat `resume: Some(_)` as a fresh session — the caller's reconnect logic (already present as `reconnect_buffer` in `AudioSession`) covers the gap.
5. **Audio is opaque bytes plus a negotiated format.** `Ready { negotiated_output }` tells the playback path the rate (24 kHz for everyone so far), rather than hard-coding it.

## 3. Wire-event mapping

### 3.1 Gemini Live (`BidiGenerateContent`) — launch target

| Direction | Gemini message | Abstraction |
|---|---|---|
| → | `setup` | `open(config)` |
| → | `realtimeInput.audio` (PCM16 16k) | `send_audio` |
| → | `clientContent` / `realtimeInput.text` | `send_text` |
| → | `toolResponse.functionResponses` | `send_tool_result` |
| → | `realtimeInput.audioStreamEnd`, `clientContent.turnComplete` | `finish_input` |
| ← | `setupComplete` | `Ready` (output fixed at PCM16 24k) |
| ← | `serverContent.inputTranscription` | `InputTranscriptDelta` |
| ← | `serverContent.outputTranscription` / model text | `OutputTranscriptDelta` |
| ← | `serverContent.modelTurn` inline audio | `AudioOut` |
| ← | `serverContent.interrupted` | `Interrupted` |
| ← | `serverContent.turnComplete` / `generationComplete` | `TurnComplete` |
| ← | `toolCall.functionCalls[]` | `ToolCall` (one event per call) |
| ← | `sessionResumptionUpdate` | `ResumeHandle` |
| ← | `goAway.timeLeft` | `GoingAway` |
| ← | socket close | `Closed` |

Auth: ephemeral tokens (`VoiceCredential::EphemeralToken`) minted by the Worker, matching the existing pattern where the Worker brokers provider credentials (`worker/src/assistant.ts`).

### 3.2 OpenAI Realtime GA (`gpt-realtime-2.1`)

| Direction | Realtime event | Abstraction |
|---|---|---|
| → | connect + `session.update` (voice, VAD mode, tools, formats) | `open(config)` |
| → | `input_audio_buffer.append` (PCM16 24k) | `send_audio` |
| → | `conversation.item.create` (text) + `response.create` | `send_text` |
| → | `conversation.item.create` (function_call_output) + `response.create` | `send_tool_result` |
| → | `input_audio_buffer.commit` + `response.create` (manual-VAD mode) | `finish_input` |
| → | `response.cancel` + `conversation.item.truncate` | `interrupt` |
| ← | `session.created` / `session.updated` | `Ready` |
| ← | `conversation.item.input_audio_transcription.delta/.completed` | `InputTranscriptDelta` |
| ← | `response.output_audio_transcript.delta` / `.done` | `OutputTranscriptDelta` |
| ← | `response.output_audio.delta` | `AudioOut` |
| ← | `input_audio_buffer.speech_started` (while a response is playing) | `Interrupted` |
| ← | `response.done` | `TurnComplete` |
| ← | `response.function_call_arguments.done` | `ToolCall` |
| ← | *(none — no server resumption)* | never emits `ResumeHandle` |
| ← | `error`, socket close | `Err(String)` / `Closed` |

Semantic vs. server VAD is provider-internal configuration surfaced through `VoiceSessionConfig` extension, not through the trait.

### 3.3 Nemotron NIM (composed adapter)

The adapter is a mini-pipeline inside one `VoiceSessionProvider`: streaming ASR (gRPC, partial/final results → `InputTranscriptDelta`) feeding an `AssistantProvider`-style LLM turn (final ASR segment → `Delta` text → `OutputTranscriptDelta`), whose text streams into the realtime TTS WebSocket (`input_text.append`/`commit` →; `conversation.item.speech.data` → `AudioOut`, `conversation.item.speech.completed` → `TurnComplete`). `interrupt` closes the in-flight TTS turn and drops queued text. Tool calls surface from the LLM layer as `ToolCall`. No resumption; `Closed` on any leg failing. This adapter proves the abstraction does not require a single provider socket.

### 3.4 PersonaPlex / Moshi-style duplex

Continuous 24 kHz audio in both directions: `send_audio` writes the uplink frame stream; downlink frames arrive as `AudioOut` continuously; text tokens (Moshi's inner monologue) map to `OutputTranscriptDelta`. `Interrupted`, `TurnComplete`, `ToolCall`, `ResumeHandle` are never emitted; `interrupt`/`finish_input` are no-ops returning `Ok(())`. Role/voice prompts ride in `system_instruction` and `voice` at `open`.

## 4. GPT-Live-1: unknowns and where the abstraction absorbs them

Known publicly: full-duplex, backchannels, pause-awareness, continues speaking while background work runs; API not yet published (sign-up form only). Unknown: transport (WebRTC vs WebSocket), event names, audio formats, whether turns/VAD are configurable at all, tool-calling shape, session limits, auth.

Absorption points, deliberately built in:

- **Duplex-safety** — because PersonaPlex forces the abstraction to work with zero turn events, GPT-Live-1's duplex behavior is already covered: consumers may never gate playback on `TurnComplete` or `Interrupted`.
- **Transport-agnostic `open`** — the trait exposes no socket; a WebRTC-based adapter (already plausible per the Realtime API precedent) changes nothing upstream.
- **Format negotiation via `Ready`** — if GPT-Live-1 emits 24 kHz opus instead of PCM16, only the adapter and the playback decode path care.
- **Tool calling optional** — if GPT-Live-1 launches without tools (like PersonaPlex), `ToolCall` simply never fires; if it launches with Realtime-style function calls, the `call_id`/`arguments_json`/`send_tool_result` triple matches.
- **Background-task continuation** — the one announced behavior with no current analogue. If it surfaces as a new server event class, it becomes a new `VoiceSessionEvent` variant (the enum is `#[non_exhaustive]`-in-spirit; consumers must have a wildcard arm). This is the only place a GPT-Live-1 adapter may require touching shared code, and it is additive.
- **Auth** — `VoiceCredential` already covers both key and ephemeral-token flows; OpenAI's existing client-secret endpoint makes the ephemeral path the likely one.

## 5. Sources

- [Introducing GPT-Live — OpenAI](https://openai.com/index/introducing-gpt-live/)
- [OpenAI launches GPT-Live-1 (MLQ)](https://mlq.ai/news/openai-launches-gpt-live-1-a-full-duplex-voice-model-that-listens-and-speaks-simultaneously/)
- [OpenAI Realtime guide](https://developers.openai.com/api/docs/guides/realtime) and [client events reference](https://developers.openai.com/api/reference/resources/realtime/client-events)
- [Realtime conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [NVIDIA Speech NIM realtime TTS API](https://docs.nvidia.com/nim/speech/latest/reference/api-references/tts/realtime-tts.html) and [API index](https://docs.nvidia.com/nim/speech/latest/reference/api-references/index.html)
- [Nemotron voice agent blueprint](https://github.com/NVIDIA-AI-Blueprints/nemotron-voice-agent)
- [PersonaPlex — NVIDIA ADLR](https://research.nvidia.com/labs/adlr/personaplex) and [the-decoder coverage](https://the-decoder.com/nvidia-open-sources-personaplex-a-voice-ai-that-listens-and-talks-at-the-same-time/)
- Gemini Live API (`BidiGenerateContent`) — Google AI developer docs (setup/clientContent/realtimeInput/toolResponse; serverContent/toolCall; PCM16 16k in / 24k out; session resumption and `goAway`).
