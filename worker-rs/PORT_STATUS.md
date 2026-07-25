# PORT_STATUS — TypeScript worker → Rust (workers-rs)

> **Production cutover complete (2026-07-24).** `worker-rs` serves
> `omi.tsc.hk` and `api.omi.tsc.hk`. `worker/` owns the D1 migrations, the
> static `public/` assets that `worker-rs` serves, and the build scripts; its
> routes and cron are disabled. FaceTime is intentionally absent in Rust (no
> bridge container; returns 501 / tool absent).
>
> **`worker/src` and `worker/test` are retained deliberately.** A scenario-level
> audit on 2026-07-25 found that the port is **not** at parity: the features in
> the "absent" table below were never ported at all. Until each is either ported
> or written off as dead product surface, the TypeScript is the only complete
> specification of what they did, and the TS tests are the only precise record of
> their behaviour. Treat that directory as a frozen reference, not as live code.

## Audit snapshot (2026-07-24, post-cutover)

**Production:** `worker-rs` (`omi-v4-api-rs`) on `omi.tsc.hk` + `api.omi.tsc.hk`.
**Migrations:** `worker/` (`omi-v4-api`) — no routes, no cron.

`worker-rs` is the authoritative behavioural implementation: it is what serves
production. The TypeScript remains the authoritative *specification* for the
behaviour that was never ported. The tables below record what was ported and,
more importantly, **what was not**. Treat the "absent" list as the live defect
backlog, not as historical notes.

### Route-surface parity (re-audited 2026-07-25, against code)

The previously recorded "~95% parity" was optimistic. A scenario-level audit of
the retired TS test suite against the Rust sources found the following gaps.
Anything marked **absent** is behaviour the production worker does not have.

| Gap | Severity | Status |
|---|---|---|
| `channel-checkout.ts` — `/subscribe` in chat, Stripe link issuance, webhook provisioning, `invoice.payment_failed` / `checkout.session.expired` | High | **ported 2026-07-25** — `channel_checkout.rs` + `routes_channels` + Stripe webhook/`stripe_sync` reconcile |
| `channel-signup.ts` — first-contact question, `parseSignupAnswer`, chat-native accounts, claim/retire helpers | High | **partial** — signup/first-contact/`/subscribe` ported (`channel_signup.rs`); **claim-on-link still missing** (see below) |
| Cloudflare AI Gateway (`aiGatewayRoute`) incl. the account/gateway id path-smuggling validation | Medium | **absent** — `CF_AI_GATEWAY_*` vars in `wrangler.toml` are read by nothing |
| Managed speech routes (`/api/v1/speech/*`) and the `speak_text` / `transcribe_audio` MCP tools | Medium | **absent** — `speech.rs` is a fully tested pure island with no caller |
| Authoritative memory log — append-on-sync, `GET /memory/log`, `memory_log_cursors` | Medium | **absent** — `memory_log.rs` is now compiled and tested but still has no route |
| `observability.ts` — Sentry error capture + Better Stack log shipping | Medium | **partial** — the cron heartbeat is ported (`glue::ping_heartbeat`); `createSentry`, the `onError` capture and the `tail` log export are still absent, native Workers Observability only |
| Streaming usage-tail settlement writes no `status='complete'` row for a streamed turn | Medium | reconciled by cron only |
| STT "idempotency key reused with different configuration" 409 | Medium | **absent** — the row is re-read but not compared |
| BYOK negotiation: closing the prior open session on start, and the superseded-session accept guard | Medium | **absent** |
| `user-profile.ts` `formatAboutUser` in memory context | Low | ported 2026-07-25 (`user_profile.rs`), not yet wired into `wasm_glue` |
| FaceTime / `facetime-bridge` | High if product-critical | **intentionally absent** — 501 / no MCP tool; needs bridge container |
| `DELETE /account` Vectorize claim purge | Low | deferred |
| Audio bytes persistence on device upload | Known stub | both TS and RS returned `persisted: false` |

**Closed 2026-07-25** (were absent, now ported with host tests):

