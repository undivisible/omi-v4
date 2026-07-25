# omi-v4-api-rs

Production Cloudflare Worker for the Omi v4 API — serves `omi.tsc.hk` and
`api.omi.tsc.hk`. It owns the deployed API, D1 migration runner, static assets,
and the Sendblue-to-Gemini-Live FaceTime bridge container.

Run `wrangler d1 migrations apply` from `worker-rs/` against
`cloud/migrations/`.

This crate has its own `wrangler.toml` (`name = "omi-v4-api-rs"`) and binds the
**same** D1 database (`database_id = 74aab5eb-...`) with its `migrations_dir`
in `cloud/migrations/`.

## Layout

- `src/auth.rs` — pure Firebase RS256 verification: JWT parse, claim validation
  (aud/iss/exp/iat/sub), JWK RS256 signature check (RustCrypto `rsa`), bearer
  extraction, Cache-Control max-age parsing. Fully `cargo test`-covered.
- `src/entitlement.rs` — pure Pro-entitlement logic incl. the
  `DEV_FAKE_PRO`/`ENVIRONMENT` guard.
- `src/setup_health.rs` — pure `/v1/setup-health` body shaping.
- `src/currents_refresh.rs` — pure refresh heuristics, draft parse, heuristic drafts.
- `src/glue.rs` — the workers-rs I/O layer (Router, D1, JWKS fetch/cache, env).
  Compiled **only** for `wasm32-unknown-unknown` so host `cargo test` never
  pulls the `worker` crate.

The pure/glue split is the testing strategy: workers-rs has no
Miniflare-equivalent harness, so all logic lives in pure functions with
`#[cfg(test)]` suites and the wasm glue stays thin.

## Deploy

```sh
bun run deploy          # worker-build --release && wrangler deploy
bun run deploy:dry-run  # build + wrangler deploy --dry-run
```

See [`CUTOVER.md`](CUTOVER.md) for rollback and [`PORT_STATUS.md`](PORT_STATUS.md)
for the completed migration record.

## Quality gates

Host toolchain here is Homebrew's `rustc` (no wasm std); the rustup `stable`
toolchain has the wasm target. Export it for any wasm command:

```sh
export RUSTC="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
```

- Host tests:    `cargo test --lib`
- Host lint:     `cargo clippy --all-targets -- -D warnings`
- Wasm lint:     `cargo clippy --target wasm32-unknown-unknown -- -D warnings`
- Wasm build:    `worker-build --release`
- Deploy check:  `bun run deploy:dry-run`

### worker-build note (RESOLVED)

`worker-build --release` produces a deployable bundle
(`build/worker/shim.mjs` + `build/index_bg.wasm`). Do not set `strip = true` in
`[profile.release]` — it removes wasm-bindgen metadata worker-build needs.
