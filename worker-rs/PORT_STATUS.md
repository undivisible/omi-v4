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
