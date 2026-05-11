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


-- ============================================================
-- SECTION 16 — FOOTBALL: STAT-CONDITIONED COMEBACK RATE
-- For every trailing-by-1 moment that crossed the rise threshold,
-- with live stats attached, slice the DC and outright comeback
-- rate by live-stat bands.
--
-- Read: a band that shows ≥10pp separation with ≥30 samples is a
-- candidate filter for OddsMonitorService.checkAndFireAlert().
--
-- DATA NOTE (2026-05-10): football_live_stats started populating
-- 2026-05-07 (corners/cards) and 2026-05-08 (SofaScore possession/
-- shots). Bands with small sample counts are flagged as "wait".
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END                                                   AS fav,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds)  AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
trigger_moments AS (
    -- First snapshot per match where:
    --   - favorite is losing by exactly 1
    --   - favorite live odds rose ≥30% from baseline
    --   - minute in 1..80
    --   - stats are attached
    SELECT DISTINCT ON (o.match_id)
        m.id                                       AS match_id,
        p.fav,
        p.fav_odds,
        m.final_home_score, m.final_away_score,
        -- Favorite-relative stat values (so HOME/AWAY symmetry is removed)
        CASE p.fav WHEN 'HOME' THEN fs.home_possession       ELSE fs.away_possession       END AS fav_poss,
        CASE p.fav WHEN 'HOME' THEN fs.home_shots_on_target  ELSE fs.away_shots_on_target  END AS fav_sot,
        CASE p.fav WHEN 'HOME' THEN fs.away_shots_on_target  ELSE fs.home_shots_on_target  END AS opp_sot,
        CASE p.fav WHEN 'HOME' THEN fs.home_shots_off_target ELSE fs.away_shots_off_target END AS fav_soft,
        CASE p.fav WHEN 'HOME' THEN fs.away_shots_off_target ELSE fs.home_shots_off_target END AS opp_soft,
        CASE p.fav WHEN 'HOME' THEN fs.home_corners          ELSE fs.away_corners          END AS fav_corners,
        CASE p.fav WHEN 'HOME' THEN fs.away_corners          ELSE fs.home_corners          END AS opp_corners,
        CASE p.fav WHEN 'HOME' THEN fs.home_red_cards        ELSE fs.away_red_cards        END AS fav_reds,
        CASE p.fav WHEN 'HOME' THEN fs.away_red_cards        ELSE fs.home_red_cards        END AS opp_reds,
        CASE p.fav
            WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
        END                                        AS dc_won,
        CASE p.fav
            WHEN 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
        END                                        AS outright_won
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m            ON m.id = o.match_id
    JOIN football_live_stats fs ON fs.odds_snapshot_id = o.id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport = 'FOOTBALL'
      AND m.final_home_score IS NOT NULL
      AND p.fav_odds <= 1.55
      AND o.match_minute BETWEEN 1 AND 80
      AND ((p.fav = 'HOME' AND o.away_score - o.home_score = 1)
        OR (p.fav = 'AWAY' AND o.home_score - o.away_score = 1))
      AND CASE p.fav
              WHEN 'HOME' THEN (o.home_win_odds - p.fav_odds) / p.fav_odds * 100
              WHEN 'AWAY' THEN (o.away_win_odds - p.fav_odds) / p.fav_odds * 100
          END >= 30
    ORDER BY o.match_id, o.captured_at
),
banded AS (
    -- A) Favorite possession band
    SELECT 'A_possession' AS hypothesis,
           CASE
               WHEN fav_poss IS NULL  THEN 'no data'
               WHEN fav_poss < 45     THEN '<45%'
               WHEN fav_poss < 55     THEN '45-54%'
               WHEN fav_poss < 65     THEN '55-64%'
               ELSE                        '>=65%'
           END AS band,
           dc_won, outright_won
    FROM trigger_moments

    UNION ALL
    -- B) Shots-on-target ratio (favorite SOT / opponent SOT, opp 0 -> 'fav+only')
    SELECT 'B_sot_ratio',
           CASE
               WHEN fav_sot IS NULL OR opp_sot IS NULL THEN 'no data'
               WHEN opp_sot = 0 AND fav_sot = 0        THEN '0-0'
               WHEN opp_sot = 0                        THEN 'fav-only'
               WHEN fav_sot::numeric / opp_sot < 0.5   THEN '<0.5x'
               WHEN fav_sot::numeric / opp_sot < 1.0   THEN '0.5-1x'
               WHEN fav_sot::numeric / opp_sot < 1.5   THEN '1-1.5x'
               WHEN fav_sot::numeric / opp_sot < 2.0   THEN '1.5-2x'
               ELSE                                         '>=2x'
           END,
           dc_won, outright_won
    FROM trigger_moments

    UNION ALL
    -- C) Red card differential (opp_reds - fav_reds): positive = favorite has man advantage
    SELECT 'C_red_diff',
           CASE
               WHEN fav_reds IS NULL OR opp_reds IS NULL THEN 'no data'
               WHEN (opp_reds - fav_reds) <= -1          THEN 'fav -1 (dis)'
               WHEN (opp_reds - fav_reds) =  0           THEN 'equal'
               WHEN (opp_reds - fav_reds) =  1           THEN 'fav +1 (adv)'
               ELSE                                            'fav +2+ (big adv)'
           END,
           dc_won, outright_won
    FROM trigger_moments

    UNION ALL
    -- D) Corner differential (fav_corners - opp_corners)
    SELECT 'D_corner_diff',
           CASE
               WHEN fav_corners IS NULL OR opp_corners IS NULL THEN 'no data'
               WHEN (fav_corners - opp_corners) <= -3          THEN '<=-3'
               WHEN (fav_corners - opp_corners) BETWEEN -2 AND -1 THEN '-2 to -1'
               WHEN (fav_corners - opp_corners) BETWEEN  0 AND  1 THEN ' 0 to +1'
               WHEN (fav_corners - opp_corners) BETWEEN  2 AND  3 THEN '+2 to +3'
               ELSE                                                    '>=+4'
           END,
           dc_won, outright_won
    FROM trigger_moments

    UNION ALL
    -- E) Total SOT volume (fav_sot + opp_sot) — proxy for game tempo
    SELECT 'E_tempo_total_sot',
           CASE
               WHEN fav_sot IS NULL OR opp_sot IS NULL THEN 'no data'
               WHEN (fav_sot + opp_sot) <= 2           THEN ' 0-2'
               WHEN (fav_sot + opp_sot) <= 5           THEN ' 3-5'
               WHEN (fav_sot + opp_sot) <= 9           THEN ' 6-9'
               ELSE                                         '10+'
           END,
           dc_won, outright_won
    FROM trigger_moments
)
SELECT
    hypothesis,
    band,
    COUNT(*)                                    AS moments,
    COUNT(*) FILTER (WHERE dc_won)              AS dc_wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE dc_won)
          / NULLIF(COUNT(*), 0), 1)             AS dc_pct,
    COUNT(*) FILTER (WHERE outright_won)        AS outright_wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE outright_won)
          / NULLIF(COUNT(*), 0), 1)             AS outright_pct,
    CASE WHEN COUNT(*) < 30 THEN 'small'
         WHEN COUNT(*) < 60 THEN 'medium'
         ELSE                    'ok'
    END                                         AS sample_quality
