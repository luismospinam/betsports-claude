# SportBets — Basketball Analysis Findings

> **Sport:** Basketball only (BASKETBALL_COMEBACK strategy).
> SQL lives in `basketball_stats.sql` (this folder) for basketball-specific sections.
> Cross-sport overview is in `../betting_stats.sql` Sections 1–3 and 14–15.
> Football analysis is in `../football/findings.md`.

**Data window:** 110 finished basketball matches as of 2026-05-03
**Stake assumed:** 1,000 COP per bet

---

## 1. Data Inventory

| Metric | Value |
|--------|-------|
| Total basketball matches tracked | 146 |
| Finished matches | 110 |
| Live right now | 3 |
| Pre-match snapshots | 96 |
| Live snapshots | 10,033 |
| Alerts fired | 60 |
| Bets placed | 34 |
| Failed / Skipped | 26 |

---

## 2. Overall P&L (34 placed bets)

| Metric | Value |
|--------|-------|
| Wins | 19 |
| Losses | 15 |
| Win rate | **55.9%** |
| Average odds | 2.04 |
| Break-even needed | 49.0% |
| EV | **+13.7%** |

Overall **profitable at current settings**. The analysis below identifies which parameters are responsible and where tighter tuning would push EV higher.

---

## 3. Period Analysis

### Ground truth (all finished matches — both sides regardless of alert)

| Period | Trailing moments | Comeback % | Avg deficit | Avg baseline odds |
|--------|-----------------|------------|-------------|-------------------|
| QUARTER1 | 51 | 54.9% | 1.9 pts | 1.40 |
| QUARTER2 | 43 | 51.2% | 4.2 pts | 1.41 |
| QUARTER3 | 36 | 36.1% | 6.1 pts | 1.44 |
| QUARTER4 | 25 | 36.0% | 5.4 pts | 1.47 |

> **HALFTIME does not exist as a period_id.** Kambi uses QUARTER2 through the halftime break. The `HALFTIME` entry in `bet-periods` config never matches any snapshot and should be removed.

### Placed bets breakdown

| Period | Bets | Win % | Avg odds | Avg rise % |
|--------|------|-------|----------|------------|
| QUARTER2 | 8 | 50.0% | 1.70 | 39.5% |
| QUARTER3 | 22 | 54.5% | 2.13 | 57.7% |
| QUARTER4 | 4 | 75.0% | 2.18 | 63.1% |

Break-even at QUARTER2 avg odds (1.70) = 58.8%. **QUARTER2 bets are losing money** (50% vs 58.8% needed). QUARTER3 and QUARTER4 are profitable — higher odds compensate for lower ground-truth comeback rates.

**→ Remove QUARTER2 from bet-periods.** Replace HALFTIME with QUARTER4. New value: `"QUARTER3,QUARTER4"`

---

## 4. Point Deficit Analysis

### Ground truth (QUARTER2–4 combined)

| Deficit band | Moments | Comeback % |
|-------------|---------|------------|
| 1–3 pts | 51 | **56.9%** |
| 4–6 pts | 22 | 36.4% |
| 7–10 pts | 16 | 25.0% |
| 11–15 pts | 12 | 25.0% |
| >15 pts | 3 | 0.0% |

### Placed bets breakdown

| Deficit band | Bets | Win % | Avg odds |
|-------------|------|-------|----------|
| 1–3 pts | 14 | 57.1% | 1.89 |
| 4–6 pts | 7 | 71.4% | 1.90 |
| 7–10 pts | 13 | 46.2% | 2.27 |

No bets were placed at >10 pts deficit (current `max-point-deficit: 10` filtered them).

The placed-bet win rate at 7–10 pts (46.2%) exceeds break-even for those odds (44.1%), but the ground truth comeback rate at that range is only 25%. The odds-rise filter is selecting the better cases within the 7–10 band, but the edge is thin.

**→ Tighten `max-point-deficit` to 6.** Beyond 6 pts, ground-truth comeback rate drops to 25% or less. The 4–6 pts band has 71.4% win on placed bets; beyond that the EV margin is too thin to justify the risk.

**→ Set `min-point-deficit` to 1.** Current value of 0 allows bets when the score is tied (deficit = 0), which is inconsistent with a "comeback" strategy. One placed bet (Fibwi Palma — score "41-41") fired on a tied game.

---

## 5. Baseline Odds Analysis

### Ground truth (QUARTER2–4)

