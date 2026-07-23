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
