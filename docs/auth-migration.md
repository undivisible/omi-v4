# Auth migration — Firebase → worker-rs

**Status:** phase 0 is wired for dual-mode authentication; phase 1 routes are not built.

This replaces an earlier draft written before the TypeScript worker was retired
on 2026-07-24. That draft's architecture was sound and is kept here; its file
paths were not, because `worker/src/auth.ts`, `desktop-auth.ts` and `routes.ts`
no longer exist.

## Why the uid is the whole story

`users.uid` is a Firebase uid, and every table keys on it — `channel_bindings`,
`entitlements`, `api_keys`, memory, currents, conversations, Stripe
`metadata.firebase_uid`. Preserve the uid and this is a **credential**
migration, not a data migration. Nothing needs rewriting; users need re-issuing.

That single fact is why the plan below has no backfill script and no
`auth_migration_links` table with per-table rewrites.

## What is in the tree now

### `worker-rs/src/session_token.rs`

Two credentials, deliberately different in kind:

- **Access token** — compact HS256 JWT, 15 min, verified with no database read.
- **Refresh token** — 32 opaque bytes; only the SHA-256 digest is stored, the
  same shape `api_keys` uses, so a database read cannot recover a credential.

No new dependency. `hmac`, `sha2`, `base64` and `subtle` were already in
`Cargo.toml`, and a JWT is a signature over two base64url segments. A JWT crate
would add a wasm-compatibility surface to maintain for ~60 lines of logic — see
the crate survey below for what that surface costs.

The header is a fixed constant, never parsed. Reading `alg` from the token is
how JWT verifiers end up accepting `none` or confusing HS256 with RS256; there
is one algorithm here, so there is nothing to read. A test asserts an
`alg: none` token is refused.

`verify_access_token` takes an optional previous secret so `AUTH_TOKEN_SECRET`
can rotate without signing every live session out.

### `worker-rs/src/channel_auth.rs`

Sign-in by a code the bot sends. This direction is friendlier than the inverse
and it is also weaker, and that difference drives everything in the module.

`handle_channel_link_redeem` already consumes these codes — but there the caller
is *already authenticated* and the code only binds a chat to a known uid. It is
a second factor, rate-limited per uid. Used for sign-in the code is the entire
credential, presented by an anonymous caller with no uid to key a limit on. The
keyspace is 31^7 ≈ 2.75e10: ample against one guesser, thin against a
distributed one when many codes are live.

Three limits, all needed:

| Limit | Stops |
| --- | --- |
| per-IP, 10 / 10 min | the naive case |
| global failure budget, 500 / 10 min | a guesser rotating IPs — nothing else does |
| per-code attempts, 5 then locked | a code under attack dying instead of the endpoint locking out honest users |

Plus a 3-minute TTL for sign-in codes against 15 for binding codes, and a
`purpose` column so a binding code can never be spent as a sign-in credential.

Malformed input deliberately does **not** consume the global budget: someone
pasting a URL into the code box must not push the endpoint toward lockout.

### `cloud/migrations/0038_worker_auth.sql`

`auth_sessions` (refresh digests, origin, rotation chain) and `auth_identities`
(provider+subject → uid). `auth_identities` is redundant with
`channel_bindings` for channel sign-in on day one, but it is what lets a
Firebase user who signs in with the same Google account or phone number land on
their **existing** uid. It is the load-bearing piece of phase 2.

Plus `attempts`, `locked_at` and `purpose` on `channel_link_codes`.

## What is not built

- The routes: `/v1/auth/channel/exchange`, `/v1/auth/refresh`, `/v1/auth/signout`,
  `/v1/auth/upgrade`.
- `routes_channels.rs::sign_up_channel_sender` is still `#[allow(dead_code)]`.
- The Flutter `WorkerAuthGateway`.

## Crate survey — wasm32-unknown-unknown

worker-rs compiles to `wasm32-unknown-unknown`. That kills most Rust auth
crates, and the failures are not obvious from documentation. Every verdict below
came from building a `cdylib` probe under worker-rs's own rustflags.

| Crate | wasm32 | Note |
| --- | --- | --- |
| `jsonwebtoken 11` + `rust_crypto` | pass | HS256/RS256/ES256/EdDSA all verified |
| `jsonwebtoken 11` default | **trap** | compiles with *no crypto provider*; fails at runtime, not build time |
| `jsonwebtoken` + `aws_lc_rs` | fail | getrandom without `js` |
| `pasetors 0.8` | pass | the only working PASETO option |
| `rusty_paseto`, `biscuit` | fail | `ring` — `SystemRandom` has no impl for this target |
| `josekit` | fail | openssl-sys |
| `argon2 0.5` | pass | but see below |
| `openidconnect 4` + `default-features = false` | pass | no reqwest, no TLS; plugs into `worker::Fetch` |
| anything pulling `ring` | fail | blanket exclusion |

Two traps worth writing down:

