-- ============================================================
-- SportBets — Data Quality Checks
--
-- PURPOSE: Diagnose data coverage gaps and quality issues that
-- could impact betting strategy effectiveness.
--
-- KEY PROBLEMS THIS SOLVES:
--   1. DC odds are missing in 82-88% of losing-by-1 moments
--   2. Pre-match baselines sometimes missing due to restart timing
--   3. Unknown if snapshot frequency is sufficient for all matches
--   4. Need to identify which competitions have worst coverage
--
-- RUN: Execute each section independently to diagnose specific issues
-- ============================================================


-- ============================================================
-- CHECK 1 — DC ODDS COVERAGE BY MATCH STATE
-- Diagnoses: When are DC odds missing? Is it consistent or state-dependent?
-- ============================================================
WITH match_states AS (
    SELECT
        o.match_id,
        o.id AS snapshot_id,
        o.match_minute,
        o.home_score,
        o.away_score,
        ABS(o.home_score - o.away_score) AS score_diff,
        CASE
            WHEN o.home_score = o.away_score THEN 'TIED'
            WHEN ABS(o.home_score - o.away_score) = 1 THEN 'LOSING_BY_1'
            WHEN ABS(o.home_score - o.away_score) = 2 THEN 'LOSING_BY_2'
            ELSE 'OTHER'
        END AS match_state,
        CASE
            WHEN o.home_draw_outcome_id IS NOT NULL AND o.home_draw_odds IS NOT NULL THEN TRUE
            ELSE FALSE
        END AS has_dc_data,
        o.home_draw_odds,
        o.away_draw_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.sport = 'FOOTBALL'
      AND m.status = 'FINISHED'
)
SELECT
    match_state,
    COUNT(*) AS total_snapshots,
    COUNT(*) FILTER (WHERE has_dc_data) AS snapshots_with_dc,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_dc_data) / COUNT(*), 1) AS dc_coverage_pct,
    ROUND(AVG(home_draw_odds)::numeric, 2) AS avg_home_dc_odds,
    ROUND(AVG(away_draw_odds)::numeric, 2) AS avg_away_dc_odds,
    COUNT(DISTINCT match_id) AS unique_matches
FROM match_states
GROUP BY match_state
ORDER BY
    CASE match_state
        WHEN 'LOSING_BY_1' THEN 1
        WHEN 'TIED' THEN 2
        WHEN 'LOSING_BY_2' THEN 3
        ELSE 4
    END;

-- Expected finding: If DC coverage is uniformly low (~15%), it's a systematic API issue.
-- If coverage varies by state, it means DC market availability depends on match situation.


-- ============================================================
-- CHECK 2 — DC COVERAGE BY COMPETITION
-- Diagnoses: Are certain leagues missing DC odds entirely?
-- ============================================================
SELECT
    m.competition,
    COUNT(DISTINCT m.id) AS matches,
    COUNT(DISTINCT o.match_id) AS matches_with_live_snapshots,
    COUNT(*) AS total_live_snapshots,
    COUNT(*) FILTER (WHERE o.home_draw_outcome_id IS NOT NULL) AS snapshots_with_dc_id,
    COUNT(*) FILTER (WHERE o.home_draw_odds IS NOT NULL) AS snapshots_with_dc_odds,
    ROUND(100.0 * COUNT(*) FILTER (WHERE o.home_draw_odds IS NOT NULL)
          / NULLIF(COUNT(*), 0), 1) AS dc_coverage_pct,
    ROUND(AVG(o.home_draw_odds)::numeric, 2) AS avg_home_dc_when_present
FROM matches m
LEFT JOIN odds_snapshots o ON o.match_id = m.id AND o.is_pre_match = FALSE
WHERE m.sport = 'FOOTBALL'
  AND m.status = 'FINISHED'
GROUP BY m.competition
HAVING COUNT(*) >= 10  -- Only competitions with meaningful sample size
ORDER BY dc_coverage_pct DESC, matches DESC;

