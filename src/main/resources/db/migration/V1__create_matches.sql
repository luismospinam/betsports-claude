CREATE TABLE matches (
    id          BIGSERIAL PRIMARY KEY,
    external_id VARCHAR(100) NOT NULL UNIQUE,
    home_team   VARCHAR(200) NOT NULL,
    away_team   VARCHAR(200) NOT NULL,
    competition VARCHAR(200),
    match_date  TIMESTAMP    NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'UPCOMING',
    betplay_url VARCHAR(500),
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_matches_status     ON matches (status);
CREATE INDEX idx_matches_match_date ON matches (match_date);
CREATE INDEX idx_matches_external_id ON matches (external_id);
