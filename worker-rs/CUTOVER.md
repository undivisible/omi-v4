# CUTOVER — omi-v4-api-rs (Rust)

**Status: DONE (2026-07-24).** Production traffic is on `omi-v4-api-rs` at
`omi.tsc.hk` and `api.omi.tsc.hk`. The retired TypeScript Worker was removed
after the Rust scenario-level parity checks passed.

The language-neutral `cloud/migrations/` directory is the schema source of
truth, and the Rust worker declares it as `migrations_dir`.

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
cargo test --lib
cargo clippy --all-targets -- -D warnings          # host lint
cargo clippy --target wasm32-unknown-unknown -- -D warnings
worker-build --release                             # produces build/worker/shim.mjs (+ index_bg.wasm)
bunx wrangler deploy --dry-run --outdir /tmp/wrs-dry # must succeed
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
requires no provisioning.

## 3. Copy secrets

Set each secret with `wrangler secret put <NAME>` (targets `omi-v4-api-rs` from
this directory). Full list:

```
TELEGRAM_WEBHOOK_SECRET
TELEGRAM_BOT_TOKEN
SENDBLUE_API_KEY_ID
SENDBLUE_API_KEY_SECRET
SENDBLUE_NUMBER
SENDBLUE_FACETIME_NUMBER
SENDBLUE_WEBHOOK_SIGNING_SECRET
SENDBLUE_WEBHOOK_PATH_TOKEN
STRIPE_SECRET_KEY
STRIPE_PRO_PRICE_ID
STRIPE_WEBHOOK_SECRET
APP_URL
MIMO_API_KEY
XAI_API_KEY
GEMINI_API_KEY
FIREBASE_SERVICE_ACCOUNT_EMAIL
FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY
```

`FACETIME_SYSTEM_PROMPT` is optional; when it is unset, the bridge uses its
built-in audio-only Omi prompt.

Any secret left unset degrades gracefully (the relevant route returns 503 /
fails closed), so a missing secret is a silent feature outage.

Non-secret config (`vars`, `MIMO_*`, `STT_*`, `GEMINI_LIVE_MODEL`,
`FACETIME_*`, `AGORA_CLOUD_PROXY`, `ENVIRONMENT`, `FIREBASE_PROJECT_ID`) is
already committed in `wrangler.toml`.

## 4. Deploy production

Custom domains and cron are enabled in `wrangler.toml`. Deploy from this directory:

```sh
bun run deploy
# or: worker-build --release && bunx wrangler deploy
```


## 5. Smoke test on the workers.dev URL

```sh
curl https://omi-v4-api-rs.<subdomain>.workers.dev/health
# → 200 {"service":"omi-v4-api","status":"ok"}
```

Then the authenticated spot-checks from README.md (`/v1/me`, `/v1/setup-health`,
`/v1/entitlement`, `/v1/profile/onboarding`, a webhook, an inbox round-trip).
Confirm static assets serve: `curl .../` returns `cloud/public/index.html`.

## 6. Verify production

```sh
curl https://omi.tsc.hk/health
curl https://api.omi.tsc.hk/health
# → 200 {"service":"omi-v4-api","status":"ok"}
```

Spot-check authenticated routes (`/v1/me`, `/v1/currents/refresh`, webhooks).

## 7. Rollback

Rollback uses a previously verified Rust Worker deployment. D1 migrations are
forward-only and require no runtime-owner change.

## Notes / residual risks

- **DO class names** in `wrangler.toml` are the Rust struct names
  (`AssistantAdmissionDo`, `SttAdmissionDo`, `RateLimiterDo`,
  `DeliveryCoordinator`). In-flight DO state (admission ledgers, rate-limit
  counters) is in-memory/short-TTL and self-heals within a cron cycle.
- **Assets path** `../cloud/public` is outside the project dir. wrangler 4.x
  accepts it (verified: "Read 3 files from the assets directory …"). If a future
  wrangler rejects it, add a `[build]` step that copies the files into
  `worker-rs/public/` and point `[assets] directory` there.
- **FaceTime** uses Sendblue only to start the call; the returned Agora channel
  is joined by a Gemini Live bridge in a Cloudflare-managed container. Docker
  is required locally only when Wrangler builds that image for deploy or a
  container-inclusive dry-run; it is not a runtime dependency.