-- Action: If coverage is <5% for a competition, consider excluding it from betting scope.
-- If coverage is high (>80%) for some leagues, prioritize those.


-- ============================================================
-- CHECK 3 — MISSING PRE-MATCH BASELINES
-- Diagnoses: How many matches lack a true pre-match snapshot?
-- ============================================================
WITH baseline_check AS (
    SELECT
        m.id AS match_id,
        m.home_team,
        m.away_team,
        m.competition,
        m.start_time,
        COUNT(*) FILTER (WHERE o.is_pre_match = TRUE) AS pre_match_count,
        COUNT(*) FILTER (WHERE o.is_pre_match = FALSE) AS live_count,
        MIN(o.captured_at) FILTER (WHERE o.is_pre_match = FALSE) AS first_live_snapshot,
        (SELECT o2.home_win_odds
         FROM odds_snapshots o2
         WHERE o2.match_id = m.id AND o2.is_pre_match = TRUE
         ORDER BY o2.captured_at DESC
         LIMIT 1) AS baseline_home_odds
    FROM matches m
    LEFT JOIN odds_snapshots o ON o.match_id = m.id
    WHERE m.sport = 'FOOTBALL'
      AND m.status = 'FINISHED'
    GROUP BY m.id, m.home_team, m.away_team, m.competition, m.start_time
)
SELECT
    COUNT(*) AS total_finished_matches,
    COUNT(*) FILTER (WHERE pre_match_count = 0) AS matches_without_baseline,
    ROUND(100.0 * COUNT(*) FILTER (WHERE pre_match_count = 0) / COUNT(*), 1) AS missing_baseline_pct,
    COUNT(*) FILTER (WHERE pre_match_count > 1) AS matches_with_multiple_baselines,
    COUNT(*) FILTER (WHERE live_count = 0) AS matches_with_no_live_data,
    ROUND(AVG(live_count)::numeric, 0) AS avg_live_snapshots_per_match
FROM baseline_check;

-- Show specific matches without baseline (for investigation)
SELECT
    match_id,
    home_team || ' vs ' || away_team AS match,
    competition,
    start_time,
    first_live_snapshot,
    EXTRACT(EPOCH FROM (first_live_snapshot - start_time))/60 AS minutes_after_kickoff
FROM baseline_check
WHERE pre_match_count = 0
ORDER BY start_time DESC
LIMIT 20;

-- Action: If >10% are missing baseline, improve pre-match snapshot capture timing.


-- ============================================================
-- CHECK 4 — SNAPSHOT FREQUENCY GAPS
-- Diagnoses: Are there long gaps between snapshots during live play?
-- ============================================================
WITH snapshot_intervals AS (
    SELECT
        o.match_id,
        o.captured_at,
        o.match_minute,
        LAG(o.captured_at) OVER (PARTITION BY o.match_id ORDER BY o.captured_at) AS prev_captured_at,
        EXTRACT(EPOCH FROM (o.captured_at - LAG(o.captured_at) OVER (PARTITION BY o.match_id ORDER BY o.captured_at))) AS seconds_since_prev
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.sport = 'FOOTBALL'
      AND m.status = 'FINISHED'
)
SELECT
    COUNT(*) AS total_intervals,
    ROUND(AVG(seconds_since_prev)::numeric, 0) AS avg_interval_sec,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY seconds_since_prev)::numeric, 0) AS median_interval_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY seconds_since_prev)::numeric, 0) AS p95_interval_sec,
    MAX(seconds_since_prev) AS max_gap_sec,
    COUNT(*) FILTER (WHERE seconds_since_prev > 120) AS gaps_over_2min,
    COUNT(*) FILTER (WHERE seconds_since_prev > 300) AS gaps_over_5min,
    ROUND(100.0 * COUNT(*) FILTER (WHERE seconds_since_prev > 120) / COUNT(*), 1) AS pct_gaps_over_2min
FROM snapshot_intervals
WHERE seconds_since_prev IS NOT NULL;

