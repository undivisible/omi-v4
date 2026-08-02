CREATE TABLE desktop_presence (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  last_polled_at INTEGER NOT NULL
);
