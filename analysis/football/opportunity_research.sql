-- ============================================================
-- SportBets — Opportunity Research Queries
-- These queries mine existing snapshot data for patterns that
-- could justify new betting paths or strategy tweaks.
-- Run each block independently.
-- ============================================================


-- ============================================================
-- OPP-1: LEADING FAVORITE STABILITY
-- Among matches where the pre-match favorite was WINNING at
-- halftime (1-0 or 2-0), how often did they hold the lead?
-- Motivation: "bet on the leader to stay ahead" path.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        CASE
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = home_win_odds THEN 'HOME'
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(home_win_odds, draw_odds, away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots
    WHERE is_pre_match = TRUE
    ORDER BY match_id, captured_at DESC
),
halftime_leading AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        p.favorite_side,
        p.fav_baseline_odds,
        o.home_score,
        o.away_score,
        o.match_minute
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND o.match_minute BETWEEN 40 AND 50
      AND (
          (p.favorite_side = 'HOME' AND o.home_score > o.away_score)
       OR (p.favorite_side = 'AWAY' AND o.away_score > o.home_score)
      )
    ORDER BY o.match_id, o.match_minute DESC
)
SELECT
    CASE
        WHEN fav_baseline_odds <= 1.30 THEN '≤1.30'
        WHEN fav_baseline_odds <= 1.50 THEN '1.31-1.50'
        ELSE '1.51-1.60'
    END                                             AS baseline_band,
    home_score || '-' || away_score                 AS halftime_score,
    COUNT(*)                                        AS matches,
    COUNT(*) FILTER (
        WHERE (h.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
           OR (h.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score)) AS held_lead,
    COUNT(*) FILTER (
        WHERE m.final_home_score = m.final_away_score)                                AS conceded_equalizer,
    COUNT(*) FILTER (
        WHERE (h.favorite_side = 'HOME' AND m.final_home_score < m.final_away_score)
           OR (h.favorite_side = 'AWAY' AND m.final_away_score < m.final_home_score)) AS lost_lead,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE (h.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
           OR (h.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                 AS held_lead_pct
FROM halftime_leading h
JOIN matches m ON m.id = h.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY baseline_band, halftime_score
ORDER BY baseline_band, halftime_score;


-- ============================================================
-- OPP-2: OVER 2.5 GOALS SIGNAL
-- When a match reaches 1-0 or 0-1 by minute 30 and both teams
-- have odds < 3.5, how often does the total end up > 2 goals?
-- Motivation: add Over 2.5 as a second bet market.
-- Requires: `over_2_5_outcome_id` added to snapshots (future).
-- ============================================================
WITH early_goal_matches AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        o.match_minute,
        o.home_score,
        o.away_score,
        o.home_win_odds,
        o.away_win_odds
    FROM odds_snapshots o
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND o.match_minute BETWEEN 20 AND 40
      AND (o.home_score + o.away_score) = 1   -- exactly 1 goal scored
    ORDER BY o.match_id, o.match_minute
)
SELECT
    COUNT(*)                                                    AS matches_1_goal_by_40m,
    COUNT(*) FILTER (WHERE m.final_home_score + m.final_away_score > 2)  AS ended_over_2_5,
    COUNT(*) FILTER (WHERE m.final_home_score + m.final_away_score = 2)  AS ended_exactly_2,
    COUNT(*) FILTER (WHERE m.final_home_score + m.final_away_score = 1)  AS ended_exactly_1,
    ROUND(100.0 * COUNT(*) FILTER (WHERE m.final_home_score + m.final_away_score > 2)
          / NULLIF(COUNT(*), 0), 1)                             AS over_2_5_rate_pct,
    ROUND(AVG(e.home_win_odds)::numeric, 2)                     AS avg_home_odds,
    ROUND(AVG(e.away_win_odds)::numeric, 2)                     AS avg_away_odds
FROM early_goal_matches e
JOIN matches m ON m.id = e.match_id
WHERE m.final_home_score IS NOT NULL;


-- ============================================================
-- OPP-3: MULTI-GOAL DEFICIT RECOVERY
-- Current strategy only bets on -1 deficit. Does -2 ever
-- recover? If so, what's the rate and at what odds?
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        CASE
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = home_win_odds THEN 'HOME'
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(home_win_odds, draw_odds, away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots
    WHERE is_pre_match = TRUE
    ORDER BY match_id, captured_at DESC
),
losing_by_2 AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        p.favorite_side,
        p.fav_baseline_odds,
        o.match_minute,
        CASE p.favorite_side
            WHEN 'HOME' THEN o.home_win_odds
            WHEN 'AWAY' THEN o.away_win_odds
            ELSE o.draw_odds
        END AS fav_odds_at_moment
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    JOIN matches m ON m.id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND m.status = 'FINISHED'
      AND p.fav_baseline_odds <= 1.60
      AND o.match_minute BETWEEN 1 AND 70
      AND (
          (p.favorite_side = 'HOME' AND o.away_score - o.home_score = 2)
       OR (p.favorite_side = 'AWAY' AND o.home_score - o.away_score = 2)
      )
    ORDER BY o.match_id, o.match_minute
)
SELECT
    COUNT(*)                                                                        AS matches_down_2,
    COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))  AS at_least_drew,
    COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))   AS won_outright,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                                                 AS dc_recovery_pct,
    ROUND(AVG(l.fav_odds_at_moment)::numeric, 2)                                    AS avg_odds_when_2_down,
    ROUND(AVG(l.match_minute)::numeric, 1)                                          AS avg_minute_when_2_down
