-- ============================================================
-- SportBets — Betting Performance Analysis
-- Run each section independently in psql or DataGrip.
--
-- SPORT SEPARATION
--   Sections 1–3  : all sports combined + per-sport breakdown
--   Sections 4–13 : FOOTBALL only (LOSING_BY_1 / TIED_HALFTIME,
--                   DC market, 1-goal deficit, minute bands 1–90)
--   Sections 14–15: BASKETBALL only (BASKETBALL_COMEBACK,
--                   period_id bands, point-deficit logic)
--
-- HOW OUTCOMES ARE DETERMINED
--   Uses the stored `market` column (V14 migration) as the authoritative source.
--   Football:
--     market = DOBLE_OPORTUNIDAD → DC bet: wins on draw-or-win (1X / X2)
--     market = RESULTADO_FINAL   → outright win only
--   Basketball:
--     market = PRORROGA_INCLUIDA → outright win only (no draw)
--   Rows where final score is NULL are still in progress or score was never captured.
--
-- P&L CALCULATIONS
--   Use actual_bet_odds (V14) for all payout math.
--   For DC bets this is the DC odds (~1.22–1.46); for outright bets = current_odds.
--   current_odds is the outright trigger-reference odds — kept for strategy analysis
--   sections (4–13) but must not be used as a payout multiplier.
-- ============================================================


-- ============================================================
-- SECTION 1 — DATA SNAPSHOT
-- Quick counts to understand how much data we have, split by sport.
-- ============================================================
SELECT
    (SELECT COUNT(*) FROM matches)                                                          AS total_matches,
    (SELECT COUNT(*) FROM matches WHERE sport = 'FOOTBALL')                                AS football_matches,
    (SELECT COUNT(*) FROM matches WHERE sport = 'BASKETBALL')                              AS basketball_matches,
    (SELECT COUNT(*) FROM matches WHERE status = 'FINISHED')                               AS finished_matches,
    (SELECT COUNT(*) FROM matches WHERE status = 'LIVE')                                   AS live_matches,
    (SELECT COUNT(*) FROM matches WHERE status = 'UPCOMING')                               AS upcoming_matches,
    (SELECT COUNT(*) FROM odds_snapshots WHERE is_pre_match = TRUE)                        AS pre_match_snapshots,
    (SELECT COUNT(*) FROM odds_snapshots WHERE is_pre_match = FALSE)                       AS live_snapshots,
    (SELECT COUNT(*) FROM betting_alerts)                                                  AS total_alerts,
    (SELECT COUNT(*) FROM betting_alerts
     WHERE trigger_scenario IN ('LOSING_BY_1','TIED_HALFTIME'))                            AS football_alerts,
    (SELECT COUNT(*) FROM betting_alerts
     WHERE trigger_scenario = 'BASKETBALL_COMEBACK')                                       AS basketball_alerts,
    (SELECT COUNT(*) FROM betting_alerts WHERE bet_status = 'PLACED')                     AS placed_bets,
    (SELECT COUNT(*) FROM betting_alerts WHERE bet_status = 'DRY_RUN')                    AS dry_run_bets,
    (SELECT COUNT(*) FROM betting_alerts WHERE bet_status = 'FAILED')                     AS failed_bets,
    (SELECT COUNT(*) FROM betting_alerts WHERE bet_status = 'SKIPPED')                    AS skipped_bets,
    (SELECT COUNT(*) FROM betting_alerts WHERE bet_status IS NULL)                        AS legacy_alerts;


