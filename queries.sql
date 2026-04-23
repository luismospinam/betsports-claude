-- ============================================================
-- SportBets — useful queries
-- ============================================================


-- ------------------------------------------------------------
-- MATCHES
-- ------------------------------------------------------------

-- All matches with their current status
SELECT external_id, home_team, away_team, competition, match_date, status
FROM matches
ORDER BY match_date DESC;

-- Matches by status (change 'LIVE' to UPCOMING / FINISHED / CANCELLED)
SELECT external_id, home_team, away_team, competition, match_date
FROM matches
WHERE status = 'LIVE'
ORDER BY match_date;

-- Matches starting in the next 24 hours
SELECT external_id, home_team, away_team, competition, match_date, status
FROM matches
WHERE match_date BETWEEN NOW() AND NOW() + INTERVAL '24 hours'
ORDER BY match_date;


-- ------------------------------------------------------------
-- ODDS SNAPSHOTS
-- ------------------------------------------------------------

-- Latest odds for every match (one row per match)
SELECT
    m.external_id,
    m.home_team,
    m.away_team,
    m.status,
    o.home_win_odds,
    o.draw_odds,
    o.away_win_odds,
    o.home_score,
    o.away_score,
    o.match_minute,
    o.captured_at
FROM odds_snapshots o
JOIN matches m ON m.id = o.match_id
WHERE o.id = (
    SELECT id FROM odds_snapshots o2
    WHERE o2.match_id = o.match_id
    ORDER BY captured_at DESC
    LIMIT 1
)
ORDER BY m.match_date DESC;

-- Pre-match baseline vs latest live odds side by side (odds drift per match)
SELECT
    m.external_id,
    m.home_team,
    m.away_team,
    m.status,
    pre.home_win_odds  AS pre_home,
    pre.draw_odds      AS pre_draw,
    pre.away_win_odds  AS pre_away,
    live.home_win_odds AS live_home,
    live.draw_odds     AS live_draw,
    live.away_win_odds AS live_away,
    ROUND(((live.home_win_odds - pre.home_win_odds) / pre.home_win_odds * 100)::numeric, 1) AS home_drift_pct,
    ROUND(((live.draw_odds     - pre.draw_odds)     / pre.draw_odds     * 100)::numeric, 1) AS draw_drift_pct,
    ROUND(((live.away_win_odds - pre.away_win_odds) / pre.away_win_odds * 100)::numeric, 1) AS away_drift_pct,
    live.home_score,
    live.away_score,
    live.match_minute
FROM matches m
JOIN odds_snapshots pre  ON pre.match_id  = m.id AND pre.is_pre_match  = TRUE
JOIN odds_snapshots live ON live.match_id = m.id AND live.is_pre_match = FALSE
WHERE live.id = (
    SELECT id FROM odds_snapshots o2
    WHERE o2.match_id = m.id AND o2.is_pre_match = FALSE
    ORDER BY captured_at DESC
    LIMIT 1
)
ORDER BY m.match_date DESC;

-- Full odds history for a specific match (by external_id)
SELECT
    o.is_pre_match,
    o.home_win_odds,
    o.draw_odds,
    o.away_win_odds,
    o.home_score,
    o.away_score,
    o.match_minute,
    o.captured_at
FROM odds_snapshots o
JOIN matches m ON m.id = o.match_id
WHERE m.external_id = 'REPLACE_WITH_EXTERNAL_ID'
ORDER BY o.captured_at;

-- Snapshot count per match (how many polls were captured)
SELECT
    m.external_id,
    m.home_team,
    m.away_team,
    m.status,
    COUNT(*) FILTER (WHERE o.is_pre_match)      AS pre_match_snapshots,
    COUNT(*) FILTER (WHERE NOT o.is_pre_match)  AS live_snapshots
FROM matches m
LEFT JOIN odds_snapshots o ON o.match_id = m.id
GROUP BY m.id, m.external_id, m.home_team, m.away_team, m.status
ORDER BY m.match_date DESC;


-- ------------------------------------------------------------
-- BETTING ALERTS
-- ------------------------------------------------------------

-- All alerts with match context
SELECT
    m.external_id,
    m.home_team,
    m.away_team,
    a.suggested_bet,
    a.baseline_odds,
    a.current_odds,
    ROUND(a.odds_increase_pct::numeric, 1) AS drift_pct,
    a.score_at_alert,
    a.notified,
    a.triggered_at
FROM betting_alerts a
JOIN matches m ON m.id = a.match_id
ORDER BY a.triggered_at DESC;

-- Undelivered Discord alerts (notified = false)
SELECT
    m.home_team,
    m.away_team,
    a.suggested_bet,
    a.current_odds,
    a.odds_increase_pct,
    a.triggered_at
FROM betting_alerts a
JOIN matches m ON m.id = a.match_id
WHERE a.notified = FALSE
ORDER BY a.triggered_at;

-- Alert summary: total fired, delivered, and average drift
SELECT
    COUNT(*)                                          AS total_alerts,
    COUNT(*) FILTER (WHERE notified)                  AS delivered,
    COUNT(*) FILTER (WHERE NOT notified)              AS pending,
    ROUND(AVG(odds_increase_pct)::numeric, 1)         AS avg_drift_pct,
    ROUND(MAX(odds_increase_pct)::numeric, 1)         AS max_drift_pct
FROM betting_alerts;


-- ------------------------------------------------------------
-- COMBINED DASHBOARD (one row per live match)
-- ------------------------------------------------------------
SELECT
    m.external_id,
    m.home_team || ' vs ' || m.away_team              AS match,
    m.competition,
    m.status,
    o.home_score || '-' || o.away_score               AS score,
    o.match_minute                                    AS minute,
    o.home_win_odds                                   AS home,
    o.draw_odds                                       AS draw,
    o.away_win_odds                                   AS away,
    COUNT(a.id)                                       AS alerts_fired,
    o.captured_at                                     AS last_poll
FROM matches m
LEFT JOIN odds_snapshots o ON o.match_id = m.id AND o.is_pre_match = FALSE
    AND o.id = (
        SELECT id FROM odds_snapshots o2
        WHERE o2.match_id = m.id AND o2.is_pre_match = FALSE
        ORDER BY captured_at DESC LIMIT 1
    )
LEFT JOIN betting_alerts a ON a.match_id = m.id
WHERE m.status = 'LIVE'
GROUP BY m.id, m.external_id, m.home_team, m.away_team, m.competition, m.status,
         o.home_score, o.away_score, o.match_minute,
         o.home_win_odds, o.draw_odds, o.away_win_odds, o.captured_at
ORDER BY m.match_date;
