CREATE VIRTUAL TABLE memory_claims_fts USING fts5(
  id UNINDEXED,
  uid UNINDEXED,
  content,
  subject,
  predicate,
  value
);

INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
SELECT id, uid, content, subject, predicate, value FROM memory_claims;