**`pasetors` works by accident of feature unification.** `ed25519-compact`
declares getrandom with `wasm_js`, which unifies into `orion`'s copy. `orion`
alone does not enable it — which is exactly why `branca`, which pulls `orion`
without `ed25519-compact`, fails. If you adopt `pasetors`, pin it and add a wasm
CI check, because a dependency bump can silently break it.

**getrandom has three incompatible generations.** 0.2 needs `features = ["js"]`
(already pinned). 0.4 needs `features = ["wasm_js"]`. **0.3 needs a rustflag**,
not a feature — `--cfg getrandom_backend="wasm_js"` in `.cargo/config.toml`. 0.2
and 0.3 were verified to coexist in one binary.

**Do not add argon2.** There are no passwords anywhere in this design — channel
identity, OIDC and OTP are all passwordless. Argon2 is also deliberately slow
and memory-hungry, which is a poor fit for the Workers CPU budget. The existing
`api_keys` pattern (high-entropy secret, SHA-256 stored, constant-time compare)
is correct for tokens and needs no KDF.

`axum-login`, `tower-sessions` and `oxide-auth` assume a tokio/tower runtime
with `Send + 'static` futures; workers-rs futures are `!Send`. This is reasoning
from their APIs, not a build test.

## Migration phases

**Phase 0 — additive, zero user impact.** **Dual-mode authentication is complete
in source.** Migration 0038, `session_token.rs`, `channel_auth.rs`, and
`authenticate` are landed. With `AUTH_DUAL_MODE` and `AUTH_TOKEN_SECRET`
configured, Worker access tokens are accepted before the Firebase fallback.
Remaining: in the Firebase-success branch, add
`INSERT OR IGNORE INTO auth_identities (provider='firebase', subject=uid, uid)`.
That builds the identity map from live traffic — no Firebase export, admin
script, or downtime.

**Phase 1 — channel sign-in live.** Ship `/v1/auth/channel/exchange`. New users
get `usr_` uids. **An existing Firebase user who already linked a chat gets
their identical uid back through `channel_bindings`** — migrated silently the
first time they use it.

**Phase 2 — silent upgrade.** New app builds, on first launch with a valid
Firebase session, POST `/v1/auth/upgrade` with the Firebase bearer. The worker
verifies it one last time, issues an `auth_sessions` row for the same uid,
records the identity, and the app drops Firebase. The user notices nothing.

**Phase 3 — Firebase read-only.** No new Firebase sign-ups; `authenticate`
still accepts Firebase but returns a `migrate: true` hint.

**Phase 4 — off.** Delete `verify_firebase_token`, `create_firebase_custom_token`,
the three secrets, `firebase_core`/`firebase_auth`. `rsa 0.9` can leave
`Cargo.toml` — it exists only for Firebase RS256 verify and custom-token
signing — unless `openidconnect` is adopted, which pulls it back.

**Export the Firebase users before phase 3, not after.** It is the only thing
that makes the residual set recoverable, and it is unavailable once the project
is deleted.

**Rollback** is flipping `AUTH_DUAL_MODE`. No data is destroyed before phase 4.

## Who could be stranded

Users who never open the app during phase 2 **and** have no linked chat.

- Google/Apple: the Firebase export gives `(provider, sub) → uid`, so signing in
  with the same account lands on the same uid. Needs the OIDC work.
- Phone-only: the export carries `phone_number` → `auth_identities('phone', …)`.
  Needs worker SMS — **Sendblue is already integrated** (`sendblue.rs`,
  `SENDBLUE_NUMBER`), so no Twilio.
- Worst case: uid recoverable by verified email against `users.email`, behind a
  manual support path. Nobody loses data.

## Blast radius in the app

Smaller than it looks. **One file imports Firebase** —
`app/lib/auth/firebase_bootstrap.dart` — with one production caller in
`app_services.dart`. `AuthGateway` is a real seam and **does not change shape**,
so all 11 test fakes keep compiling.

`app/lib/api/worker_http.dart` needs **no changes at all**: it is already
provider-generic and every feature client rides it. `AuthSession` needs no model
change — `idToken` carries the Omi access token instead. `AuthPhase.restoring`
already exists, which is exactly what a network-round-trip `restoreSession()`
needs.

The one genuinely new client dependency is secure storage: Firebase owns refresh
persistence today and nothing in the app persists tokens itself. On macOS that
means a keychain entitlement, which `Release.entitlements` does not currently
have.

There is **no** `google-services.json`, no `GoogleService-Info.plist`, no
`firebase_options.dart`, no Gradle plugin. Config exists only as `--dart-define`
— which is why CI-built releases could never sign in until that was fixed.

The token crosses into Rust as a field named `firebaseToken`
(`command.dart`, `transcription_auth.dart`), and `tool/check_rinf_bindings.sh`
asserts those names. It is an opaque bearer string, so nothing breaks
functionally; rename it in a dedicated commit, not mixed into the auth change.
