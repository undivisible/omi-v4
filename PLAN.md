# Omi v4 living plan

Updated: 2026-07-22
Status: architecture locked; v0 implementation and platform validation in progress

## Product

Omi v4 is an ultrasimple thinking partner and second brain that works across every device. It remembers what the user saw, said, and did; works with Omi hardware; surfaces what matters next; learns from outcomes; and performs approved actions.

## Locked decisions

| Area | Decision |
| --- | --- |
| Application | Flutter for iOS, Android, macOS, Windows, and web; no desktop WebView |
| Rust bridge | Rinf typed asynchronous signals; binary signals for bounded audio frames |
| Live STT | Rust owns bounded transcription sessions; Deepgram is the managed/BYOK live route, local STT fails closed until a real provider exists, and MiMo remains batch-only |
| Rust runtime | One `hub` crate using `rx4` ("rotary"), `rs_ai`, and platform-gated `praefectus` |
| Device ownership | Mobile owns BLE, background hardware relay, firmware, pairing, and device management; desktop owns primary assistant interaction and computer use |
| Cloud | Bun/TypeScript Hono Worker, D1, R2, Queues, Workflows, Durable Objects where state coordination requires them |
| Identity | Firebase Auth remains; phone OTP is primary, Google/Apple OAuth optional, Firebase UID is the initial canonical user ID |
| Data | New SaaS data goes to D1; no Firestore/D1 dual-write; import upstream Firestore data only through explicit jobs |
| Memory | Personal Memory and Recommendation Memory remain separate domains |
| Billing | Stripe webhook state controls two plans tied to Firebase UID |
| UI reference | `omi-v3` main and upstream Omi provide production behavior; `codex/onboarding-web-demo` provides the borderless five-beat onboarding and warm-paper hub interaction model |

## Product surfaces

| Surface | First release responsibility |
| --- | --- |
| Mobile | Omi hardware relay, pairing, firmware, connection health, capture status, and device management (the only Devices surface; desktop has none) |
| Desktop | A single continuous-chat home surface: no multi-destination navigation. Currents surfaces directly in chat home as "What matters next" task rows; screen context, local computer use, and the both-Shift voice/input gesture remain desktop-owned; Settings (reached via the macOS app menu, ⌘,, or the menu-bar item, not a nav destination) consolidates account/setup content |
| Web | Signed portal for memory, Currents, account, connections, and billing |
| Public site | Product explanation, pricing, download/sign-in; initially a public route in the Flutter web build |
| Channels | Telegram and Blooio/iMessage are primary conversational portals into the same desktop chat and agent session; linking is server-side only for this pass (see Channels and identity) |

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
- [ ] Verify the Flutter gradient shell and every onboarding, single-chat-surface, and product surface on target platforms.
- [x] Verify the Bun/Hono Worker contracts, D1 schema, auth boundary, and channel webhook boundaries.
- [x] Provision the production Worker and D1, apply all migrations, and verify the live fail-closed edge boundary.
- [x] Complete production Dart consumption of generated Rinf signals and published `zkr` memory storage/search.
- [x] Implement Worker D1 persistence, Stripe entitlement, Telegram linking/ingestion, and Blooio linking/ingestion with fail-closed signatures.
- [x] Connect the durable Telegram/Blooio inbox and app/web chat to one Firebase-UID-scoped conversation transport with ordered replay cursors and idempotent client messages.
- [x] Implement the first evidence-backed Current end to end: cited candidate generation, deterministic ranking, feedback, approved action handoff, and outcome learning.
- [x] Connect channel messages to the desktop agent with UID-scoped ordered leases, offline retry, atomic conversation persistence, and durable outbound replies.
- [ ] Prove Telegram and Blooio round trips with real credentials and a continuously connected desktop client.
- [ ] Finish desktop both-Shift voice capture; the global gesture, microphone/STT path, and failure-safe teardown exist, but physical Windows proof does not.
- [ ] Add the desktop menu-bar companion: show the single most important current task first, with capture and listening state/actions directly beneath it; keep it a compact portal into the same desktop agent session rather than a separate assistant.
- [ ] Move `rx4` ("rotary") usage beyond version-reporting into real extraction/ranking calls; it is core to the assistant/extraction/ranking architecture, but integration is in progress.
- [x] Complete the audited live-STT slice between bounded Omi BLE/Rinf audio and idempotent final-transcript `zkr` capture, including managed/BYOK provider routing, reconnect gaps, final drain, cancellation, and typed stop acknowledgements.
- [ ] Re-prove Android, iOS without signing, macOS, Windows, and web release builds on the exact release head after this integration lands.
- [ ] Wire Firebase Auth, real channel delivery, physical Omi hardware, desktop permissions/computer use, and model routes against real credentials and devices.

