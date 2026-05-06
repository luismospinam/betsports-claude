-- ============================================================
-- SportBets — Basketball Performance Analysis
-- Run each section independently in psql or DataGrip.
--
-- All queries filter to m.sport = 'BASKETBALL'.
-- Outcome is always outright win (no draw in basketball).
--
-- HOW OUTCOMES ARE DETERMINED
--   BASKETBALL_COMEBACK → PRORROGA_INCLUIDA (outright, OT included)
--   HOME wins if final_home_score > final_away_score
--   AWAY wins if final_away_score > final_home_score
--   Rows where final_home_score IS NULL = pending / score not captured
--
-- PERIOD IDs in Kambi for basketball:
--   QUARTER1, QUARTER2, QUARTER3, QUARTER4, OT1
--   NOTE: 'HALFTIME' does NOT appear as a period_id — Kambi uses QUARTER2
--   through the halftime break. Remove HALFTIME from bet-periods config.
-- ============================================================


-- ============================================================
-- SECTION 1 — DATA SNAPSHOT
-- ============================================================
SELECT
    COUNT(*)                                                                AS total_matches,
    COUNT(*) FILTER (WHERE status = 'FINISHED')                            AS finished,
    COUNT(*) FILTER (WHERE status = 'LIVE')                                AS live,
    COUNT(*) FILTER (WHERE status = 'UPCOMING')                            AS upcoming,
    (SELECT COUNT(*) FROM odds_snapshots o
     JOIN matches m ON m.id = o.match_id
     WHERE m.sport = 'BASKETBALL' AND o.is_pre_match = TRUE)               AS pre_match_snapshots,
    (SELECT COUNT(*) FROM odds_snapshots o
     JOIN matches m ON m.id = o.match_id
     WHERE m.sport = 'BASKETBALL' AND o.is_pre_match = FALSE)              AS live_snapshots,
    (SELECT COUNT(*) FROM betting_alerts a
     JOIN matches m ON m.id = a.match_id WHERE m.sport = 'BASKETBALL')    AS total_alerts,
    (SELECT COUNT(*) FROM betting_alerts a
     JOIN matches m ON m.id = a.match_id
     WHERE m.sport = 'BASKETBALL' AND a.bet_status = 'PLACED')            AS placed_bets,
    (SELECT COUNT(*) FROM betting_alerts a
     JOIN matches m ON m.id = a.match_id
     WHERE m.sport = 'BASKETBALL'
       AND a.bet_status IN ('FAILED', 'SKIPPED'))                         AS failed_skipped
FROM matches WHERE sport = 'BASKETBALL';


-- ============================================================
-- SECTION 2 — BET OUTCOME PER ALERT
-- One row per alert: match, score at alert, final score, result.
-- ============================================================
SELECT
    a.id                                                                    AS alert_id,
    m.home_team || ' vs ' || m.away_team                                    AS match_desc,
    m.competition,
    a.suggested_bet,
    a.bet_status,
    ROUND(a.baseline_odds::numeric, 2)                                      AS baseline_odds,
    ROUND(a.current_odds::numeric, 2)                                       AS current_odds,
    ROUND(a.odds_increase_pct::numeric, 1)                                  AS rise_pct,
    a.score_at_alert,
    m.final_home_score || '-' || m.final_away_score                         AS final_score,
    CASE
        WHEN m.final_home_score IS NULL                                         THEN 'PENDING'
        WHEN a.suggested_bet = 'HOME' AND m.final_home_score > m.final_away_score THEN 'WIN'
        WHEN a.suggested_bet = 'AWAY' AND m.final_away_score > m.final_home_score THEN 'WIN'
        ELSE 'LOSS'
    END                                                                     AS result,
    a.triggered_at
FROM betting_alerts a
JOIN matches m ON m.id = a.match_id
WHERE m.sport = 'BASKETBALL'
ORDER BY a.triggered_at DESC;


