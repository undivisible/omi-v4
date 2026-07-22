# omi-v4-api-rs

A parity port of the TypeScript Cloudflare Worker in `worker/` to Rust via
[`workers-rs`](https://github.com/cloudflare/workers-rs) (crate `worker` 0.8.5).

This crate is deliberately isolated from `worker/`: it has its own
`wrangler.toml` (`name = "omi-v4-api-rs"`) and never touches the TS worker's
config. The TS worker stays deployable until cutover. Both workers bind the
**same** D1 database (`database_id = 74aab5eb-...`); the **TS worker owns the
schema and migrations** — this crate declares no `migrations_dir`.

## Layout

- `src/auth.rs` — pure Firebase RS256 verification: JWT parse, claim validation
  (aud/iss/exp/iat/sub), JWK RS256 signature check (RustCrypto `rsa`), bearer
  extraction, Cache-Control max-age parsing. Fully `cargo test`-covered.
- `src/entitlement.rs` — pure Pro-entitlement logic incl. the
  `DEV_FAKE_PRO`/`ENVIRONMENT` guard.
- `src/setup_health.rs` — pure `/v1/setup-health` body shaping.
- `src/glue.rs` — the workers-rs I/O layer (Router, D1, JWKS fetch/cache, env).
  Compiled **only** for `wasm32-unknown-unknown` so host `cargo test` never
  pulls the `worker` crate.

The pure/glue split is the testing strategy: workers-rs has no
Miniflare-equivalent harness, so all logic lives in pure functions with
`#[cfg(test)]` suites and the wasm glue stays thin.

## Quality gates

Host toolchain here is Homebrew's `rustc` (no wasm std); the rustup `stable`
toolchain has the wasm target. Export it for any wasm command:

```sh
export RUSTC="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
```

- Host tests:    `cargo test`                                   (24 tests green)
- Host lint:     `cargo clippy --all-targets -- -D warnings`    (clean)
- Wasm check:    `cargo check --target wasm32-unknown-unknown`  (clean)
- Wasm lint:     `cargo clippy --target wasm32-unknown-unknown -- -D warnings`
- Wasm build:    `cargo build --release --target wasm32-unknown-unknown` (ok)

### worker-build note

`worker-build --release` compiles the crate to wasm successfully, then fails in
the `wasm-bindgen` post-processing step with:

```
externref table required for catch wrappers
```

because worker-build passes `--force-enable-abort-handler` and rustc 1.97 does
not emit an externref table by default. Running `wasm-bindgen` on the produced
`.wasm` **without** that flag succeeds and yields the deployable module, so this
is a toolchain-version alignment issue (rustc / wasm-bindgen 0.2.126 /
worker-build), not a defect in the port. `.cargo/config.toml` enables
`+reference-types,+multivalue` for the wasm target as the standard mitigation;
resolving the abort-handler flag fully is a cutover-time task (pin a
rustc/wasm-bindgen combination known to emit the table).

## Manual integration smoke (`npx wrangler dev`)

There is no automated Worker harness. After `wrangler dev` (once the
worker-build step is green in CI), verify:

1. `GET /health` → `200 {"service":"omi-v4-api","status":"ok"}`.
2. `GET /v1/me` with no `Authorization` → `401 {"error":"Authentication required"}`.
3. `GET /v1/me` with `Authorization: Bearer <invalid>` → `401 {"error":"Authentication failed"}`.
4. `GET /v1/me` with a valid Firebase ID token → `200 {"uid","email","channels":[]}`.
5. `GET /v1/setup-health` (authed) → JSON booleans matching configured vars/secrets.
6. `GET /v1/entitlement` (authed, `DEV_FAKE_PRO=true`, non-prod) → `{"plan":"pro","active":true}`.
7. `GET /v1/profile/onboarding` → `{"complete":false,"completedAt":null}` initially.
8. `PUT /v1/profile/onboarding` `{"complete":true}` → `{"complete":true,"completedAt":<ms>}`;
   `{"complete":false}` → `400 {"error":"Invalid onboarding state"}`.
9. `DELETE /v1/account` (authed) → `204`, rows removed across the uid-scoped tables.

## Ported endpoints (Phase 1)

`GET /health`, `GET /v1/me`, `GET /v1/setup-health`, `GET /v1/entitlement`,
`GET|PUT /v1/profile/onboarding`, `DELETE /v1/account`, plus the Firebase
RS256 auth middleware. See `PORT_STATUS.md` for the full module tracker.
