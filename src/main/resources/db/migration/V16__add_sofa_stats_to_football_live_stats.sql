ALTER TABLE football_live_stats
    ADD COLUMN home_possession       INTEGER,
    ADD COLUMN away_possession       INTEGER,
    ADD COLUMN home_shots_on_target  INTEGER,
    ADD COLUMN away_shots_on_target  INTEGER,
    ADD COLUMN home_shots_off_target INTEGER,
    ADD COLUMN away_shots_off_target INTEGER;