## Initial modules

| File | Owns | Reuses |
| --- | --- | --- |
| `app/lib/memory/` and `app/lib/features/memory_screen.dart` | Personal Memory state and screens | upstream Omi domain language and source evidence |
| `app/lib/currents/` and `app/lib/features/currents_screen.dart` | Recommendation state, ranking display, feedback | `omi-v3/app/src/lib/home-cards.ts` behavior |
| `app/lib/device/` and `app/lib/features/device_screen.dart` | Omi pairing, BLE/audio status, phone capture | upstream Flutter device and capture services |
| `app/native/hub/src/lib.rs` | Rinf signals, `rx4`, `rs_ai`, computer-use orchestration | `praefectus` crate; no fork |
| `worker/src/index.ts` | Authenticated API, D1 memory, channels, plans, managed inference | `omi-v3/desktop/cloud-api` |

## Rinf boundary

Flutter owns UI, navigation, Firebase, secure storage, notifications, permissions, BLE, microphone, background lifecycle, and global keyboard adapters.

Rust owns assistant sessions, provider routing, memory extraction contracts, proactive ranking, skill review, action policy, computer-use invocation, and streaming orchestration.

| Direction | Signals |
| --- | --- |
| Dart to Rust | send message, capture event, start transcription metadata/config, bounded audio chunk, approval decision, device state, stop/cancel |
| Rust to Dart | sourced transcript delta, assistant delta, Current update, action proposal, tool progress, error, runtime status |

Native builds link the full hub. Web builds use the same signal schema but compile a wasm-safe hub subset and route inference, memory, and actions to the Worker. `praefectus` compiles only for macOS, Windows, and Linux desktop targets; iOS, Android, and web never link or initialize it.

## Onboarding

1. Sign in with phone OTP, Google, or Apple; explain Firebase's authentication disclosure separately from memory and AI processing consent.
2. Ask three conversational questions: identity, current priorities, and what the user wants Omi to notice or help with.
3. Require each platform's applicable core desktop capabilities, then run bounded native scans of approved workspace roots and available Apple Notes/Mail stores with explicit per-source results before showing editable “what I understand about you” evidence.
4. Teach voice by asking the user to say “What are my tasks?” and render the real tasks returned by the assistant.
5. Continue into the single continuous-chat hub with setup tasks for Calendar, Reminders, Contacts, Location, Telegram, Blooio, Notion, providers, and Omi hardware, consolidated into the Settings surface (app menu ⌘, or menu-bar item) rather than separate Setup/Account screens.

Onboarding keeps its borderless, always-on-top presentation; the hub itself is a normal titled macOS window with native traffic-light window controls, not a borderless always-on-top panel.

Use upstream Flutter's mature consent, name, language, permission, knowledge-graph, and device flows. Use `omi-v3`'s borderless gradient sequence and warm-paper hub as the presentation and interaction reference while retaining v4's real service boundaries.

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

Windows computer use is a first-class `praefectus` path: it must inspect UI Automation targets and execute policy-approved pointer clicks and keyboard text entry. Process-integrity boundaries may prevent control of elevated applications, but Windows itself is not a read-only or unsupported target.

Calendar and Reminders use the native EventKit bridge and are actionable post-onboarding setup tasks that import bounded evidence into `zkr`. Contacts and Location remain later setup tasks. Camera and Photos are omitted until a concrete feature needs them.

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
- `rx4` (also called "rotary") is the core extraction/ranking engine for the assistant/recommendation stack, reused before adding another recommendation engine; usage today is version-reporting only (`rx4::VERSION`), and moving it into real extraction/ranking calls is near-term work (see Active build checklist).
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