-- ============================================================
-- SECTION 2 — BET OUTCOME PER ALERT  (all sports)
-- One row per alert with: sport, match, score at alert, final score, and whether the bet won.
-- NULL in "bet_won" = match not finished yet or final score not captured.
-- ============================================================
WITH alert_outcomes AS (
    SELECT
        a.id                                                        AS alert_id,
        m.sport,
        m.home_team || ' vs ' || m.away_team                        AS match_desc,
        m.competition,
        a.suggested_bet,
        a.trigger_scenario,
        a.bet_status,
        a.baseline_odds,
        a.current_odds,
        ROUND(a.odds_increase_pct::numeric, 1)                      AS rise_pct,
        a.score_at_alert,
        m.final_home_score,
        m.final_away_score,
        a.triggered_at,
        COALESCE(a.market, 'RESULTADO_FINAL')                       AS market,
        -- Determine outcome using stored market column
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            -- DC bet wins on draw-or-win
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet
                    WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                    WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
                    ELSE FALSE
                END
            -- Outright bet (football or basketball) must win
            ELSE
                CASE a.suggested_bet
                    WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                    WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
                    WHEN 'DRAW' THEN m.final_home_score = m.final_away_score
                    ELSE FALSE
                END
        END                                                         AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
)
SELECT
    alert_id,
    sport,
    match_desc,
    competition,
    suggested_bet,
    trigger_scenario,
    market,
    bet_status,
    baseline_odds,
    current_odds,
    rise_pct,
    score_at_alert,
    final_home_score || '-' || final_away_score                     AS final_score,
    CASE bet_won WHEN TRUE THEN 'WIN' WHEN FALSE THEN 'LOSS' ELSE 'PENDING' END AS result,
    triggered_at
FROM alert_outcomes
ORDER BY triggered_at DESC;


-- ============================================================
-- SECTION 3 — P&L SUMMARY  (all sports, grouped by sport + scenario/market)
-- Uses 1000 COP stake. Adjust :stake_cop if different.
-- Payout on win = stake * odds. Net = payout - stake.
-- ============================================================
WITH alert_outcomes AS (
    SELECT
        a.id,
        m.sport,
        a.trigger_scenario,
        a.bet_status,
        a.current_odds,
        COALESCE(a.actual_bet_odds, a.current_odds)     AS bet_odds,
        COALESCE(a.market, 'RESULTADO_FINAL')           AS market,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet
                    WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                    WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
                    ELSE FALSE END
            ELSE
                CASE a.suggested_bet
                    WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                    WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
                    WHEN 'DRAW' THEN m.final_home_score = m.final_away_score
                    ELSE FALSE END
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
),
pnl AS (
    SELECT
        sport,
        trigger_scenario,
        market,
        COUNT(*)                                        AS total_bets,
        COUNT(*) FILTER (WHERE bet_won IS TRUE)         AS wins,
        COUNT(*) FILTER (WHERE bet_won IS FALSE)        AS losses,
        COUNT(*) FILTER (WHERE bet_won IS NULL)         AS pending,
        ROUND(AVG(bet_odds)::numeric, 2)                AS avg_odds,
        ROUND(SUM(CASE bet_won WHEN TRUE  THEN bet_odds - 1
                               WHEN FALSE THEN -1
                               ELSE 0 END)::numeric, 2) AS net_units,
        ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
              / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
        ROUND((100.0 / NULLIF(AVG(bet_odds), 0))::numeric, 1)     AS breakeven_pct
    FROM alert_outcomes
    GROUP BY GROUPING SETS (
        (sport, trigger_scenario, market),
        (sport, trigger_scenario),
        (sport),
        ()  -- grand total
    )
)
SELECT
    COALESCE(sport,            '— ALL —')   AS sport,
    COALESCE(trigger_scenario, '— TOTAL —') AS scenario,
    COALESCE(market,           '—')         AS market,
    total_bets,
    wins,
    losses,
    pending,
    avg_odds,
    win_rate_pct,
    breakeven_pct                           AS breakeven_needed_pct,
    net_units,
    ROUND(net_units * 1000::numeric)        AS net_cop_per_1000_stake
FROM pnl
ORDER BY sport NULLS LAST, scenario NULLS LAST, market;


-- ============================================================
-- FOOTBALL SECTIONS (4–13)
-- All queries below filter to m.sport = 'FOOTBALL'.
-- ============================================================


