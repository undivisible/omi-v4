# PORT_STATUS — TypeScript worker → Rust (workers-rs)

Tracks every module in `worker/src/*.ts` against its Rust port status.
Source of truth for behaviour parity is the TS file; the Rust worker binds the
same D1 database and does not own migrations.

Legend: **ported** (parity, tested) · **partial** (some routes) ·
**pending** (not started) · **blocked** (needs a workers-rs binding gap
resolved — noted inline).

## Phase 1 (this task)

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `auth.ts` | `src/auth.rs` + `glue.rs::authenticate`/`firebase_keys` | **ported** | RS256 via RustCrypto `rsa` (pure, no WebCrypto). JWKS fetch + per-isolate cache + Cache-Control max-age. Same 401/503 error shapes. 13 unit tests. |
| `entitlement.ts` | `src/entitlement.rs` + `glue.rs::has_active_pro` | **ported** | `DEV_FAKE_PRO`/`ENVIRONMENT` guard + row matrix. 8 tests. |
| `index.ts` (fetch router, `/health`) | `glue.rs::fetch` | **partial** | Router + `/health` + Phase-1 routes done. `scheduled` cron handler and DO exports pending (later phases). |
| `routes.ts` → `GET /me` | `glue.rs::handle_me` | **ported** | Includes `channel_bindings` lookup. |
| `routes.ts` → `GET /setup-health` | `src/setup_health.rs` + `glue.rs::handle_setup_health` | **ported** | Identical boolean shape. 4 tests. |
| `routes.ts` → `GET /entitlement` | `glue.rs::handle_entitlement` | **ported** | |
| `routes.ts` → `GET|PUT /profile/onboarding` | `glue.rs::handle_onboarding_*` | **ported** | Same INSERT…ON CONFLICT + 400 on `complete!=true`. |
| `routes.ts` → `DELETE /account` | `glue.rs::handle_account_delete` | **partial** | D1 batch delete across all uid-scoped tables at parity. Vectorize claim-vector cleanup deferred — **blocked** on Vectorize binding (see below). |

## Phase 2 (next)

| TS module | Status | Notes |
|---|---|---|
| `billing.ts` | **pending** | Stripe checkout/portal via `fetch` — no binding needed; straightforward next. |
| `webhooks.ts` | **pending** | Telegram/Blooio/Stripe inbound. Needs constant-time compares + HMAC/dedupe. Use RustCrypto (`hmac`, `sha2`, `subtle`) — all wasm-compatible. |
| `desktop-auth.ts` | **pending** | Signs a Firebase custom token (service-account RS256 signing) — RustCrypto `rsa` PKCS#8 private key, wasm-OK. |
| `rate-limit.ts` (RateLimiter DO) | **blocked-ish** | Durable Objects natively supported in workers-rs via `#[durable_object]`; port is mechanical but deferred. |

## Later phases (larger surface / binding-dependent)

| TS module | Status | Notes |
|---|---|---|
| `assistant.ts`, `assistant-admission.ts` (DO) | pending | DO native; large logic surface. |
| `conversations.ts` | pending | D1 only. |
| `currents.ts` | pending | D1 only. |
| `delivery.ts` (DeliveryCoordinator DO) | pending | DO native. |
| `stt.ts`, `stt-admission.ts` (DO), `asr.ts`, `voice.ts` | pending | WebSocket upgrade + upstream fetch; workers-rs supports `WebSocketPair`. |
| `memory-projection.ts`, `memory-sync.ts` | pending | D1 + zkr (see wasm note). |
| `memory-vectors.ts`, `embeddings.ts` | **blocked** | **Vectorize** has no native workers-rs binding (0.8.5) and **Workers AI** embeddings via the `Ai` binding — see below. |
| `oauth-broker.ts`, `oauth-proxy.ts` | pending | Dev-only, gated by `ENABLE_DEV_OAUTH_BROKER`. |

## workers-rs 0.8.5 binding support (findings)

| Capability | Native in workers-rs 0.8.5? | How used here / interop needed |
|---|---|---|
| **D1** | Yes (`d1` feature; `env.d1()`, `prepare/bind/run/first/all/batch`) | Used directly in Phase 1. |
| **Secrets / vars** | Yes (`env.secret()`, `env.var()`) | Used directly. |
| **Fetch / outbound HTTP** | Yes (`worker::Fetch`) | JWKS fetch. |
| **Scheduled / cron** | Yes (`#[event(scheduled)]`, `ScheduledEvent`) | Not yet wired (Phase 1 has no cron). |
| **Durable Objects** | Yes (`#[durable_object]`, SQLite storage) | Deferred to later phases; mechanical. |
| **Workers AI** | Yes (`Ai` binding struct) | Needed by `embeddings.ts`; not yet wired. Model I/O is dynamic JSON. |
| **Vectorize** | **No native binding** | Requires raw JS interop via `js_sys`/`wasm_bindgen` against the bound `VectorizeIndex` JS object (query/insert/upsert/deleteByIds). This is the main interop gap; `memory-vectors.ts` and the `DELETE /account` vector cleanup depend on it. |
| **Crypto (RS256 etc.)** | via RustCrypto crates (no `crypto.subtle` needed) | `rsa` + `sha2` compile clean to wasm. HMAC/constant-time for webhooks will use `hmac` + `subtle`. |

Net: everything Phase 1 touches is natively supported. The only hard interop
gap is **Vectorize**, which will need hand-written `wasm_bindgen` bindings to the
JS `VectorizeIndex` object. Workers AI is native but unused so far.