This pass runs Telegram and Blooio as server-side-only SaaS channels: bot/channel credentials are Worker environment variables (`TELEGRAM_BOT_TOKEN`, `BLOOIO_API_KEY`, already implemented), and there is no per-user in-app linking UI surfaced in desktop Settings for now. The linking widget and its tests (`ChannelConnectionTile`) remain in the codebase; they are simply not shown in the current Settings surface.

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

The task executor records a bounded progress fingerprint after each step. Repeated identical calls, repeated failures, or no material progress stop safe automatic retries and ask the user; an ambiguous side effect is never replayed and remains `unknown` until reconciled or replaced by a newly approved attempt.

Compaction preserves unresolved user constraints, task leases, policy/approval receipts, and tool call/result pairing. Large artifacts and audit records stay outside the prompt behind stable handles and are retrieved on demand.

A typed setup-health report checks Firebase, Worker bindings, channel links, model routes, desktop permissions, memory, and device relay without exposing credentials or running arbitrary shell probes. Onboarding and Settings render the same report.

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
- The hub surfaces an upgrade/BYOK prompt in `app/lib/features/setup_account_screens.dart`'s `SettingsScreen` contrasting managed Omi AI cost (~$35/mo equivalent usage) against bringing a personal xAI/Grok key (~$5/mo equivalent) to reduce cost; it deep-links into the Settings plan tile and is a real UI addition, not aspirational.

### Routing

| Task | Default route |
| --- | --- |
| Fast extraction/ranking | local or BYOK fast tier; managed `mimo-v2.5` for Omi AI |
| Deep planning | user-selected model; managed `mimo-v2.5-pro` for Omi AI |
| xAI chat | `grok-4.5` or authenticated catalog choice through supported xAI credentials |
| xAI voice | `grok-voice-latest` through short-lived client secrets when xAI is selected |
| Live multilingual STT | Deepgram managed/BYOK; local unavailable until implemented; MiMo remains batch-only |

Keep `grok-composer-2.5-fast` only when the authenticated xAI catalog returns it. Existing ChatGPT/Codex and xAI OAuth code is a reference, not proof that consumer subscriptions may fund third-party API traffic. Unsupported subscription-token reuse does not ship; OpenAI API access otherwise uses documented API credentials.

### Payments stay disabled during testing

Stripe is intentionally unconfigured (`STRIPE_SECRET_KEY`/`STRIPE_PRO_PRICE_ID` unset) so `_PlanTile`'s checkout/portal actions fail closed with no live charge path; `AppServices.canUseApi` (`app/lib/app_services.dart:321`) gates chat/API access on auth and processing consent only, never on plan or entitlement, so the app stays fully usable for free during this testing phase. Do not wire real Stripe credentials until the provider-choice model below is designed and approved.

### Future: native computer connection

A later version adds a native computer connection: deep OS-level control beyond the current praefectus computer-use path, so Omi can operate the machine directly rather than only through the fenced accessibility-action pipeline.

### Future: provider choice under a SuperGrok/subscription plan (not yet designed)

When a paid plan is reintroduced, offer a subscription tier (e.g. riding an xAI SuperGrok-style subscription) with a visible "or use your own API keys" fallback next to it, plus explicit provider choice rather than one fixed managed stack:

- **Embeddings**: offer a small set of provider choices, or compute them ourselves if cost allows, or run them fully local (candidates to evaluate: OpenAI, Voyage, Cohere, a local model) — survey how comparable agent products (e.g. Pi) structure this choice before committing to one.
- **STT**: let the user pick among OpenAI, xAI, Gemini, and Deepgram (Deepgram remains the only one implemented today; the others are future BYOK routes).
- Keep this deliberately out of scope until the testing phase above is done — the goal now is zero payment complexity, not a polished pricing page.

### Future: Google Calendar/Tasks sync via the Worker (deferred)

Once the EventKit proactive sync (macOS/iOS opt-in that mirrors due-bearing currents into Apple Calendar events and Reminders) ships, the cross-platform successor is Google Calendar and Google Tasks sync brokered by the Worker over OAuth: the Worker holds the refresh token, performs the idempotent upsert/complete/remove pass server-side on currents changes, and Windows/Android/web clients get the same proactive behavior without any native calendar bridge. Explicitly deferred until EventKit sync has proven the sync contract.