-- ============================================================
-- SECTION 4 — ODDS RISE % BANDS  [FOOTBALL]
-- How does win rate correlate with how much the odds rose at alert time?
-- Use this to tune odds-rise-threshold-pct and odds-rise-max-pct.
-- ============================================================
WITH outcomes AS (
    SELECT
        a.odds_increase_pct,
        a.current_odds,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score ELSE FALSE END
            ELSE
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
                                     WHEN 'DRAW' THEN m.final_home_score = m.final_away_score ELSE FALSE END
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'FOOTBALL'
)
SELECT
    CASE
        WHEN odds_increase_pct < 15   THEN '  <15%'
        WHEN odds_increase_pct < 20   THEN '15-20%'
        WHEN odds_increase_pct < 30   THEN '20-30%'
        WHEN odds_increase_pct < 40   THEN '30-40%'
        WHEN odds_increase_pct < 60   THEN '40-60%'
        WHEN odds_increase_pct < 80   THEN '60-80%'
        ELSE                               ' ≥80% (collapse risk)'
    END                                     AS odds_rise_band,
    COUNT(*)                                AS bets,
    COUNT(*) FILTER (WHERE bet_won IS TRUE) AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(current_odds)::numeric, 2)    AS avg_odds_at_alert
FROM outcomes
GROUP BY odds_rise_band
ORDER BY odds_rise_band;


-- ============================================================
-- SECTION 5 — MATCH MINUTE BANDS  [FOOTBALL]
-- Which part of the match yields better bets?
-- Use to tune min-match-minute, max-match-minute, halftime window.
-- ============================================================
WITH snapshots_near_alert AS (
    SELECT DISTINCT ON (a.id)
        a.id          AS alert_id,
        a.trigger_scenario,
        a.bet_status,
        a.suggested_bet,
        a.current_odds,
        COALESCE(a.market, 'RESULTADO_FINAL') AS market,
        o.match_minute,
        m.final_home_score,
        m.final_away_score
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    JOIN odds_snapshots o ON o.match_id = a.match_id AND o.is_pre_match = FALSE
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'FOOTBALL'
    ORDER BY a.id, ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at)))
),
outcomes AS (
    SELECT
        match_minute,
        trigger_scenario,
        CASE
            WHEN final_home_score IS NULL THEN NULL
            WHEN market = 'DOBLE_OPORTUNIDAD' THEN
                CASE suggested_bet WHEN 'HOME' THEN final_home_score >= final_away_score
                                   WHEN 'AWAY' THEN final_away_score >= final_home_score ELSE FALSE END
            ELSE
                CASE suggested_bet WHEN 'HOME' THEN final_home_score > final_away_score
                                   WHEN 'AWAY' THEN final_away_score > final_home_score
                                   WHEN 'DRAW' THEN final_home_score = final_away_score ELSE FALSE END
        END AS bet_won
    FROM snapshots_near_alert
)
SELECT
    CASE
        WHEN match_minute < 30  THEN ' 1-29'
        WHEN match_minute < 45  THEN '30-44'
        WHEN match_minute < 60  THEN '45-59'
        WHEN match_minute < 75  THEN '60-74'
        ELSE                         '75-90'
    END                                     AS minute_band,
    trigger_scenario,
    COUNT(*)                                AS bets,
    COUNT(*) FILTER (WHERE bet_won IS TRUE) AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1) AS win_rate_pct
FROM outcomes
GROUP BY minute_band, trigger_scenario
ORDER BY minute_band, trigger_scenario;


-- ============================================================
-- SECTION 6 — BASELINE ODDS BANDS  [FOOTBALL]
-- What kind of favorites succeed when they fall behind?
-- Use to tune max-baseline-odds.
-- ============================================================
WITH outcomes AS (
    SELECT
        a.baseline_odds,
        a.current_odds,
        a.trigger_scenario,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score ELSE FALSE END
            ELSE
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
                                     WHEN 'DRAW' THEN m.final_home_score = m.final_away_score ELSE FALSE END
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'FOOTBALL'
)
SELECT
    CASE
        WHEN baseline_odds <= 1.30 THEN '≤1.30 (dominant)'
        WHEN baseline_odds <= 1.40 THEN '1.31-1.40'
        WHEN baseline_odds <= 1.50 THEN '1.41-1.50'
        WHEN baseline_odds <= 1.60 THEN '1.51-1.60'
        ELSE                            '>1.60 (weak fav)'
    END                                         AS baseline_band,
    COUNT(*)                                    AS bets,
    COUNT(*) FILTER (WHERE bet_won IS TRUE)     AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(current_odds)::numeric, 2)        AS avg_current_odds
FROM outcomes
GROUP BY baseline_band
ORDER BY baseline_band;


