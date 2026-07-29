CREATE TABLE cupboard_tenants (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  tenant_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);
