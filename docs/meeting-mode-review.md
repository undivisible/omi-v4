# Desktop meeting mode: review against two open-source meeting assistants

*Research pass, 2026-07-23. Both reference projects were cloned read-only into a
scratch directory outside this repository and read directly; every claim below
cites a file that was actually opened. Neither project's code was copied into
omi-v4. Both are MIT licensed.*

| Project | What it is | Stack | Read at |
|---|---|---|---|
| [fastrepl/anarlog](https://github.com/fastrepl/anarlog) (Hyprnote) | "Open source Granola AI alternative" — the closest thing to a direct competitor for our note-enhancement flow | Rust + Tauri + TypeScript, ~180 workspace crates | `crates/`, `apps/desktop/` |
| [Zackriya-Solutions/meetily](https://github.com/Zackriya-Solutions/meetily) | Privacy-first, fully local meeting assistant: local Whisper/Parakeet STT, Ollama summarization | Rust + Tauri + Next.js | `frontend/src-tauri/src/`, `BLUETOOTH_PLAYBACK_NOTICE.md` |

---

## 1. What each project does, and how it is built

### 1.1 anarlog / Hyprnote

**Shape.** A very large Cargo workspace (`crates/`, ~180 members) plus a Tauri
plugin layer (`plugins/`) and a TypeScript desktop app (`apps/desktop/`). The
meeting path is split across:

- `crates/audio-actual/` — platform audio sources. `src/speaker/macos.rs`
  builds a CoreAudio process tap (`ca::TapDesc::with_mono_global_tap_excluding_processes`)
  wrapped in a private aggregate device, exactly the same primitive our
  `corti-coreaudio` dependency uses. `src/mic.rs` is the microphone source.
- `crates/audio-actual/src/capture/stream.rs` — joins mic + speaker into a
  `CaptureFrame { raw_mic, raw_speaker, aec_mic }`, running their own echo
  cancellation (an ONNX DTLN model in `crates/aec/`, plus a linear
  residual-echo canceller with double-talk detection, lines 520-652).
- `crates/listener-core/src/actors/` — a `ractor` actor tree: `source` →
  `listener` (transcription) and `recorder` (disk/memory), supervised by
  `session/supervisor.rs`.
- `crates/transcript/` — the transcript model: `ChannelProfile`, per-channel
  word state machines (`channel_state.rs`), speaker labelling (`label.rs`).
- `crates/template-app/assets/*.jinja` — the LLM prompts.
- `crates/detect/src/meeting_ax.rs` — 5,400 lines of macOS Accessibility
  tree-walking to identify the meeting platform, extract participant names,
  and even scrape the in-meeting chat.

**The three ideas that make it good.**

1. **The two capture tracks are never merged.**
   `crates/listener-core/src/actors/source/pipeline.rs:199` (`select_tracks`)
   keeps `mic` and `spk` separate all the way to the transcriber
   (`ListenerMsg::AudioDual`). Speaker identity then falls out for free:
   `crates/transcript/src/label.rs` renders `ChannelProfile::DirectMic` as
   "You" and `RemoteParty` as another speaker, with a `SpeakerLabeler` that
   assigns stable "Speaker N" numbers to unresolved keys.
2. **The audio path survives the transcriber going away.**
   Same `pipeline.rs`: an `AudioBuffer` (150 chunks) holds audio while the
   listener is detached, a `backlog_quota` drains it at 1.25× real time so
   catch-up never floods the socket, and a `ReplayHistory` (5 s) is replayed
   into a *newly attached* listener so a reconnect loses nothing
   (`prepare_listener_refresh`, line 95).
3. **The enhancement prompt is much more opinionated than ours.**
   `crates/template-app/assets/enhance.system.md.jinja` bans generic
   "Overview"/"Introduction"/"Participants" sections, demands at least three
   detailed bullets per section, forbids nesting beyond one level, explicitly
   tells the model that "Notes and transcript may contain errors made by human
   and STT" and to make the best of it, and distinguishes *pre-meeting* notes
   from *during-meeting* notes so the model can tell what the user actually
   captured live. `enhance.user.md.jinja` feeds a speaker-prefixed transcript
   (`_macros.jinja` `transcripts` macro emits `{{ segment.speaker }}: {{ segment.text }}`).

### 1.2 meetily

**Shape.** A Tauri app whose Rust side (`frontend/src-tauri/src/`) is much
flatter: `audio/` (~16k lines) for capture, `whisper_engine/` and
`parakeet_engine/` for local STT, `summary/` for the LLM pipeline, plus
provider modules (`ollama/`, `openai/`, `anthropic/`, `groq/`, `openrouter/`).

**The three ideas that make it good.**

1. **Local-first STT and summarization, with a real provider abstraction.**
   `whisper_engine/` wraps `whisper-rs 0.13.2` with per-platform acceleration
   features (`Cargo.toml:45-53`: metal/coreml on macOS, cuda/vulkan/hipblas
   elsewhere); `parakeet_engine/` runs NVIDIA Parakeet through
   `ort 2.0.0-rc.10`. `summary/llm_client.rs` fronts Ollama and four cloud
   providers behind one interface.
2. **Map-reduce summarization with a template registry.**
   `summary/processor.rs` chunks the transcript on sentence boundaries with
   overlap (`chunk_text`, line 190), summarizes each chunk, combines, then
   fills a *template*. Templates are JSON documents
   (`frontend/src-tauri/templates/standard_meeting.json`, `daily_standup.json`,
   `retrospective.json`, `sales_marketing_client_call.json`,
   `project_sync.json`) with per-section instructions and even a table format
   for action items with an **Owner** column and a transcript-timestamp
   reference. The final system prompt (`build_final_report_system_prompt`,
   line 149) is heavily anti-hallucination: *"Only use information present in
   the source text; do not add or infer anything… If a section has no relevant
   info, write 'None noted in this section.'… If unsure about something, omit
   it."*
3. **Honest, specific audio hardware handling.**
   `audio/device_monitor.rs` polls the device list every 2-5 s, flags
   Bluetooth devices by name heuristic (`airpods`/`bluetooth`/`wireless`) and
   gives them a *longer* disconnect grace period (3 polls vs 2) because they
   drop briefly; it emits `DeviceDisconnected`/`DeviceReconnected` events that
   the recording pipeline acts on. `audio/vad.rs` runs Silero VAD with
   carefully commented, painfully-earned thresholds.

**`BLUETOOTH_PLAYBACK_NOTICE.md`, read in full.** It is worth being precise
about what it says, because it is *not* about capture: it documents that
recordings made at 48 kHz can sound sped-up or chipmunk-like **when played
back through Bluetooth headphones**, because macOS resamples for the BT codec
and gets it wrong; the recorded file is fine. Their stated conclusions:
recording *through* a Bluetooth mic is fine (they resample correctly),
monitoring live is fine, only playback review is affected, and the fix is
"review on speakers or wired headphones", plus an in-app warning when a BT
output device is active.

For us that means: **the notice is not the cause of our capture trouble**, and
copying anything from it would be cargo-culting. The genuinely transferable
part is the neighbouring `device_monitor.rs` behaviour — Bluetooth endpoints
disappear and reappear mid-meeting, and a fixed grace period tuned for wired
devices will end a meeting that has not ended.

---

## 2. Where we already stand

Our meeting mode (`app/native/hub/src/meeting.rs`, `meeting_capture.rs`,
`meeting_detector.rs`; `app/lib/features/meeting_*.dart`) is far smaller than
either project and, in a few places, better factored:

- **Capture uses the same CoreAudio primitive both of them use**, via
  `corti-coreaudio`'s `TapTarget::Global` + `OutputLayout::TwoTrack`, and the
  crate already gives us `ch0 = mic ("me")`, `ch1 = tap ("them")`.
- **The meeting is a state machine, not a recording session.**
  `MeetingGate` (`meeting_detector.rs:16`) has an 8 s off-grace period so a
  momentary detection miss does not end the meeting; `BrowserGate` backs the
  poll off from 4 s to 15 s when nothing is happening. Neither reference has
  an equivalent power-aware backoff.
- **Recovery is already wired end-to-end.** `meeting_capture_session_lost`
  → `AppServices._handleMeetingEvent` (`app_services.dart:1266`) →
  `_provideMeetingAuth()` → `CaptureSlot::provide` → `sync` restarts capture.
  `meeting_system_audio_unavailable` → mic-only fallback. Our `stt.rs`
  `recover()` already does bounded reconnect with a `TranscriptGap` signal —
  a stronger correctness story than either reference, which mostly just
  reconnects.
- **We are honest about jots.** The Granola-style "expand my rough bullets"
  loop is genuinely equivalent to anarlog's.

And where they are plainly better:

- **We threw away the speaker split.** `mix_two_track_to_mono` averaged
  `ch0` and `ch1` into one channel, so every downstream consumer — the live
  panel, the transcript, the note prompt, the action-item owners — had no idea
  who was talking. anarlog gets this for free from the same audio we already
  had.
- **Our enhancement prompt was thin.** Six lines of JSON schema and one
  sentence about jots, against anarlog's 45-line system prompt and meetily's
  explicit anti-hallucination rules.
- **Our detection list was narrow.** Seven browsers, three title keywords, no
  Slack huddles, no Discord, no Zoom-in-browser.
- **We had no failure signal for a silent far end.** A tap that runs but
  carries no remote audio looked identical to a working meeting.
- **No local STT, no local summarization.** meetily runs entirely offline;
  we require Deepgram.

---

## 3. Ranked adoption list

Ranked by (value to a real meeting) ÷ (risk + cost). "Adopted" items are in
this branch; see §4 for what they touch.

### Rank 1 — Speaker attribution from the two capture tracks — **adopted**

*Source:* anarlog `crates/transcript/src/label.rs`,
`crates/listener-core/src/actors/source/pipeline.rs:199`.

**Benefit:** the single largest quality jump available to us. Attribution
turns "we agreed to ship Friday" into "*Them:* we agreed to ship Friday",
which (a) makes the live panel readable, (b) lets the note model assign action
item owners, (c) lets it distinguish what the user committed to from what was
asked of them.

**Cost:** low, *if* we do not change the audio we send. anarlog sends both
channels to the transcriber; we cannot, because our managed transcription
endpoint is provisioned server-side with fixed channel parameters
(`stt.rs:148` `managed_endpoint` rejects any endpoint carrying a query
string, so the client cannot request `multichannel`). Sending two-channel
audio to a session negotiated for one would corrupt every managed meeting.

**What we did instead:** measure both tracks where we already decode them and
compare their short-term energy. `mix_two_track_to_mono_measured` returns the
identical mono stream plus per-track mean-square energy; a decaying
`SpeakerTracker` names the dominant side; `observe_final_segment` samples it
when a segment finalizes. The mono audio sent to Deepgram is byte-for-byte
what it was before, so nothing about the provider contract, the AEC
behaviour, or the mic-only fallback changes.

**Fit:** good. It is the same information anarlog uses, derived rather than
transported, and it degrades to today's behaviour (`Unknown` → no prefix)
whenever the two tracks are ambiguous or absent.

**Honest limitation:** this is *channel* attribution, not diarization. Three
people on the far end are all "Them". See rank 8.

### Rank 2 — A much stronger enhancement prompt — **adopted**

*Source:* anarlog `enhance.system.md.jinja` (structure rules), meetily
`summary/processor.rs:149` (grounding rules) and
`templates/standard_meeting.json` (action owners).

**Benefit:** high, and free at runtime. Both references have clearly spent
real iterations here and we had not.

**Cost:** near zero — prompt text plus a slightly richer JSON schema.

**Adopted:** grounding ("never infer, never invent a name, a date, or a
number… if you are unsure, leave it out"), an explicit statement that the
transcript is STT output and the jots are typed in a hurry, the speaker-prefix
convention, a ban on generic Overview/Introduction/Participants sections, a
two-bullet minimum per section, "weave jots into the section they belong to
rather than making them headings", and "leave arrays empty rather than
padding". Schema gains structured `actions` with an `owner` and a new
`openQuestions` list.

**Deliberately not adopted:** anarlog's *pre-meeting vs during-meeting* note
split. It is a good idea, but it presumes a note document that exists before
the meeting starts; our jots only exist during. Revisit if we add calendar-
linked agendas.

### Rank 3 — A silent-far-end advisory — **adopted (our own, prompted by their audio work)**

Neither project has exactly this; it is the failure mode their audio code is
full of workarounds for. `FarEndWatch` accumulates 25 s of audio and, if the
local track is clearly active while the remote track has been digital silence
throughout, raises `meeting_far_end_silent` once. The assist panel shows a
one-line warning.

**Benefit:** high. Today a meeting where the tap sees nothing produces a
plausible-looking one-sided transcript and a confidently wrong summary.
**Cost:** ~40 lines and one advisory error code. **Fit:** clean — it rides
the same `NativeError` channel the other capture advisories use.

### Rank 4 — Wider meeting detection — **adopted**

*Source:* anarlog `crates/detect/src/meeting_ax.rs:36` (`MEETING_APP_BUNDLES`).

Their bundle list covers Slack, Discord, Webex, and 20+ browsers including
Arc, Dia, Vivaldi, Comet, Helium and Opera GX. We added Slack/Discord/Webex
as microphone-owning call apps (a Slack huddle *is* a meeting), the missing
browsers to both the name list and the `pgrep` pattern, and title keywords for
Zoom-in-browser (`zoom.us/j/`, `zoom.us/wc/`), Jitsi, Whereby, Gather,
BlueJeans, Livestorm and Slack huddles.

**Cost:** trivial. **Risk:** the only real risk is a false positive arming
capture, so the browser keywords stay shaped like join URLs or
in-call-only titles — "Pricing — Zoom" still does not trigger, and there is a
test for it.

### Rank 5 — Bluetooth-aware device grace periods — **deferred, small**

*Source:* meetily `audio/device_monitor.rs:60`.

Their insight — a Bluetooth endpoint that vanishes for 5 s has not been
unplugged — is real and cheap. It does not fit *yet* because we have no device
monitor at all: our capture is a global tap, not a named device, so there is
no device identity to watch. Wiring one is a genuine feature (a CoreAudio
device-list listener plus routing the events into `MeetingGate`), not a
one-line change, and today's 8 s `MeetingGate` off-grace already absorbs most
of the same transients. Worth doing when we add explicit input-device
selection.

### Rank 6 — Backlog buffering and replay across a transcriber reconnect — **deferred, medium**

*Source:* anarlog `pipeline.rs:39-215` (`AudioBuffer`, `backlog_quota`,
`ReplayHistory`).

**Benefit:** real but narrower than it looks for us. Our `stt.rs recover()`
already reconnects with backoff and emits an explicit `TranscriptGap` so the
gap is *recorded* rather than silently swallowed — which is arguably more
honest than anarlog's replay, and matters more for a memory system than for a
notes app. What we would gain is 3-5 s of otherwise-lost speech per reconnect.

**Cost:** medium-high. `SttHandle::send_audio` currently rejects above a
64 KiB pending ceiling (`stt.rs:27`); adding replay means a second, larger
ring in the capture thread, a rate-limited drain, and careful interaction with
the managed session's non-reconnectable path. It also changes the meaning of
`TranscriptGap`. Not worth doing in the same change as speaker attribution.

### Rank 7 — Note templates — **deferred, medium**

*Source:* meetily `frontend/src-tauri/templates/*.json` +
`summary/templates/loader.rs`; anarlog's `template_numbered` macro.

A registry of named note shapes (standup, retro, client call, 1:1) with
per-section instructions is a good product feature and both projects have it.
It needs UI (picking a template, editing one), persistence, and a template
resolution step before the prompt — a feature, not a refinement. What we
*did* take from it now is the shape of the sections themselves: owners on
action items, and an "open questions" list.

### Rank 8 — Real speaker diarization — **deferred, large**

*Source:* anarlog `crates/pyannote-local` (ONNX pyannote segmentation +
embeddings via `hypr-onnx`, `knf-rs` for features, `simsimd` for cosine
similarity) and `crates/segmentation`. meetily's README markets diarization
but ships it in their paid PRO tier, not in this MIT repository — worth
knowing before anyone cites them as prior art for it.

Rank 1 gives us You/Them for free. Going beyond that means per-speaker
embeddings and clustering on the remote track, which is an ONNX runtime, two
model files (~6 MB segmentation + ~17 MB embedding), a clustering pass, and a
speaker-naming UI. Note that Deepgram already returns `speaker` indices when
`diarize=true` — which our BYOK path already requests (`stt.rs:102`) and then
discards, because `DeepgramWord` only deserializes `start`/`end`. **The
cheapest next step by far is to parse `speaker` and `channel_index` out of the
Deepgram words we already receive** and combine that with our track
attribution; that is a follow-up, not this change.

### Rank 9 — Local STT (Whisper / Parakeet) — **deferred; plan in §5**

### Rank 10 — Local LLM summarization via Ollama — **deferred; plan in §5**

### Not adopted: accessibility-tree meeting introspection

anarlog's `meeting_ax.rs` extracts participant names, platform, and in-meeting
chat by walking the macOS AX tree (`MAX_TREE_DEPTH: 18`, `MAX_NODES: 1800`).
The participant list it produces is what makes their `participants` prompt
field trustworthy. It is also 5,400 lines of per-platform, per-version
scraping that breaks whenever Zoom reflows a panel, and it demands the
Accessibility permission for a capability the user did not ask for. Our
`participants` field stays "names actually mentioned in the transcript".
Revisit only if participant naming becomes a headline feature.

### Not adopted: their AEC

anarlog runs a DTLN ONNX echo canceller plus a linear residual canceller
(`crates/aec/`, `capture/stream.rs:520-652`). We fixed our echo loop by
enabling the macOS voice-processing AEC on the microphone, which is the
platform's own implementation and costs us no model, no ONNX runtime, and no
tuning. Nothing in this change touches the microphone configuration; the
speaker tracker only *reads* the decoded tracks, and it in fact benefits from
AEC being on (a clean `ch0` makes the energy comparison sharper). Their work
is worth revisiting only if we ever need to run on a platform without a
system AEC.

---

## 4. What changed in this branch

| Area | File | Change |
|---|---|---|
| Capture | `app/native/hub/src/meeting_capture.rs` | `MeetingSpeaker`, `TrackEnergy`, `mix_two_track_to_mono_measured`, `SpeakerTracker` (+ process-global accessor), `FarEndWatch`; capture loop feeds both. The mono PCM sent to the provider is unchanged. |
| Session | `app/native/hub/src/meeting.rs` | `push_final` takes a speaker and renders labelled, merged turns; `ActionItem { text, owner }`; `open_questions`; rewritten `note_prompt`; markdown and metadata render owners and open questions. |
| Signals | `app/native/hub/src/signals.rs` | New `MeetingTranscriptTurn` event; `MeetingInsight.speaker`. Regenerated with `app/tool/generate_rinf_bindings.sh`. |
| Detection | `app/native/hub/src/meeting_detector.rs` | Wider native-call bundle list, browser list, `pgrep` pattern and call-window keywords. |
| Panel | `app/lib/features/meeting_assist_panel.dart` | Highlights render `MeetingTranscriptTurn` with a speaker prefix; insights show `KIND · Speaker`; a far-end-silent warning row. |

Tests: 7 new Rust unit tests in `meeting_capture.rs`, 5 new/updated in
`meeting.rs`, 3 new in `meeting_detector.rs`; 2 new Flutter widget tests in
`app/test/features/meeting_assist_panel_test.dart`.

---

## 5. Adoption plans for the heavy items

### 5.1 Local STT (Whisper or Parakeet)

**Why it is not half-implemented here.** A local STT engine is a model
downloader, a model store, a compute-backend selection matrix, a streaming
chunker with VAD, and a second transcription lifecycle. Both references needed
thousands of lines for it (meetily: `whisper_engine/` + `parakeet_engine/` +
`audio/vad.rs`; anarlog: `crates/whisper-local`, `local-stt-core`,
`local-stt-server`, `owhisper-client`, `vad`, `audio-chunking`). Shipping a
fraction of that would be worse than not shipping it.

**How it would slot in.** We already have the seam:
`TranscriptionAuth::Local` exists in `signals.rs` and today returns
`SttError::Unavailable` from `ConnectionPlan::from_auth` (`stt.rs:113`). That
is exactly where a local engine attaches — the same place `chat_router.rs`
routes ordinary chat to on-device Apple Foundation Models before falling back
online. The parallel is direct: `local_ai::is_available()` gates the chat
route; a `local_stt::is_available()` would gate the transcription route, with
Deepgram as the fallback rather than the default.

Concretely:

1. **Engine.** `whisper-rs` (MIT, wraps whisper.cpp/MIT) with the `coreml`
   and `metal` features on macOS — the same choice both references made
   (`meetily/frontend/src-tauri/Cargo.toml:178`,
   `anarlog/crates/whisper-local/Cargo.toml`). Parakeet via `ort` is faster
   but drags in ONNX Runtime and is English-only; Whisper large-v3-turbo is
   the better first target for a multilingual product.
2. **Models.** `ggml-large-v3-turbo-q5_0` ≈ 550 MB, `ggml-small` ≈ 466 MB,
   `ggml-base` ≈ 142 MB. Models are MIT (whisper.cpp conversions of OpenAI
   Whisper, MIT). They must be **downloaded on first use, not bundled** — a
   500 MB app is not shippable — which means a download manager with resume,
   checksum verification, and a cache under Application Support. anarlog has a
   whole crate for this (`crates/model-downloader`).
3. **Chunking.** Whisper is not streaming. Both references solve this with
   VAD-delimited chunks: Silero VAD (MIT) via `silero-rs` in meetily
   (`audio/vad.rs`), or `earshot`/Silero-ONNX in anarlog (`crates/vad`), then
   speech-segment chunking with merge/redemption policy
   (`crates/audio-chunking/src/vad/chunk_policy.rs`). Budget a `local_stt.rs`
   plus a `vad.rs` in the hub, both feeding the existing
   `crate::meeting::observe_final_segment` path so nothing downstream changes.
4. **Where it lives.** A new `app/native/hub/src/local_stt.rs` behind a
   Cargo feature, called from `stt::spawn` when
   `matches!(auth, TranscriptionAuth::Local)`. `SttHandle` keeps its shape
   (`send_audio` / `finish` / `cancel`), so `meeting_capture.rs` and
   `transcription.rs` are untouched. `TranscriptDelta` already carries a
   `provider` field for attribution.
5. **Size and licensing.** `whisper-rs` MIT, whisper.cpp MIT, Silero VAD MIT,
   models MIT. No telemetry in any of them. Binary cost: whisper.cpp with
   Metal + CoreML adds roughly 3-6 MB to the hub dylib; the models are
   out-of-band. Build cost is the real tax — whisper.cpp is a C++ build that
   will slow every clean `cargo build` and complicate the macOS bundle.
6. **Sequencing.** Do rank 8's cheap half first (parse Deepgram's existing
   `speaker`/`channel_index`), then local STT behind a feature flag with a
   settings toggle, defaulting off, and only flip the default once accuracy
   has been measured against Deepgram on real meeting audio.

### 5.2 Local LLM summarization via Ollama

**How it would slot in.** `generate_note_output` in `meeting.rs:984` is
already a two-step provider chain: `local_ai::respond` (Apple Foundation
Models, via `chat_router.rs`) then `dev_gemini::generate`. Ollama becomes a
third arm of that chain, not a new architecture.

**Why it is deferred.** Apple Foundation Models already give us on-device
summarization on the hardware we target, with no install step, no 4-8 GB
download, and no separate server process. Ollama's advantage over that is
model choice and non-Apple platforms — real, but not urgent. Concretely it
would be:

1. A `local_llm.rs` speaking Ollama's `/api/generate` over `reqwest` to
   `http://127.0.0.1:11434` (no new dependency; the hub already uses
   `reqwest`). meetily's `summary/llm_client.rs` is the reference shape.
2. Detection: a `GET /api/tags` probe with a short timeout, cached, plus a
   settings field for the endpoint and model. Never auto-install Ollama.
3. Chunking for small context windows: meetily's `chunk_text` +
   chunk-summarize + combine + template-fill (`summary/processor.rs:190-510`)
   is the right pattern, and our `SUMMARY_TRANSCRIPT_CHARS = 12_000` truncation
   is the thing it would replace. This is the part with real value even for
   the *cloud* path: today a three-hour meeting silently loses everything past
   12k characters.
4. Licensing: Ollama itself is MIT and runs as a separate user-installed
   process, so nothing is vendored; model licences (Llama, Gemma, Qwen) vary
   and are the user's choice, which is the right place for that decision to
   live.

**The one piece worth pulling forward regardless of Ollama:** map-reduce
chunking of long transcripts, because it fixes a real truncation bug we have
today on any provider.