-- ============================================================
-- SECTION 3 — P&L BY PERIOD AND POINT DEFICIT
-- Groups placed bets by the period the alert fired in and the
-- point deficit at alert time.
-- Use to tune bet-periods, min/max-point-deficit.
-- ============================================================
WITH snap AS (
    SELECT DISTINCT ON (a.id)
        a.id                                                                AS alert_id,
        a.suggested_bet,
        a.bet_status,
        ROUND(a.baseline_odds::numeric, 2)                                  AS baseline_odds,
        ROUND(a.current_odds::numeric, 2)                                   AS current_odds,
        ROUND(COALESCE(a.actual_bet_odds, a.current_odds)::numeric, 2)      AS bet_odds,
        ROUND(a.odds_increase_pct::numeric, 1)                              AS rise_pct,
        o.period_id,
        ABS(o.home_score - o.away_score)                                    AS deficit_at_alert,
        m.final_home_score,
        m.final_away_score,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.suggested_bet = 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN a.suggested_bet = 'AWAY' THEN m.final_away_score > m.final_home_score
            ELSE FALSE
        END                                                                 AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    JOIN odds_snapshots o ON o.match_id = a.match_id AND o.is_pre_match = FALSE
    WHERE m.sport = 'BASKETBALL'
      AND a.bet_status IN ('PLACED', 'DRY_RUN')
    ORDER BY a.id, ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at)))
)
SELECT
    COALESCE(period_id, 'UNKNOWN')                  AS period,
    CASE
        WHEN deficit_at_alert <= 3  THEN '1-3 pts'
        WHEN deficit_at_alert <= 6  THEN '4-6 pts'
        WHEN deficit_at_alert <= 10 THEN '7-10 pts'
        WHEN deficit_at_alert <= 15 THEN '11-15 pts'
        ELSE                             '>15 pts'
    END                                             AS deficit_band,
    COUNT(*)                                        AS bets,
    COUNT(*) FILTER (WHERE bet_won IS TRUE)         AS wins,
    COUNT(*) FILTER (WHERE bet_won IS FALSE)        AS losses,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1)      AS win_rate_pct,
    ROUND(AVG(bet_odds)::numeric, 2)                AS avg_odds,
    ROUND(AVG(baseline_odds)::numeric, 2)           AS avg_baseline_odds,
    ROUND(AVG(rise_pct)::numeric, 1)                AS avg_rise_pct,
    ROUND(SUM(CASE bet_won WHEN TRUE  THEN bet_odds - 1
                           WHEN FALSE THEN -1
                           ELSE 0 END)::numeric, 2) AS net_units
FROM snap
GROUP BY GROUPING SETS (
    (period_id, deficit_band),
    (period_id),
    ()
)
ORDER BY period NULLS LAST, deficit_band NULLS LAST;


-- ============================================================
-- SECTION 4 — ODDS RISE THRESHOLD ANALYSIS
-- Simulates different odds-rise-threshold-pct values.
-- Use to tune odds-rise-threshold-pct.
-- ============================================================
WITH outcomes AS (
    SELECT
        a.odds_increase_pct,
        a.current_odds,
        COALESCE(a.actual_bet_odds, a.current_odds) AS bet_odds,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.suggested_bet = 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN a.suggested_bet = 'AWAY' THEN m.final_away_score > m.final_home_score
            ELSE FALSE
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE m.sport = 'BASKETBALL'
      AND a.bet_status IN ('PLACED', 'DRY_RUN')
),
thresholds AS (SELECT unnest(ARRAY[20,25,30,35,40,50,60]) AS threshold)
SELECT
    t.threshold                                         AS min_rise_pct,
    COUNT(o.*)                                         AS qualifying_bets,
    COUNT(*) FILTER (WHERE o.bet_won IS TRUE)          AS wins,
    COUNT(*) FILTER (WHERE o.bet_won IS FALSE)         AS losses,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(o.bet_odds)::numeric, 2)                 AS avg_odds,
    ROUND((COUNT(*) FILTER (WHERE o.bet_won IS TRUE)::numeric
           / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0)
           * AVG(o.bet_odds) - 1)::numeric * 100, 1)   AS ev_pct
FROM thresholds t
CROSS JOIN outcomes o
WHERE o.odds_increase_pct >= t.threshold
GROUP BY t.threshold
ORDER BY t.threshold;