FROM banded
GROUP BY hypothesis, band
ORDER BY hypothesis, band;


-- ============================================================
-- SECTION 17 — BASKETBALL: STAT-CONDITIONED COMEBACK RATE
-- For every Q2/Q3/Q4 trailing moment of a pre-match favorite
-- (baseline <= 1.45, deficit 1..10, rise >= 30%) with stats attached,
-- slice outright-win rate by live-stat patterns.
--
-- Hypotheses tested:
--   A — Favorite 3PT% gap vs opponent (regression to mean argument)
--   B — Favorite FG% gap vs opponent
--   C — Turnover differential (fav_to - opp_to)
--   D — Did the favorite already have a 5+ pt lead earlier? (biggest_lead)
--   E — Time-spent-in-lead differential (favorite was clearly in control earlier)
--
-- DATA NOTE (2026-05-10): basketball_live_stats started 2026-05-09;
-- expect small samples until data accumulates.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS fav_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
trigger_moments AS (
    SELECT DISTINCT ON (o.match_id, o.period_id)
        m.id AS match_id,
        o.period_id,
        p.fav,
        p.fav_odds,
        m.final_home_score, m.final_away_score,
        -- Favorite-relative scoring percentages
        CASE p.fav
            WHEN 'HOME' THEN bs.home_three_pointers_made::numeric
                              / NULLIF(bs.home_three_pointers_attempted, 0) * 100
            ELSE             bs.away_three_pointers_made::numeric
                              / NULLIF(bs.away_three_pointers_attempted, 0) * 100
        END AS fav_3pct,
        CASE p.fav
            WHEN 'HOME' THEN bs.away_three_pointers_made::numeric
                              / NULLIF(bs.away_three_pointers_attempted, 0) * 100
            ELSE             bs.home_three_pointers_made::numeric
                              / NULLIF(bs.home_three_pointers_attempted, 0) * 100
        END AS opp_3pct,
        CASE p.fav
            WHEN 'HOME' THEN bs.home_field_goals_made::numeric
                              / NULLIF(bs.home_field_goals_attempted, 0) * 100
            ELSE             bs.away_field_goals_made::numeric
                              / NULLIF(bs.away_field_goals_attempted, 0) * 100
        END AS fav_fgpct,
        CASE p.fav
            WHEN 'HOME' THEN bs.away_field_goals_made::numeric
                              / NULLIF(bs.away_field_goals_attempted, 0) * 100
            ELSE             bs.home_field_goals_made::numeric
                              / NULLIF(bs.home_field_goals_attempted, 0) * 100
        END AS opp_fgpct,
        CASE p.fav WHEN 'HOME' THEN bs.home_turnovers       ELSE bs.away_turnovers       END AS fav_to,
        CASE p.fav WHEN 'HOME' THEN bs.away_turnovers       ELSE bs.home_turnovers       END AS opp_to,
        CASE p.fav WHEN 'HOME' THEN bs.home_biggest_lead    ELSE bs.away_biggest_lead    END AS fav_big_lead,
        CASE p.fav WHEN 'HOME' THEN bs.home_time_spent_in_lead_sec
                                          ELSE bs.away_time_spent_in_lead_sec    END AS fav_lead_sec,
        CASE p.fav WHEN 'HOME' THEN bs.away_time_spent_in_lead_sec
                                          ELSE bs.home_time_spent_in_lead_sec    END AS opp_lead_sec,
        CASE p.fav
            WHEN 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
        END                                                                              AS outright_won
    FROM odds_snapshots o
    JOIN pre_match_favs       p  ON p.match_id = o.match_id
    JOIN matches              m  ON m.id       = o.match_id
    JOIN basketball_live_stats bs ON bs.odds_snapshot_id = o.id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND m.sport  = 'BASKETBALL'
      AND m.final_home_score IS NOT NULL
      AND p.fav_odds <= 1.45
      AND o.period_id IN ('QUARTER2', 'QUARTER3', 'QUARTER4')
      AND ((p.fav = 'HOME' AND o.away_score - o.home_score BETWEEN 1 AND 10)
        OR (p.fav = 'AWAY' AND o.home_score - o.away_score BETWEEN 1 AND 10))
      AND CASE p.fav
              WHEN 'HOME' THEN (o.home_win_odds - p.fav_odds) / p.fav_odds * 100
              WHEN 'AWAY' THEN (o.away_win_odds - p.fav_odds) / p.fav_odds * 100
          END >= 30
    ORDER BY o.match_id, o.period_id, o.captured_at
),
banded AS (
    -- A) Favorite 3PT% gap (fav - opp). Negative = fav cold (regression argument)
    SELECT 'A_3pt_gap' AS hypothesis,
           CASE
               WHEN fav_3pct IS NULL OR opp_3pct IS NULL THEN 'no data'
               WHEN (fav_3pct - opp_3pct) <= -15         THEN 'fav <<< opp (-15+)'
               WHEN (fav_3pct - opp_3pct) <  -5          THEN 'fav < opp (-5..-15)'
               WHEN (fav_3pct - opp_3pct) <=  5          THEN 'even (-5..+5)'
               ELSE                                           'fav > opp (+5+)'
           END AS band,
           outright_won
    FROM trigger_moments

    UNION ALL
    -- B) Favorite FG% gap (fav - opp)
    SELECT 'B_fg_gap',
           CASE
               WHEN fav_fgpct IS NULL OR opp_fgpct IS NULL THEN 'no data'
               WHEN (fav_fgpct - opp_fgpct) <= -10        THEN 'fav <<< opp'
               WHEN (fav_fgpct - opp_fgpct) <    0        THEN 'fav < opp'
               WHEN (fav_fgpct - opp_fgpct) <=   5        THEN 'roughly even'
               ELSE                                            'fav > opp'
           END,
           outright_won
    FROM trigger_moments

    UNION ALL
    -- C) Turnover differential (fav_to - opp_to). Negative = favorite has fewer TOs.
    SELECT 'C_to_diff',
           CASE
               WHEN fav_to IS NULL OR opp_to IS NULL THEN 'no data'
               WHEN (fav_to - opp_to) <= -3          THEN 'fav -3+ (clean)'
               WHEN (fav_to - opp_to) BETWEEN -2 AND -1 THEN 'fav -1/-2'
               WHEN (fav_to - opp_to) =  0           THEN 'equal'
               WHEN (fav_to - opp_to) BETWEEN 1 AND 2 THEN 'fav +1/+2'
               ELSE                                       'fav +3+ (sloppy)'
           END,
           outright_won
    FROM trigger_moments

    UNION ALL
    -- D) Favorite's biggest lead so far. >0 = was leading earlier (regression argument)
    SELECT 'D_fav_biggest_lead',
           CASE
               WHEN fav_big_lead IS NULL THEN 'no data'
               WHEN fav_big_lead <= 0    THEN 'never led'
               WHEN fav_big_lead <  5    THEN ' 1-4 led'
               WHEN fav_big_lead <  10   THEN ' 5-9 led'
               ELSE                            '10+ led'
           END,
           outright_won
    FROM trigger_moments

    UNION ALL
    -- E) Time-spent-in-lead differential (fav_sec - opp_sec)
    SELECT 'E_lead_time_diff',
           CASE
               WHEN fav_lead_sec IS NULL OR opp_lead_sec IS NULL THEN 'no data'
               WHEN (fav_lead_sec - opp_lead_sec) <= -300        THEN 'opp +5min'
               WHEN (fav_lead_sec - opp_lead_sec) <    0         THEN 'opp slight'
               WHEN (fav_lead_sec - opp_lead_sec) <=  300        THEN 'roughly even'
               ELSE                                                   'fav +5min'
           END,
           outright_won
    FROM trigger_moments
)
SELECT
    hypothesis,
    band,
    COUNT(*)                                       AS moments,
    COUNT(*) FILTER (WHERE outright_won)           AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE outright_won)
          / NULLIF(COUNT(*), 0), 1)                AS outright_pct,
    CASE WHEN COUNT(*) < 30 THEN 'small'
         WHEN COUNT(*) < 60 THEN 'medium'
         ELSE                    'ok'
    END                                            AS sample_quality