| Baseline band | Moments | Comeback % |
|--------------|---------|------------|
| ≤1.20 | 19 | 57.9% |
| 1.21–1.30 | 16 | 56.3% |
| **1.31–1.40** | **16** | **81.3%** |
| 1.41–1.50 | 7 | 0.0% |
| 1.51–1.60 | 18 | 5.6% |
| >1.60 | 28 | 35.7% |

### Placed bets breakdown

| Baseline band | Bets | Win % | Avg odds |
|--------------|------|-------|----------|
| ≤1.20 | 7 | 71.4% | 1.68 |
| 1.21–1.30 | 9 | 55.6% | 1.91 |
| **1.31–1.40** | **7** | **85.7%** | **1.97** |
| 1.41–1.50 | 7 | 42.9% | 2.40 |
| 1.51–1.60 | 4 | 0.0% | 2.42 |

The 1.31–1.40 band is the standout: **85.7% win rate and 81.3% ground-truth comeback**. The 1.51–1.60 band is a disaster in both views (0% placed, 5.6% ground truth). The 1.41–1.50 band conflict (42.9% placed bets vs 0% ground truth) is a small-sample tension — only 7 moments in ground truth.

**→ Lower `max-baseline-odds` to 1.40.** The 1.41–1.50 ground truth is 0%, and placed bets barely reach break-even (42.9% at avg 2.40 odds = EV ~+3%). The 1.51–1.60 band has never won a placed bet. Everything above 1.40 is dead weight.

---

## 6. Odds Rise Threshold Analysis

| Min rise % | Bets | Win % | Avg odds | EV % |
|-----------|------|-------|----------|------|
| 20% | 34 | 55.9% | 2.04 | +13.7% |
| 25% | 31 | 58.1% | 2.08 | +20.9% |
| 30% | 30 | 56.7% | 2.10 | +19.2% |
| **35%** | **21** | **66.7%** | **2.24** | **+49.4%** |
| 40% | 18 | 61.1% | 2.30 | +40.6% |
| 50% | 13 | 53.8% | 2.48 | +33.5% |
| 60% | 10 | 60.0% | 2.61 | +56.8% |

The 35% threshold is the optimal balance: **+49.4% EV with 21 bets**. Beyond 40% the bet count shrinks quickly. Raising to 60% gives nominally higher EV but 10 bets is too thin for confidence.

**→ Raise `odds-rise-threshold-pct` to 35.**

---

## 7. Max Current Odds Analysis

| Max current odds | Bets | Win % | Avg odds | EV % |
|-----------------|------|-------|----------|------|
| 2.00 | 22 | 59.1% | 1.74 | +3.0% |
| 2.50 | 28 | 57.1% | 1.86 | +6.0% |
| **3.00** | **32** | **59.4%** | **1.96** | **+16.5%** |
| 3.50 | 34 | 55.9% | 2.04 | +13.7% |
| 4.00 | 34 | 55.9% | 2.04 | +13.7% (same) |

Adding bets above 3.00 (odds 3.00–4.00) drags the EV down from +16.5% to +13.7%. No bets were placed between 3.50–4.00 in the dataset, so the 3.50 and 4.00 rows are identical.

**→ Keep `max-current-odds` at 3.00.** Already at the sweet spot.

---

## 8. Config Changes Applied (2026-05-03)

