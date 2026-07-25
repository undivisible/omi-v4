ALTER TABLE memory_evidence ADD COLUMN byte_start INTEGER;
ALTER TABLE memory_evidence ADD COLUMN byte_end INTEGER;

ALTER TABLE memory_claims ADD COLUMN subject TEXT NOT NULL DEFAULT 'person';
ALTER TABLE memory_claims ADD COLUMN predicate TEXT NOT NULL DEFAULT 'remembers';
ALTER TABLE memory_claims ADD COLUMN value TEXT;
ALTER TABLE memory_claims ADD COLUMN status TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('proposed', 'accepted', 'superseded', 'rejected'));
ALTER TABLE memory_claims ADD COLUMN recorded_until INTEGER;
UPDATE memory_claims SET value = content WHERE value IS NULL;

ALTER TABLE memory_claim_evidence ADD COLUMN relation TEXT NOT NULL DEFAULT 'supports' CHECK (relation IN ('supports', 'contradicts'));
ALTER TABLE memory_claim_evidence ADD COLUMN confidence_basis_points INTEGER NOT NULL DEFAULT 10000 CHECK (confidence_basis_points BETWEEN 0 AND 10000);

ALTER TABLE memory_profile_entries ADD COLUMN profile_key TEXT NOT NULL DEFAULT 'memory';
ALTER TABLE memory_profile_entries ADD COLUMN profile_value TEXT;
UPDATE memory_profile_entries
SET profile_value = (SELECT value FROM memory_claims WHERE memory_claims.id = memory_profile_entries.claim_id)
WHERE profile_value IS NULL;
