CREATE TABLE odds_snapshots (
    id             BIGSERIAL PRIMARY KEY,
    match_id       BIGINT           NOT NULL REFERENCES matches (id) ON DELETE CASCADE,
    home_win_odds  DOUBLE PRECISION NOT NULL,
    draw_odds      DOUBLE PRECISION NOT NULL,
    away_win_odds  DOUBLE PRECISION NOT NULL,
    is_pre_match   BOOLEAN          NOT NULL DEFAULT FALSE,
    home_score     INT,
    away_score     INT,
    captured_at    TIMESTAMP        NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_odds_match_id    ON odds_snapshots (match_id);
CREATE INDEX idx_odds_captured_at ON odds_snapshots (captured_at);
CREATE INDEX idx_odds_pre_match   ON odds_snapshots (match_id, is_pre_match);
