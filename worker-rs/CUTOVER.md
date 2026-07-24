# CUTOVER — omi-v4-api (TS) → omi-v4-api-rs (Rust)

**Status: DONE (2026-07-24).** Production traffic is on `omi-v4-api-rs` at
`omi.tsc.hk` and `api.omi.tsc.hk`. The TypeScript worker (`omi-v4-api`) remains
deployed for **D1 migrations only** — its `routes` and `triggers.crons` are
disabled in `worker/wrangler.jsonc`.

Both workers bind the **same** D1 database (`database_id 74aab5eb-…`); the **TS
worker owns the schema/migrations** — the Rust worker declares no
`migrations_dir` and must never run D1 migrations.

This document is kept as rollback/deploy reference.

## 0. Prerequisites

- `wrangler` 4.x, logged into the Cloudflare account that owns `omi-v4-api`.
- The rustup **stable** toolchain with the wasm target (host Homebrew rustc has
  no wasm std):
  ```sh
  export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
  ```
- `worker-build` 0.8.5 (`cargo install worker-build`).

## 1. Build & verify locally

```sh
cd worker-rs
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
cargo test --lib                                   # 161 host tests
cargo clippy --all-targets -- -D warnings          # host lint
cargo clippy --target wasm32-unknown-unknown -- -D warnings
worker-build --release                             # produces build/worker/shim.mjs (+ index_bg.wasm)
npx wrangler deploy --dry-run --outdir /tmp/wrs-dry # must succeed
```

> Build note: `[profile.release]` must NOT set `strip = true`. Cargo's strip
> removes the wasm `target_features` custom section that wasm-bindgen reads to
> detect `reference-types` (enabled in `.cargo/config.toml`); without it,
> worker-build's forced `--force-enable-abort-handler` step fails with
> "externref table required for catch wrappers". wasm-opt strips debug info for
> size afterward, so the final bundle is unaffected.

## 2. Create the Vectorize index (one-time, before deploy)

The Rust worker binds `MEMORY_VECTORS` with a graceful runtime fallback (memory
context is `null` when unbound), so deploy will not fail if the index is
missing — but semantic memory search stays dark until it exists. Create it once:

```sh
wrangler vectorize create omi-memory-claims --dimensions=768 --metric=cosine
wrangler vectorize create-metadata-index omi-memory-claims --property-name=uid --type=string
```

Dimensions (768) match Workers AI `@cf/baai/bge-base-en-v1.5`. The `AI` binding
requires no provisioning. If the TS worker already created this index, skip —
the Rust worker binds the same `index_name`.

## 3. Copy secrets

The Rust worker reads the **same** secret names as the TS worker. Set each with
`wrangler secret put <NAME>` (targets `omi-v4-api-rs` from this directory). Full
list:

```
TELEGRAM_WEBHOOK_SECRET
TELEGRAM_BOT_TOKEN
SENDBLUE_API_KEY_ID
SENDBLUE_API_KEY_SECRET
SENDBLUE_NUMBER
SENDBLUE_WEBHOOK_SIGNING_SECRET
SENDBLUE_WEBHOOK_PATH_TOKEN
STRIPE_SECRET_KEY
STRIPE_PRO_PRICE_ID
STRIPE_WEBHOOK_SECRET
APP_URL
MIMO_API_KEY
DEEPGRAM_API_KEY
GEMINI_API_KEY
FIREBASE_SERVICE_ACCOUNT_EMAIL
FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY
```

List what the live TS worker has with `wrangler secret list --name omi-v4-api`
and mirror every entry. Any secret left unset degrades gracefully (the relevant
route returns 503 / fails closed), so a missing secret is a silent feature
outage — verify the list matches exactly.

Non-secret config (`vars`, `MIMO_*`, `STT_*`, `GEMINI_LIVE_MODEL`,
`ENVIRONMENT`, `FIREBASE_PROJECT_ID`) is already committed in `wrangler.toml` at
parity with `worker/wrangler.jsonc` — no action needed.

## 4. Deploy production

Custom domains and cron are enabled in `wrangler.toml`. Deploy from this directory:

```sh
npm run deploy
# or: worker-build --release && npx wrangler deploy
```

Do **not** re-enable `routes` or `triggers.crons` on the TS worker — dual cron or
dual domain against the same D1 will leak admission DO slots.

## 5. Smoke test on the workers.dev URL

```sh
curl https://omi-v4-api-rs.<subdomain>.workers.dev/health
# → 200 {"service":"omi-v4-api","status":"ok"}
```

Then the authenticated spot-checks from README.md (`/v1/me`, `/v1/setup-health`,
`/v1/entitlement`, `/v1/profile/onboarding`, a webhook, an inbox round-trip).
Confirm static assets serve: `curl .../` returns `worker/public/index.html`.

## 6. Verify production

```sh
curl https://omi.tsc.hk/health
curl https://api.omi.tsc.hk/health
# → 200 {"service":"omi-v4-api","status":"ok"}
```

Spot-check authenticated routes (`/v1/me`, `/v1/currents/refresh`, webhooks).

## 7. Rollback

To revert to the TS worker on the custom domains:

1. Uncomment `routes` and `triggers.crons` in `worker/wrangler.jsonc` and
   redeploy `omi-v4-api`.
2. Comment out `[[routes]]` and `[triggers]` in `worker-rs/wrangler.toml` and
   redeploy `omi-v4-api-rs`.
3. D1 needs no rollback — the schema never changed and both workers wrote
   compatible rows.

## Notes / residual risks

- **DO class names** in `wrangler.toml` are the Rust struct names
  (`AssistantAdmissionDo`, `SttAdmissionDo`, `RateLimiterDo`,
  `DeliveryCoordinator`) — a **separate** DO namespace from the TS worker. In-
  flight DO state (admission ledgers, rate-limit counters) does NOT carry over
  at cutover; both are in-memory/short-TTL and self-heal within a cron cycle.
- **Assets path** `../worker/public` is outside the project dir. wrangler 4.x
  accepts it (verified: "Read 3 files from the assets directory …"). If a future
  wrangler rejects it, add a `[build]` step that copies the files into
  `worker-rs/public/` and point `[assets] directory` there.
- **nodejs_compat**: the TS worker sets `compatibility_flags = ["nodejs_compat"]`;
  the Rust worker does not need it (pure wasm, no Node APIs) and omits it.
- **FaceTime** is not ported: no Gemini Live bridge container in worker-rs.
  Public API / MCP FaceTime tools return 501 or are absent; vars are present for
  future porting. Do not dual-route FaceTime on a TS shadow worker.
