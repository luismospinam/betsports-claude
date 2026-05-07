CREATE TABLE football_live_stats (
    id                BIGSERIAL PRIMARY KEY,
    odds_snapshot_id  BIGINT NOT NULL UNIQUE REFERENCES odds_snapshots(id),
    home_corners      INTEGER,
    away_corners      INTEGER,
    home_yellow_cards INTEGER,
    away_yellow_cards INTEGER,
    home_red_cards    INTEGER,
    away_red_cards    INTEGER
);