FROM banded
GROUP BY hypothesis, band
ORDER BY hypothesis, band;


-- ============================================================
-- SECTION 18 — COUNTERFACTUAL P&L GRID  [both sports]
-- "If we had set baseline_ceiling=X and rise_threshold=Y, what
-- total simulated P&L would we have generated across ALL finished
-- matches?" — answers whether the current filters are too tight
-- (leaving money on the table) or too loose.
--
-- Differs from §13A (placed-bets-only sim): this scans every
-- finished match's snapshot stream, finds the FIRST moment that
-- satisfies the cell's filters, and treats it as a simulated bet.
--
-- Market choice mirrors OddsMonitorService:
--   football: cur_odds < 1.50 → outright @ cur_odds
--             1.50 ≤ cur_odds < 3.00 → DC @ dc_odds (excluded if null)
--             cur_odds ≥ 3.00 → outright @ cur_odds
--   basketball: always outright @ cur_odds (PRORROGA_INCLUIDA)
-- ============================================================

-- 18A — Football counterfactual
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END                                                  AS fav,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) AS baseline
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
losing_moments AS (
    SELECT
        o.match_id, o.captured_at,
        p.fav, p.baseline,
        CASE p.fav WHEN 'HOME' THEN o.home_win_odds  ELSE o.away_win_odds  END AS cur_odds,
        CASE p.fav WHEN 'HOME' THEN o.home_draw_odds ELSE o.away_draw_odds END AS dc_odds,
        CASE p.fav
            WHEN 'HOME' THEN (o.home_win_odds - p.baseline) / p.baseline * 100
            WHEN 'AWAY' THEN (o.away_win_odds - p.baseline) / p.baseline * 100
        END AS rise_pct,
        m.final_home_score, m.final_away_score
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m         ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED' AND m.sport = 'FOOTBALL'
      AND m.final_home_score IS NOT NULL
      AND o.match_minute BETWEEN 1 AND 80
      AND ((p.fav = 'HOME' AND o.away_score - o.home_score = 1)
        OR (p.fav = 'AWAY' AND o.home_score - o.away_score = 1))
      AND p.fav IN ('HOME', 'AWAY')
),
grid AS (
    SELECT b.ceiling, r.threshold
    FROM      (SELECT unnest(ARRAY[1.30, 1.40, 1.55, 1.70, 1.90]) AS ceiling)   b
    CROSS JOIN (SELECT unnest(ARRAY[20, 30, 40, 60, 80, 100])     AS threshold) r
),
first_trigger AS (
    SELECT DISTINCT ON (lm.match_id, g.ceiling, g.threshold)
        lm.match_id, g.ceiling, g.threshold,
        lm.fav, lm.baseline, lm.cur_odds, lm.dc_odds,
        lm.final_home_score, lm.final_away_score,
        CASE
            WHEN lm.cur_odds < 1.50 OR lm.cur_odds >= 3.00 THEN 'OUTRIGHT'
            ELSE 'DC'
        END AS market
    FROM losing_moments lm
    JOIN grid g ON lm.baseline <= g.ceiling AND lm.rise_pct >= g.threshold
    WHERE lm.cur_odds <= 3.50      -- safety cap; mirrors strategy with slack
    ORDER BY lm.match_id, g.ceiling, g.threshold, lm.captured_at
),
scored AS (
    SELECT
        ceiling, threshold, market,
        CASE WHEN market = 'DC' THEN dc_odds ELSE cur_odds END AS bet_odds,
        CASE
            WHEN market = 'DC' THEN
                CASE fav WHEN 'HOME' THEN final_home_score >= final_away_score
                         WHEN 'AWAY' THEN final_away_score >= final_home_score END
            ELSE
                CASE fav WHEN 'HOME' THEN final_home_score >  final_away_score
                         WHEN 'AWAY' THEN final_away_score >  final_home_score END
        END AS bet_won
    FROM first_trigger
    WHERE (market = 'OUTRIGHT') OR (market = 'DC' AND dc_odds IS NOT NULL)
)
SELECT
    ceiling                                              AS max_baseline_odds,
    threshold                                            AS rise_threshold_pct,
    COUNT(*)                                             AS sim_bets,
    COUNT(*) FILTER (WHERE market = 'DC')                AS dc_bets,
    COUNT(*) FILTER (WHERE market = 'OUTRIGHT')          AS outright_bets,
    COUNT(*) FILTER (WHERE bet_won)                      AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE bet_won)
          / NULLIF(COUNT(*), 0), 1)                      AS win_pct,
    ROUND(AVG(bet_odds)::numeric, 2)                     AS avg_bet_odds,
    ROUND(SUM(CASE bet_won WHEN TRUE THEN bet_odds - 1 ELSE -1 END)::numeric, 2) AS net_units,
    ROUND(SUM(CASE bet_won WHEN TRUE THEN bet_odds - 1 ELSE -1 END)::numeric * 1000) AS net_cop