-- ============================================================
-- SECTION 7 — COMEBACK RATE (GROUND TRUTH)  [FOOTBALL]
-- Among ALL finished football matches where the pre-match favorite
-- was losing by exactly 1 goal at some point in the betting window,
-- how often did they actually come back?
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE
      AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
losing_moments AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        p.favorite_side,
        p.fav_odds,
        o.match_minute,
        o.home_score,
        o.away_score
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport = 'FOOTBALL'
      AND o.match_minute BETWEEN 1 AND 80
      AND (
          (p.favorite_side = 'HOME' AND o.away_score - o.home_score = 1)
       OR (p.favorite_side = 'AWAY' AND o.home_score - o.away_score = 1)
      )
    ORDER BY o.match_id, o.captured_at
),
with_final AS (
    SELECT
        l.*,
        m.final_home_score,
        m.final_away_score,
        CASE l.favorite_side
            WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
        END AS drew_or_won,
        CASE l.favorite_side
            WHEN 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
        END AS won_outright
    FROM losing_moments l
    JOIN matches m ON m.id = l.match_id
    WHERE m.final_home_score IS NOT NULL
)
SELECT
    CASE
        WHEN fav_odds <= 1.30 THEN '≤1.30'
        WHEN fav_odds <= 1.40 THEN '1.31-1.40'
        WHEN fav_odds <= 1.50 THEN '1.41-1.50'
        WHEN fav_odds <= 1.60 THEN '1.51-1.60'
        ELSE                       '>1.60'
    END                                                             AS baseline_band,
    COUNT(*)                                                        AS matches_favorite_was_losing,
    COUNT(*) FILTER (WHERE won_outright)                            AS won_outright_count,
    COUNT(*) FILTER (WHERE drew_or_won AND NOT won_outright)        AS drew_count,
    COUNT(*) FILTER (WHERE NOT drew_or_won)                         AS lost_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE won_outright)
          / NULLIF(COUNT(*), 0), 1)                                 AS outright_comeback_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE drew_or_won)
          / NULLIF(COUNT(*), 0), 1)                                 AS dc_comeback_pct
FROM with_final
GROUP BY GROUPING SETS ((baseline_band), ())
ORDER BY baseline_band NULLS LAST;


-- ============================================================
-- SECTION 8 — NEAR-MISSES  [FOOTBALL]
-- Matches where the favorite was losing by 1 in the window
-- but no alert fired — and what the final result was.
-- Useful for identifying over-conservative filter settings.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE
      AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
candidates AS (
    SELECT
        o.match_id,
        p.favorite_side,
        p.fav_baseline_odds,
        MAX(CASE p.favorite_side
                WHEN 'HOME' THEN (o.home_win_odds - p.fav_baseline_odds) / p.fav_baseline_odds * 100
                WHEN 'AWAY' THEN (o.away_win_odds - p.fav_baseline_odds) / p.fav_baseline_odds * 100
                ELSE             (o.draw_odds      - p.fav_baseline_odds) / p.fav_baseline_odds * 100
            END)                                AS peak_odds_rise_pct,
        MAX(CASE p.favorite_side
                WHEN 'HOME' THEN o.home_win_odds
                WHEN 'AWAY' THEN o.away_win_odds
                ELSE             o.draw_odds
            END)                                AS peak_odds,
        MIN(o.match_minute)                     AS first_losing_minute
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport = 'FOOTBALL'
      AND p.fav_baseline_odds <= 1.60
      AND o.match_minute BETWEEN 1 AND 80
      AND (
          (p.favorite_side = 'HOME' AND o.away_score - o.home_score = 1)
       OR (p.favorite_side = 'AWAY' AND o.home_score - o.away_score = 1)
      )
    GROUP BY o.match_id, p.favorite_side, p.fav_baseline_odds
)
SELECT
    m.home_team || ' vs ' || m.away_team                AS match_desc,
    m.competition,
    c.favorite_side,
    ROUND(c.fav_baseline_odds::numeric, 2)              AS baseline_odds,
    ROUND(c.peak_odds_rise_pct::numeric, 1)             AS peak_rise_pct,
    ROUND(c.peak_odds::numeric, 2)                      AS peak_odds,
    c.first_losing_minute,
    m.final_home_score || '-' || m.final_away_score     AS final_score,
    CASE c.favorite_side
        WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
        WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
    END                                                 AS was_comeback,
    EXISTS (SELECT 1 FROM betting_alerts a WHERE a.match_id = m.id)  AS alert_fired