### Future: remote channel-triggered computer-use (being scoped separately)

Allow a message on a linked channel (Telegram/Blooio) to trigger a computer-use action on the user's desktop, with every individual action gated by the existing per-action approval receipt flow — no channel message ever executes without a fresh on-device approval. Scoping happens in its own track; nothing in the current channel pipeline may bypass the proposal/approval fence.

## Cloud and migration

1. Keep Firebase Auth and verify Firebase ID tokens at the Worker.
2. Map each Firebase UID to one D1 user row and Stripe entitlement.
3. Store new conversations, memory, Currents, channel links, and audits only in D1.
4. Import required Firestore history explicitly; never maintain permanent dual writes.
5. Add Vectorize, R2, Queues, Workflows, or Containers only when a measured feature needs each one.

## Current release train

| Slice | Implemented | Proof still required |
| --- | --- | --- |
| Product shell | Gradient Flutter onboarding plus a single continuous-chat desktop hub with Currents surfaced as task rows and Settings consolidated into the app menu; Devices is mobile-only, Memory is web-portal-only | Rendered accessibility/responsive audit on every target |
| Native hub | Generated Rinf signals, UID-scoped production Dart configuration/event consumption, bounded/reaped command registry, ordered configuration, nonblocking/idempotent `zkr` 0.3.0 capture, cited retrieval, correction, and deletion with transcript locators, managed/BYOK live STT, source gaps, final drain, typed stop acknowledgements, atomic computer-use approval/execution, cancellation, `rx4`, and `praefectus` | Credentialed live-provider proof, physical-device lifecycle stress, local STT only after a real provider exists, and real `rx4` extraction/ranking calls beyond version-reporting |
| Mobile relay | Omi-filtered BLE discovery, connect/discover, battery/codec reads, bounded sequenced PCM8/PCM16/Opus reassembly, native PCM8-to-linear16 conversion, disconnect/EOS, restart handling, and completed-transcript capture into evidenced `zkr` memory | Credentialed live Deepgram, physical iOS/Android sessions, and background recovery |
| SaaS backend | Firebase-token boundary, D1 memory/settings, Stripe entitlements, Telegram, Blooio, cited retrieval, durable channel-to-desktop leases, and serialized outbound delivery | Real Firebase/Stripe/channel credentials and preview deployment |
| Shared conversation | UID-scoped persistence, ordered replay, desktop channel dispatch, offline retry, and atomic outbound replies | Live app/web refresh and credentialed Telegram/Blooio proof |
| Desktop voice | Both-Shift tap/hold/hands-free state machine, macOS/Windows PCM16 capture, permission-first managed STT, authority fencing, final transcript submission, acknowledged pre-EOS cancellation, and navigation/error cleanup | Physical macOS/Windows shortcut tests, Windows negotiated-format proof, and credentialed managed-STT proof |
| Currents and reflection | Cited candidate generation from live current-profile memory, deterministic ranking, D1 persistence, feedback, approval-bound action handoff, and outcome learning | Credentialed end-to-end action proof and idempotent nightly Daily Review orchestration |
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
- `rx4` and `praefectus` need feature-gated audits for mobile and wasm linking.
- `omi-v3` implements MiMo ASR/translation but not managed MiMo Pro chat, Telegram, Grok voice, or a complete Recommendation Memory lifecycle.
- Cloudflare bindings and secrets in the reference backend are placeholders; deployment proof starts only after real preview resources exist.
- Rinf 8.10's bundled Cargokit uses an API removed by Gradle 9; Android stays on the latest Flutter-supported Gradle 8 line until Rinf publishes a compatible release.
- Flutter 3.44.6 macOS universal-framework verification currently conflicts with the newer `lipo -verify_arch` argument form; keep any local toolchain shim out of the repository and verify CI on a supported Xcode image.
- OpenClaw and Hermes evolve independently. Their adapters need host-contract tests and durable ingestion; the neutral `zkr` crate must not absorb agent-specific lifecycle behavior.
- Telegram and Blooio now feed the authenticated desktop assistant through a strict ordered lease and persist its reply into the shared replay before durable provider delivery; live provider credentials and foreground cross-client refresh remain unproved.
- Currents generates one idempotent cited recommendation from live current-profile memory when the surface loads; nightly reflection remains unwired.

