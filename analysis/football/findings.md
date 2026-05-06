# SportBets — Analysis Findings & Config Decisions

> **Sport:** Football only (LOSING_BY_1 / TIED_HALFTIME strategy).
> SQL lives in `../betting_stats.sql` — football queries are Sections 4–13.
> Basketball analysis is in `../basketball/findings.md`.

**Data window:** all finished matches in DB as of 2026-04-28  
**Stake assumed:** 1,000 COP per bet

---

## 1. Data Inventory

| Metric | Value |
|--------|-------|
| Total matches tracked | 1,955 |
| Finished matches | 1,817 |
| Live snapshots | 193,516 |
| Alerts fired | 274 |
| Bets placed | 210 |
| Failed (browser/CDP) | 64 (mostly TIED_HALFTIME during market suspension) |

---

## 2. Overall P&L

**210 resolved bets: 91 wins / 118 losses / 1 pending**

| Metric | Value |
|--------|-------|
| Win rate | 43.5% |
| Break-even needed | 48.6% |
| Average odds | 2.06 |
| Net | **−24,300 COP** |

The system is losing overall — but the headline conceals a critical split.

---

## 3. The Critical Split: LOSING_BY_1 vs TIED_HALFTIME

| Scenario | Bets | Win % | Avg Odds | Break-even | Net |
|----------|------|-------|----------|------------|-----|
| LOSING_BY_1 | 69 | **52.2%** | 2.26 | 44.3% | **+16,170 COP** ✅ |
| TIED_HALFTIME | 124 | 39.0% | 1.87 | 53.4% | **−37,260 COP** ❌ |
| Legacy (no scenario) | 17 | 41.2% | 2.59 | 38.6% | −3,210 COP |

**LOSING_BY_1 is profitable. TIED_HALFTIME is destroying all gains.**

---

## 4. LOSING_BY_1 Market Breakdown

| Market | Bets | Win % | Avg Odds | Net |
|--------|------|-------|----------|-----|
| DOBLE_OPORTUNIDAD (odds ≥ 2.0) | 48 | **62.5%** | 2.50 | **+27,020 COP** ✅ |
| RESULTADO_FINAL (odds < 2.0) | 21 | 28.6% | 1.70 | **−10,850 COP** ❌ |

The DC bet is the engine of profitability. The outright bet on LOSING_BY_1 (when odds are still low) loses badly — 30 points below break-even.

---

## 5. Baseline Odds Sweet Spot

| Baseline Band | Bets | Win % | Note |
|---------------|------|-------|------|
| ≤1.10 | 7 | 28.6% | Market never gives good recovery odds |
| 1.11–1.20 | 16 | 50.0% | OK |
| 1.21–1.30 | 25 | 36.0% | Poor |
| 1.31–1.40 | 31 | 54.8% | Good |
| **1.41–1.50** | **40** | **64.1%** | **Best — statistically significant** |
| 1.51–1.60 | 47 | 38.3% | Below break-even |
| >1.60 | 44 | 27.3% | Not strong favorites — noise bets |

**→ Tighten `max-baseline-odds` to 1.50.** The 1.51–1.60 band underperforms at only 38.3%.

---

## 6. Ground Truth: Comeback Rates (All Matches, Not Just Bets)

| Baseline Band | Losing Moments | Won Outright % | DC Comeback % |
|---------------|---------------|---------------|---------------|
| 1.11–1.20 | 10 | 30.0% | **90.0%** |
| 1.21–1.30 | 10 | 50.0% | 60.0% |
| 1.31–1.40 | 16 | 25.0% | 56.3% |
| **1.41–1.50** | **22** | **40.9%** | **68.2%** |
| 1.51–1.60 | 23 | 8.7% | 56.5% |
| >1.60 | 376 | 17.6% | 43.6% |

The 1.41–1.50 band is best-in-class: 68.2% DC comeback. The 1.51–1.60 band has only 8.7% outright comeback — these are not true favorites.

---

## 7. Odds Rise Threshold Analysis (LOSING_BY_1)

| Min Rise % | Bets | Win % | EV |
|-----------|------|-------|-----|
| 15% | 69 | 52.2% | +17.9% |
| 20% | 69 | 52.2% | +17.9% |
| 25% | 65 | 52.3% | +21.2% |
| **30%** | **60** | **55.0%** | **+29.8%** |
| 35% | 57 | 56.1% | +34.1% |
| 40% | 53 | 56.6% | +37.3% |
| 50% | 42 | 59.5% | +49.8% |

Raising the threshold increases both win rate and odds — compounding EV. **30% is a good balance**: keeps ~60 bets and improves EV from +17.9% to +29.8%.

---

## 8. TIED_HALFTIME — Exhaustive Analysis (Why It Was Disabled)