FROM candidates c
JOIN matches m ON m.id = c.match_id
WHERE m.final_home_score IS NOT NULL
ORDER BY peak_odds_rise_pct DESC;


-- ============================================================
-- SECTION 9 — DOUBLE CHANCE DATA QUALITY  [FOOTBALL]
-- How often were DC odds/IDs available?
-- ============================================================
SELECT
    COUNT(*)                                                                    AS total_live_snapshots,
    COUNT(*) FILTER (WHERE home_draw_outcome_id IS NOT NULL)                    AS with_dc_outcome_id,
    COUNT(*) FILTER (WHERE home_draw_odds IS NOT NULL)                          AS with_dc_odds,
    ROUND(100.0 * COUNT(*) FILTER (WHERE home_draw_outcome_id IS NOT NULL)
          / NULLIF(COUNT(*), 0), 1)                                             AS dc_id_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE home_draw_odds IS NOT NULL)
          / NULLIF(COUNT(*), 0), 1)                                             AS dc_odds_coverage_pct,
    ROUND(AVG(home_draw_odds)::numeric, 3)                                      AS avg_home_draw_odds,
    ROUND(AVG(away_draw_odds)::numeric, 3)                                      AS avg_away_draw_odds
FROM odds_snapshots o
JOIN matches m ON m.id = o.match_id
WHERE o.is_pre_match = FALSE
  AND m.sport = 'FOOTBALL';

-- DC availability per competition
SELECT
    m.competition,
    COUNT(DISTINCT m.id)                                                        AS matches,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.home_draw_outcome_id IS NOT NULL)
          / NULLIF(COUNT(*), 0), 1)                                             AS dc_id_coverage_pct
FROM odds_snapshots o
JOIN matches m ON m.id = o.match_id
WHERE o.is_pre_match = FALSE
  AND m.sport = 'FOOTBALL'
GROUP BY m.competition
HAVING COUNT(*) >= 5
ORDER BY dc_id_coverage_pct DESC;