-- Show worst gaps (for debugging scheduler issues)
SELECT
    m.home_team || ' vs ' || m.away_team AS match,
    s.match_minute,
    s.prev_captured_at,
    s.captured_at,
    ROUND(s.seconds_since_prev / 60.0, 1) AS gap_minutes
FROM snapshot_intervals s
JOIN matches m ON m.id = s.match_id
WHERE s.seconds_since_prev > 180  -- Gaps over 3 minutes
ORDER BY s.seconds_since_prev DESC
LIMIT 20;

-- Expected: Median ~45s (configured polling). If P95 >120s, investigate scheduler delays.


-- ============================================================
-- CHECK 5 — DC OUTCOME ID vs ODDS MISMATCH
-- Diagnoses: Are there cases where we have outcome ID but no odds, or vice versa?
-- ============================================================
SELECT
    COUNT(*) AS total_live_snapshots,
    COUNT(*) FILTER (WHERE home_draw_outcome_id IS NOT NULL AND home_draw_odds IS NULL) AS has_id_no_odds,
    COUNT(*) FILTER (WHERE home_draw_outcome_id IS NULL AND home_draw_odds IS NOT NULL) AS has_odds_no_id,
    COUNT(*) FILTER (WHERE home_draw_outcome_id IS NOT NULL AND home_draw_odds IS NOT NULL) AS has_both,
    COUNT(*) FILTER (WHERE home_draw_outcome_id IS NULL AND home_draw_odds IS NULL) AS has_neither,
    ROUND(100.0 * COUNT(*) FILTER (WHERE home_draw_outcome_id IS NOT NULL AND home_draw_odds IS NULL)
          / NULLIF(COUNT(*), 0), 2) AS id_no_odds_pct
FROM odds_snapshots o
JOIN matches m ON m.id = o.match_id
WHERE o.is_pre_match = FALSE
  AND m.sport = 'FOOTBALL'
  AND m.status = 'FINISHED';

-- Action: If has_id_no_odds is high, the DC odds parsing logic may be broken.


-- ============================================================
-- CHECK 6 — ALERTS THAT SHOULD HAVE USED DC BUT DIDN'T
-- Diagnoses: How many LOSING_BY_1 alerts used RESULTADO_FINAL when DC was available?
-- ============================================================
WITH alert_market_check AS (
    SELECT
        a.id AS alert_id,
        m.home_team || ' vs ' || m.away_team AS match,
        a.trigger_scenario,
        a.current_odds,
        COALESCE(a.market, 'RESULTADO_FINAL') AS market_used,
        a.score_at_alert,
        -- Find the snapshot that triggered this alert
        (SELECT o.home_draw_odds
         FROM odds_snapshots o
         WHERE o.match_id = a.match_id
           AND ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at))) < 60
         ORDER BY ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at)))
         LIMIT 1) AS dc_odds_at_trigger,
        a.triggered_at
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.trigger_scenario = 'LOSING_BY_1'
      AND m.sport = 'FOOTBALL'
)
SELECT
    COUNT(*) AS total_losing_by_1_alerts,
    COUNT(*) FILTER (WHERE market_used = 'DOBLE_OPORTUNIDAD') AS used_dc,
    COUNT(*) FILTER (WHERE market_used = 'RESULTADO_FINAL') AS used_outright,
    COUNT(*) FILTER (WHERE market_used = 'RESULTADO_FINAL' AND dc_odds_at_trigger IS NOT NULL) AS outright_when_dc_available,
    COUNT(*) FILTER (WHERE market_used = 'RESULTADO_FINAL' AND dc_odds_at_trigger IS NULL) AS outright_when_dc_missing,
    ROUND(100.0 * COUNT(*) FILTER (WHERE dc_odds_at_trigger IS NULL) / COUNT(*), 1) AS dc_missing_at_alert_pct
FROM alert_market_check;

-- Show specific cases where DC was available but not used (config bug?)
SELECT
    match,
    score_at_alert,
    current_odds,
    dc_odds_at_trigger,
    market_used,
    triggered_at
