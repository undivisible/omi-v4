# Auth migration plan — Firebase → Cloudflare Workers

**Status:** plan only — production still uses Firebase ID tokens (`worker/src/auth.ts`, `app/lib/auth/`). Do not implement until this doc is reviewed and sequenced.

## Why move

- **Single stack:** API, D1, Durable Objects, and auth all on Cloudflare — fewer external dependencies and clearer data residency.
- **Cost & control:** Firebase Auth billing and Google lock-in; worker-issued sessions let us tune TTL, revocation, and audit in D1.
- **Consistency:** Desktop browser handoff (`worker/src/desktop-auth.ts`) already mints short-lived worker sessions; extending that pattern to all clients is natural.

Firebase **UID** is the tenant key everywhere today (`users.uid`, `channel_bindings.uid`, hub `firebase_memory_scope`, Stripe `metadata.firebase_uid`). Migration must preserve or map that key so memory, channels, and billing stay attached.

---

## Current architecture

| Layer | Mechanism |
|---|---|
| **Mobile / desktop sign-in** | Firebase Auth (Google, Apple, phone OTP) via `app/lib/auth/auth_controller.dart` |
| **API auth** | `Authorization: Bearer <Firebase ID token>` verified RS256 against Google JWKs (`verifyFirebaseToken`) |
| **Session on client** | Firebase refresh tokens; serialized refresh + 401 retry (commit `0a321b0`) |
| **Worker user row** | Upsert on first authenticated request: `INSERT INTO users (uid, email, …)` where `uid = Firebase sub` |
| **Desktop handoff** | PKCE-style session in `desktop_auth_sessions`; still bound with Firebase token at finish |
| **Public API** | API keys **or** Firebase bearer (`public-api.ts`) |
| **Channels / billing** | All keyed by Firebase UID |

There is **no** separate worker session table for normal app traffic — the Firebase JWT *is* the session.

---

## Target architecture

Cloudflare does not ship a Firebase Auth replacement. The practical target is **first-party auth on Workers**:

1. **Identity providers (unchanged UX):** Google, Apple, phone OTP — but OAuth/OIDC flows terminate at the Worker, not Firebase SDK.
2. **Worker-issued JWTs** (HS256 or ES256 with key in Workers secret / rotating KV):
   - Claims: `sub` (Omi user id), `email`, `iat`, `exp`, optional `session_id`
   - Short access token (15–60 min) + refresh token stored hashed in D1
3. **D1 tables** (new):
   - `auth_identities` — `(provider, provider_subject) → uid`
   - `auth_sessions` — refresh token hash, device label, revoked_at, last_seen
   - `auth_migration_links` — `firebase_uid → omi_uid` during transition (often 1:1)
4. **`requireAuth` middleware** accepts **either** Firebase JWT **or** Omi JWT during migration window; sets unified `Auth { uid, email, source }`.

Optional later: **Cloudflare Zero Trust Access** in front of `/portal` only — not a replacement for mobile/desktop API auth.

---

## User id strategy

**Recommended:** keep `users.uid` values equal to existing Firebase UIDs for migrated users.

- Zero rewrite of memory blobs, channel bindings, entitlements, conversation rows.
- New sign-ups after cutover get `omi_` or UUID ids; migration table only needed for edge cases.

**Alternative:** new canonical id + `auth_migration_links` on every table — high risk, avoid unless Firebase export forces it.

---

## Transition phases

### Phase 0 — Prep (no user impact)

- [ ] Add D1 migrations: `auth_identities`, `auth_sessions`, `auth_migration_links`
- [ ] Implement `issueOmiToken` / `verifyOmiToken` alongside `verifyFirebaseToken`
- [ ] Dual-verify middleware behind env flag `AUTH_DUAL_MODE=1`
- [ ] Admin script: import Firebase users export into `auth_identities` (email, phone, provider ids) keyed by existing UID
- [ ] Metrics: log `auth.source` (`firebase` vs `omi`) per route

### Phase 1 — New sign-ups on Worker auth (optional early)

- Web portal (`api.omi.tsc.hk/portal`) and new app builds use Worker OAuth first.
- Firebase remains for existing installs until forced upgrade.
- On first Worker login for an email that exists in Firebase export → attach to same UID.

### Phase 2 — Dual auth (main migration window)