-- ============================================================
-- SECTION 5 — MAX CURRENT ODDS CEILING ANALYSIS
-- Simulates different max-current-odds values.
-- ============================================================
WITH outcomes AS (
    SELECT
        a.current_odds,
        COALESCE(a.actual_bet_odds, a.current_odds) AS bet_odds,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.suggested_bet = 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN a.suggested_bet = 'AWAY' THEN m.final_away_score > m.final_home_score
            ELSE FALSE
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE m.sport = 'BASKETBALL'
      AND a.bet_status IN ('PLACED', 'DRY_RUN')
),
ceilings AS (SELECT unnest(ARRAY[2.0, 2.5, 3.0, 3.5, 4.0]) AS ceiling)
SELECT
    c.ceiling                                          AS max_current_odds,
    COUNT(o.*)                                         AS qualifying_bets,
    COUNT(*) FILTER (WHERE o.bet_won IS TRUE)          AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(o.bet_odds)::numeric, 2)                 AS avg_odds,
    ROUND((COUNT(*) FILTER (WHERE o.bet_won IS TRUE)::numeric
           / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0)
           * AVG(o.bet_odds) - 1)::numeric * 100, 1)   AS ev_pct
FROM ceilings c
CROSS JOIN outcomes o
WHERE o.current_odds <= c.ceiling
GROUP BY c.ceiling
ORDER BY c.ceiling;


-- ============================================================
-- SECTION 6 — BASELINE ODDS BANDS (placed bets)
-- Use to tune max-baseline-odds.
-- ============================================================
SELECT
    CASE
        WHEN a.baseline_odds <= 1.20 THEN '<=1.20'
        WHEN a.baseline_odds <= 1.30 THEN '1.21-1.30'
        WHEN a.baseline_odds <= 1.40 THEN '1.31-1.40'
        WHEN a.baseline_odds <= 1.50 THEN '1.41-1.50'
        WHEN a.baseline_odds <= 1.60 THEN '1.51-1.60'
        ELSE                              '>1.60'
    END                                                 AS baseline_band,
    COUNT(*)                                            AS bets,
    COUNT(*) FILTER (WHERE
        (a.suggested_bet = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (a.suggested_bet = 'AWAY' AND m.final_away_score > m.final_home_score)) AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE
        (a.suggested_bet = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (a.suggested_bet = 'AWAY' AND m.final_away_score > m.final_home_score))
     / NULLIF(COUNT(*) FILTER (WHERE m.final_home_score IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(a.current_odds)::numeric, 2)              AS avg_odds
FROM betting_alerts a
JOIN matches m ON m.id = a.match_id
WHERE m.sport = 'BASKETBALL'
  AND a.bet_status IN ('PLACED', 'DRY_RUN')
  AND m.final_home_score IS NOT NULL
GROUP BY baseline_band
ORDER BY baseline_band;


-- ============================================================
-- SECTION 7 — GROUND TRUTH: COMEBACK RATE BY PERIOD
-- Among ALL finished basketball matches, how often does the
-- pre-match favorite win when trailing in each quarter?
-- Validates the BASKETBALL_COMEBACK edge before relying on bets.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav_side,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
      AND o.home_win_odds IS NOT NULL AND o.away_win_odds IS NOT NULL
    ORDER BY o.match_id, o.captured_at DESC
),
trailing_moments AS (
    SELECT DISTINCT ON (o.match_id, o.period_id)
        o.match_id, o.period_id, p.fav_side, p.fav_odds,
        ABS(o.home_score - o.away_score) AS deficit
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE AND m.status = 'FINISHED' AND m.sport = 'BASKETBALL'
      AND o.period_id IN ('QUARTER1', 'QUARTER2', 'QUARTER3', 'QUARTER4')
      AND ((p.fav_side = 'HOME' AND o.away_score > o.home_score)
        OR (p.fav_side = 'AWAY' AND o.home_score > o.away_score))
    ORDER BY o.match_id, o.period_id, o.captured_at
)
SELECT
    t.period_id,
    COUNT(*)                                            AS trailing_moments,
    COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score)) AS won,
    ROUND(100.0 * COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score))
     / NULLIF(COUNT(*), 0), 1)                          AS comeback_pct,
    ROUND(AVG(t.deficit)::numeric, 1)                   AS avg_deficit,
    ROUND(AVG(t.fav_odds)::numeric, 2)                  AS avg_baseline_odds