FROM scored
GROUP BY ceiling, threshold
ORDER BY ceiling, threshold;


-- 18B — Basketball counterfactual
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS baseline
    FROM odds_snapshots o JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
trailing_moments AS (
    SELECT
        o.match_id, o.captured_at, o.period_id,
        p.fav, p.baseline,
        CASE p.fav WHEN 'HOME' THEN o.home_win_odds ELSE o.away_win_odds END AS cur_odds,
        CASE p.fav
            WHEN 'HOME' THEN (o.home_win_odds - p.baseline) / p.baseline * 100
            WHEN 'AWAY' THEN (o.away_win_odds - p.baseline) / p.baseline * 100
        END AS rise_pct,
        ABS(o.home_score - o.away_score) AS deficit,
        m.final_home_score, m.final_away_score
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m         ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED' AND m.sport = 'BASKETBALL'
      AND m.final_home_score IS NOT NULL
      AND o.period_id IN ('QUARTER2', 'QUARTER3', 'QUARTER4')
      AND ((p.fav = 'HOME' AND o.away_score > o.home_score)
        OR (p.fav = 'AWAY' AND o.home_score > o.away_score))
),
grid AS (
    SELECT b.ceiling, r.threshold, d.deficit_cap
    FROM      (SELECT unnest(ARRAY[1.30, 1.40, 1.45, 1.55])  AS ceiling)     b
    CROSS JOIN (SELECT unnest(ARRAY[20, 30, 40, 60])         AS threshold)   r
    CROSS JOIN (SELECT unnest(ARRAY[3, 6, 10])               AS deficit_cap) d
),
first_trigger AS (
    SELECT DISTINCT ON (tm.match_id, g.ceiling, g.threshold, g.deficit_cap)
        tm.match_id, g.ceiling, g.threshold, g.deficit_cap,
        tm.fav, tm.baseline, tm.cur_odds,
        tm.final_home_score, tm.final_away_score
    FROM trailing_moments tm
    JOIN grid g ON tm.baseline <= g.ceiling
              AND tm.rise_pct  >= g.threshold
              AND tm.deficit BETWEEN 1 AND g.deficit_cap
    WHERE tm.cur_odds <= 3.00
    ORDER BY tm.match_id, g.ceiling, g.threshold, g.deficit_cap, tm.captured_at
)
SELECT
    ceiling                                              AS max_baseline_odds,
    threshold                                            AS rise_threshold_pct,
    deficit_cap                                          AS max_point_deficit,
    COUNT(*)                                             AS sim_bets,
    COUNT(*) FILTER (WHERE
        CASE fav WHEN 'HOME' THEN final_home_score > final_away_score
                 WHEN 'AWAY' THEN final_away_score > final_home_score END) AS wins,
    ROUND(100.0 * COUNT(*) FILTER (WHERE
        CASE fav WHEN 'HOME' THEN final_home_score > final_away_score
                 WHEN 'AWAY' THEN final_away_score > final_home_score END)
          / NULLIF(COUNT(*), 0), 1)                      AS win_pct,
    ROUND(AVG(cur_odds)::numeric, 2)                     AS avg_bet_odds,
    ROUND(SUM(CASE WHEN
        CASE fav WHEN 'HOME' THEN final_home_score > final_away_score
                 WHEN 'AWAY' THEN final_away_score > final_home_score END
        THEN cur_odds - 1 ELSE -1 END)::numeric, 2)      AS net_units