## Immediate next task

Prove managed/BYOK Deepgram with real credentials and a physical Omi on iOS and Android, including PCM8/PCM16/Opus, reconnect gaps, EOS, stop-before-EOS, and revocation. Next, prove the implemented Telegram/Blooio desktop round trip and cited Current approval/outcome path with real credentials, then add foreground conversation refresh. Run combined multi-platform CI and separately prove Firebase/Cloudflare bindings before calling the product deployed. Add local STT only when `rs_ai_local` supplies a real supported provider; until then it fails closed. Keep nightly Daily Review orchestration as the first v1 follow-on unless it is required for the launch demo.

## Progress log

- 2026-07-21: Established proactive second-brain direction, separate memory domains, Firebase-compatible D1 transition, and two-plan cost model.
- 2026-07-21: Replaced React Native/UniFFI with Flutter/Rinf, selected device-first capture and cross-platform clients, added Telegram/Blooio, onboarding, model routing, both-Shift gesture, build sprint, and three validation days.
- 2026-07-21: Locked desktop-first assistant roles, mobile hardware relay, web memory portal, four-permission desktop gate, voice-created first tasks, deferred connection tasks, and channel-triggered desktop actions.
- 2026-07-21: Locked the desktop menu-bar hierarchy to the most important current task first, followed by capture and live listening controls backed by the same agent and voice session.
- 2026-07-21: Added task-scoped authority, ask-when-blocked behavior, chat-controlled typed settings, progressive tool disclosure, and hybrid direct/programmatic tool execution.
- 2026-07-21: Added evidence-backed temporal claims, bounded hot profile, retrieval packs, inspected skills, `rs_gbrain` reuse limits, and cited Daily Reviews with separately validated memory/task/skill candidates.
- 2026-07-21: Published `zkr 0.1.1`, integrated its source/evidence retrieval and projection lifecycle into the Rinf hub, implemented mobile BLE relay and Worker SaaS/channel boundaries, and moved the roadmap from scaffolding to release-build and credentialed-integration proof.
- 2026-07-21: Replaced the provisional four-boolean desktop permission gate with platform-aware capability states; macOS uses TCC/direct distribution while Windows uses limited UI Automation, privacy-aware microphone access, and per-session capture selection.
- 2026-07-21: Published `zkr 0.1.2` with idempotent ingestion and hardened OpenClaw/Hermes plugins; audited the Omi runtime for bounded tasks, shutdown, cancellation, audio lifecycle, configuration ordering, and retry-safe capture.
- 2026-07-21: Published `zkr 0.1.3`, added UID-bound Firebase authentication and versioned processing consent, implemented guarded macOS/Windows browser handoff, and connected bounded BLE PCM8/PCM16/Opus audio with deterministic EOS into the Rinf hub.
- 2026-07-21: Added generation-fenced completed-transcript capture into `zkr`, Durable Object-serialized Telegram/Blooio outbound delivery, iOS 15 Firebase/Rinf packaging, and responsive accessibility coverage.
- 2026-07-21: Connected Telegram/Blooio ingestion to the desktop assistant with UID-scoped FIFO leases, safe offline retry, token-fenced completion, atomic shared-conversation replies, and durable provider delivery.
- 2026-07-21: Published `zkr` 0.1.5 transcript locators and completed bounded managed/BYOK Deepgram sessions, physical Omi packet reassembly and PCM8 conversion, final-drain/stop acknowledgement, content-redacted Rinf bindings, and atomic approved computer-use execution; local STT now fails closed until a real provider exists.
- 2026-07-21: Integrated `zkr` 0.1.7 at the Rinf hub with tenant/person-scoped correction and deletion, cited retrieval, stale-claim suppression, schema-integrity migration, and redacted lifecycle commands.
- 2026-07-21: Upgraded the Rinf hub to `zkr` 0.2.0 after its isolation, bitemporal, embedding-lifecycle, deletion, plugin, migration, release, and security audits passed.
- 2026-07-21: Rendered the authenticated, credential-redacted Worker setup-health contract in Flutter Setup so missing Firebase, channels, billing, model routes, and desktop authentication are visible without exposing secrets.
- 2026-07-21: Replaced the Flutter plan placeholder with strict entitlement loading and external Stripe Checkout or billing-portal handoff for the two-plan SaaS model.
- 2026-07-22: Redesigned the desktop hub as a single continuous-chat surface with Currents rendered as "What matters next" task rows, moved to a normal titled window with native traffic-light controls (onboarding stays borderless), consolidated Setup/Account into one Settings surface reached via the macOS app menu, and corrected PLAN.md's crate references (`praefectus` replacing `rs_peekaboo`, `rx4` ("rotary") as one crate, not two, `zkr` 0.3.0).
- 2026-07-22: Closed the audit-and-completion cycle: three parallel audits (security, logic/completeness, performance) over the realtime batch found no critical issues and every verified finding was fixed — Gemini token minting is entitlement-gated and ledgered, OAuth tokens are AES-GCM encrypted at rest with race-safe refresh rotation and pinned xAI discovery, provider-ended live sessions keep their transcript, meeting controls survive hub restarts and report failures honestly, and the browser poll is pgrep-gated with an adaptive interval. Desktop voice now routes through Gemini Live input transcription (Deepgram fallback intact), meetings capture real audio via the corti-coreaudio system tap (mic fallback, managed-auth re-mint on session loss) under a persisted SystemAudioCaptureMode setting, Gemini voice replies play audibly through a new AVAudioEngine playout bridge with barge-in flush, and docs/mobile-companion-app.md specs the pendant-companion mobile refactor (phases 1-6 pending). Gemini Live duplex voice sessions in the hub (`live_voice.rs`, `RealtimeVoiceProvider` trait with Worker-minted ephemeral tokens), real `rx4` extraction of transcript/chat captures into ranked zkr claims (`extraction.rs`), idempotent Daily Review generation into zkr (`daily_review.rs`, local-AI summary with deterministic fallback), meeting mode phase 1 ported from omi-v3 (`meeting_detector.rs` with corti-coreaudio mic-owner detection, `capture_policy.rs`, `MeetingStateChanged` signal), Worker `mimo-v2.5-asr` batch transcription and subscription-token chat proxying, and repaired ARCHITECTURE.md mermaid diagrams/provider descriptions.
- 2026-07-22: Settled the AI-provider architecture: managed chat stays on MiMo through the Worker (token-plan-sgp endpoint for dev only; pay-as-you-go before real users), on-device summaries stay on `rs_ai_local` (macOS arm64), live voice targets the Gemini Live API (`gemini-3.1-flash-live-preview`) via Worker-minted ephemeral tokens, and long-form transcription targets `mimo-v2.5-asr` (base64 chunked; no streaming input exists). Shipped multi-provider BYOK (ordered secure-storage list, newest routes first, collapsed Settings UI) and a dev-gated Worker device-code OAuth broker with ChatGPT/xAI subscription sign-in tiles; xAI voice via Grok login was ruled out (voice is API-key-metered only). Remaining: Rust-hub Gemini Live client for the actual audio session, mimo-v2.5-asr long-form capture path, and OAuth-token chat routing through the broker.
- 2026-07-22: Added a dev-only no-account mode: with a developer `GEMINI_API_KEY` (resolved from the environment, `~/.config/omi/dev.env`, or `worker/.dev.vars` — the latter already gitignored), the hub falls back to direct Gemini `generateContent` on `gemini-3.1-flash-lite` for chat/drafts, live voice connects straight to the Gemini Live WebSocket with the key (`?key=` instead of Worker-minted `access_token`), and the onboarding scan summary uses the same key when `rs_ai_local` is unavailable. Keys are validated, never logged, redacted in Debug output, and this path is strictly for local development. Also shipped: native Liquid Glass pill (NSGlassEffectView on macOS 26+, NSVisualEffectView fallback, Dart-reported rounded-rect masks), bar-free hub chrome, the onboarding ×2 slide-apart reveal, and Currents-sourced action-aware pill suggestions (mailto drafting under a 2.5s cap, verbatim-URL open plus computer-use handoff, chat fallback).
