-- Sessions issued by this worker, replacing Firebase ID tokens.
--
-- Additive only. Nothing here changes an existing uid: users.uid stays the
-- identity everything else is keyed on (channel_bindings, entitlements,
-- api_keys, memory, currents, Stripe metadata), so this is a credential
-- migration and not a data migration.

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  -- SHA-256 of the refresh token. The token itself is never stored, so a
  -- database read cannot recover a usable credential.
  refresh_hash TEXT NOT NULL,
  device_label TEXT,
  -- 'channel' | 'desktop' | 'oidc' | 'firebase_upgrade'
  origin TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  -- Set when this row replaced another during refresh rotation. A refresh
  -- token presented twice means it leaked; the chain is how that is detected.
  rotated_from TEXT
);
CREATE UNIQUE INDEX auth_sessions_refresh ON auth_sessions(refresh_hash);
CREATE INDEX auth_sessions_uid_live ON auth_sessions(uid, revoked_at, expires_at);

-- Maps an external identity to a uid. Redundant with channel_bindings for
-- channel sign-in on day one, but it is what lets a Firebase user who signs
-- in with the same Google account or phone number land on their existing uid
-- rather than a new one.
CREATE TABLE auth_identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX auth_identities_uid ON auth_identities(uid);

-- Hardening for sign-in by code.
--
-- When a link code only *binds* a chat to an already-authenticated user it is
-- a second factor, and rate limiting keys on the authenticated uid. Using the
-- same code to *sign in* makes it the entire credential, presented by an
-- anonymous caller with no uid to key on. The keyspace is 31^7, which is ample
-- against one guesser and thin against many, so each code gets its own attempt
-- budget and locks itself out.
ALTER TABLE channel_link_codes ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channel_link_codes ADD COLUMN locked_at INTEGER;
-- Codes minted for sign-in expire faster than codes minted for binding.
ALTER TABLE channel_link_codes ADD COLUMN purpose TEXT NOT NULL DEFAULT 'link';
