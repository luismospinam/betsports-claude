ALTER TABLE matches ADD COLUMN sport VARCHAR(20) NOT NULL DEFAULT 'FOOTBALL';
CREATE INDEX idx_matches_sport ON matches (sport);
