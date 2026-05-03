-- Explicitly mark all existing matches as FOOTBALL.
-- V11 adds the column with DEFAULT 'FOOTBALL' which covers rows at migration time,
-- but this makes the intent explicit and handles any edge cases.
UPDATE matches SET sport = 'FOOTBALL' WHERE sport IS NULL OR sport != 'BASKETBALL';