- **The Stripe webhook dropped the unclaimed-customer guard.** Both entitlement
  writes in `glue.rs` set `stripe_customer_id = excluded.stripe_customer_id`
  unconditionally. `entitlements.stripe_customer_id` is uniquely indexed
  (migration 0004) and Stripe reuses one customer across two Omi accounts that
  share an email, so the second account's webhook threw on the index — a 500,
  and no entitlement for someone who had paid. `stripe-entitlement.ts:20` records
  that this had already happened once and been fixed there; the port lost the
  fix. Worse, the reconciliation sweep could not repair it, because the sweep
  would hit the same index: the one customer the net exists for was the one it
  could never catch. Both statements now use the guarded
  `stripe_sync::{CLAIM_STRIPE_CUSTOMER_SQL, APPLY_SUBSCRIPTION_STATE_SQL}`, so
  the webhook and the sweep share one statement and cannot diverge again.
- `POST /v1/webhooks/sendblue/:token` — the parser was ported but **no route was
  registered**, so iMessage inbound was dead in production. Registered in
  `glue.rs`.
- `crepus-safety.ts` → `src/crepus_safety.rs` — the closed action-verb set and
  the image-`src` SSRF guard (private/link-local/`.local`/`.internal` hosts,
  userinfo, 2000-char cap). `currents::sanitize_crepus` previously applied only
  a length cap.
- `channel-group.ts` → `src/channel_group.rs` — group chats could be linked as a
  personal channel. Now guarded in `glue::bind_channel` and
  `routes_channels::issue_link_code`.
- `channel-style.ts` → `src/channel_style.rs` — markdown was reaching Telegram
  and iMessage unsanitized and replies were not capped per channel. Wired into
  `inbox_fallback` and `routes_channels::send_channel_text`.
- `user-profile.ts` → `src/user_profile.rs` (pure logic; wiring pending).
- `memory_log.rs` was never declared in `lib.rs` — dead code whose five tests
  never ran. Now compiled.
- **The cron ran four of the TS worker's seven scheduled jobs.** `cron-cursor.ts`
  → `src/cron_cursor.rs`, `digests.ts` → `src/digests.rs`, and the
  `generateDueCurrents` driver → `currents.rs::wasm_glue`, all three wired into
  `glue.rs::scheduled` along with the Better Stack heartbeat. Until this landed,
  no user had received a cron-minted Current or a digest since the 2026-07-24
  cutover, and the missing heartbeat is why that went unnoticed: the monitor was
  never told the batch had run, so it had nothing to alert on.
- **`currents.ts` was recorded below as "ported" while its cron driver had never
  been written.** The routes were ported; `generateDueCurrents` — the daily
  driver that mints Currents for every onboarded user in their local morning —
  was not, and the row said nothing about it. Corrected in place. Read that as a
  warning about this document: a row that names a file is not evidence that
  every exported symbol in the file has a counterpart here.

Legend: **ported** (parity, tested) · **partial** (some routes) ·
**pending** (not started) · **blocked** (needs a workers-rs binding gap
resolved — noted inline).

