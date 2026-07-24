-- Rename stored channel id `blooio` → `imessage`.
-- SQLite cannot ALTER CHECK constraints, so every table whose CHECK mentions
-- `blooio` is rebuilt (CREATE new → copy with remap → DROP old → RENAME).
-- Order is FK-safe: dependents are rebuilt before (or without) dropping parents.

-- channel_link_tokens
CREATE TABLE channel_link_tokens_v2 (
  token_hash TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
INSERT INTO channel_link_tokens_v2
  (token_hash, uid, channel, expires_at, consumed_at, created_at)
SELECT token_hash, uid,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       expires_at, consumed_at, created_at
FROM channel_link_tokens;
DROP TABLE channel_link_tokens;
ALTER TABLE channel_link_tokens_v2 RENAME TO channel_link_tokens;
CREATE INDEX channel_link_tokens_uid ON channel_link_tokens(uid, channel, created_at DESC);

-- channel_bindings
CREATE TABLE channel_bindings_v2 (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  channel_user_id TEXT NOT NULL,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  verified_at INTEGER NOT NULL,
  revoked_at INTEGER,
  channel_chat_id TEXT,
  conversation_reset_cursor INTEGER,
  PRIMARY KEY (channel, channel_user_id)
);
INSERT INTO channel_bindings_v2
  (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id, conversation_reset_cursor)
SELECT CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       channel_user_id, uid, verified_at, revoked_at, channel_chat_id, conversation_reset_cursor
FROM channel_bindings;
DROP TABLE channel_bindings;
ALTER TABLE channel_bindings_v2 RENAME TO channel_bindings;
CREATE INDEX channel_bindings_uid ON channel_bindings(uid, channel);

-- webhook_events
CREATE TABLE webhook_events_v2 (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  event_id TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (channel, event_id)
);
INSERT INTO webhook_events_v2 (channel, event_id, received_at)
SELECT CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       event_id, received_at
FROM webhook_events;
DROP TABLE webhook_events;
ALTER TABLE webhook_events_v2 RENAME TO webhook_events;

-- channel_inbox: park completions, rebuild parent, restore completions
CREATE TABLE channel_inbox_completions_backup AS
SELECT * FROM channel_inbox_completions;
DROP TABLE channel_inbox_completions;
CREATE TABLE channel_inbox_v2 (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  event_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  text TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  lease_until INTEGER,
  lease_token TEXT,
  last_error TEXT,
  completed_at INTEGER,
  received_at INTEGER NOT NULL,
  UNIQUE (channel, event_id)
);
INSERT INTO channel_inbox_v2
  (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id,
   text, payload, status, attempts, lease_until, lease_token, last_error,
   completed_at, received_at)
SELECT id, uid,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       event_id, message_id, channel_user_id, channel_chat_id,
       text, payload, status, attempts, lease_until, lease_token, last_error,
       completed_at, received_at
FROM channel_inbox;
DROP TABLE channel_inbox;
ALTER TABLE channel_inbox_v2 RENAME TO channel_inbox;
CREATE INDEX channel_inbox_uid_received ON channel_inbox(uid, received_at, id);
CREATE TABLE channel_inbox_completions (
  inbox_id TEXT NOT NULL REFERENCES channel_inbox(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  attempt INTEGER NOT NULL CHECK (attempt BETWEEN 1 AND 5),
  lease_token TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('retry')),
  result_status TEXT NOT NULL CHECK (result_status IN ('pending', 'failed')),
  completed_at INTEGER NOT NULL,
  PRIMARY KEY (inbox_id, lease_token),
  UNIQUE (inbox_id, attempt, outcome)
);
INSERT INTO channel_inbox_completions
  (inbox_id, uid, attempt, lease_token, outcome, result_status, completed_at)
SELECT inbox_id, uid, attempt, lease_token, outcome, result_status, completed_at
FROM channel_inbox_completions_backup;
DROP TABLE channel_inbox_completions_backup;

-- channel_deliveries + conversation_messages (messages FK → deliveries)
CREATE TABLE channel_deliveries_v2 (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  idempotency_key TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  text TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'delivering', 'retry', 'sent', 'failed', 'unknown', 'cancelled')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  next_attempt_at INTEGER NOT NULL,
  lease_until INTEGER,
  lease_token TEXT,
  provider_message_id TEXT,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  sent_at INTEGER,
  UNIQUE (uid, channel, idempotency_key)
);
INSERT INTO channel_deliveries_v2
  (id, uid, channel, idempotency_key, channel_chat_id, text, state, attempts,
   next_attempt_at, lease_until, lease_token, provider_message_id, last_error,
   created_at, updated_at, sent_at)