FROM first_trigger
GROUP BY ceiling, threshold, deficit_cap
ORDER BY ceiling, threshold, deficit_cap;


-- ============================================================
-- SECTION 19 — MISS-CAUSE DECOMPOSITION
-- For every finished match where no alert fired, classify the
-- SINGLE dominant reason — the first condition that failed in
-- the strategy's filter order.
-- ============================================================

-- 19A — Football miss causes
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.home_win_odds THEN 'HOME'
            WHEN LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) = o.away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END                                                  AS fav,
        LEAST(o.home_win_odds, o.draw_odds, o.away_win_odds) AS baseline
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'FOOTBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
match_stats AS (
    SELECT
        m.id AS match_id, m.final_home_score, m.final_away_score,
        p.fav, p.baseline,
        EXISTS (SELECT 1 FROM betting_alerts a
                WHERE a.match_id = m.id
                  AND a.trigger_scenario IN ('LOSING_BY_1','TIED_HALFTIME'))     AS alert_fired,
        (SELECT MAX(CASE p.fav
                       WHEN 'HOME' THEN (o.home_win_odds - p.baseline)/p.baseline*100
                       WHEN 'AWAY' THEN (o.away_win_odds - p.baseline)/p.baseline*100
                    END)
         FROM odds_snapshots o
         WHERE o.match_id = m.id AND o.is_pre_match = FALSE
           AND o.match_minute BETWEEN 1 AND 80
           AND ((p.fav = 'HOME' AND o.away_score - o.home_score = 1)
             OR (p.fav = 'AWAY' AND o.home_score - o.away_score = 1))
        )                                                                       AS max_rise_pct,
        (SELECT MIN(CASE p.fav WHEN 'HOME' THEN o.home_win_odds ELSE o.away_win_odds END)
         FROM odds_snapshots o
         WHERE o.match_id = m.id AND o.is_pre_match = FALSE
           AND o.match_minute BETWEEN 1 AND 80
           AND ((p.fav = 'HOME' AND o.away_score - o.home_score = 1)
             OR (p.fav = 'AWAY' AND o.home_score - o.away_score = 1))
        )                                                                       AS min_cur_odds_in_trailing,
        CASE p.fav
            WHEN 'HOME' THEN m.final_home_score >= m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score >= m.final_home_score
            ELSE NULL
        END                                                                     AS was_comeback
    FROM matches m
    LEFT JOIN pre_match_favs p ON p.match_id = m.id
    WHERE m.status = 'FINISHED' AND m.sport = 'FOOTBALL'
      AND m.final_home_score IS NOT NULL
),
classified AS (
    SELECT *,
        CASE
            WHEN alert_fired                                   THEN '0_alert_fired'
            WHEN baseline IS NULL                              THEN '1_no_pre_match_baseline'
            WHEN max_rise_pct IS NULL                          THEN '2_never_trailed_by_1'
            WHEN baseline > 1.55                               THEN '3_baseline_too_high'
            WHEN max_rise_pct < 30                             THEN '4_never_crossed_rise'
            WHEN min_cur_odds_in_trailing > 3.00               THEN '5_current_always_too_high'
            ELSE                                                    '6_uncovered_BUG_SIGNAL'
        END AS miss_cause
    FROM match_stats
)
SELECT
    miss_cause,
    COUNT(*)                                             AS matches,
    COUNT(*) FILTER (WHERE was_comeback)                 AS dc_comebacks_in_bucket,
    ROUND(100.0 * COUNT(*) FILTER (WHERE was_comeback)
          / NULLIF(COUNT(*), 0), 1)                      AS dc_comeback_pct,
    -- crude P&L proxy at avg DC odds 1.30
    ROUND((COUNT(*) FILTER (WHERE was_comeback) * 0.30
           - COUNT(*) FILTER (WHERE NOT was_comeback))::numeric, 0)
                                                         AS approx_net_units_if_DC