-- ============================================================
-- SECTION 10 — HALFTIME PATH (TIED_HALFTIME) DETAILED ANALYSIS  [FOOTBALL]
-- ============================================================
WITH halftime_snapshots AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        o.match_minute,
        o.home_score,
        o.away_score,
        o.home_win_odds,
        o.away_win_odds,
        o.draw_odds,
        (SELECT CASE
            WHEN LEAST(s.home_win_odds, s.draw_odds, s.away_win_odds) = s.home_win_odds THEN 'HOME'
            WHEN LEAST(s.home_win_odds, s.draw_odds, s.away_win_odds) = s.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
         END
         FROM odds_snapshots s
         WHERE s.match_id = o.match_id AND s.is_pre_match = TRUE
         ORDER BY s.captured_at DESC LIMIT 1)                        AS favorite_side
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport = 'FOOTBALL'
      AND o.home_score = o.away_score
      AND o.match_minute BETWEEN 10 AND 60
    ORDER BY o.match_id, o.captured_at
)
SELECT
    COUNT(*)                                                                AS total_tied_moments,
    COUNT(*) FILTER (WHERE m.final_home_score > m.final_away_score
                      AND h.favorite_side = 'HOME')                         AS home_fav_won,
    COUNT(*) FILTER (WHERE m.final_away_score > m.final_home_score
                      AND h.favorite_side = 'AWAY')                         AS away_fav_won,
    COUNT(*) FILTER (WHERE m.final_home_score = m.final_away_score)         AS ended_draw,
    COUNT(*) FILTER (WHERE (h.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
                        OR (h.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))
                                                                            AS fav_won_count,
    ROUND(100.0 * COUNT(*) FILTER (
            WHERE (h.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
               OR (h.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                                         AS fav_win_pct,
    ROUND(AVG(CASE h.favorite_side WHEN 'HOME' THEN h.home_win_odds ELSE h.away_win_odds END)::numeric, 2)
                                                                            AS avg_fav_odds_when_tied
FROM halftime_snapshots h
JOIN matches m ON m.id = h.match_id
WHERE m.final_home_score IS NOT NULL
  AND h.favorite_side IS NOT NULL;


-- ============================================================
-- SECTION 11 — ODDS DRIFT TIMELINE FOR ALERTED MATCHES  [all sports]
-- Shows odds history around each alert event.
-- ============================================================
SELECT
    m.sport,
    m.home_team || ' vs ' || m.away_team                AS match_desc,
    a.triggered_at                                      AS alert_time,
    a.trigger_scenario,
    o.match_minute,
    CASE (SELECT CASE
                WHEN LEAST(s.home_win_odds, s.draw_odds, s.away_win_odds) = s.home_win_odds THEN 'HOME'
                WHEN LEAST(s.home_win_odds, s.draw_odds, s.away_win_odds) = s.away_win_odds THEN 'AWAY'
                ELSE 'DRAW'
            END
          FROM odds_snapshots s
          WHERE s.match_id = m.id AND s.is_pre_match = TRUE
          ORDER BY s.captured_at DESC LIMIT 1)
        WHEN 'HOME' THEN o.home_win_odds
        WHEN 'AWAY' THEN o.away_win_odds
        ELSE             o.draw_odds
    END                                                 AS fav_odds,
    o.home_score || '-' || o.away_score                 AS score,
    o.captured_at,
    CASE WHEN o.captured_at < a.triggered_at THEN 'BEFORE' ELSE 'AFTER' END AS relative_to_alert
FROM betting_alerts a
JOIN matches m ON m.id = a.match_id
JOIN odds_snapshots o ON o.match_id = m.id AND o.is_pre_match = FALSE
   AND o.captured_at BETWEEN a.triggered_at - INTERVAL '20 minutes'
                         AND a.triggered_at + INTERVAL '30 minutes'
ORDER BY m.id, o.captured_at;


-- ============================================================
-- SECTION 12 — UNTAPPED OPPORTUNITIES  [FOOTBALL]
-- Finished matches where a comeback DID happen but no alert fired.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE
      AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
missed AS (
    SELECT
        m.id AS match_id,
        m.home_team, m.away_team, m.competition,
        p.favorite_side,
        p.fav_baseline_odds,
        m.final_home_score,
        m.final_away_score,
        CASE p.favorite_side
            WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
        END AS was_comeback,
        (SELECT ROUND(MAX(
            CASE p.favorite_side
                WHEN 'HOME' THEN (o2.home_win_odds - p.fav_baseline_odds) / p.fav_baseline_odds * 100
                WHEN 'AWAY' THEN (o2.away_win_odds - p.fav_baseline_odds) / p.fav_baseline_odds * 100
                ELSE 0
            END)::numeric, 1)
         FROM odds_snapshots o2
         WHERE o2.match_id = m.id AND o2.is_pre_match = FALSE
           AND o2.match_minute BETWEEN 1 AND 80
           AND (
               (p.favorite_side = 'HOME' AND o2.away_score - o2.home_score = 1)
            OR (p.favorite_side = 'AWAY' AND o2.home_score - o2.away_score = 1)
           ))                                                                AS peak_rise_pct
    FROM matches m
    JOIN pre_match_favs p ON p.match_id = m.id
    WHERE m.status = 'FINISHED'
      AND m.sport = 'FOOTBALL'
      AND m.final_home_score IS NOT NULL
      AND p.fav_baseline_odds <= 1.60
      AND NOT EXISTS (SELECT 1 FROM betting_alerts a WHERE a.match_id = m.id)
)
SELECT
    home_team || ' vs ' || away_team      AS match_desc,
    competition,
    favorite_side,
    ROUND(fav_baseline_odds::numeric, 2)  AS baseline_odds,
    peak_rise_pct,
    final_home_score || '-' || final_away_score AS final_score,
    was_comeback
FROM missed
WHERE peak_rise_pct IS NOT NULL
ORDER BY was_comeback DESC NULLS LAST, peak_rise_pct DESC;


-- ============================================================
-- SECTION 13 — CONFIG TUNING CHEAT SHEET  [FOOTBALL]
-- ============================================================

-- A) What win rate at different odds-rise thresholds?
WITH outcomes AS (
    SELECT
        a.odds_increase_pct,
        a.current_odds,
        COALESCE(a.actual_bet_odds, a.current_odds) AS bet_odds,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score ELSE FALSE END
            ELSE
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score > m.final_home_score ELSE FALSE END
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'FOOTBALL'
),
thresholds AS (SELECT unnest(ARRAY[10,15,20,25,30,35,40,50]) AS threshold)
SELECT
    t.threshold                             AS odds_rise_threshold_pct,
    COUNT(o.*)                              AS qualifying_bets,
    COUNT(*) FILTER (WHERE o.bet_won IS TRUE)  AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(o.bet_odds)::numeric, 2)      AS avg_odds,
    ROUND(((COUNT(*) FILTER (WHERE o.bet_won IS TRUE)::numeric
           / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0)
           * AVG(o.bet_odds) - 1) * 100)::numeric, 1) AS expected_value_pct
FROM thresholds t
CROSS JOIN outcomes o
WHERE o.odds_increase_pct >= t.threshold
GROUP BY t.threshold
ORDER BY t.threshold;

-- B) What win rate at different max-baseline-odds ceilings?
WITH outcomes AS (
    SELECT
        a.baseline_odds,
        a.current_odds,
        a.trigger_scenario,
        a.suggested_bet,
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.market = 'DOBLE_OPORTUNIDAD' THEN
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score ELSE FALSE END
            ELSE
                CASE a.suggested_bet WHEN 'HOME' THEN m.final_home_score > m.final_away_score
                                     WHEN 'AWAY' THEN m.final_away_score > m.final_home_score ELSE FALSE END
        END AS bet_won
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'FOOTBALL'
),
ceilings AS (SELECT unnest(ARRAY[1.30, 1.40, 1.50, 1.60, 1.70, 1.80]) AS ceiling)
SELECT
    c.ceiling                                AS max_baseline_odds,
    COUNT(o.*)                               AS qualifying_bets,
    COUNT(*) FILTER (WHERE o.bet_won IS TRUE)  AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE o.bet_won IS NOT NULL), 0), 1) AS win_rate_pct