## Phase 1 (this task)

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `auth.ts` | `src/auth.rs` + `glue.rs::authenticate`/`firebase_keys` | **ported** | RS256 via RustCrypto `rsa` (pure, no WebCrypto). JWKS fetch + per-isolate cache + Cache-Control max-age. Same 401/503 error shapes. 13 unit tests. |
| `entitlement.ts` | `src/entitlement.rs` + `glue.rs::has_active_pro` | **ported** | `DEV_FAKE_PRO`/`ENVIRONMENT` guard + row matrix. 8 tests. |
| `index.ts` (fetch router, `/health`, `scheduled`) | `glue.rs::fetch` + `glue.rs::scheduled` | **ported** | Router + `/health` + all route groups registered. The single `#[event(scheduled)]` runs every minutely-cron piece in TS order: `generateDueDigests → generateDueCurrents → deliverDueChannelMessages` (one chain: digests are generated before deliveries drain so a digest entering the queue this tick ships in the same batch, and a failure earlier in the chain skips the rest of it), `respondToStaleInboxItems`, `reconcileManagedAssistantRequests`, `reconcileStripeSubscriptions`, then `backfillClaimVectors → drainPendingEmbeddings` (memory `cron_slice`), then `pingHeartbeat`. `[triggers] crons = ["* * * * *"]` declared in `wrangler.toml`. DO exports present. Divergences: workers-rs Router handlers get no execution `Context`, so the TS `waitUntil` slices are awaited inline (each error-isolated, matching the per-branch `.catch`) and run sequentially rather than concurrently. Heartbeat parity is exact including the asymmetry — `reconcileManagedAssistantRequests` is the only TS branch without a `.catch`, so it is the only failure that suppresses the beat. |
| `routes.ts` → `GET /me` | `glue.rs::handle_me` | **ported** | Includes `channel_bindings` lookup. |
| `routes.ts` → `GET /setup-health` | `src/setup_health.rs` + `glue.rs::handle_setup_health` | **ported** | Identical boolean shape. 4 tests. |
| `routes.ts` → `GET /entitlement` | `glue.rs::handle_entitlement` | **ported** | |
| `routes.ts` → `GET|PUT /profile/onboarding` | `glue.rs::handle_onboarding_*` | **ported** | Same INSERT…ON CONFLICT + 400 on `complete!=true`. |
| `routes.ts` → `GET|PUT /settings` | `src/settings.rs` + `glue.rs::handle_settings_*` | **ported** | Security-relevant: `PUT` owns `user_settings.revision` (= `policy_generation`), the mechanism a user uses to revoke standing current-approvals — the approval gate in `routes_memory/wasm_glue.rs` reads `policy_generation = COALESCE((SELECT revision FROM user_settings…), 0)`, so without this route the revision could never bump and revocation was inoperative. Parity: same up-front validation (patch keys, `Number(expectedRevision)` safe-int ≥0 with `undefined`→NaN reject, duration allow-list, approval/proactive value checks), 409 revision conflict, `expandsAuthority` owner-confirmation-receipt consume (403 shapes), scoped `setting_scopes` upsert (`ON CONFLICT(uid,duration,scope_id)`) vs persistent `revision+1` UPDATE / `revision=1` INSERT-OR-IGNORE, `settingsDiff`, and the scopeId/expiresAt guards. Pure logic + 8 host tests in `settings.rs`. |
| `routes.ts` → `POST /channels/:channel/messages` | `glue.rs::handle_channel_message_post` + `routes_channels::dispatch_channel_message` | **ported** | App-initiated outbound send: `text`/idempotency-key validation (len≥8 + `^[A-Za-z0-9._:-]+$`), `channel_bindings` lookup (409 not-linked), idempotent `INSERT OR IGNORE INTO channel_deliveries` + re-read conflict (409), `appendConversationMessage` (409 on conflict), DeliveryCoordinator `/deliver` dispatch (503 on failure), and the 200/503/502/202 status machine from the re-read state. `dispatch_channel_message` added to `routes_channels.rs` (uses the existing `dispatch_to_coordinator`). Pure `valid_idempotency_key` + `delivery_status` with 2 host tests in `delivery.rs`. |
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
| `embeddings.ts` + `memory-vectors.ts` (search path) | `routes_memory/wasm_glue.rs` | **ported (default)** | Single hand-written `js_sys` FFI to the JS `VectorizeIndex` object (`query`/`upsert`/`deleteByIds` with metadata filters) plus `embed_texts` via the native `Ai` binding, compiled by DEFAULT. `MEMORY_VECTORS`/`AI` declared in `wrangler.toml`; when unbound at runtime the FFI returns `None` and memory context is `null` (TS parity). The old feature-gated duplicate `src/vectorize_ffi.rs` and the `vectorize` cargo feature were REMOVED. See "Vectorize FFI outcome" below. |
| `rate-limit.ts` (RateLimiter DO) | `src/rate_limit.rs` + `routes_ai.rs::RateLimiterDo` | **ported** | Fixed-window counter + refresh-lock mutex. The `#[durable_object] RateLimiterDo` lives in `routes_ai.rs`; the `RATE_LIMITER` binding and the `v1` migration class are declared in `wrangler.toml`. See "AI routes" below. |