FROM alert_market_check
WHERE market_used = 'RESULTADO_FINAL'
  AND dc_odds_at_trigger IS NOT NULL
  AND current_odds >= 2.0  -- Should have used DC per config
ORDER BY triggered_at DESC
LIMIT 10;


-- ============================================================
-- CHECK 7 — DC CACHE EFFECTIVENESS
-- Diagnoses: Are DC odds being fetched successfully when needed?
-- Note: This checks if DC odds appear in snapshots during LOSING_BY_1 states
-- ============================================================
WITH losing_moments AS (
    SELECT
        o.match_id,
        o.captured_at,
        o.match_minute,
        o.home_score,
        o.away_score,
        o.home_win_odds,
        o.away_win_odds,
        o.home_draw_odds,
        o.away_draw_odds,
        -- Get baseline to identify which side is favorite
        (SELECT CASE
            WHEN LEAST(s.home_win_odds, s.away_win_odds) = s.home_win_odds THEN 'HOME'
            ELSE 'AWAY'
         END
         FROM odds_snapshots s
         WHERE s.match_id = o.match_id AND s.is_pre_match = TRUE
         ORDER BY s.captured_at DESC LIMIT 1) AS favorite_side,
        (SELECT s.home_win_odds
         FROM odds_snapshots s
         WHERE s.match_id = o.match_id AND s.is_pre_match = TRUE
         ORDER BY s.captured_at DESC LIMIT 1) AS baseline_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.sport = 'FOOTBALL'
      AND m.status = 'FINISHED'
      AND ((o.home_score = o.away_score + 1) OR (o.away_score = o.home_score + 1))  -- Losing by 1
      AND o.match_minute BETWEEN 1 AND 80
)
SELECT
    COUNT(*) AS total_losing_by_1_snapshots,
    COUNT(DISTINCT match_id) AS unique_matches,
    COUNT(*) FILTER (WHERE home_draw_odds IS NOT NULL OR away_draw_odds IS NOT NULL) AS snapshots_with_dc,
    ROUND(100.0 * COUNT(*) FILTER (WHERE home_draw_odds IS NOT NULL OR away_draw_odds IS NOT NULL)
          / COUNT(*), 1) AS dc_available_pct,
    COUNT(*) FILTER (WHERE baseline_odds <= 1.60 AND (home_draw_odds IS NOT NULL OR away_draw_odds IS NOT NULL)) AS strong_fav_with_dc,
    COUNT(*) FILTER (WHERE baseline_odds <= 1.60) AS strong_fav_total,
    ROUND(100.0 * COUNT(*) FILTER (WHERE baseline_odds <= 1.60 AND (home_draw_odds IS NOT NULL OR away_draw_odds IS NOT NULL))
          / NULLIF(COUNT(*) FILTER (WHERE baseline_odds <= 1.60), 0), 1) AS strong_fav_dc_pct
FROM losing_moments;

-- Action: If strong_fav_dc_pct < 30%, the DC fetch/cache logic needs improvement.


-- ============================================================
-- CHECK 8 — FINAL SCORE CAPTURE COMPLETENESS
-- Diagnoses: How many finished matches never got final scores recorded?
-- ============================================================
SELECT
    COUNT(*) AS total_finished_matches,
    COUNT(*) FILTER (WHERE final_home_score IS NULL) AS missing_final_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE final_home_score IS NULL) / COUNT(*), 1) AS missing_score_pct,
    COUNT(*) FILTER (WHERE status = 'FINISHED' AND final_home_score IS NULL AND start_time < NOW() - INTERVAL '7 days') AS old_matches_missing_score
FROM matches
WHERE sport = 'FOOTBALL'
  AND status = 'FINISHED';

-- Show recent matches without final score
SELECT
    id,
    home_team || ' vs ' || away_team AS match,
    competition,
    start_time,
    status,
    (SELECT COUNT(*) FROM odds_snapshots WHERE match_id = matches.id AND is_pre_match = FALSE) AS live_snapshot_count
