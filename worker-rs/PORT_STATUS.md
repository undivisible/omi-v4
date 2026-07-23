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

## Phase 2 (this task — landed)

Same pure-logic/glue split as Phase 1: pure decision/crypto logic in
host-testable modules (`cargo test`), thin wasm glue for D1/fetch/JS interop.

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `webhooks.ts` | `src/webhooks.rs` + `src/crypto_util.rs` + `glue.rs::handle_webhook_*` | **ported** | Telegram (constant-time secret-header compare via `subtle`), Blooio + Stripe (timestamped HMAC-SHA256 ±300s, `hmac`/`sha2`), `webhook_events`/`stripe_events` dedupe, link-token binding with conflict detection (`bind_channel`), `channel_inbox` + conversation append idempotency (`enqueue_channel_message`/`append_conversation_message`), Stripe entitlement state machine incl. the `stripe_event_created` ordering guard. 24 pure tests (HMAC vectors, link-token regexes, Telegram/Blooio/Stripe extraction). |
| `billing.ts` | `src/billing.rs` + `glue.rs::handle_billing_*` | **ported** | Stripe checkout/portal via `fetch` (form-encoded, `stripe-version` pinned), metadata `firebase_uid` propagation, customer-id-over-email precedence, fail-closed 503 when unconfigured / 502 on provider failure / 404 no customer. 6 pure tests. |
| `desktop-auth.ts` | `src/desktop_auth.rs` + `glue.rs::handle_desktop_*` | **ported** | 3-step handoff (start/complete/exchange): PKCE-style SHA-256 verifier challenge, single-use consumption (`consumed_at` change guard), 6-digit confirmation with atomic 5-attempt lockout (`bind_desktop_session`), per-IP 10/10min rate limit, public-origin validation, service-account RS256 custom-token signing (RustCrypto `rsa` PKCS#8). 8 pure tests incl. sign→verify round-trip and escaped-newline PEM. |
| `conversations.ts` | `src/conversations.rs` + `glue.rs::handle_inbox_*`/`handle_messages_*`/`handle_cursor_put` | **ported** | Inbox claim/complete lease mechanics, atomic completion batch with the `Channel is not linked` re-read fallback, retry state machine + completion idempotency, replay messages/cursors with optimistic-revision conflict (409). Payload-hash idempotency shared with webhooks. 8 pure tests. `memoryContext` returns `null` unless the `vectorize` feature is on (see below) — parity-safe because TS also returns null when `MEMORY_VECTORS`/`AI` are unbound. `dispatchChannelMessage` (DeliveryCoordinator DO) is a best-effort call the TS wraps in try/catch-ignore; skipped here (DO is a later phase; the scheduled drain still delivers). |
| `embeddings.ts` + `memory-vectors.ts` (search path) | `src/vectorize_ffi.rs` | **ported (feature-gated)** | Hand-written `wasm_bindgen`/`js_sys` FFI to the JS `VectorizeIndex` object: `query`/`upsert`/`deleteByIds` with metadata filters, plus `embed_texts` via the native `Ai` binding. JSON round-trip interop (`JSON.parse`/`stringify`) keeps it dependency-light. Wires `memory_context_for` into inbox claim. **OFF by default** behind `--features vectorize`; MEMORY_VECTORS/AI bindings must be declared in `wrangler.toml` before enabling. See "Vectorize FFI outcome" below. |
| `rate-limit.ts` (RateLimiter DO) | — | **pending** | Durable Objects natively supported in workers-rs via `#[durable_object]`; mechanical, deferred. |

### Vectorize FFI outcome

The known interop gap is **resolved**, not stubbed-silently. `vectorize_ffi.rs`
binds the `VectorizeIndex` JS object by reading the `MEMORY_VECTORS` binding off
the env with `js_sys::Reflect` and invoking `query`/`upsert`/`deleteByIds` as JS
methods, marshalling arguments/results as JSON. Embeddings use the native
`worker::Ai` binding (`env.ai("AI")`). It compiles and lints clean on
`wasm32-unknown-unknown` under `--features vectorize` (clippy `-D warnings`) and
builds in release. It is **gated OFF by default** so the shipped default build
declares no Vectorize/AI bindings and the inbox `memoryContext` is honestly
`null` (matching TS behaviour when those bindings are absent) — no silently
broken vector code. Remaining before enabling in production: declare
`[[vectorize]]` (`binding = "MEMORY_VECTORS"`) and the `[ai]` binding in
`wrangler.toml`, and port the scheduled `drainPendingEmbeddings`/
`backfillClaimVectors`/`deleteClaimVectors` drivers (the `upsert`/`delete_by_ids`
FFI they need is already implemented) plus the `DELETE /account` vector cleanup.

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

## Delivery & OAuth

Group port of `delivery.ts`, `inbox-fallback.ts`, `oauth-broker.ts`,
`oauth-proxy.ts`, plus a self-contained `rate-limit.ts` copy. Pure logic lives
in `src/delivery.rs`, `src/oauth.rs`, `src/inbox_fallback.rs` (host-testable);
the wasm I/O layer is `src/routes_channels.rs` + `src/rate_limit_lock.rs`.
Routes join the shared Router via `routes_channels::register` (single merge seam
line in `glue.rs::fetch`); `mod routes_channels` + `mod rate_limit_lock` are the
two lib.rs lines. AES-GCM at rest uses RustCrypto `aes-gcm` (wasm-clean,
byte-compatible with the TS WebCrypto layout: 12-byte IV prepended, 16-byte tag
appended).

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `delivery.ts` | `src/delivery.rs` + `routes_channels.rs` | **ported** | `DeliveryCoordinator` DO (`#[durable_object]`, per-uid/channel identity fencing, `/deliver` `/unlink` `/cancel-orphans`), Telegram/Blooio provider sends, retry-after (header seconds + HTTP-date + JSON `retry_after`) with jittered exponential backoff, orphan cancellation, ambiguous-Telegram `unknown` outcome, stable idempotency-key digest. `deliverDueChannelMessages` cron piece ported as `deliver_due_channel_messages(env)` (additive; wire into the unified `#[event(scheduled)]` at merge). 15 pure unit tests. |
| `inbox-fallback.ts` | `src/inbox_fallback.rs` + `routes_channels.rs` | **partial** | 2-min claim threshold, lease claim/fencing (`channel_inbox` UPDATE…RETURNING + `lease_token` guard), retry/failed release transitions, non-Pro static ack, final-attempt ack, `CHANNEL_FALLBACK_RESPONDER` flag, prompt assembly + reply trim/cap — all ported. Pro completion (`runManagedInboxCompletion`), `memoryContextFor`, and `completeInboxItemDone` are **cross-group placeholders** clearly marked in `routes_channels.rs` (MERGE PLACEHOLDERS block); until they land the claim is released for retry so nothing is dropped. 6 pure unit tests. |
| `oauth-broker.ts` | `src/oauth.rs` + `routes_channels.rs` | **ported** | Device start/poll/status/delete, AES-GCM encrypt/decrypt at rest, pinned x.ai discovery with per-isolate cache + endpoint allowlist, poll error allowlist (202 pending vs 400), `account_id` pattern, `ENABLE_DEV_OAUTH_BROKER` gate, `oauth-device-start`/`oauth-device-poll` rate limits. 10 pure unit tests. |
| `oauth-proxy.ts` | `src/oauth.rs` + `routes_channels.rs` | **ported** | Subscription chat proxy, `needs_refresh` leeway check, refresh with `expires_in` fallback TTL, compare-and-swap rotation keyed on the old refresh token + loser re-read, per-`(uid,provider)` refresh lock, streaming upstream passthrough with `no-store`/`nosniff` headers. |
| `rate-limit.ts` | `src/rate_limit_lock.rs` | **ported (self-contained copy)** | `RateLimiter` DO (fixed-window counter + refresh mutex) + `consume_rate_limit`/`acquire_refresh_lock`/`release_refresh_lock`. Dedupe with the rate-limit group at merge (keep one DO + one binding). |

wrangler.toml: appended `DELIVERY_COORDINATOR` + `RATE_LIMITER` DO bindings and
a `new_classes` migration in a marked block (dedupe `RATE_LIMITER` at merge).

glue.rs edits (minimal, additive, no reformatting): `authenticate` /
`AuthOutcome` / `error_json` made `pub(crate)` for reuse by the OAuth handlers;
one merge-seam line calling `routes_channels::register(router)`.

Known parity gaps (documented, not defects):
- Provider `fetch` omits the TS `AbortSignal.timeout(15s)` — workers-rs
  `RequestInit` has no signal field; relies on the platform subrequest timeout.
- `boundedJson` is approximated by a 1 MiB text read + object check rather than
  the streaming byte-cap reader; same reject behaviour for oversize/non-object.
- Reply cap counts Unicode scalars (`chars().take(4096)`) vs the TS UTF-16
  `slice`; differs only for astral characters near the 4096 boundary.

Gates (rustup `stable`, wasm target): `cargo test --lib` 51 green · `cargo
clippy --all-targets -D warnings` clean (host) · `cargo clippy --target
wasm32-unknown-unknown -D warnings` clean · `cargo build --release --target
wasm32-unknown-unknown` clean.
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
## Memory & currents

Parallel module-group port (memory-sync, memory-vectors, embeddings, currents,
and the memory routes from `routes.ts`). All route registrations live in
`src/routes_memory.rs` and its `routes_memory/wasm_glue.rs`, wired via one
`register(router)` hook (single line in `glue.rs::fetch`) plus one
`cron_slice(env)` hook (single clearly-marked call in the additive
`#[event(scheduled)]` handler in `glue.rs`). Pure logic is host-tested; the
workers-rs I/O layer is wasm-only.

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `memory-sync.ts` | `routes_memory.rs` (pure) + `wasm_glue.rs::handle_zkr_sync` | **ported** | `POST /v1/memory/zkr-sync`: scope checks (tenant/person == uid), commit/event staging + 409 conflict shapes, `applyCommit` (idempotent replay, correction/deletion), `touchedClaimIds` → vector enqueue + inline drain. Pure parsing/identity/canonical-json host-tested. |
| `memory-vectors.ts` | `routes_memory.rs` (pure) + `wasm_glue.rs` | **ported** | `projectedClaimId`, `claimText`, drain partition (eligible→upsert / missing→delete), backfill, `searchMemoryClaims` (uid-filtered query + D1 re-check). Vectorize via hand-written `js_sys` FFI (`Vectorize::{query,upsert,delete_by_ids}`); AI via native `Ai` binding. |
| `embeddings.ts` | `routes_memory.rs::{embedding_inputs,parse_embeddings}` + `wasm_glue.rs::embed_texts` | **ported** | `@cf/baai/bge-base-en-v1.5` via `Ai.run`; response-shape validation host-tested. |
| `currents.ts` | `routes_memory.rs` (pure) + `wasm_glue.rs` | **ported** | generate/candidates/list/feedback/accept/approve/receipt-claim/reject/outcome. Deterministic confidence+learned-adjustment ordering (SQL) + weights host-tested; `rowToCurrent` projection + ISO formatting host-tested; sha256 (RustCrypto), receipt tokens (base64url), uuid v4. |
| `memory-projection.ts` | `wasm_glue/projection_sql.rs` + `wasm_glue.rs::{project_zkr_memory,ensure_projected}` | **ported** | Needed by the group; 10-statement projection batch reproduced verbatim, run as per-route middleware. |
| `routes.ts` memory routes | `wasm_glue.rs` | **ported** | `GET/POST /v1/memory/retrieve`, `GET /v1/memory/semantic-search`, `GET|POST /v1/memories`, `POST /v1/memory/sources/:id/revisions`, `DELETE /v1/memory/sources/:id`, `GET|POST /v1/memory/daily-reviews`. |

Cron: `cron_slice` runs `backfillClaimVectors` then `drainPendingEmbeddings`
(parity with `index.ts` scheduled block).

**Divergence (documented):** the TS defers `drainPendingEmbeddings` via
`executionCtx.waitUntil`; workers-rs `Router` handlers do not receive the
execution `Context`, so drains are awaited inline. Vector state converges
identically — only response latency differs.

**Cargo:** enabled `serde_json` `preserve_order` (JS object-iteration parity for
`deletionTarget` shorthand); added wasm-only `serde-wasm-bindgen` (Vectorize FFI
arg/return conversion).

**Parity tests (host, `routes_memory::tests`):** scope rejection, commit-window
validation, canonical-json determinism, record-identity per kind, deletion-target
normalization, touched-claim-id projection/dedupe, embedding-shape validation,
drain partition, memory-context capping, `rowToCurrent` projection, learned
weights + sort key, candidate/feedback/approval/receipt/outcome validation,
retrieve-match quoting, ISO formatting, receipt/hash patterns.

**Gates:** `cargo test` 50 green · `cargo clippy --all-targets -D warnings`
(host) clean · `cargo clippy --target wasm32 -D warnings` clean ·
`cargo build --release --target wasm32-unknown-unknown` clean.