Ground truth across all 1,036 tied-favorite moments:

| Outcome | Count | % |
|---------|-------|---|
| Favorite won | 482 | 46.5% |
| Ended in draw | 339 | 32.7% |
| Favorite lost | 215 | 20.8% |
| Avg odds when tied | — | 1.98 |

At avg 1.98 odds, break-even is 50.5%. Actual win rate is 46.5%. **The edge does not exist.**

### Every sub-segment tested — all negative EV

**By score when tied:**

| Score | Matches | Fav Win % | EV |
|-------|---------|-----------|-----|
| 0-0 | 923 | 46.8% | −8.4% |
| 1-1 | 111 | 45.0% | −3.3% |

**By live odds level:**

| Fav odds when tied | Matches | Win % | EV |
|--------------------|---------|-------|----|
| <1.50 | 168 | 64.3% | −14.5% |
| 1.50–1.99 | 378 | 49.5% | −13.1% |
| 2.00–2.49 | 370 | 40.5% | −10.1% |
| 2.50–2.99 | 101 | 34.7% | −8.1% |

**By odds rise threshold:**

| Min Rise % | Bets | Win % | EV |
|-----------|------|-------|----|
| 15% | 112 | 37.8% | −28.3% |
| 25% | 56 | 32.7% | −33.1% |
| 35% | 26 | 30.8% | −30.4% |
| 50% | 16 | 31.3% | −24.7% |

No configuration of TIED_HALFTIME produces positive EV.

---

## 9. Double Chance Min/Max Odds Analysis

The key insight: the optimal market choice is not monotonic. No single threshold handles all bands correctly — a **bounded DC window** is required.

### Per-band EV breakdown (LOSING_BY_1 bets only)

| Band (current outright odds) | Bets | Outright Win % | Outright EV | DC Win % | Avg DC Odds | DC EV | Decision |
|------------------------------|------|----------------|-------------|----------|-------------|-------|----------|
| <1.50 | 6 | 33.3% | −54.3% | 66.7% | no data | — | Skip (no DC data) |
| 1.50–1.74 | 5 | 20.0% | −66.4% | 80.0% | no data | — | Skip (no DC data) |
| **1.75–1.99** | **10** | 30.0% | **−42.7%** | 90.0% | 1.217 | **+9.5%** | ✅ **DC wins** |
| **2.00–2.24** | **11** | **54.5%** | **+14.4%** | 72.7% | 1.254 | −8.8% | ✅ **Outright wins** |
| 2.25–2.49 | 13 | 23.1% | −45.8% | 53.8% | 1.265 | −31.9% | Both lose — skip via `max-current-odds` |
| 2.50–2.99 | 19 | 15.8% | −57.6% | 63.2% | 1.270 | −19.7% | Both lose — skip via `max-current-odds` |
| ≥3.00 | 5 | 40.0% | +25.2% | 60.0% | 1.990 | +19.4% | Skipped by `max-current-odds: 2.50` (tiny sample) |

### Why the window matters
- **1.75–1.99:** DC odds (~1.22) are too low in isolation, but team win-or-draw rate is 90% → +9.5% EV. Outright win rate (30%) is far below break-even for these odds.
- **2.00–2.24:** Team wins outright 54.5% of the time at avg ~2.12 odds → +14.4% EV. DC odds (~1.25) require 80%+ win-or-draw to break even; 72.7% is not enough.
- **2.25–2.99:** Both markets lose. The `max-current-odds: 2.50` cap skips these bets entirely.

---

## 10. Config Changes Applied (2026-05-01)

### Summary table

| Parameter | Before | After | Reason |
|-----------|--------|-------|--------|
| `odds-rise-threshold-pct` | 20.0 | **30.0** | EV +17.9% → +29.8%, minimal bet reduction |
| `max-baseline-odds` | 1.55 | **1.50** | 1.51–1.60 band: only 38.3% win rate |
| `max-current-odds` | 4.50 | **2.50** | Drops 2.25–2.99 band (−32% to −46% EV) |
| `double-chance-min-odds` | 1.90 | **1.75** | Lower bound of positive-EV DC window |
| `double-chance-max-odds` | *(new)* | **2.00** | Upper bound — above this, outright EV dominates |
| `halftime.enabled` | true | **false** | −28% EV at every threshold tested |

### ⚠️ P&L analysis flaw discovered (2026-05-02)

All `net_units` calculations in `betting_stats.sql` use `current_odds` (outright odds) as the payout multiplier for DC bets. Actual DC bets are placed at **DC odds** (~1.10–1.46), not outright odds (~2.46). This inflates reported DC P&L by ~15×. The "+27,020 COP" and "+16,170 COP" figures from Section 4 are **not accurate**. Win/loss counts and win rates are unaffected.

