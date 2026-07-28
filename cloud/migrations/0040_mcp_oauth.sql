-- OAuth 2.1 authorization-code authority for the Omi MCP protected resource.
--
-- These are intentionally separate from `oauth_connections`: that older table
-- represents Omi connecting OUT to a provider, while these tables represent an
-- external client connecting IN to the user's Omi MCP resource.
--
-- Secrets/codes/tokens are stored only as SHA-256 digests. Redirect URI and
-- scopes are checked by the Worker before insertion and again at use time.

CREATE TABLE oauth_clients (
  client_id TEXT PRIMARY KEY,
  client_type TEXT NOT NULL CHECK (client_type IN ('public', 'confidential')),
  redirect_uris TEXT NOT NULL CHECK (json_valid(redirect_uris)),
  allowed_scopes TEXT NOT NULL CHECK (json_valid(allowed_scopes)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at INTEGER NOT NULL,
  disabled_at INTEGER
);

CREATE TABLE oauth_grants (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_id TEXT NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
  scopes TEXT NOT NULL CHECK (json_valid(scopes)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  revoked_at INTEGER,
  UNIQUE (uid, client_id)
);
CREATE INDEX oauth_grants_client_uid ON oauth_grants(client_id, uid);

CREATE TABLE oauth_authorization_codes (
  id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  grant_id TEXT NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  client_id TEXT NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
  redirect_uri TEXT NOT NULL,
  resource TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX oauth_codes_redeem ON oauth_authorization_codes(code_hash, expires_at, consumed_at);

CREATE TABLE oauth_refresh_tokens (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  family_id TEXT NOT NULL,
  grant_id TEXT NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES oauth_refresh_tokens(id) ON DELETE SET NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX oauth_refresh_lookup ON oauth_refresh_tokens(token_hash, expires_at, revoked_at);
CREATE INDEX oauth_refresh_family ON oauth_refresh_tokens(family_id, revoked_at);