FROM classified
GROUP BY miss_cause
ORDER BY miss_cause;


-- 19B — Basketball miss causes
WITH pre_match_favs AS (
    SELECT DISTINCT ON (o.match_id) o.match_id,
        CASE WHEN o.home_win_odds <= o.away_win_odds THEN 'HOME' ELSE 'AWAY' END AS fav,
        LEAST(o.home_win_odds, o.away_win_odds)                                  AS baseline
    FROM odds_snapshots o JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = TRUE AND m.sport = 'BASKETBALL'
    ORDER BY o.match_id, o.captured_at DESC
),
match_stats AS (
    SELECT
        m.id AS match_id, m.final_home_score, m.final_away_score,
        p.fav, p.baseline,
        EXISTS (SELECT 1 FROM betting_alerts a
                WHERE a.match_id = m.id AND a.trigger_scenario = 'BASKETBALL_COMEBACK') AS alert_fired,
        (SELECT MAX(CASE p.fav
                       WHEN 'HOME' THEN (o.home_win_odds - p.baseline)/p.baseline*100
                       WHEN 'AWAY' THEN (o.away_win_odds - p.baseline)/p.baseline*100
                    END)
         FROM odds_snapshots o
         WHERE o.match_id = m.id AND o.is_pre_match = FALSE
           AND o.period_id IN ('QUARTER2','QUARTER3','QUARTER4')
           AND ((p.fav = 'HOME' AND o.away_score > o.home_score)
             OR (p.fav = 'AWAY' AND o.home_score > o.away_score))
        ) AS max_rise_pct,
        (SELECT MIN(CASE p.fav WHEN 'HOME' THEN o.home_win_odds ELSE o.away_win_odds END)
         FROM odds_snapshots o
         WHERE o.match_id = m.id AND o.is_pre_match = FALSE
           AND o.period_id IN ('QUARTER2','QUARTER3','QUARTER4')
           AND ((p.fav = 'HOME' AND o.away_score > o.home_score)
             OR (p.fav = 'AWAY' AND o.home_score > o.away_score))
        ) AS min_cur_odds,
        (SELECT MIN(ABS(o.home_score - o.away_score))
         FROM odds_snapshots o
         WHERE o.match_id = m.id AND o.is_pre_match = FALSE
           AND o.period_id IN ('QUARTER2','QUARTER3','QUARTER4')
           AND ((p.fav = 'HOME' AND o.away_score > o.home_score)
             OR (p.fav = 'AWAY' AND o.home_score > o.away_score))
        ) AS min_deficit_in_trailing,
        CASE p.fav
            WHEN 'HOME' THEN m.final_home_score > m.final_away_score
            WHEN 'AWAY' THEN m.final_away_score > m.final_home_score
        END AS was_outright_comeback
    FROM matches m
    LEFT JOIN pre_match_favs p ON p.match_id = m.id
    WHERE m.status = 'FINISHED' AND m.sport = 'BASKETBALL'
      AND m.final_home_score IS NOT NULL
),
classified AS (
    SELECT *,
        CASE
            WHEN alert_fired                          THEN '0_alert_fired'
            WHEN baseline IS NULL                     THEN '1_no_pre_match_baseline'
            WHEN max_rise_pct IS NULL                 THEN '2_never_trailed_in_Q234'
            WHEN baseline > 1.45                      THEN '3_baseline_too_high'
            WHEN min_deficit_in_trailing > 6          THEN '4_deficit_too_large_throughout'
            WHEN max_rise_pct < 30                    THEN '5_never_crossed_rise'
            WHEN min_cur_odds > 3.00                  THEN '6_current_always_too_high'
            ELSE                                           '7_uncovered_BUG_SIGNAL'
        END AS miss_cause
    FROM match_stats
)
SELECT
    miss_cause,
    COUNT(*)                                             AS matches,
    COUNT(*) FILTER (WHERE was_outright_comeback)        AS comebacks_in_bucket,
    ROUND(100.0 * COUNT(*) FILTER (WHERE was_outright_comeback)
          / NULLIF(COUNT(*), 0), 1)                      AS comeback_pct