FROM ceilings c
CROSS JOIN outcomes o
WHERE o.baseline_odds <= c.ceiling
GROUP BY c.ceiling
ORDER BY c.ceiling;


-- ============================================================
-- BASKETBALL SECTIONS (14–15)
-- All queries below filter to m.sport = 'BASKETBALL'.
-- Bet outcome is always outright (no draw in basketball).
-- ============================================================


-- ============================================================
-- SECTION 14 — BASKETBALL P&L BY PERIOD AND POINT DEFICIT
-- Groups BASKETBALL_COMEBACK alerts by the period in which the
-- alert fired and the point deficit at alert time.
-- Use this to tune bet-periods, min/max-point-deficit, and
-- odds-rise-threshold-pct for the basketball strategy.
-- ============================================================
WITH snapshots_near_alert AS (
    -- Closest live snapshot to each basketball alert (carries period_id)
    SELECT DISTINCT ON (a.id)
        a.id          AS alert_id,
        a.suggested_bet,
        a.bet_status,
        a.baseline_odds,
        a.current_odds,
        COALESCE(a.actual_bet_odds, a.current_odds) AS bet_odds,
        a.odds_increase_pct,
        o.period_id,
        o.home_score,
        o.away_score,
        m.final_home_score,
        m.final_away_score,
        -- Outright outcome only (no draw in basketball)
        CASE
            WHEN m.final_home_score IS NULL THEN NULL
            WHEN a.suggested_bet = 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN a.suggested_bet = 'AWAY' THEN m.final_away_score > m.final_home_score
            ELSE FALSE
        END AS bet_won,
        -- Point deficit of the favorite at alert time
        ABS(o.home_score - o.away_score) AS deficit_at_alert
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    JOIN odds_snapshots o ON o.match_id = a.match_id AND o.is_pre_match = FALSE
    WHERE a.bet_status IN ('PLACED', 'DRY_RUN')
      AND m.sport = 'BASKETBALL'
      AND a.trigger_scenario = 'BASKETBALL_COMEBACK'
    ORDER BY a.id, ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at)))
)
SELECT
    COALESCE(period_id, 'UNKNOWN')          AS period,
    CASE
        WHEN deficit_at_alert <= 5  THEN ' 1-5 pts'
        WHEN deficit_at_alert <= 10 THEN ' 6-10 pts'
        WHEN deficit_at_alert <= 15 THEN '11-15 pts'
        ELSE                             '>15 pts'
    END                                     AS deficit_band,
    COUNT(*)                                AS bets,
    COUNT(*) FILTER (WHERE bet_won IS TRUE) AS wins,
    COUNT(*) FILTER (WHERE bet_won IS FALSE) AS losses,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won IS TRUE)
          / NULLIF(COUNT(*) FILTER (WHERE bet_won IS NOT NULL), 0), 1) AS win_rate_pct,
    ROUND(AVG(bet_odds)::numeric, 2)        AS avg_odds,
    ROUND(AVG(baseline_odds)::numeric, 2)   AS avg_baseline_odds,
    ROUND(AVG(odds_increase_pct)::numeric, 1) AS avg_rise_pct,
    ROUND(SUM(CASE bet_won WHEN TRUE  THEN bet_odds - 1
                           WHEN FALSE THEN -1
                           ELSE 0 END)::numeric, 2) AS net_units