### Vectorize FFI outcome (unified, default-on)

There is now **one** Vectorize implementation: `routes_memory/wasm_glue.rs`. It
binds the `VectorizeIndex` JS object by reading the `MEMORY_VECTORS` binding off
the env with `js_sys::Reflect` and invoking `query`/`upsert`/`deleteByIds` as JS
methods; embeddings use the native `worker::Ai` binding. It is compiled **by
default** (the `vectorize` cargo feature and the duplicate `src/vectorize_ffi.rs`
were deleted). `[[vectorize]]` (`binding = "MEMORY_VECTORS"`,
`index_name = "omi-memory-claims"`) and `[ai]` (`binding = "AI"`) are declared
in `wrangler.toml`. Runtime is fail-safe: when the bindings are absent the FFI
returns `None` and memory context is `null`, matching TS behaviour — so the
build is honest with or without the index provisioned. The scheduled
`backfillClaimVectors`/`drainPendingEmbeddings` drivers run via `cron_slice`;
`DELETE /account` vector cleanup remains the one deferred Vectorize consumer
(documented in Phase 1).

## Device cloud sync (home STA)

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `device-sync.ts` | `src/device_sync.rs` + `routes_device.rs` | **ported** | `POST /api/v1/devices/register` (Firebase) mints `omi_dev_` token (SHA-256 digest stored; prior tokens revoked); 10/hour register rate limit via RateLimiter DO. `POST /api/v1/devices/:deviceId/audio` requires Bearer/`x-device-token`, rejects revoked device **or** token (SQL join), enforces 4 MiB + 30/min upload rate limit, inserts `device_audio_uploads` metadata, returns `persisted: false` (same stub as TS). `startSeq` accepted as number or decimal string (u64-safe). `parseHomeUploadPreamble` host-tested. Account-delete table list updated (`devices` / `device_tokens` / `device_audio_uploads`). |

## Currents refresh

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `currents-refresh.ts` | `src/currents_refresh.rs` + `wasm_glue.rs` | **ported** | `POST /v1/currents/refresh`: gatherRefreshContext, aiNeedsRefresh, aiDrafts/heuristicDrafts, regenerateCurrents, read/write state. OpenRouter speed tier via `OPENROUTER_API_KEY`. |

## Later phases (larger surface / binding-dependent)

| TS module | Status | Notes |
|---|---|---|
| `assistant.ts`, `assistant-admission.ts` (DO) | **ported** | See "AI routes" below. |
| `conversations.ts` | **ported** | See the Delivery / AI / Memory sections below; D1 replay + inbox landed. |
| `currents.ts` | **ported** | Routes + refresh: see "Memory & currents" below. The `generateDueCurrents` cron driver was missing when this row first read "ported"; ported 2026-07-25 into `currents.rs::wasm_glue` — see "Cron jobs" below. |
| `delivery.ts` (DeliveryCoordinator DO) | **ported** | See "Delivery" below. |
| `stt.ts`, `stt-admission.ts` (DO), `asr.ts`, `voice.ts` | **ported** | See "AI routes" below. |
| `memory-projection.ts`, `memory-sync.ts` | **ported** | See "Memory & currents" below. |
| `memory-vectors.ts`, `embeddings.ts` | **ported (default)** | Vectorize via `js_sys` FFI; see Vectorize section. |
| `facetime.ts` / bridge | **intentionally absent** | Needs Gemini Live bridge container; keep on TS until that stack exists for RS. Hub FaceTime join is behind `facetime` Cargo feature (default off). |
| `digests.ts`, `cron-cursor.ts` | **ported** | See "Cron jobs" below. |
| `stripe-sync.ts` | **ported** | `src/stripe_sync.rs`, ported separately; `reconcileStripeSubscriptions` is wired into `glue.rs::scheduled` in its TS position. |
| `observability.ts` | **partial** | Heartbeat only; Sentry capture and tail log shipping remain absent. See the audit table above. |
| `channel-checkout.ts` | **ported** | `src/channel_checkout.rs` + `routes_channels` + webhook/`stripe_sync` reconcile; `/subscribe` in `CHANNEL_COMMANDS`. |
| `channel-signup.ts` | **partial** | Pure signup + first-contact in `channel_signup.rs` / `routes_channels`; **claim-on-link on `POST /v1/channels/link` still missing** — TS retires/claims the chat-native placeholder (`claimChannelAccount`) when redeeming a link code; Rust `handle_channel_link_redeem` binds only and does not claim the placeholder, and rejects an existing binding owned by that placeholder with 409. |

