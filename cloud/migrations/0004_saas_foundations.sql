ALTER TABLE entitlements ADD COLUMN stripe_subscription_id TEXT;
ALTER TABLE entitlements ADD COLUMN stripe_price_id TEXT;
ALTER TABLE entitlements ADD COLUMN stripe_event_created INTEGER NOT NULL DEFAULT 0;

CREATE UNIQUE INDEX entitlements_stripe_customer
ON entitlements(stripe_customer_id)
WHERE stripe_customer_id IS NOT NULL;

CREATE TABLE stripe_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  received_at INTEGER NOT NULL
);

ALTER TABLE channel_bindings ADD COLUMN channel_chat_id TEXT;

CREATE TABLE channel_inbox (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  event_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  text TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  received_at INTEGER NOT NULL,
  UNIQUE (channel, event_id)
);
CREATE INDEX channel_inbox_uid_received ON channel_inbox(uid, received_at DESC);
