# Omi v4 living plan

Updated: 2026-07-21
Status: architecture locked; v0 implementation and platform validation in progress

## Product

Omi v4 is an ultrasimple thinking partner and second brain that works across every device. It remembers what the user saw, said, and did; works with Omi hardware; surfaces what matters next; learns from outcomes; and performs approved actions.

## Locked decisions

| Area | Decision |
| --- | --- |
| Application | Flutter for iOS, Android, macOS, Windows, and web; no desktop WebView |
| Rust bridge | Rinf typed asynchronous signals; binary signals for bounded audio frames |
| Live STT | Rust owns bounded transcription sessions; Deepgram is the managed/BYOK live route, local STT fails closed until a real provider exists, and MiMo remains batch-only |
| Rust runtime | One `hub` crate using `rx4`, `rs_ai`, and platform-gated `rs_peekaboo` |
| Device ownership | Mobile owns BLE, background hardware relay, firmware, pairing, and device management; desktop owns primary assistant interaction and computer use |
| Cloud | Bun/TypeScript Hono Worker, D1, R2, Queues, Workflows, Durable Objects where state coordination requires them |
| Identity | Firebase Auth remains; phone OTP is primary, Google/Apple OAuth optional, Firebase UID is the initial canonical user ID |
| Data | New SaaS data goes to D1; no Firestore/D1 dual-write; import upstream Firestore data only through explicit jobs |
| Memory | Personal Memory and Recommendation Memory remain separate domains |
| Billing | Stripe webhook state controls two plans tied to Firebase UID |
| UI reference | `omi-v3` main provides functional behavior; `codex/onboarding-web-demo` provides gradient and profile-conversation visuals only |

## Product surfaces

| Surface | First release responsibility |
| --- | --- |
| Mobile | Omi hardware relay, pairing, firmware, connection health, capture status, and device management |
| Desktop | Primary assistant, memory/Currents, chat, screen context, local computer use, both-Shift voice/input gesture |
| Web | Signed portal for memory, Currents, account, connections, and billing |
| Public site | Product explanation, pricing, download/sign-in; initially a public route in the Flutter web build |
| Channels | Telegram and Blooio/iMessage are primary conversational portals into the same desktop chat and agent session |

## Minimal repository

```text
omi-v4/
  app/                 Flutter application and web portal
  app/native/hub/      Rinf Rust hub
  worker/              Bun/Hono Cloudflare API
  PLAN.md              this living plan
```

Do not create separate packages for memory, Currents, channels, or providers until a file has more than one independent owner.

