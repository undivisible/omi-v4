CREATE TABLE channel_checkout_sessions (
  session_id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('telegram', 'blooio')),
  channel_user_id TEXT NOT NULL,
  channel_chat_id TEXT NOT NULL,
  price_cents INTEGER NOT NULL,
  url TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE INDEX channel_checkout_sessions_live
ON channel_checkout_sessions(uid, expires_at DESC);

-- The email Stripe collected at checkout. It is deliberately not written to
-- users.email: that column means "the identity this account signs in with",
-- and a channel account still has none.
ALTER TABLE channel_accounts ADD COLUMN billing_email TEXT;

-- Reconciliation reads these two the way the cron does, oldest first.
CREATE INDEX entitlements_reconcile
ON entitlements(updated_at)
WHERE stripe_subscription_id IS NOT NULL;