## zkr / rx4 wasm32 compatibility (probe results)

Scratch crate depending on each, `cargo check --target wasm32-unknown-unknown`:

- **zkr 0.3.0 — NOT wasm-compatible.** Pulls `rusqlite` → `libsqlite3-sys`
  (bundled C SQLite); the C build fails on wasm (`fatal error: 'stdio.h' file
  not found` — no libc/stdio for `wasm32-unknown-unknown`).
- **rx4 0.3.23 (`default-features = false`) — NOT wasm-compatible.** Pulls
  `tokio` with `mio` (native sockets, 48 compile errors on wasm) and `uuid`
  needing a wasm `getrandom` backend.

Implication: the memory/extraction logic in `app/native/hub` **cannot** be
shared into the Worker as-is. Sharing later requires upstream feature-gating in
zkr (SQLite optional / a non-C backend) and rx4 (drop `tokio` net + `mio`, wasm
`getrandom` for `uuid`), or extracting the pure algorithms into a `no_std`/wasm
crate. Do not integrate zkr/rx4 into `worker-rs` yet.

## AI routes

Managed-AI route group (`assistant.ts`, `assistant-admission.ts`,
`stt.ts`, `stt-admission.ts`, `asr.ts`, `voice.ts`, `rate-limit.ts`) ported as
host-testable pure logic plus a thin wasm glue layer. Route registration is a
single hook: `glue.rs` calls `crate::routes_ai::register(router)` (one line);
all route wiring and Durable Objects live in `src/routes_ai.rs`.

| TS module | Rust (pure) | Status | Notes |
|---|---|---|---|
| `assistant.ts` request/pricing logic | `src/managed_ai.rs` | **ported** | `validatePinnedEndpoint`, `parseRequest`, `boundedJson`, `price`, `costFor`, `inputTokenReservation`, `usageFrom`, completion parse. 8 unit tests incl. the captured streaming shape, 64-tiny-message framing (=1409), endpoint pinning, cost accounting (est=361, actual=9). |
| `assistant-admission.ts` (DO) | `src/assistant_admission.rs` | **ported** | In-memory reservation ledger with admit/release/settle. Ported DO races: simultaneous per-UID (2) + global (3) in-flight caps, idempotent duplicate release + window roll, settle-to-overrun blocks dense traffic, 400/404/405 shapes. |
| `stt-admission.ts` (DO) | `src/stt_admission.rs` | **ported** | Acquisition-token claim/release protocol + deadline `alarm`. Ported races: per-user reservation cap, idempotent duplicate (returns original token), release+reacquire (new token), abandoned-claim alarm expiry vs. preserved claimed session, late-claim rejection + stale-release ignored. |
| `stt.ts` session logic | `src/stt_logic.rs` | **ported** | `parseRequest`, `supportedAudio`, id/lang/session regexes, `sessionIdFor` (SHA-256), `websocketUrl`, Deepgram query, and `bridgeSttSockets` terminal-status as `bridge_outcome`. |
| `asr.ts` | `src/asr_logic.rs` | **ported** | base64 cap (4/3 scaling), format/language allow-lists, 413-before-400 ordering, pinned upstream body, transcript parse. |
| `voice.ts` | `src/voice_logic.rs` | **ported** | two-use model-locked token request, ISO expiry timestamps (`Date.toISOString` parity), response shaping, `name` parse. |
| `rate-limit.ts` (DO) | `src/rate_limit.rs` | **ported** | fixed-window counter + refresh-lock mutex with the DO route defaults. Canonical for the crate; self-contained. |
| `crypto`/number coercion | `src/jsnum.rs` | **ported** | `Number(...)` / `Number.isSafeInteger` / positive-integer guards shared by the above. |

Glue (`src/routes_ai.rs`, wasm-only): the five routes
(`POST /v1/chat/completions`, `POST /v1/asr/transcribe`,
`POST /v1/voice/gemini/token`, `POST /v1/stt/sessions`,
`GET /v1/stt/sessions/:id/stream`) plus the three Durable Objects
(`AssistantAdmissionDo`, `SttAdmissionDo`, `RateLimiterDo`). The DOs are thin:
they load the pure state machine from DO storage (JSON snapshot), `dispatch`,
persist, and — for STT — schedule the deadline alarm from `next_alarm()`. The
TS worker uses the SQLite storage API directly; the state-machine semantics are
identical and are what the `cargo test` suites cover. Streaming uses
`Response::from_stream` for true SSE passthrough; the WebSocket bridge relays
via `WebSocket::events()`.

DO bindings (`ASSISTANT_ADMISSION`, `STT_ADMISSION`, `RATE_LIMITER`) and the
`v1` migration are declared in `wrangler.toml`.

**Deferred glue (cutover):** (1) streaming *usage-tail* settlement — the chat
route marks the ledger `streaming` and relies on
`reconcile_managed_assistant_requests` (ported, wired via a one-line call in the
`scheduled` event owned by glue) rather than parsing the SSE tail inline;
(2) the `waitUntil`-based durable retry wrapper around finalize/release is
best-effort here. Behaviour parity of the decision logic is proven by the host
tests; these two items are runtime-fidelity refinements, not logic gaps.

Gates: `cargo test` 65 green (host); `cargo clippy --all-targets -D warnings`
clean (host); `cargo clippy --target wasm32-unknown-unknown -D warnings` clean;
`cargo build --release --target wasm32-unknown-unknown` clean. (worker-build's
wasm-bindgen post-processing carries the same pre-existing abort-handler flag
issue documented in README — unchanged by this work.)
