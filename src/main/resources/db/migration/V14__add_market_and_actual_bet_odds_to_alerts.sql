-- Fixes three bugs:
--   1. P&L inflation: current_odds stores outright odds even for DC bets (~2.50),
--      but payout is at DC odds (~1.22-1.46). All P&L queries used the wrong multiplier.
--   2. Browser deviation check broken: triggerOdds passed to browser was outright odds,
--      so betslip DC odds (~1.22) always failed the 15% deviation guard silently.
--   3. Discord message showed outright odds for DC bets.
--
-- market:         which bet offer was used (RESULTADO_FINAL / DOBLE_OPORTUNIDAD / PRORROGA_INCLUIDA)
-- actual_bet_odds: odds the bet was actually placed at — DC odds for DOBLE_OPORTUNIDAD,
--                  current_odds for all others.

ALTER TABLE betting_alerts
    ADD COLUMN market           VARCHAR(30),
    ADD COLUMN actual_bet_odds  DOUBLE PRECISION;

-- Backfill market using same thresholds as current application logic:
--   LOSING_BY_1 + current_odds in [1.50, 3.00) → DOBLE_OPORTUNIDAD
--   BASKETBALL_COMEBACK                         → PRORROGA_INCLUIDA
--   everything else                             → RESULTADO_FINAL
UPDATE betting_alerts
SET market = CASE
    WHEN trigger_scenario = 'LOSING_BY_1'
         AND current_odds >= 1.50 AND current_odds < 3.00 THEN 'DOBLE_OPORTUNIDAD'
    WHEN trigger_scenario = 'BASKETBALL_COMEBACK'         THEN 'PRORROGA_INCLUIDA'
    ELSE                                                       'RESULTADO_FINAL'
END;

-- Backfill actual_bet_odds:
--   Non-DC bets: actual_bet_odds = current_odds (outright was the market)
--   DC bets:     find closest live snapshot with DC odds and use that side's DC odds.
--                Returns NULL if no DC odds were captured near the alert — honest gap.
UPDATE betting_alerts a
SET actual_bet_odds = CASE
    WHEN a.market != 'DOBLE_OPORTUNIDAD' THEN a.current_odds
    ELSE (
        SELECT CASE a.suggested_bet
                   WHEN 'HOME' THEN o.home_draw_odds
                   WHEN 'AWAY' THEN o.away_draw_odds
               END
        FROM odds_snapshots o
        WHERE o.match_id = a.match_id
          AND o.is_pre_match = FALSE
          AND o.home_draw_odds IS NOT NULL
        ORDER BY ABS(EXTRACT(EPOCH FROM (o.captured_at - a.triggered_at)))
        LIMIT 1
    )
END;
