PRAGMA foreign_keys = ON;

CREATE TABLE byok_negotiation_sessions (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('open', 'agreed', 'closed')),
  turns INTEGER NOT NULL DEFAULT 0,
  standard_price_cents INTEGER NOT NULL,
  floor_price_cents INTEGER NOT NULL,
  price_cents INTEGER NOT NULL,
  grants TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(grants)),
  transcript TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(transcript)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX byok_negotiation_sessions_uid_created
ON byok_negotiation_sessions(uid, created_at DESC);

CREATE TABLE byok_price_agreements (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  session_id TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('negotiated', 'standard')),
  price_cents INTEGER NOT NULL,
  standard_price_cents INTEGER NOT NULL,
  floor_price_cents INTEGER NOT NULL,
  grants TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(grants)),
  transcript TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(transcript)),
  agreed_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