The reusable memory engine lives in the public [`tschk/zkr`](https://github.com/tschk/zkr) repository. Omi v4 consumes it through the Rinf hub; scheduling, channel delivery, Currents, and nightly workflow orchestration remain in Omi v4.

## Active build checklist

- [x] Verify the `zkr` evidence, temporal-claim, profile, review, and retrieval core.
- [ ] Verify the Flutter gradient shell and every onboarding, navigation, and product surface on target platforms.
- [x] Verify the Bun/Hono Worker contracts, D1 schema, auth boundary, and channel webhook boundaries.
- [x] Complete production Dart consumption of generated Rinf signals and published `zkr` memory storage/search.
- [x] Implement Worker D1 persistence, Stripe entitlement, Telegram linking/ingestion, and Blooio linking/ingestion with fail-closed signatures.
- [x] Connect the durable Telegram/Blooio inbox and app/web chat to one Firebase-UID-scoped conversation transport with ordered replay cursors and idempotent client messages.
- [x] Implement the first evidence-backed Current end to end: cited candidate generation, deterministic ranking, feedback, approved action handoff, and outcome learning.
- [ ] Connect channel messages to a live desktop agent session, prove outbound delivery with real credentials, and add an offline retry queue.
- [ ] Finish desktop both-Shift voice capture; native macOS/Windows key events and the shared gesture state machine exist, but the microphone path and physical Windows proof do not.
- [x] Complete the audited live-STT slice between bounded Omi BLE/Rinf audio and idempotent final-transcript `zkr` capture, including managed/BYOK provider routing, reconnect gaps, final drain, cancellation, and typed stop acknowledgements.
- [ ] Re-prove Android, iOS without signing, macOS, Windows, and web release builds on the exact release head after this integration lands.
- [ ] Wire Firebase Auth, real channel delivery, physical Omi hardware, desktop permissions/computer use, and model routes against real credentials and devices.

## Initial modules

| File | Owns | Reuses |
| --- | --- | --- |
| `app/lib/memory/` and `app/lib/features/memory_screen.dart` | Personal Memory state and screens | upstream Omi domain language and source evidence |
| `app/lib/currents/` and `app/lib/features/currents_screen.dart` | Recommendation state, ranking display, feedback | `omi-v3/app/src/lib/home-cards.ts` behavior |
| `app/lib/device/` and `app/lib/features/device_screen.dart` | Omi pairing, BLE/audio status, phone capture | upstream Flutter device and capture services |
| `app/native/hub/src/lib.rs` | Rinf signals, `rx4`, `rs_ai`, computer-use orchestration | `rotary` and `rs_peekaboo` crates; no fork |
| `worker/src/index.ts` | Authenticated API, D1 memory, channels, plans, managed inference | `omi-v3/desktop/cloud-api` |

## Rinf boundary

Flutter owns UI, navigation, Firebase, secure storage, notifications, permissions, BLE, microphone, background lifecycle, and global keyboard adapters.

Rust owns assistant sessions, provider routing, memory extraction contracts, proactive ranking, skill review, action policy, computer-use invocation, and streaming orchestration.

| Direction | Signals |
| --- | --- |
| Dart to Rust | send message, capture event, start transcription metadata/config, bounded audio chunk, approval decision, device state, stop/cancel |
| Rust to Dart | sourced transcript delta, assistant delta, Current update, action proposal, tool progress, error, runtime status |

Native builds link the full hub. Web builds use the same signal schema but compile a wasm-safe hub subset and route inference, memory, and actions to the Worker. `rs_peekaboo` compiles only for macOS, Windows, and Linux desktop targets; iOS, Android, and web never link or initialize it.

## Onboarding

1. Sign in with phone OTP, Google, or Apple; explain Firebase's authentication disclosure separately from memory and AI processing consent.
2. Ask three conversational questions: identity, current priorities, and what the user wants Omi to notice or help with.
3. Require each platform's applicable core desktop capabilities, then scan and show editable “what I understand about you” evidence.
4. Teach voice by asking the user to say “What are my tasks?” and render the real tasks returned by the assistant.
5. Continue into the main screen with setup tasks for Calendar, Reminders, Contacts, Location, Telegram, Blooio, Notion, providers, and Omi hardware.

Use upstream Flutter's mature consent, name, language, permission, knowledge-graph, and device flows. Use `omi-v3`'s gradient profile conversation as presentation, not application code.

Production memory, screen, audio, AI, and channel processing requires a durable, versioned consent receipt bound to the current Firebase UID and exact enabled scopes. Authentication alone grants no processing authority. Revocation removes local authority before asynchronous provider sign-out, and an account change invalidates a receipt issued to another UID.

## Desktop capabilities

Model native access as typed states: `unsupported`, `notApplicable`, `unknown`, `notDetermined`, `denied`, `requiresSettings`, `requiresSelection`, `limited`, and `granted`. Onboarding blocks only when a capability is required on the current platform and has not reached an acceptable state.

| Capability | macOS direct distribution | Windows | Product reason |
| --- | --- | --- | --- |
| Accessibility | Required TCC grant | UI Automation is limited by process integrity; no equivalent grant | Read interface structure and perform approved computer-use actions |
| Microphone | Required TCC grant | Require the applicable privacy/capture path | Voice assistant and meeting/capture input |
| Screen capture | Required TCC grant | Require a window/display selection for each capture session | Screen context, visual memory, and action grounding |
| Broad file access | Require concrete-root access and guide Full Disk Access | Report actual ACL scope as limited; no equivalent grant | File and workspace discovery for the second brain |

The macOS v0 is notarized direct distribution without App Sandbox because broad workspace discovery conflicts with sandbox scope. Windows remains `asInvoker`; do not request elevation or `uiAccess` merely to satisfy onboarding.

Windows computer use is a first-class `rs_peekaboo` path: it must inspect UI Automation targets and execute policy-approved pointer clicks and keyboard text entry. Process-integrity boundaries may prevent control of elevated applications, but Windows itself is not a read-only or unsupported target.

Calendar, Reminders, Contacts, and Location remain prominent post-onboarding setup tasks. Camera and Photos are omitted until a concrete feature needs them.

## Personal Memory

`source -> short_term -> long_term -> archive`

- Conversations, screen observations, messages, files, and captures remain source records.
- Every memory has evidence; source deletion retracts unsupported derived facts.
- D1 is authoritative; search and graph indexes are rebuildable projections.
- Users can inspect, correct, pin, archive, export, and delete memory.
- A small mobile WAL protects unsynced recordings from data loss; this is reliability, not local-first authority.

### Memory views

| View | Role |
| --- | --- |
| Episodes/Sources | Append-only ground truth with channel, time, subject, sensitivity, consent, and tombstone state |
| Temporal claims | Evidenced subject/predicate/object facts with confidence and validity windows; superseded history remains queryable |
| Hot profile | Small bounded stable/current summary used frequently in prompts and directly editable by the user |
| Retrieval pack | Bounded hybrid semantic, keyword, entity, graph, and time results with citations and explicit gaps |
| Skills | Inspectable procedural knowledge learned from repeated successful outcomes, separate from facts and preferences |

Use upstream Omi's unified Short-term/Long-term/Archive lifecycle, evidence, deterministic operations, commits, transactional outbox, conflict review, and deletion propagation. Add Graphiti-style temporal validity, Hindsight-style evidence-backed reflection, Hermes-style bounded hot context, and Supermemory-style stable/current profile separation. Do not adopt a second vendor memory authority.

Use `rs_gbrain` only as a pattern for SQLite/FTS5, explicit typed edges, an injected Embedder, hybrid ranking, bounded graph traversal, and retrieval packs. Do not copy its hash embedder defaults, O(n) vector scan as a cloud design, heuristic relationship inference, incomplete tenancy, MCP boundary, or templated dream behavior.

### Daily Review

The nightly cycle creates one editable, idempotent Daily Review per Person, local date, and input revision.

1. Select that day's conversations, screen observations, messages, tasks, actions, and evidence.
2. Write a cited text overview covering events, decisions, progress, unfinished commitments, people, and projects.
3. Emit separate candidate temporal claims, profile changes, task follow-ups, expiry suggestions, and procedural lessons.
4. Validate, deduplicate, and route candidates through their normal domain lifecycles; never treat the review itself as Long-term Personal Memory.
5. Save the review even when no memory promotion occurs; source deletion regenerates or retracts affected text and citations.

## Recommendation Memory and Currents

`candidate -> surfaced -> accepted | snoozed | dismissed -> completed | expired`

- A Current includes evidence, reason, timing, confidence, and one proposed next step.
- Feedback changes future ranking without rewriting Personal Memory.
- Accepted actions create an execution record and require approval at the action boundary.
- `rx4` extraction/ranking is reused before adding another recommendation engine.
- Hermes-style background review proposes skills and preference updates; the user can inspect or disable them.

## Hardware and capture

| Capability | v0 implementation |
| --- | --- |
| Omi BLE/audio | Reuse upstream Flutter iOS/Android protocol, transports, and 3-byte audio framing |
| Phone microphone | Reuse upstream native phone-mic bridges and Flutter capture lifecycle |
| Streaming STT | Deepgram for live multilingual transcription; local STT is deferred until a real provider is integrated |
| Managed batch STT | MiMo `mimo-v2.5-asr` for compatible Omi AI recordings |
| Desktop/web | Control and observe a linked mobile capture session; desktop microphone can use platform plugins, browser capture remains foreground-only |

Do not rewrite the proven BLE and microphone bridges through Rinf during v0. Rinf carries their state and bounded audio events into Rust only where Rust processing is useful.

### Minimal live-STT architecture

Flutter sends `StartTranscription` before the first binary audio chunk with the stable audio stream ID, device/source ID, negotiated format, requested BCP-47 language or `multi`, and the selected `managed`, `byok`, or `local` route. Rust owns the bounded session, decoding, provider connection, final drain, cancellation, and transcript emission; Flutter continues to own BLE and platform capture lifecycle.

- Managed sessions use an authenticated, entitled Worker session or proxy. Managed provider credentials never ship to the client.
- Managed chat uses the OpenAI-compatible streaming contract at `/v1/chat/completions`. `rs_ai` emits `stream_options.include_usage: true`; the Worker applies its bounded default when `max_tokens` is absent and rejects requests above its output-token ceiling.
- BYOK credentials are loaded from platform secure storage, passed once to the native session, and never placed in preferences, URLs, logs, events, or durable storage. Local STT currently fails closed before accepting audio.
- Deepgram Nova-3 is the first live multilingual route. `multi` means provider auto-detection; unsupported explicit languages fail with a typed error and may fall back only to a route that declares support. MiMo ASR remains recorded/batch-only.
- Provider connections use keepalive, bounded 250/500/1000 ms BYOK retries, and cancellation on EOS, consent revocation, or authority change. During reconnect, the 64 KiB audio queue remains bounded; disconnected audio that cannot be retained is rejected with an explicit source gap. Never replay already-sent unacknowledged audio; increment the STT epoch when the provider connection changes.
- A transcript segment keeps the audio stream ID, deterministic segment ID, immutable logical segment sequence across reconnects, STT epoch, device/source ID, provider, language, audio-derived start/end time, text, and final flag. Revisions reuse the segment identity; only final segments enter `zkr`, keyed by Firebase UID, stream, and logical segment sequence.

## Desktop both-Shift gesture

The gesture is the chord of both physical Shift keys, not one Shift key.

| Gesture | Result |
| --- | --- |
| Press and release both Shift keys quickly | Open/focus the floating text input |
| Hold both for the configured threshold | Start voice capture and show live listening state |
| Release after voice starts | Continue hands-free capture rather than stopping |
| Press the chord again or activate stop | Stop capture and submit the utterance |
| Escape | Cancel capture and discard the unsent utterance |

Flutter owns the shared state machine. Small native keyboard adapters report physical left/right Shift down/up events on macOS and Windows. The threshold remains configurable because keyboard hardware and accessibility timing vary. The gesture is desktop-only and disabled while secure input is active.

## Channels and identity

| Channel | Account mapping |
| --- | --- |
| Application | Firebase UID from phone OTP, Google, or Apple |
| Telegram | Bot sends a short-lived link code; Worker binds Telegram user/chat IDs to Firebase UID |
| Blooio | E.164 number and Blooio chat identity bind to Firebase UID after an authenticated link flow |

Both adapters normalize inbound messages into the same desktop conversation and agent session. A user can ask from iMessage or Telegram for a computer-use action; the desktop agent plans and executes it under the remote-action approval policy. Webhooks verify provider authenticity, deduplicate event IDs, reject unlinked senders, and store delivery state. Blooio initially uses its unified HTTP API for iMessage/SMS/RCS/WhatsApp; advanced number management is not required for v0.

## Task authority and approvals

- The user authorizes a task once; the agent may take actions allowed by the current policy until that task finishes, expires, or is cancelled.
- The agent asks when it is stuck, instructions conflict, intent is ambiguous, or the next action exceeds the task's capability lease.
- Each lease is bound to task ID, capability/effect, resource scope, and expiry; it cannot silently become a persistent permission.
- Financial, destructive, account, credential, privacy, and authority-expanding changes remain separate policy boundaries configured by the owner.
- Every action and approval is auditable and can be cancelled from desktop, web, Telegram, or Blooio.

## Chat-controlled application

The user can navigate, connect services, change preferences, manage memory, control devices, and adjust agent autonomy by asking in chat. Chat and Settings call the same typed control service.

`change_settings` accepts a typed patch with an expected revision and a `task`, `session`, or `persistent` duration. Deterministic code validates allowed keys, types, ranges, risk class, restart requirements, and concurrent changes, then returns the exact diff and effective policy.

A model may translate “make AI approvals auto approve” into a proposed patch. A local model is not the authorization authority. Any change that expands the agent's control requires owner confirmation under the policy that existed before the change; the new policy cannot approve itself. Operating-system permissions still use the operating-system UI.

## Tool context and execution

Keep only a small control plane in every model request:

| Always loaded | Purpose |
| --- | --- |
| `search_tools` / `load_tools` | Discover only currently permitted capabilities, then load selected full schemas |
| `get_settings` / `change_settings` | Read or propose typed configuration changes |
| `request_user_input` / `request_approval` | Resolve ambiguity, conflicts, blocks, and scope expansion |
| `task_status` / `cancel_task` | Inspect or stop the active task |
| `memory_search` | Retrieve bounded personal context with evidence |

MCP, integration, and computer-use schemas are deferred. Search returns compact names, summaries, and effects; full schemas load only for selected tools and unload after the task. The catalog contains only tools already eligible under global, user, channel, task, and platform policy. Denied tools are not discoverable.

Use direct typed tool calls for one atomic read or mutation. Use sandboxed programmatic tool calling for three or more dependent operations, loops, joins, filtering, aggregation, or large intermediate results. Generated code can call only broker-exposed typed tools; every consequential effect still passes through the same policy, validation, idempotency, and audit boundary.

Compaction preserves unresolved user constraints, task leases, policy/approval receipts, and tool call/result pairing. Large artifacts and audit records stay outside the prompt behind stable handles and are retrieved on demand.

### Model delegation boundary

The primary assistant remains the conversational and planning authority. A small local model may receive a bounded request, compact settings schema, selected retrieval pack, and only low-risk eligible tools. It is useful for intent classification, typed settings-patch proposals, extraction, summarization, ranking, and simple reversible actions. It never receives ambient credentials or authority to expand policy.

Use a same-model subagent only when the task needs independent deep reasoning or a separate long context. Do not spend a full-model subagent turn on deterministic settings changes or one-tool operations.

## Models and cost policy

### Omi plan — no managed inference

- Cross-device memory, hardware, Currents, chat shell, and channel linking.
- Local models plus user-owned BYOK credentials.
- Provider OAuth only where the provider explicitly permits third-party product use.
- Omi does not pay the user's inference bill.

### Omi AI plan

- Everything in Omi plus managed model and transcription quotas.
- MiMo `mimo-v2.5`, `mimo-v2.5-pro`, and compatible `mimo-v2.5-asr` routes.
- Hosted scheduled work and higher channel/action limits.
- Stripe webhook entitlement is checked on every managed route.
- Managed `mimo-v2.5-pro` planning uses Xiaomi's official overseas pay-as-you-go price published at https://platform.xiaomimimo.com/docs/en-US/price/pay-as-you-go and verified 2026-07-21: USD $0.435 per million uncached input tokens and $0.87 per million output tokens. Worker micro-USD price variables remain configurable and fail closed when missing, non-integral, or non-positive.
- Managed Deepgram Nova-3 reservations use a conservative USD $0.01 per minute ceiling. [Deepgram's official pricing](https://deepgram.com/pricing) was verified 2026-07-21 at $0.0077 per minute for monolingual and $0.0092 per minute for multilingual pay-as-you-go transcription; the Worker rounds above both rates and fails closed on an invalid price.
- Admission estimates use cache-miss input pricing, the requested output ceiling, UTF-8 content and role bytes, plus fixed per-request and per-message framing reserves. Actual provider usage atomically settles the rolling reservation, including overruns; missing usage retains the conservative reserve and stale requests are reconciled after crashes.

### Routing

| Task | Default route |
| --- | --- |
| Fast extraction/ranking | local or BYOK fast tier; managed `mimo-v2.5` for Omi AI |
| Deep planning | user-selected model; managed `mimo-v2.5-pro` for Omi AI |
| xAI chat | `grok-4.5` or authenticated catalog choice through supported xAI credentials |
| xAI voice | `grok-voice-latest` through short-lived client secrets when xAI is selected |
| Live multilingual STT | Deepgram managed/BYOK; local unavailable until implemented; MiMo remains batch-only |

Keep `grok-composer-2.5-fast` only when the authenticated xAI catalog returns it. Existing ChatGPT/Codex and xAI OAuth code is a reference, not proof that consumer subscriptions may fund third-party API traffic. Unsupported subscription-token reuse does not ship; OpenAI API access otherwise uses documented API credentials.

## Cloud and migration

1. Keep Firebase Auth and verify Firebase ID tokens at the Worker.
2. Map each Firebase UID to one D1 user row and Stripe entitlement.
3. Store new conversations, memory, Currents, channel links, and audits only in D1.
4. Import required Firestore history explicitly; never maintain permanent dual writes.
5. Add Vectorize, R2, Queues, Workflows, or Containers only when a measured feature needs each one.

## Current release train

| Slice | Implemented | Proof still required |
| --- | --- | --- |
| Product shell | Gradient Flutter navigation, onboarding, chat, Memory, Currents, Devices, Setup, and Account | Rendered accessibility/responsive audit on every target |
| Native hub | Generated Rinf signals, UID-scoped production Dart configuration/event consumption, bounded/reaped command registry, ordered configuration, nonblocking/idempotent `zkr` 0.1.5 capture/search with transcript locators, managed/BYOK live STT, source gaps, final drain, typed stop acknowledgements, atomic computer-use approval/execution, cancellation, `rx4`, and `rs_peekaboo` | Credentialed live-provider proof, physical-device lifecycle stress, and local STT only after a real provider exists |
| Mobile relay | Omi-filtered BLE discovery, connect/discover, battery/codec reads, bounded sequenced PCM8/PCM16/Opus reassembly, native PCM8-to-linear16 conversion, disconnect/EOS, restart handling, and completed-transcript capture into evidenced `zkr` memory | Credentialed live Deepgram, physical iOS/Android sessions, and background recovery |
| SaaS backend | Firebase-token boundary, D1 memory/settings, Stripe entitlements, Telegram, Blooio, cited retrieval, and durable outbound delivery with per-account/channel serialization | Real Firebase/Stripe/channel credentials and preview deployment |
| Shared conversation | App/native assistant streaming and durable channel inbox/outbox are implemented independently | UID-scoped conversation persistence, desktop/app/web synchronization, channel-to-agent dispatch, replay cursors, and offline recovery |
| Currents and reflection | Validated Current state model, native signal shape, memory evidence/review primitives, and empty-state UI | Candidate generation/ranking, D1 persistence, feedback/action lifecycle, outcome learning, and idempotent nightly Daily Review orchestration |
| Platform packages | Web release, Android release APK, universal macOS 12 release app, Windows release, and exact-head Android/iOS/macOS/Windows/web CI proof | Signed physical-device installation and release-channel distribution |

Do not count a compiled adapter as a deployed integration. Credentialed provider tests, physical-device tests, release packages, CI, and public deployment remain separate proof layers.

## Three validation days

### Test day 1 — platform and identity

1. Build Android, iOS without signing, macOS, Windows, and web in CI.
2. Exercise phone OTP, Google/Apple where supported, refresh, logout, and account linking.
3. Validate Rinf generation drift, native linking, web wasm headers, and streaming backpressure.
4. Verify navigation, onboarding, accessibility, responsive layouts, and gradients on real rendered surfaces.

### Test day 2 — memory, hardware, and actions

1. Exercise Omi BLE/audio and phone microphone on physical iOS and Android devices.
2. Verify managed and BYOK Deepgram, fail-closed Local behavior, reconnect gaps, deterministic sourced transcript identity, WAL recovery, MiMo batch ASR, and transcript normalization separately.
3. Test memory evidence, correction, source deletion, sync, export, and account deletion.
4. Test both-Shift timing, secure-input suppression, computer-use approval, cancellation, and audit records.

### Test day 3 — SaaS and channels

1. Test Stripe checkout/webhook/portal and expired or forged entitlements in test mode.
2. Test Telegram and Blooio signature verification, linking, deduplication, formatting, delivery, and retry.
3. Load-test Worker limits, D1 queries, audio upload boundaries, and model cost accounting.
4. Run the full user journey, fix release blockers, record the demo, and tag the first candidate only after proof passes.

## v0 acceptance

1. The same account links mobile, desktop, web, Telegram, and Blooio to one Firebase UID and assistant session.
2. A physical Omi device streams through the mobile app into a sourced conversation and evidenced memory with deterministic segment IDs and inspectable device/time ranges.
3. Currents surfaces one recommendation with reason, source, feedback, and an approved action path.
4. Telegram and Blooio messages resolve to the desktop chat and can request an audited computer-use action.
5. Free/BYOK and Omi AI users receive the correct models without exposing managed secrets.

## Known constraints

- Firebase phone authentication on macOS and Windows uses the implemented browser handoff with a short-lived PKCE verifier, explicit matching confirmation code, atomic attempt lockout, and single-use custom-token exchange; deployment still requires real Firebase and Worker configuration.
- Omi hardware capture is mobile-owned in v0 because upstream has no macOS/Windows BLE bridge and browsers cannot provide equivalent background BLE.
- `rx4` and `rs_peekaboo` need feature-gated audits for mobile and wasm linking.
- `omi-v3` implements MiMo ASR/translation but not managed MiMo Pro chat, Telegram, Grok voice, or a complete Recommendation Memory lifecycle.
- Cloudflare bindings and secrets in the reference backend are placeholders; deployment proof starts only after real preview resources exist.
- Rinf 8.10's bundled Cargokit uses an API removed by Gradle 9; Android stays on the latest Flutter-supported Gradle 8 line until Rinf publishes a compatible release.
- Flutter 3.44.6 macOS universal-framework verification currently conflicts with the newer `lipo -verify_arch` argument form; keep any local toolchain shim out of the repository and verify CI on a supported Xcode image.
- OpenClaw and Hermes evolve independently. Their adapters need host-contract tests and durable ingestion; the neutral `zkr` crate must not absorb agent-specific lifecycle behavior.
- Telegram and Blooio currently provide authenticated linking, durable ingestion, and bounded delivery, but they are not yet portals into the live desktop assistant session; no cross-client conversation synchronization or replay cursor exists.
- Currents currently has a validated state model and presentation shell only. No production candidate generator, persistence route, feedback learner, action handoff, or scheduled nightly reflection is wired.

## Immediate next task

Prove managed/BYOK Deepgram with real credentials and a physical Omi on iOS and Android, including PCM8/PCM16/Opus, reconnect gaps, EOS, stop-before-EOS, and revocation. Next, wire one UID-scoped conversation through app/web, Telegram/Blooio, and the desktop agent, then ship one evidence-backed Current through feedback and approved action. After those v0 paths exist, run combined multi-platform CI and separately prove Firebase/Cloudflare bindings before calling the product deployed. Add local STT only when `rs_ai_local` supplies a real supported provider; until then it fails closed. Keep nightly Daily Review orchestration as the first v1 follow-on unless it is required for the launch demo.

## Progress log

- 2026-07-21: Established proactive second-brain direction, separate memory domains, Firebase-compatible D1 transition, and two-plan cost model.
- 2026-07-21: Replaced React Native/UniFFI with Flutter/Rinf, selected device-first capture and cross-platform clients, added Telegram/Blooio, onboarding, model routing, both-Shift gesture, build sprint, and three validation days.
- 2026-07-21: Locked desktop-first assistant roles, mobile hardware relay, web memory portal, four-permission desktop gate, voice-created first tasks, deferred connection tasks, and channel-triggered desktop actions.
- 2026-07-21: Added task-scoped authority, ask-when-blocked behavior, chat-controlled typed settings, progressive tool disclosure, and hybrid direct/programmatic tool execution.
- 2026-07-21: Added evidence-backed temporal claims, bounded hot profile, retrieval packs, inspected skills, `rs_gbrain` reuse limits, and cited Daily Reviews with separately validated memory/task/skill candidates.
- 2026-07-21: Published `zkr 0.1.1`, integrated its source/evidence retrieval and projection lifecycle into the Rinf hub, implemented mobile BLE relay and Worker SaaS/channel boundaries, and moved the roadmap from scaffolding to release-build and credentialed-integration proof.
- 2026-07-21: Replaced the provisional four-boolean desktop permission gate with platform-aware capability states; macOS uses TCC/direct distribution while Windows uses limited UI Automation, privacy-aware microphone access, and per-session capture selection.
- 2026-07-21: Published `zkr 0.1.2` with idempotent ingestion and hardened OpenClaw/Hermes plugins; audited the Omi runtime for bounded tasks, shutdown, cancellation, audio lifecycle, configuration ordering, and retry-safe capture.
- 2026-07-21: Published `zkr 0.1.3`, added UID-bound Firebase authentication and versioned processing consent, implemented guarded macOS/Windows browser handoff, and connected bounded BLE PCM8/PCM16/Opus audio with deterministic EOS into the Rinf hub.
- 2026-07-21: Added generation-fenced completed-transcript capture into `zkr`, Durable Object-serialized Telegram/Blooio outbound delivery, iOS 15 Firebase/Rinf packaging, and responsive accessibility coverage.
- 2026-07-21: Published `zkr` 0.1.5 transcript locators and completed bounded managed/BYOK Deepgram sessions, physical Omi packet reassembly and PCM8 conversion, final-drain/stop acknowledgement, content-redacted Rinf bindings, and atomic approved computer-use execution; local STT now fails closed until a real provider exists.
