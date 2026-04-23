CREATE TABLE betting_alerts (
    id                BIGSERIAL PRIMARY KEY,
    match_id          BIGINT           NOT NULL REFERENCES matches (id) ON DELETE CASCADE,
    suggested_bet     VARCHAR(10)      NOT NULL,  -- HOME / AWAY / DRAW
    current_odds      DOUBLE PRECISION NOT NULL,
    baseline_odds     DOUBLE PRECISION NOT NULL,
    odds_increase_pct DOUBLE PRECISION NOT NULL,
    score_at_alert    VARCHAR(20),
    message           TEXT,
    notified          BOOLEAN          NOT NULL DEFAULT FALSE,
    triggered_at      TIMESTAMP        NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_alerts_match_id     ON betting_alerts (match_id);
CREATE INDEX idx_alerts_triggered_at ON betting_alerts (triggered_at);