## Cron jobs

The minutely cron is the whole of the product's proactive surface, and it is the
one place where "the module exists" and "the module runs" come apart: a driver
that nothing calls looks identical to a ported one in a table like this. All
seven TS jobs now run. Ordering inside `glue.rs::scheduled` is behaviour — see
the `index.ts` row in Phase 1.

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `cron-cursor.ts` | `src/cron_cursor.rs` | **ported** | `loadCronCursor`/`saveCronCursor`/`scanOnboardedUsers` over `cron_cursors`. The keyset page resumes strictly after the stored uid and wraps to the head within the same tick when the tail is exhausted; the wrap is completed by *writing* `""`, not only by the re-query, which is what stops a cursor parking past the tail for ever. Each cron name rotates independently. Rotation decisions are pure (`should_wrap`, `cursor_after_page`) with 6 host tests that replay the TS `cron-cursor.test.ts` page/wrap sequence against an in-memory keyset. |
| `digests.ts` | `src/digests.rs` | **ported** | `localClock`, the daily (07) / nightly (21) local windows, both body builders and `storeDigest` (fixed `input_revision` per kind → UNIQUE (uid, local_date, input_revision) idempotency, citations, and the single `channel_deliveries` enqueue keyed `digest:<kind>:<uid>:<local_date>`). Clock, window test and body assembly are pure with 19 host tests: negative offsets, fractional offsets (+05:30, +05:45, −03:30), the hour-wide window swept minute by minute, local midnight / month / leap-year rollover, the nightly `[day_start, +1 day)` window against a non-UTC day, and the local-date idempotency key across a whole local day. |
| `currents.ts` → `generateDueCurrents` | `currents.rs::wasm_glue` | **ported** | Daily driver: rotate a page of onboarded users, gate on the user's own local 07 hour, skip anyone with a `currents_daily_batches` row for that local date, mint up to 3 via the existing `generate_one_current`, then record the batch row (written even when nothing was minted — it marks the turn, not the yield). `CURRENTS_DAILY_HOUR` aliases `digests::DAILY_HOUR` so the two windows cannot drift. 2 host tests. |
| `observability.ts` → `pingHeartbeat` | `glue.rs::ping_heartbeat` | **ported** | POST to `BETTERSTACK_HEARTBEAT_URL` (read as var-then-secret, undeclared in `wrangler.toml` on purpose so an unconfigured environment is simply silent), every failure path silent. Fired only when the batch resolves, so a broken cron alerts by *absence*. |

Known parity gaps in this group (documented, not defects):
- Body caps count Unicode scalars (`chars().take(4096)`) where the TS `slice`
  counts UTF-16 code units; they differ only for astral characters straddling
  the 4096th position. Same divergence as the channel reply cap.
- The five cron branches run sequentially rather than under a `Promise.all`, so
  a slow branch delays the ones after it within a tick (crate-wide divergence:
  workers-rs handlers get no execution `Context`).

Gates after this group (rustup `stable`): `cargo test --lib` 385 passed / 1
ignored · `cargo clippy --all-targets -- -D warnings` clean ·
`cargo clippy --target wasm32-unknown-unknown -- -D warnings` clean.

## workers-rs 0.8.5 binding support (findings)