- All app versions ≥ **N** send Omi JWT; older builds still send Firebase JWT.
- `requireAuth` tries Omi JWT first, falls back to Firebase.
- **Silent migration on login:** user signs in with Google/Apple/phone on new stack → worker finds `auth_identities` or Firebase token one last time → issues Omi refresh session, marks `auth_migration_links.migrated_at`.
- **Desktop handoff:** replace Firebase bind step with Omi access token at session finish.
- **Channel link / API keys:** unchanged — still `uid`-scoped.

### Phase 3 — Firebase read-only

- Disable new Firebase project sign-ups in Firebase console.
- Reject Firebase JWTs except for allowlisted UIDs not yet migrated (401 + `migrate: true` body).
- Push app update: “Sign in again once to update your session.”

### Phase 4 — Firebase off

- Remove `verifyFirebaseToken`, Firebase SDK from Flutter/Rust clients, `FIREBASE_PROJECT_ID` secret.
- Delete Firebase project after backup export.

---

## Per-platform client changes

| Client | Work |
|---|---|
| **Flutter `auth_gateway`** | New `WorkerAuthGateway`: OAuth deep links / ASWebAuthenticationSession, secure storage for refresh token |
| **Phone OTP** | Worker sends SMS (Twilio/etc.) or keep Firebase phone **only** until SMS on worker is ready — explicit sub-phase |
| **Rust hub** | Replace Firebase token in sync calls with Omi JWT from Dart sidecar / shared keychain |
| **Web portal** | Cookie or localStorage refresh; CSRF on refresh endpoint |
| **MCP / public API** | API keys unchanged; bearer docs mention Omi JWT |

---

## Existing edge cases

### Channel-only accounts (`chan_*` UIDs)

Created via `/signup` on Telegram/iMessage (being removed). These have no email and no Firebase identity.

**Migration options:**

1. **Soft deprecation:** leave `chan_*` rows; `/status` and `/whoami` already explain “sign in on desktop and /start to move across.”
2. **Merge flow:** when user links code after real sign-in, offer to import channel conversation history into their Firebase/Worker UID (one-time `UPDATE channel_bindings SET uid = ?` + conversation merge job).
3. **Hard sunset:** email/Telegram nudge + delete unlinked `chan_*` after 90 days.

Recommend **1 + 2** — no forced data loss.

### Stripe metadata

Today: `metadata.firebase_uid`. Add `metadata.omi_uid` in parallel during Phase 2; webhook handler accepts either until Phase 4.

### BYOK / entitlements

Already keyed by `uid` — no change if UID preserved.

---

## Security checklist

- Refresh tokens: opaque, hashed (SHA-256), rotatable on use
- Revocation: `auth_sessions.revoked_at` + optional KV denylist for access tokens
- Rate limits: reuse `rate-limit.ts` on `/v1/auth/*`
- OAuth state/nonce stored in D1 or KV with TTL
- Phone OTP: same 6-digit pattern as desktop handoff or TOTP-style
- No auth secrets in client binaries except public OAuth client ids

---

## Rollback

Keep Firebase project and dual-verify for **≥ 30 days** after Phase 2 start. Rollback = flip `AUTH_DUAL_MODE` to Firebase-only and ship hotfix client if needed.

---

## Open decisions (need product sign-off)

1. **Phone OTP:** migrate off Firebase Auth phone provider in Phase 2 or Phase 4?
2. **Session length:** match Firebase (~1h ID token) or longer-lived refresh with sliding window?
3. **Web-only users:** is portal-only auth enough before forcing app download?
4. **chan_* sunset date** if any channel-only accounts remain in prod.

---

## Related files

- `worker/src/auth.ts` — Firebase verification today
- `worker/src/desktop-auth.ts` — partial worker session pattern
- `app/lib/auth/` — client auth abstraction
- `worker/src/routes.ts` — `POST /v1/channels/link` and all authenticated routes
- `docs/telegram-test.md` — channel linking (independent of auth provider if UID stable)

---

## Immediate fixes (done separately from this plan)

- Telegram `/signup` no longer creates channel-only accounts — directs users to download app and link.
- Desktop chat redeems link codes embedded in natural language (e.g. “my telegram code is CMKCVXM”), not only bare 7-character messages.