FROM trailing_moments t
JOIN matches m ON m.id = t.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY t.period_id
ORDER BY t.period_id;


-- ============================================================
-- SECTION 8 — GROUND TRUTH: COMEBACK RATE BY POINT DEFICIT
-- (QUARTER2 + QUARTER3 + QUARTER4 combined)
-- Use to tune min-point-deficit and max-point-deficit.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav_side,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
      AND o.home_win_odds IS NOT NULL AND o.away_win_odds IS NOT NULL
    ORDER BY o.match_id, o.captured_at DESC
),
trailing_moments AS (
    SELECT DISTINCT ON (o.match_id, o.period_id)
        o.match_id, o.period_id, p.fav_side, p.fav_odds,
        ABS(o.home_score - o.away_score) AS deficit
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE AND m.status = 'FINISHED' AND m.sport = 'BASKETBALL'
      AND o.period_id IN ('QUARTER2', 'QUARTER3', 'QUARTER4')
      AND ((p.fav_side = 'HOME' AND o.away_score > o.home_score)
        OR (p.fav_side = 'AWAY' AND o.home_score > o.away_score))
    ORDER BY o.match_id, o.period_id, o.captured_at
)
SELECT
    CASE
        WHEN deficit <= 3  THEN '1-3 pts'
        WHEN deficit <= 6  THEN '4-6 pts'
        WHEN deficit <= 10 THEN '7-10 pts'
        WHEN deficit <= 15 THEN '11-15 pts'
        ELSE                    '>15 pts'
    END                                                 AS deficit_band,
    COUNT(*)                                            AS trailing_moments,
    COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score)) AS won,
    ROUND(100.0 * COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score))
     / NULLIF(COUNT(*), 0), 1)                          AS comeback_pct,
    ROUND(AVG(deficit)::numeric, 1)                     AS avg_deficit
FROM trailing_moments t
JOIN matches m ON m.id = t.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY deficit_band
ORDER BY deficit_band;


-- ============================================================
-- SECTION 9 — GROUND TRUTH: BASELINE ODDS BANDS
-- (QUARTER2 + QUARTER3 + QUARTER4 combined)
-- Use to tune max-baseline-odds.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav_side,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
      AND o.home_win_odds IS NOT NULL AND o.away_win_odds IS NOT NULL
    ORDER BY o.match_id, o.captured_at DESC
),
trailing_moments AS (
    SELECT DISTINCT ON (o.match_id, o.period_id)
        o.match_id, o.period_id, p.fav_side, p.fav_odds,
        ABS(o.home_score - o.away_score) AS deficit
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE AND m.status = 'FINISHED' AND m.sport = 'BASKETBALL'
      AND o.period_id IN ('QUARTER2', 'QUARTER3', 'QUARTER4')
      AND ((p.fav_side = 'HOME' AND o.away_score > o.home_score)
        OR (p.fav_side = 'AWAY' AND o.home_score > o.away_score))
    ORDER BY o.match_id, o.period_id, o.captured_at
)
SELECT
    CASE
        WHEN fav_odds <= 1.20 THEN '<=1.20'
        WHEN fav_odds <= 1.30 THEN '1.21-1.30'
        WHEN fav_odds <= 1.40 THEN '1.31-1.40'
        WHEN fav_odds <= 1.50 THEN '1.41-1.50'
        WHEN fav_odds <= 1.60 THEN '1.51-1.60'
        ELSE                       '>1.60'
    END                                                 AS baseline_band,
    COUNT(*)                                            AS trailing_moments,
    COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score)) AS won,
    ROUND(100.0 * COUNT(*) FILTER (WHERE
        (t.fav_side = 'HOME' AND m.final_home_score > m.final_away_score)
     OR (t.fav_side = 'AWAY' AND m.final_away_score > m.final_home_score))
     / NULLIF(COUNT(*), 0), 1)                          AS comeback_pct
FROM trailing_moments t
JOIN matches m ON m.id = t.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY baseline_band
ORDER BY baseline_band;