FROM classified
GROUP BY miss_cause
ORDER BY miss_cause;


-- ============================================================
-- SECTION 20 — MONITORING COVERAGE AUDIT  [both sports]
-- Surfaces system blind spots distinct from strategy issues.
-- ============================================================

-- 20A — Live snapshots per finished match (distribution)
WITH per_match AS (
    SELECT m.id, m.sport,
           COUNT(o.id) FILTER (WHERE o.is_pre_match = FALSE) AS live_snaps
    FROM matches m
    LEFT JOIN odds_snapshots o ON o.match_id = m.id
    WHERE m.status = 'FINISHED'
    GROUP BY m.id, m.sport
)
SELECT
    sport,
    CASE
        WHEN live_snaps = 0       THEN '00 (no live data)'
        WHEN live_snaps <  5      THEN '01-04'
        WHEN live_snaps < 10      THEN '05-09'
        WHEN live_snaps < 20      THEN '10-19'
        WHEN live_snaps < 40      THEN '20-39'
        WHEN live_snaps < 80      THEN '40-79'
        ELSE                           '80+'
    END                                                  AS snapshots_band,
    COUNT(*)                                             AS matches,
    ROUND(100.0 * COUNT(*)
          / SUM(COUNT(*)) OVER (PARTITION BY sport), 1) AS pct_within_sport