| Parameter | Before | After | Reason |
|-----------|--------|-------|--------|
| `odds-rise-threshold-pct` | 20.0 | **35.0** | EV +13.7% → +49.4%, 34 → 21 bets |
| `max-baseline-odds` | 1.50 | **1.40** | 1.41–1.50 band: 0% ground-truth comeback; 1.51–1.60: 0% win in placed bets |
| `max-current-odds` | 3.00 | **3.00** (no change) | Already at optimal point (+16.5% EV) |
| `min-point-deficit` | 0 | **1** | Prevents betting on tied score (deficit=0), inconsistent with comeback strategy |
| `max-point-deficit` | 10 | **6** | Ground truth: 25% comeback at 7–10 pts; edge too thin beyond 6 |
| `bet-periods` | QUARTER2,HALFTIME,QUARTER3 | **QUARTER3,QUARTER4** | HALFTIME never fires (period_id doesn't exist in data); QUARTER2 loses money (50% win vs 58.8% break-even at avg 1.70 odds) |

### Expected impact

Tighter filters reduce bet count from ~34 to an estimated ~12–15 per equivalent data window, but EV improves from +13.7% to an estimated +40–50%.

---

## 9. Re-analysis (2026-05-09)

**Data window:** 498 matches tracked / 432 finished / 166 alerts / 76 placed bets  
**Stake assumed:** 1,000 COP per bet

### Data Inventory

| Metric | Value |
|--------|-------|
| Total basketball matches tracked | 498 |
| Finished matches | 432 |
| Live now | 16 |
| Upcoming | 50 |
| Pre-match snapshots | 344 |
| Live snapshots | 33,579 |
| Alerts fired | 166 |
| Bets placed | 76 |
| Failed / Skipped | 90 |

### Overall P&L (76 placed bets)

| Metric | Value |
|--------|-------|
| Wins | 38 |
| Losses | 37 |
| Pending | 1 |
| Win rate | **50.7%** |
| Average odds | 2.023 |
| Break-even needed | 49.4% |
| Net COP | **−1,020** ≈ flat |

Win rate dropped from 55.9% (34 bets) to 50.7% (76 bets). The strategy is barely above break-even but generating no real profit. The +13.7% EV from the May 3 report was driven by a small sample; the larger dataset shows no meaningful edge at current config.

### P&L by Period

| Period | Placed | Wins | Win% | Avg Odds | Net COP |
|--------|--------|------|------|----------|---------|
| QUARTER2 | 15 | 8 | 53.3% | 1.759 | −390 |
| QUARTER3 | 49 | 24 | **50.0%** | 2.063 | **−1,400** |
| QUARTER4 | 12 | 6 | 50.0% | 2.191 | +770 |

QUARTER2 bets in the table are from before the 2026-05-03 config change (period has been removed from `bet-periods`). Q3 and Q4 are both at exactly 50% — statistically indistinguishable from a coin flip. Q4 is marginally positive only because the avg odds are higher (2.191 vs 2.063). Both periods need more data before drawing conclusions from the post-config-change subset.

### P&L by Baseline Odds Band

| Baseline Band | Placed | Wins | Win% | Avg Odds | Net COP |
|--------------|--------|------|------|----------|---------|
| < 1.20 | 14 | 10 | **71.4%** | 1.640 | **+2,850** ✅ |
| 1.20–1.29 | 18 | 8 | 47.1% | 1.926 | **−1,850** ❌ |
| **1.30–1.39** | **24** | **13** | **54.2%** | **2.122** | **+2,490** ✅ |
| 1.40–1.49 | 15 | 7 | 46.7% | 2.212 | +490 |
| 1.50+ | 5 | 0 | 0.0% | 2.376 | **−5,000** ❌ |

The < 1.20 band (+2,850) and 1.30–1.39 band (+2,490) are profitable. The 1.20–1.29 band is a blind spot — high sample count but losing. The 1.50+ band is 0/5 — these should not be firing (config has `max-baseline-odds: 1.40`; the 5 bets above 1.50 are from before the May 3 change). The profitable pattern from the May 3 analysis (1.31–1.40 standout) is confirmed with the larger sample. The 1.20–1.29 gap is new and worth watching — the ground truth may simply have lower comeback rates in that band.

### P&L by Point Deficit

| Deficit Band | Placed | Wins | Win% | Avg Odds | Net COP |
|-------------|--------|------|------|----------|---------|
| 1 pt | 4 | 3 | 75.0% | 2.270 | **+2,480** ✅ |
| 2 pts | 9 | 4 | 44.4% | 1.934 | **−1,990** ❌ |
| 3 pts | 10 | 4 | 40.0% | 1.786 | **−2,960** ❌ |
| 4–6 pts | 29 | 12 | 42.9% | 1.984 | **−4,850** ❌ |
| **7+ pts** | **24** | **15** | **62.5%** | **2.158** | **+6,300** ✅ |

This is the most critical finding. The current config bets on deficits of 1–6 pts, but **deficits of 2–6 pts are all losing money**. The only profitable bands are 1 pt (high win rate at good odds) and 7+ pts (underdog odds large enough to compensate for lower win rate). The 4–6 pt band alone accounts for 29 bets and −4,850 COP — the single biggest drag on the strategy.

The 7+ pt bets (24 placed) should not exist under the current `max-point-deficit: 6` config, which means most of these are from before the May 3 change. Their 62.5% win rate and +6,300 COP are a signal worth noting: larger deficits may present better odds value than moderate ones.

### Ground Truth (2026-05-09)

432 finished basketball matches → **132 had a Q3/Q4 trailing moment with 1–6 pt deficit** → **53.4% comeback rate**.

This ground truth rate (53.4%) almost exactly matches the placed-bet win rate (50.7%). This is the key problem: the odds filter is adding essentially **zero selection edge** over randomly picking any trailing team in Q3/Q4. The strategy is paying for bets that are priced fairly by the market.

### Config recommendations from this run

| Parameter | Current | Recommended | Reason |
|-----------|---------|-------------|--------|
| `max-point-deficit` | 6 | **evaluate splitting** | 2–6 pts all lose; 1 pt wins; 7+ pts wins but currently excluded |
| `min-point-deficit` | 1 | **keep** | Correct |
| `max-baseline-odds` | 1.40 | **1.39** or consider **< 1.20 + 1.30–1.39 only** | 1.20–1.29 band is losing; skipping it may help |

The deficit finding suggests a non-contiguous filter (allow 1 pt, skip 2–6, allow 7+) is the only profitable configuration — but that is architecturally awkward. A simpler first step is to tighten `max-point-deficit` to 3 (keeping only the 1–3 band) and accept fewer bets, or to raise `odds-rise-threshold-pct` further to filter out the lower-quality cases within the 2–6 pt range. Needs further data to decide.

---

## 10. Live-Stats Integration — first pass (2026-05-10)

**Goal:** test whether SofaScore live stats (3PT%, FG%, turnovers, biggest lead, time-spent-in-lead) can isolate the trailing-favorite moments where a comeback is actually likely — closing the §9 finding that the odds filter alone adds essentially **zero edge** above the 53.4% ground-truth rate.

**SQL:** `betting_stats.sql` Section 17 — for every Q2/Q3/Q4 trailing moment of a pre-match favorite (baseline ≤1.45, deficit 1–10, rise ≥30%) with stats attached, group outright win rate by stat band.

### Data reality at run time

Basketball stats started populating **2026-05-09** — one day before this section was written. The trigger-moment join landed on **3–11 rows per hypothesis**, every cell flagged "small."

| Hypothesis | Bands with data | Max samples in any band |
|------------|----------------|------------------------|
| A — 3PT% gap (fav − opp) | 3 | 3 |
| B — FG% gap | 3 | 2 |
| C — Turnover differential | 2 | 3 |
| D — Favorite's biggest lead so far | 1 | 5 |
| E — Time-in-lead differential | 2 | 3 |

### Honest verdict

**No actionable signal today.** Every band is below the n=30 threshold and the totals (≤11 per hypothesis) are below any reasonable confidence floor. The query structure is in place; the bottleneck is purely volume.

### Re-run plan

The basketball trigger moment volume is much lower than football (Q3/Q4 trailing moments at the 1.45 baseline cap are scarce — see §9 ground-truth count of 132). Realistic timeline:

| Date | Expected trigger-moment count | Action |
|------|------------------------------|--------|
| **2026-05-24** (~2 weeks) | ~30–50 | First credible re-run; flag any hypothesis where one band reaches n≥30 |
| **2026-06-10** (~1 month) | ~60–100 | Second re-run; promote any band that holds ≥10pp separation to a config knob |

### Hypotheses ranked by likelihood of being useful

Based on basketball domain logic, not data:

1. **D — Favorite's biggest lead so far.** If the favorite was up 5+ at any point earlier and then fell behind, the regression-to-mean argument is strongest. This is the most theoretically defensible signal and the easiest to wire as a filter (`min-fav-biggest-lead`).
2. **A — 3PT% gap.** Cold 3-point shooting reverts more reliably than cold 2-point shooting. If `fav_3pct − opp_3pct ≤ −15`, a regression argument applies.
3. **C — Turnover differential.** Negative TO diff (favorite cleaner) with a deficit suggests the deficit is shooting-luck-driven, not control-driven.

E (lead-time differential) and B (FG% gap) are weaker — too noisy in basketball where short streaks dominate.

### Architectural note for when a signal is promoted

The current filters in `BasketballOddsMonitorService.checkAndFireAlert()` are all live-snapshot-derived (period_id, deficit, current odds, baseline odds, rise pct). Adding a stat filter requires:

1. Joining the `basketball_live_stats` row for `snapshot.id` *inside* `processLiveMatch()` — currently stats are written *after* the bet decision; the order must flip so the decision can read them.
2. Handling the null case: SofaScore can fail to find a match (the `sofaScoreIdCache` empty-string sentinel) — the filter must treat missing stats as "pass through" or "skip", configurable per-knob.
3. Adding the knob to `application.yml` under `betplay.basketball.monitor` with the analytical justification in this file, like every other current knob.