| Capability | Native in workers-rs 0.8.5? | How used here / interop needed |
|---|---|---|
| **D1** | Yes (`d1` feature; `env.d1()`, `prepare/bind/run/first/all/batch`) | Used directly in Phase 1. |
| **Secrets / vars** | Yes (`env.secret()`, `env.var()`) | Used directly. |
| **Fetch / outbound HTTP** | Yes (`worker::Fetch`) | JWKS fetch. |
| **Scheduled / cron** | Yes (`#[event(scheduled)]`, `ScheduledEvent`) | Wired: `[triggers] crons = ["* * * * *"]` drives `glue.rs::scheduled`. |
| **Durable Objects** | Yes (`#[durable_object]`, SQLite storage) | Wired: `DeliveryCoordinator`, `AssistantAdmissionDo`, `SttAdmissionDo`, `RateLimiterDo`. |
| **Workers AI** | Yes (`Ai` binding struct) | Wired: `embed_texts` in `routes_memory/wasm_glue.rs` via the `AI` binding. |
| **Vectorize** | **No native binding** | Requires raw JS interop via `js_sys`/`wasm_bindgen` against the bound `VectorizeIndex` JS object (query/insert/upsert/deleteByIds). This is the main interop gap; `memory-vectors.ts` and the `DELETE /account` vector cleanup depend on it. |
| **Crypto (RS256 etc.)** | via RustCrypto crates (no `crypto.subtle` needed) | `rsa` + `sha2` compile clean to wasm. HMAC/constant-time for webhooks will use `hmac` + `subtle`. |

Net: everything is natively supported except **Vectorize**, which is bound by
hand-written `wasm_bindgen`/`js_sys` interop against the JS `VectorizeIndex`
object (see the Vectorize section above).

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

## Delivery

Group port of `delivery.ts` and `inbox-fallback.ts`. Pure logic lives in
`src/delivery.rs` and `src/inbox_fallback.rs` (host-testable); the wasm I/O
layer is `src/routes_channels.rs`, added to lib.rs by the single
`mod routes_channels` line.

The dev-only OAuth broker/proxy that this group also carried was deleted along
with its TS originals.

| TS module | Rust | Status | Notes |
|---|---|---|---|
| `delivery.ts` | `src/delivery.rs` + `routes_channels.rs` | **ported** | `DeliveryCoordinator` DO (`#[durable_object]`, per-uid/channel identity fencing, `/deliver` `/unlink` `/cancel-orphans`), Telegram/Blooio provider sends, retry-after (header seconds + HTTP-date + JSON `retry_after`) with jittered exponential backoff, orphan cancellation, ambiguous-Telegram `unknown` outcome, stable idempotency-key digest. `deliverDueChannelMessages` cron piece ported as `deliver_due_channel_messages(env)` (additive; wire into the unified `#[event(scheduled)]` at merge). 15 pure unit tests. |
| `inbox-fallback.ts` | `src/inbox_fallback.rs` + `routes_channels.rs` | **ported** | 2-min claim threshold, lease claim/fencing (`channel_inbox` UPDATE…RETURNING + `lease_token` guard), retry/failed release transitions, non-Pro static ack, final-attempt ack, `CHANNEL_FALLBACK_RESPONDER` flag, prompt assembly + reply trim/cap. Cross-group calls now WIRED: `runManagedInboxCompletion` → `routes_ai::run_managed_inbox_completion` (admission DO admit/settle/release + `managed_ai_requests` ledger + non-streaming MIMO completion), `memoryContextFor` → `routes_memory::memory_context_for` (single Vectorize impl), `completeInboxItemDone` → `glue::complete_inbox_done` (delivery + conversation-message batch with the `Channel is not linked` re-read). 6 pure unit tests. |

