# CUTOVER — omi-v4-api (TS) → omi-v4-api-rs (Rust)

Runbook for replacing the live TypeScript worker (`omi-v4-api`, serving
`omi.tsc.hk`) with the Rust port (`omi-v4-api-rs`). Both bind the **same** D1
database (`database_id 74aab5eb-…`); the **TS worker owns the schema/migrations**
— the Rust worker declares no `migrations_dir` and must never run D1 migrations.

The two workers can run side by side: only the custom-domain route is exclusive.
Until the route is swapped, the Rust worker is reachable on its
`*.workers.dev` URL and shares all D1 state with the live worker, so you can
smoke it against production data without taking traffic.

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
BLOOIO_WEBHOOK_SIGNING_SECRET
BLOOIO_API_KEY
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

## 4. Deploy WITHOUT the domain (shadow)

The `[[routes]]` custom-domain block in `wrangler.toml` is commented out on
purpose so a deploy cannot steal `omi.tsc.hk` from the live worker.

```sh
npx wrangler deploy          # publishes omi-v4-api-rs on *.workers.dev only
```

Deploy order relative to the TS worker does not matter for D1 (shared schema);
the cron `triggers` (`* * * * *`) will begin firing on the Rust worker as soon
as it deploys. Because both workers now run the same minutely cron against the
same tables, that is safe (every cron piece is idempotent / lease-fenced), but
if you want to avoid double-processing during the shadow window, temporarily
remove `[triggers]` from the Rust worker until the domain swap, or disable the
TS worker's cron.

## 5. Smoke test on the workers.dev URL

```sh
curl https://omi-v4-api-rs.<subdomain>.workers.dev/health
# → 200 {"service":"omi-v4-api","status":"ok"}
```

Then the authenticated spot-checks from README.md (`/v1/me`, `/v1/setup-health`,
`/v1/entitlement`, `/v1/profile/onboarding`, a webhook, an inbox round-trip).
Confirm static assets serve: `curl .../` returns `worker/public/index.html`.

## 6. Swap the domain (cutover)

Two options — pick one:

- **Route-move (fastest rollback):** in the Cloudflare dashboard (or by removing
  `routes` from `worker/wrangler.jsonc` and redeploying the TS worker), release
  `omi.tsc.hk` from `omi-v4-api`. Then uncomment the `[[routes]]` block in
  `worker-rs/wrangler.toml` and `npx wrangler deploy`. There is a brief window
  where the domain is unrouted; keep it short.
- **Takeover:** uncomment the `[[routes]]` block and `npx wrangler deploy` the
  Rust worker. Cloudflare reassigns the custom domain to the last deployer.
  Verify immediately.

```sh
curl https://omi.tsc.hk/health   # → 200 from the Rust worker
```

## 7. Rollback

The TS worker is untouched and still deployed. To revert:

1. Re-comment the `[[routes]]` block in `worker-rs/wrangler.toml` and
   `npx wrangler deploy` (releases the domain from the Rust worker), **or** just
   redeploy the TS worker with its `routes` block to reclaim `omi.tsc.hk`.
2. Restore the TS worker's cron if you disabled it in step 4.
3. D1 needs no rollback — the schema never changed and both workers wrote
   compatible rows.

Keep the Rust worker deployed on `*.workers.dev` after rollback so the next
attempt skips steps 2–4.

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
- **Streaming usage-tail settlement** for managed chat is reconciled by the
  minutely cron (`reconcileManagedAssistantRequests`) rather than parsed inline —
  budgets converge within one cron cycle, matching the TS deferral.