FROM matches
WHERE sport = 'FOOTBALL'
  AND status = 'FINISHED'
  AND final_home_score IS NULL
ORDER BY start_time DESC
LIMIT 10;

-- Action: If >5%, improve final score sync from Kambi API.


-- ============================================================
-- CHECK 9 — MATCH STATUS TRANSITION ACCURACY
-- Diagnoses: Are matches being marked LIVE/FINISHED correctly?
-- ============================================================
WITH status_timeline AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        status,
        start_time,
        NOW() - start_time AS time_since_start
    FROM matches
    WHERE sport = 'FOOTBALL'
    ORDER BY match_id, start_time
)
SELECT
    COUNT(*) FILTER (WHERE status = 'UPCOMING' AND time_since_start > INTERVAL '3 hours') AS stuck_in_upcoming,
    COUNT(*) FILTER (WHERE status = 'LIVE' AND time_since_start > INTERVAL '4 hours') AS stuck_in_live,
    COUNT(*) FILTER (WHERE status = 'FINISHED' AND time_since_start < INTERVAL '90 minutes') AS finished_too_early
FROM status_timeline;

-- Show potentially stuck matches
SELECT
    id,
    home_team || ' vs ' || away_team AS match,
    status,
    start_time,
    ROUND(EXTRACT(EPOCH FROM (NOW() - start_time))/3600.0, 1) AS hours_since_start,
    (SELECT COUNT(*) FROM odds_snapshots WHERE match_id = matches.id) AS total_snapshots
FROM matches
WHERE sport = 'FOOTBALL'
  AND ((status = 'LIVE' AND start_time < NOW() - INTERVAL '3 hours')
    OR (status = 'UPCOMING' AND start_time < NOW() - INTERVAL '2 hours'))
ORDER BY start_time;


-- ============================================================
-- SUMMARY REPORT — Overall Data Health Score
-- ============================================================
WITH metrics AS (
    SELECT
        (SELECT COUNT(*) FROM matches WHERE sport = 'FOOTBALL' AND status = 'FINISHED') AS total_matches,
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_pre_match = TRUE) / NULLIF(COUNT(DISTINCT match_id), 0), 1)
         FROM odds_snapshots o JOIN matches m ON m.id = o.match_id
         WHERE m.sport = 'FOOTBALL' AND m.status = 'FINISHED') AS baseline_coverage_pct,
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE home_draw_odds IS NOT NULL) / COUNT(*), 1)
         FROM odds_snapshots o JOIN matches m ON m.id = o.match_id
         WHERE o.is_pre_match = FALSE AND m.sport = 'FOOTBALL' AND m.status = 'FINISHED') AS dc_coverage_pct,
        (SELECT ROUND(AVG(snapshot_count)::numeric, 0)
         FROM (SELECT COUNT(*) AS snapshot_count
               FROM odds_snapshots o JOIN matches m ON m.id = o.match_id
               WHERE o.is_pre_match = FALSE AND m.sport = 'FOOTBALL' AND m.status = 'FINISHED'
               GROUP BY o.match_id) x) AS avg_snapshots_per_match,
        (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE final_home_score IS NOT NULL) / COUNT(*), 1)
         FROM matches WHERE sport = 'FOOTBALL' AND status = 'FINISHED') AS final_score_pct
)
SELECT
    total_matches,
    baseline_coverage_pct,
    dc_coverage_pct,
    avg_snapshots_per_match,
    final_score_pct,
    -- Overall health score (weighted average)
    ROUND(
        (LEAST(baseline_coverage_pct, 100) * 0.25 +
         LEAST(dc_coverage_pct, 100) * 0.35 +
         LEAST(avg_snapshots_per_match / 100.0 * 100, 100) * 0.20 +
         LEAST(final_score_pct, 100) * 0.20), 1
    ) AS overall_health_score
FROM metrics;

-- Health score interpretation:
--   90-100: Excellent data quality
--   70-89:  Good, minor improvements needed
--   50-69:  Fair, significant gaps exist
--   <50:    Poor, critical issues affecting strategy