wrangler.toml: appended `DELIVERY_COORDINATOR` + `RATE_LIMITER` DO bindings and
a `new_classes` migration in a marked block (dedupe `RATE_LIMITER` at merge).


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
| `currents.ts` | `routes_memory.rs` (pure) + `wasm_glue.rs` | **ported** | generate/candidates/list/feedback/accept/approve/receipt-claim/reject/outcome. Deterministic confidence+learned-adjustment ordering (SQL) + weights host-tested; `rowToCurrent` projection + ISO formatting host-tested; sha256 (RustCrypto), receipt tokens (base64url), uuid v4. **Routes only** — the `generateDueCurrents` cron driver is `currents.rs::wasm_glue`, ported 2026-07-25 (see "Cron jobs"). Known gap: `generate_one_current` does not author the `heroCrepus` `.crepus` hero column the TS insert carries, so a cron-minted or `/generate`d Current renders as the client's hand-built row rather than the Now-Brief card. |
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

## Cutover readiness — remaining risks (honest list)

Production cutover is **done** (2026-07-24). The 2026-07-25 audit found the
earlier "~95% parity" figure was optimistic; the absent-behaviour rows in the
table above are the backlog that number concealed. Residual risks:

- **The absent features are absent in production, not merely untested.** Chat
  `/subscribe` checkout and chat-native signup **were ported 2026-07-25**
  (`channel_checkout` / `channel_signup` / `routes_channels`). Remaining channel
  gap: **claim-on-link** — `POST /v1/channels/link` does not claim/retire the
  chat-native placeholder account the way TS `routes.post("/channels/link")`
  does, so redeeming a code against a signup-created placeholder can 409 or
  leave an unclaimed `channel_accounts` row. `claim_channel_account` exists but
  is not called from the redeem path.
- **Digests, daily Currents and cursor rotation were inert from the 2026-07-24
  cutover until they were ported on 2026-07-25.** No user received a
  cron-minted Current or a digest in that window. The three jobs are now in
  `glue.rs::scheduled`, but nothing has replayed the missed days: users are
  current from the next tick in their local morning, not backfilled. The
  heartbeat that would have caught this within a minute is now ported too, and
  is the reason to treat any future silent cron as a monitoring failure first.
- **DELETE /account Vectorize cleanup** still deferred: account deletion removes
  all D1 rows but does not delete the user's claim vectors from the
  `omi-memory-claims` index. Orphaned vectors are uid-filtered and never
  surfaced to other users, but they are not purged. The `delete_by_ids` FFI
  exists; wiring it into the delete path is the one open Vectorize consumer.
- **Durable Object state does not migrate** at cutover. The Rust worker uses its
  own DO namespace (`AssistantAdmissionDo`/`SttAdmissionDo`/`RateLimiterDo`/
  `DeliveryCoordinator`). In-flight admission ledgers and rate-limit counters
  reset; both are short-TTL/self-healing and reconverge within a cron cycle.
- **Provider `fetch` timeouts**: workers-rs `RequestInit` has no `AbortSignal`
  field, so the TS per-request `AbortSignal.timeout(...)` guards are dropped in
  favour of the platform subrequest timeout (delivery, MIMO completion).
- **Streaming usage-tail settlement** for `/v1/chat/completions` is reconciled
  by the minutely cron rather than parsed inline; budgets converge within one
  cron cycle (TS-equivalent deferral).
- **Local dev caveat**: Vectorize is "not supported" in `wrangler dev --local`
  and AI "always remote"; semantic-search paths return null/empty locally. This
  is a Miniflare limitation, not a port gap — both work against the deployed
  worker (or `wrangler dev --remote`).
- **Assets path** `../worker/public` is outside the project dir; wrangler 4.x
  accepts it (verified). If a future wrangler rejects it, copy into
  `worker-rs/public/` via a `[build]` step (documented in CUTOVER.md).

## Build pipeline (RESOLVED)

`worker-build --release` produces `build/worker/shim.mjs` + `build/index_bg.wasm`
and `npx wrangler deploy --dry-run --outdir /tmp/wrs-dry` succeeds. The former
"externref table required for catch wrappers" blocker was `[profile.release]
strip = true` stripping the wasm `target_features` section that wasm-bindgen
reads to detect `reference-types`; fixed by `strip = false` (wasm-opt still
strips debug info for size). See README.md and CUTOVER.md.
