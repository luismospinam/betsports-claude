-- Stores the Double Chance (Doble Oportunidad) outcome IDs from Kambi:
--   home_draw_outcome_id → "1X" (home win or draw)
--   away_draw_outcome_id → "X2" (away win or draw)
-- Used for Path A (LOSING_BY_1) bets instead of outright win outcome IDs.
ALTER TABLE odds_snapshots
    ADD COLUMN home_draw_outcome_id BIGINT,
    ADD COLUMN away_draw_outcome_id BIGINT;
