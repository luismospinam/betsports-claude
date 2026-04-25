ALTER TABLE matches
    ADD COLUMN final_home_score INT,
    ADD COLUMN final_away_score INT;

-- Backfill from the most recent odds snapshot that has a score
UPDATE matches m
SET final_home_score = s.home_score,
    final_away_score = s.away_score
FROM (
    SELECT DISTINCT ON (match_id) match_id, home_score, away_score
    FROM odds_snapshots
    WHERE home_score IS NOT NULL
    ORDER BY match_id, captured_at DESC
) s
WHERE m.id = s.match_id
  AND m.status = 'FINISHED';
