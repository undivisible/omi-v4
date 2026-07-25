PRAGMA foreign_keys = ON;

CREATE TABLE memory_sources (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  external_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  tombstoned_at INTEGER,
  UNIQUE (uid, kind, external_id)
);
CREATE INDEX memory_sources_uid_updated ON memory_sources(uid, updated_at DESC);

CREATE TABLE memory_source_revisions (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK (revision > 0),
  content_hash TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload)),
  observed_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (source_id, revision)
);
CREATE INDEX memory_source_revisions_uid_source ON memory_source_revisions(uid, source_id, revision DESC);

CREATE TABLE memory_evidence (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  source_revision_id TEXT NOT NULL REFERENCES memory_source_revisions(id) ON DELETE CASCADE,
  quote TEXT NOT NULL,
  locator TEXT CHECK (locator IS NULL OR json_valid(locator)),
  created_at INTEGER NOT NULL
);
CREATE INDEX memory_evidence_uid_revision ON memory_evidence(uid, source_revision_id);

CREATE TABLE memory_claims (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  content TEXT NOT NULL,
  valid_from INTEGER,
  valid_to INTEGER,
  recorded_at INTEGER NOT NULL,
  retracted_at INTEGER,
  supersedes_claim_id TEXT REFERENCES memory_claims(id) ON DELETE SET NULL,
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
CREATE INDEX memory_claims_uid_recorded ON memory_claims(uid, recorded_at DESC);

CREATE TABLE memory_claim_evidence (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  claim_id TEXT NOT NULL REFERENCES memory_claims(id) ON DELETE CASCADE,
  evidence_id TEXT NOT NULL REFERENCES memory_evidence(id) ON DELETE CASCADE,
  PRIMARY KEY (claim_id, evidence_id)
);
CREATE INDEX memory_claim_evidence_uid ON memory_claim_evidence(uid, claim_id);

CREATE TABLE memory_profile_entries (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  claim_id TEXT NOT NULL REFERENCES memory_claims(id) ON DELETE CASCADE,
  profile_kind TEXT NOT NULL CHECK (profile_kind IN ('stable', 'current')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'pinned', 'archived')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (uid, claim_id)
);
CREATE INDEX memory_profile_entries_uid_kind ON memory_profile_entries(uid, profile_kind, updated_at DESC);

CREATE TABLE memory_daily_reviews (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  local_date TEXT NOT NULL,
  input_revision TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  retracted_at INTEGER,
  UNIQUE (uid, local_date, input_revision)
);
CREATE INDEX memory_daily_reviews_uid_date ON memory_daily_reviews(uid, local_date DESC);

CREATE TABLE memory_daily_review_citations (
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  review_id TEXT NOT NULL REFERENCES memory_daily_reviews(id) ON DELETE CASCADE,
  evidence_id TEXT NOT NULL REFERENCES memory_evidence(id) ON DELETE CASCADE,
  PRIMARY KEY (review_id, evidence_id)
);

INSERT INTO memory_sources (id, uid, kind, external_id, created_at, updated_at, tombstoned_at)
SELECT 'legacy-source-' || id, uid, source, id, created_at, updated_at, deleted_at
FROM personal_memories;

INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)
SELECT 'legacy-revision-' || id, 'legacy-source-' || id, uid, 1, id, json_object('content', content), created_at, created_at
FROM personal_memories;

INSERT INTO memory_evidence (id, uid, source_revision_id, quote, locator, created_at)
SELECT 'legacy-evidence-' || id, uid, 'legacy-revision-' || id, content, evidence, created_at
FROM personal_memories;

INSERT INTO memory_claims (id, uid, content, recorded_at, retracted_at)
SELECT 'legacy-claim-' || id, uid, content, created_at, deleted_at
FROM personal_memories;

INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id)
SELECT uid, 'legacy-claim-' || id, 'legacy-evidence-' || id
FROM personal_memories;

INSERT INTO memory_profile_entries (id, uid, claim_id, profile_kind, status, created_at, updated_at)
SELECT id, uid, 'legacy-claim-' || id, 'current', CASE WHEN deleted_at IS NULL THEN 'active' ELSE 'archived' END, created_at, updated_at
FROM personal_memories;

DROP TABLE personal_memories;

ALTER TABLE user_settings ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;

CREATE TABLE setting_scopes (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  duration TEXT NOT NULL CHECK (duration IN ('task', 'session')),
  scope_id TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  patch TEXT NOT NULL CHECK (json_valid(patch)),
  created_at INTEGER NOT NULL,
  expires_at INTEGER,
  UNIQUE (uid, duration, scope_id)
);
CREATE INDEX setting_scopes_uid_scope ON setting_scopes(uid, duration, scope_id);

CREATE TABLE owner_confirmation_receipts (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  purpose TEXT NOT NULL,
  value TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
);
CREATE INDEX owner_confirmation_receipts_uid ON owner_confirmation_receipts(uid, purpose, created_at DESC);
