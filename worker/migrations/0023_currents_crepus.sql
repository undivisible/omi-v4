PRAGMA foreign_keys = ON;

ALTER TABLE currents ADD COLUMN crepus TEXT CHECK (crepus IS NULL OR length(crepus) <= 8000);