FROM losing_by_2 l
JOIN matches m ON m.id = l.match_id
WHERE m.final_home_score IS NOT NULL;


-- ============================================================
-- OPP-4: COMPETITION-SPECIFIC WIN RATES
-- Some leagues may have higher comeback rates than others.
-- Use to decide whether to filter by competition.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        CASE
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = home_win_odds THEN 'HOME'
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(home_win_odds, draw_odds, away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots
    WHERE is_pre_match = TRUE
    ORDER BY match_id, captured_at DESC
),
losing_moments AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        p.favorite_side
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND p.fav_baseline_odds <= 1.60
      AND o.match_minute BETWEEN 1 AND 80
      AND (
          (p.favorite_side = 'HOME' AND o.away_score - o.home_score = 1)
       OR (p.favorite_side = 'AWAY' AND o.home_score - o.away_score = 1)
      )
    ORDER BY o.match_id, o.captured_at
)
SELECT
    m.competition,
    COUNT(*)                                                                    AS matches_fav_losing,
    COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))  AS came_back,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                                             AS comeback_pct
FROM losing_moments l
JOIN matches m ON m.id = l.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY m.competition
HAVING COUNT(*) >= 3
ORDER BY comeback_pct DESC;


-- ============================================================
-- OPP-5: HOME vs AWAY COMEBACK ASYMMETRY
-- Home teams may have better comeback rates than away teams.
-- Informs whether to skip AWAY favorite bets.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        CASE
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = home_win_odds THEN 'HOME'
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(home_win_odds, draw_odds, away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots
    WHERE is_pre_match = TRUE
    ORDER BY match_id, captured_at DESC
),
losing_moments AS (
    SELECT DISTINCT ON (o.match_id)
        o.match_id,
        p.favorite_side,
        p.fav_baseline_odds
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    WHERE o.is_pre_match = FALSE
      AND p.fav_baseline_odds <= 1.60
      AND o.match_minute BETWEEN 1 AND 80
      AND (
          (p.favorite_side = 'HOME' AND o.away_score - o.home_score = 1)
       OR (p.favorite_side = 'AWAY' AND o.home_score - o.away_score = 1)
      )
    ORDER BY o.match_id, o.captured_at
)
SELECT
    favorite_side,
    COUNT(*)                                                                    AS losing_moments,
    COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))   AS won_outright,
    COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))  AS dc_comeback,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score > m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score > m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                                             AS outright_comeback_pct,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE (l.favorite_side = 'HOME' AND m.final_home_score >= m.final_away_score)
           OR (l.favorite_side = 'AWAY' AND m.final_away_score >= m.final_home_score))
          / NULLIF(COUNT(*), 0), 1)                                             AS dc_comeback_pct
FROM losing_moments l
JOIN matches m ON m.id = l.match_id
WHERE m.final_home_score IS NOT NULL
GROUP BY favorite_side;