FROM per_match
GROUP BY sport, snapshots_band
ORDER BY sport, snapshots_band;

-- 20B — Pre-match coverage per sport
SELECT
    m.sport,
    COUNT(*)                                                                     AS finished_matches,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM odds_snapshots o
        WHERE o.match_id = m.id AND o.is_pre_match = TRUE))                      AS with_pre_match,
    ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM odds_snapshots o
        WHERE o.match_id = m.id AND o.is_pre_match = TRUE))
          / NULLIF(COUNT(*), 0), 1)                                              AS pre_match_coverage_pct
FROM matches m
WHERE m.status = 'FINISHED'
GROUP BY m.sport;

-- 20C — Live snapshot rate by hour-of-day Bogota (last 14 days)
SELECT
    EXTRACT(HOUR FROM o.captured_at AT TIME ZONE 'America/Bogota')::INT AS hour_co,
    COUNT(*)                                                            AS snapshots,
    COUNT(DISTINCT o.match_id)                                          AS unique_live_matches
FROM odds_snapshots o
WHERE o.is_pre_match = FALSE
  AND o.captured_at > NOW() - INTERVAL '14 days'
GROUP BY hour_co
ORDER BY hour_co;

-- 20D — Day-level outage detection (last 14 days)
WITH days AS (
    SELECT generate_series(
        (CURRENT_DATE - INTERVAL '14 days')::date,
        CURRENT_DATE,
        '1 day'::interval
    )::date AS day
),
snaps_per_day AS (
    SELECT (o.captured_at AT TIME ZONE 'America/Bogota')::date AS day,
           COUNT(*) AS snapshots
    FROM odds_snapshots o
    WHERE o.is_pre_match = FALSE
      AND o.captured_at > NOW() - INTERVAL '15 days'
    GROUP BY day
)
SELECT d.day, COALESCE(s.snapshots, 0) AS snapshots,
       CASE WHEN COALESCE(s.snapshots, 0) < 100 THEN '*** SUSPECT OUTAGE ***' ELSE '' END AS flag
FROM days d
LEFT JOIN snaps_per_day s ON s.day = d.day
ORDER BY d.day;
