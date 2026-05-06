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