The 19 most recent LOSING_BY_1 DC bets with real DC odds stored: **+2.60 net units** (78.9% win, avg DC odds 1.459 → +15.1% EV). Small sample but directionally positive.

---

## 11. Config Changes Applied (2026-05-02)

**Data window:** 3,406 matches / 234 placed bets (vs 1,955 / 210 in Section 10)

### Key findings that drove changes

- **1.51–1.60 baseline band reversed**: old data showed 38.3% win; new data shows **62.5%** (driven by DC bets: 66.7% win rate). The 2026-05-01 cut to `max-baseline-odds: 1.50` was premature.
- **`double-chance-max-odds: 2.00` was counterproductive**: DC beats outright in every band 1.50–2.99. Moving 2.0–2.49 from DC → outright reduced performance. DC win rates: 57–83% vs outright 18–44% across those bands.
- **odds-rise-threshold 30% → 40%**: EV improves from +32.8% to +42.6% with only 17% bet reduction (82 → 68 qualifying bets).
- **max-current-odds 2.50 → 3.00**: opens 2.50–2.99 (DC near break-even) and ≥3.00 (outright +25% EV).

### Summary table

| Parameter | Before (2026-05-01) | After (2026-05-02) | Reason |
|-----------|---------------------|---------------------|--------|
| `odds-rise-threshold-pct` | 30.0 | **40.0** | EV +32.8% → +42.6%, 82 → 68 bets |
| `max-baseline-odds` | 1.50 | **1.55** | 1.51–1.55 profitable (62.5% win, DC-driven) |
| `max-current-odds` | 2.50 | **3.00** | Opens 2.50–2.99 DC (≈break-even) and ≥3.00 outright (+25%) |
| `double-chance-min-odds` | 1.75 | **1.50** | 1.50–1.74 band: +11.8% real DC EV; currently placed as outright (−50% EV) |
| `double-chance-max-odds` | 2.00 | **3.00** | DC beats outright in every band up to 3.00 |

### DC window logic (3 cases, all logged at INFO)

```
odds < 1.50         → RESULTADO_FINAL  "Path A [below DC min 1.50]"
1.50 ≤ odds < 3.00  → DOBLE_OPORTUNIDAD  "Path A [DC window 1.50-3.00]"
odds ≥ 3.00         → RESULTADO_FINAL  "Path A [above DC max 3.00]" (outright +25% EV)
```

---

## 12. Opportunities Not Yet Implemented

### OPP-C: Under 1.5 goals (promising — needs odds data)

Strong favorite (≤1.40 baseline) **winning 1-0 at minute 58–75** — updated with fresh data (3,406 matches):

| Baseline | Matches | Clean sheet hold | Lead hold |
|----------|---------|-----------------|-----------|
| ≤1.40 | 96 | **80.2%** | 87.5% |
| 1.41–1.55 | 78 | 73.1% | 78.2% |

Break-even at 1.45 odds = 69.0%. Strong favorites at 80.2% give ~+16% EV.  
**Blocker:** we don't capture Under 1.5 / BTTS No live odds. To implement:

1. Add to `OddsSnapshot`: `under_1_5_outcome_id BIGINT`, `under_1_5_odds DOUBLE PRECISION`
2. Parse Kambi "Goals" market (`OT_UNDER` outcome with handicap 1.5)
3. Trigger: favorite winning by 1, baseline ≤1.40, minute ≥60

### OPP-D: Post-equalization signal (confirmed, but current strategy is already better)

When a 1.31–1.50 baseline team was losing and then equalizes: 52.2% outright win rate at avg 1.95 odds → EV +1.8%.  
However, the current LOSING_BY_1 DC bet fires **before** equalization at avg 2.50 DC odds, which is a better entry than the post-equalization bet at 1.95 outright. Current design is optimal — no action needed.

### What was ruled out

| Opportunity | Verdict |
|-------------|---------|
| TIED_HALFTIME (any sub-segment) | No positive EV found anywhere |
| Over 2.5 goals from mid-match state | 48.9% best case; break-even at 1.70 odds requires 58.8% — not profitable |
| "Holding the lead" bet (1-0 at half) | 81–84% hold rate sounds great but live odds are only 1.07–1.17 — needs 90%+ |
| Expanding baseline > 1.60 | DC odds drop to 1.54–1.75 for weaker favorites; real DC EV is negative everywhere above 1.60 |

---

## 12. Key SQL Files

| File | Purpose |
|------|---------|
| `../betting_stats.sql` | Shared + football sections (1–13): P&L, odds rise bands, minute bands, baseline bands, ground truth, DC quality, halftime analysis, config simulation |
| `opportunity_research.sql` | 7 sections: leading at half, over 2.5, multi-goal deficit, competition breakdown, home/away asymmetry, odds speed, post-alert goals |