-- ============================================================
-- OPP-6: ODDS SPEED — HOW FAST DO ODDS RISE?
-- Checks whether the odds rise is gradual or sudden.
-- If most of the rise happens within 1-2 polls (90s),
-- we may be reacting too late.
-- ============================================================
WITH pre_match_favs AS (
    SELECT DISTINCT ON (match_id)
        match_id,
        CASE
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = home_win_odds THEN 'HOME'
            WHEN LEAST(home_win_odds, draw_odds, away_win_odds) = away_win_odds THEN 'AWAY'
            ELSE 'DRAW'
        END AS favorite_side,
        LEAST(home_win_odds, draw_odds, away_win_odds) AS fav_baseline_odds
    FROM odds_snapshots
    WHERE is_pre_match = TRUE
    ORDER BY match_id, captured_at DESC
),
fav_odds_series AS (
    SELECT
        o.match_id,
        p.favorite_side,
        p.fav_baseline_odds,
        o.captured_at,
        o.match_minute,
        CASE p.favorite_side
            WHEN 'HOME' THEN o.home_win_odds
            WHEN 'AWAY' THEN o.away_win_odds
            ELSE o.draw_odds
        END AS fav_odds,
        LAG(CASE p.favorite_side
            WHEN 'HOME' THEN o.home_win_odds
            WHEN 'AWAY' THEN o.away_win_odds
            ELSE o.draw_odds
        END) OVER (PARTITION BY o.match_id ORDER BY o.captured_at) AS prev_fav_odds
    FROM odds_snapshots o
    JOIN pre_match_favs p ON p.match_id = o.match_id
    WHERE o.is_pre_match = FALSE
)
SELECT
    CASE
        WHEN (fav_odds - prev_fav_odds) / NULLIF(prev_fav_odds, 0) * 100 < 5   THEN ' <5% per poll'
        WHEN (fav_odds - prev_fav_odds) / NULLIF(prev_fav_odds, 0) * 100 < 10  THEN ' 5-10%'
        WHEN (fav_odds - prev_fav_odds) / NULLIF(prev_fav_odds, 0) * 100 < 20  THEN '10-20%'
        ELSE '≥20% sudden spike'
    END                                             AS rise_per_poll,
    COUNT(*)                                        AS occurrences,
    ROUND(AVG(match_minute)::numeric, 1)            AS avg_minute,
    ROUND(AVG(fav_odds)::numeric, 2)                AS avg_odds_after
FROM fav_odds_series
WHERE prev_fav_odds IS NOT NULL
  AND fav_odds > prev_fav_odds          -- only when odds increased
  AND fav_baseline_odds <= 1.60
GROUP BY rise_per_poll
ORDER BY rise_per_poll;


-- ============================================================
-- OPP-7: SCORE SEQUENCE AFTER ALERT
-- For each alert, how many goals were scored after the alert?
-- If the favorite consistently scores 1 more goal → strategy works.
-- Requires match-level detail to be meaningful.
-- ============================================================
WITH score_at_alert AS (
    SELECT
        a.id AS alert_id,
        a.suggested_bet,
        a.trigger_scenario,
        a.current_odds,
        a.triggered_at,
        -- Parse score_at_alert "H-A" string
        SPLIT_PART(a.score_at_alert, '-', 1)::int   AS alert_home_goals,
        SPLIT_PART(a.score_at_alert, '-', 2)::int   AS alert_away_goals,
        m.final_home_score,
        m.final_away_score,
        m.id AS match_id
    FROM betting_alerts a
    JOIN matches m ON m.id = a.match_id
    WHERE a.score_at_alert IS NOT NULL
      AND a.score_at_alert LIKE '%-%'
      AND m.final_home_score IS NOT NULL
)
SELECT
    trigger_scenario,
    suggested_bet                                                   AS fav_side,
    COUNT(*)                                                        AS alerts,
    -- Goals the favorite scored after the alert
    ROUND(AVG(
        CASE suggested_bet
            WHEN 'HOME' THEN (final_home_score - alert_home_goals)
            WHEN 'AWAY' THEN (final_away_score - alert_away_goals)
            ELSE 0
        END)::numeric, 2)                                           AS avg_fav_goals_after_alert,
    -- Goals the opponent scored after the alert
    ROUND(AVG(
        CASE suggested_bet
            WHEN 'HOME' THEN (final_away_score - alert_away_goals)
            WHEN 'AWAY' THEN (final_home_score - alert_home_goals)
            ELSE 0
        END)::numeric, 2)                                           AS avg_opp_goals_after_alert,
    -- Net goal difference after alert (positive = fav scored more)
    ROUND(AVG(
        CASE suggested_bet
            WHEN 'HOME' THEN (final_home_score - alert_home_goals) - (final_away_score - alert_away_goals)
            WHEN 'AWAY' THEN (final_away_score - alert_away_goals) - (final_home_score - alert_home_goals)
            ELSE 0
        END)::numeric, 2)                                           AS avg_net_goals_for_fav
FROM score_at_alert
GROUP BY trigger_scenario, suggested_bet;