SELECT id, uid,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       idempotency_key, channel_chat_id, text, state, attempts,
       next_attempt_at, lease_until, lease_token, provider_message_id, last_error,
       created_at, updated_at, sent_at
FROM channel_deliveries;

CREATE TABLE conversation_messages_v2 (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  client_message_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  source TEXT NOT NULL CHECK (source IN ('app', 'web', 'desktop', 'telegram', 'imessage')),
  text TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  channel_message_id TEXT,
  delivery_id TEXT REFERENCES channel_deliveries_v2(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (conversation_id, client_message_id)
);
INSERT INTO conversation_messages_v2
  (cursor, id, conversation_id, uid, client_message_id, role, source, text,
   payload_hash, channel_message_id, delivery_id, created_at)
SELECT cursor, id, conversation_id, uid, client_message_id, role,
       CASE WHEN source = 'blooio' THEN 'imessage' ELSE source END,
       text, payload_hash, channel_message_id, delivery_id, created_at
FROM conversation_messages;

DROP TABLE conversation_messages;
DROP TABLE channel_deliveries;
ALTER TABLE channel_deliveries_v2 RENAME TO channel_deliveries;
ALTER TABLE conversation_messages_v2 RENAME TO conversation_messages;
CREATE INDEX channel_deliveries_due
ON channel_deliveries(state, next_attempt_at, lease_until);
CREATE INDEX conversation_messages_replay
ON conversation_messages(uid, conversation_id, cursor);

-- channel_link_codes
CREATE TABLE channel_link_codes_v2 (
  code_hash TEXT PRIMARY KEY,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);
INSERT INTO channel_link_codes_v2
  (code_hash, channel, channel_user_id, channel_chat_id, nonce, expires_at, consumed_at, created_at)
SELECT code_hash,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       channel_user_id, channel_chat_id, nonce, expires_at, consumed_at, created_at
FROM channel_link_codes;
DROP TABLE channel_link_codes;
ALTER TABLE channel_link_codes_v2 RENAME TO channel_link_codes;
CREATE INDEX channel_link_codes_sender
ON channel_link_codes(channel, channel_user_id, expires_at DESC);

-- channel_accounts
CREATE TABLE channel_accounts_v2 (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  claimed_at INTEGER,
  claimed_by_uid TEXT,
  retired_at INTEGER,
  billing_email TEXT
);
INSERT INTO channel_accounts_v2
  (uid, channel, channel_user_id, channel_chat_id, created_at, claimed_at,
   claimed_by_uid, retired_at, billing_email)
SELECT uid,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       channel_user_id, channel_chat_id, created_at, claimed_at,
       claimed_by_uid, retired_at, billing_email
FROM channel_accounts;
DROP TABLE channel_accounts;
ALTER TABLE channel_accounts_v2 RENAME TO channel_accounts;
CREATE UNIQUE INDEX channel_accounts_live
ON channel_accounts(channel, channel_user_id)
WHERE claimed_at IS NULL AND retired_at IS NULL;
CREATE INDEX channel_accounts_identity
ON channel_accounts(channel, channel_user_id, created_at DESC);

-- channel_first_contact
CREATE TABLE channel_first_contact_v2 (
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  asked_at INTEGER NOT NULL,
  answered_at INTEGER,
  PRIMARY KEY (channel, channel_user_id)
);
INSERT INTO channel_first_contact_v2
  (channel, channel_user_id, channel_chat_id, asked_at, answered_at)
SELECT CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       channel_user_id, channel_chat_id, asked_at, answered_at
FROM channel_first_contact;
DROP TABLE channel_first_contact;
ALTER TABLE channel_first_contact_v2 RENAME TO channel_first_contact;

-- channel_checkout_sessions
CREATE TABLE channel_checkout_sessions_v2 (
  session_id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'imessage')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  price_cents INTEGER NOT NULL,
  url TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  completed_at INTEGER
);
INSERT INTO channel_checkout_sessions_v2
  (session_id, uid, channel, channel_user_id, channel_chat_id, price_cents,
   url, created_at, expires_at, completed_at)
SELECT session_id, uid,
       CASE WHEN channel = 'blooio' THEN 'imessage' ELSE channel END,
       channel_user_id, channel_chat_id, price_cents,
       url, created_at, expires_at, completed_at
FROM channel_checkout_sessions;
DROP TABLE channel_checkout_sessions;
ALTER TABLE channel_checkout_sessions_v2 RENAME TO channel_checkout_sessions;
CREATE INDEX channel_checkout_sessions_live
ON channel_checkout_sessions(uid, expires_at DESC);
