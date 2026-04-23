ALTER TABLE odds_snapshots
    ADD COLUMN home_outcome_id BIGINT,
    ADD COLUMN draw_outcome_id BIGINT,
    ADD COLUMN away_outcome_id BIGINT;
