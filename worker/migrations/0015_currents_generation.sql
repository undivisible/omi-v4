PRAGMA foreign_keys = ON;

ALTER TABLE currents ADD COLUMN generation_key TEXT;
CREATE UNIQUE INDEX currents_uid_generation ON currents(uid, generation_key) WHERE generation_key IS NOT NULL;