FROM snapshots_near_alert
GROUP BY GROUPING SETS (
    (period_id, deficit_band),
    (period_id),
    ()
)
ORDER BY period NULLS LAST, deficit_band NULLS LAST;


-- ============================================================
-- SECTION 15 — BASKETBALL COMEBACK RATE (GROUND TRUTH)
-- Among ALL finished basketball matches where the pre-match
-- favorite was behind in a monitored period, how often did
-- they win outright?
-- Use to validate the BASKETBALL_COMEBACK edge before tuning.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        CASE
            WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME'
            ELSE 'AWAY'
        END AS favorite_side,
        LEAST(o.home_win_odds, o.away_win_odds) AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE
      AND m.sport = 'BASKETBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
trailing_moments AS (
    -- First snapshot per match per period where the favorite is behind
    SELECT DISTINCT ON (o.match_id, o.period_id)
        o.match_id,
        o.period_id,
        p.favorite_side,
        p.fav_odds,
        o.home_score,
        o.away_score,
        ABS(o.home_score - o.away_score) AS deficit
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport = 'BASKETBALL'
      AND o.period_id IN ('HALFTIME', 'QUARTER3', 'QUARTER4')
      AND (
          (p.favorite_side = 'HOME' AND o.away_score > o.home_score)
       OR (p.favorite_side = 'AWAY' AND o.home_score > o.away_score)
      )
    ORDER BY o.match_id, o.period_id, o.captured_at
),
with_final AS (
    SELECT
        t.*,
        m.final_home_score,
        m.final_away_score,
        CASE t.favorite_side
            WHEN 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
        END AS won_outright
    FROM trailing_moments t
    JOIN matches m ON m.id = t.match_id
    WHERE m.final_home_score IS NOT NULL
)
SELECT
    period_id                                                               AS period,
    CASE
        WHEN fav_odds <= 1.30 THEN '≤1.30'
        WHEN fav_odds <= 1.40 THEN '1.31-1.40'
        WHEN fav_odds <= 1.50 THEN '1.41-1.50'
        WHEN fav_odds <= 1.60 THEN '1.51-1.60'
        ELSE                       '>1.60'
    END                                                                     AS baseline_band,
    CASE
        WHEN deficit <= 5  THEN ' 1-5 pts'
        WHEN deficit <= 10 THEN ' 6-10 pts'
        WHEN deficit <= 15 THEN '11-15 pts'
        ELSE                    '>15 pts'
    END                                                                     AS deficit_band,
    COUNT(*)                                                                AS trailing_moments,
    COUNT(*) FILTER (WHERE won_outright)                                    AS won_outright_count,
    COUNT(*) FILTER (WHERE NOT won_outright)                                AS lost_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE won_outright)
          / NULLIF(COUNT(*), 0), 1)                                         AS comeback_pct
FROM with_final
GROUP BY GROUPING SETS (
    (period_id, baseline_band, deficit_band),
    (period_id, baseline_band),
    (period_id),
    ()
)
ORDER BY period NULLS LAST, baseline_band NULLS LAST, deficit_band NULLS LAST;
