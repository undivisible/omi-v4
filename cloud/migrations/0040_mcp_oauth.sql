CREATE TABLE oauth_authorization_codes (
  code_hash TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  scopes TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX oauth_authorization_codes_expiry ON oauth_authorization_codes(expires_at);

CREATE TABLE oauth_access_tokens (
  token_hash TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_id TEXT NOT NULL,
  scopes TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX oauth_access_tokens_expiry ON oauth_access_tokens(expires_at);
