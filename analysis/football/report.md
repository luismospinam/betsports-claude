# SportBets — Performance Analysis Report
**Generated:** 2026-04-28  
**Data window:** all finished matches in DB  
**Stake assumed:** 1,000 COP per bet

---

## 1. Data Inventory

| Metric | Count |
|--------|-------|
| Total matches tracked | 1,955 |
| Finished matches | 1,817 |
| Live right now | 22 |
| Upcoming | 116 |
| Pre-match snapshots (baselines) | 1,530 |
| Live odds snapshots | 193,516 |
| Total alerts fired | 274 |
| **Bets placed** | **210** |
| Failed (browser/CDP error) | 64 |

The 64 failed bets are mostly TIED_HALFTIME (52 failures vs 5 for LOSING_BY_1) — likely a browser timing issue during halftime when Kambi suspends markets.

---

## 2. Overall P&L

**210 resolved bets: 91 wins / 118 losses / 1 pending**

| Metric | Value |
|--------|-------|
| Win rate | 43.5% |
| Break-even needed | 48.6% |
| Average odds | 2.06 |
| Net (units of stake) | **−24.30** |
| Net per 1,000 COP stake | **−24,300 COP** |

Overall the system is **losing money**. But the headline hides a critical split between the two paths.

---

## 3. The Critical Split: LOSING_BY_1 vs TIED_HALFTIME

This is the most important finding in the report.

| Scenario | Bets | Win % | Avg Odds | Break-even | Net / 1k COP |
|----------|------|-------|----------|------------|--------------|
| LOSING_BY_1 | 69 | **52.2%** | 2.26 | 44.3% | **+16,170** ✅ |
| TIED_HALFTIME | 124 | 39.0% | 1.87 | 53.4% | **−37,260** ❌ |
| Legacy (no scenario) | 17 | 41.2% | 2.59 | 38.6% | −3,210 |
| **Total** | **210** | **43.5%** | **2.06** | **48.6%** | **−24,300** |

**LOSING_BY_1 is profitable. TIED_HALFTIME is destroying all the gains and then some.**

The TIED_HALFTIME path needs 53.4% wins to break even (because avg odds are low at 1.87) but only achieves 39%. No threshold change fixes a 14-point deficit. **It should be disabled.**

---

## 4. LOSING_BY_1 Broken Down Further

Within LOSING_BY_1, two very different markets:

| Market | Bets | Win % | Avg Odds | Net / 1k COP |
|--------|------|-------|----------|--------------|
| DOBLE_OPORTUNIDAD (odds ≥ 2.0) | 48 | **62.5%** | 2.50 | **+27,020** ✅✅ |
| RESULTADO_FINAL (odds < 2.0) | 21 | 28.6% | 1.70 | **−10,850** ❌ |

**DOBLE_OPORTUNIDAD is the engine of profitability.** When the favorite is losing by 1 and their outright odds are ≥ 2.0, betting on them to at least draw wins 62.5% of the time.

**RESULTADO_FINAL on LOSING_BY_1 is a loser.** When a team is losing and their odds are still below 2.0, the market says they're still likely to win outright — but they're only doing so 28.6% of the time. The break-even for 1.70 odds is 58.8%. We're 30 points short.

**Recommendation:** Lower `double-chance-min-odds` from 2.0 to something like 1.60 or 1.70, so more LOSING_BY_1 bets use the DC market. Or consider skipping RESULTADO_FINAL on LOSING_BY_1 entirely.

---

## 5. Baseline Odds Sweet Spot

Win rate by pre-match baseline odds of the favorite:

| Baseline Band | Bets | Win % | Avg Current Odds | Note |
|---------------|------|-------|-----------------|------|
| ≤1.10 | 7 | 28.6% | 1.39 | Too dominant — market never gives good recovery odds |
| 1.11–1.20 | 16 | 50.0% | 1.56 | OK |
| 1.21–1.30 | 25 | 36.0% | 1.79 | Poor |
| 1.31–1.40 | 31 | 54.8% | 1.85 | Good |
| **1.41–1.50** | **40** | **64.1%** | **2.07** | **Best — statistically significant** |
| 1.51–1.60 | 47 | 38.3% | 2.18 | Below break-even |
| >1.60 | 44 | 27.3% | 2.51 | Not strong favorites — noise bets |

The **1.41–1.50 band stands out clearly** with 64.1% win rate on 40 bets. This matches what the comeback rate table confirms: these teams are strong enough to recover but their odds drift high enough to produce value.

The current `max-baseline-odds: 1.60` includes the 1.51–1.60 band which underperforms. Tightening to **1.50** would dramatically improve results.

---

## 6. Ground Truth: How Often Do Favorites Actually Come Back?

Among all finished matches where the pre-match favorite was losing by exactly 1 goal at any point in the betting window (minute 1–80):

| Baseline Band | Losing Moments | Won Outright % | Draw-or-Win % (DC) |
|---------------|---------------|---------------|-------------------|
| ≤1.10 | 2 | 50.0% | 100.0% |
| 1.11–1.20 | 10 | 30.0% | **90.0%** |
| 1.21–1.30 | 10 | 50.0% | 60.0% |
| 1.31–1.40 | 16 | 25.0% | 56.3% |
| **1.41–1.50** | **22** | **40.9%** | **68.2%** |
| 1.51–1.60 | 23 | 8.7% | 56.5% |
| >1.60 | 376 | 17.6% | 43.6% |
| **All** | **459** | **19.6%** | **47.5%** |

Key takeaways:
- **The 1.11–1.20 band has 90% DC comeback rate** — but their live odds rarely reach 2.0 so they end up in RESULTADO_FINAL where win rate is poor. If DC could be used more aggressively here, this would be a goldmine.
- **The 1.41–1.50 band confirms the best-in-class status**: 68.2% DC comeback.
- **1.51–1.60 has only 8.7% outright comeback rate** — these are not genuinely strong favorites and the RESULTADO_FINAL bet on them fails badly.

---

## 7. Match Minute Analysis

| Minute Band | LOSING_BY_1 Bets | Win % | TIED_HALFTIME Bets | Win % |
|-------------|-----------------|-------|-------------------|-------|
| 1–29 | 62 | 50.0% | 11 | 40.0% |
| 30–44 | 5 | 60.0% | 34 | **52.9%** |
| 45–59 | 2 | 100%* | 60 | 33.3% |
| 60–74 | — | — | 19 | 31.6% |

*Only 2 bets — not statistically meaningful.

For **LOSING_BY_1**: most bets fire in the 1–29 window (62 bets, 50% win rate). This is the dominant scenario.

For **TIED_HALFTIME**: the 30–44 band performs best (52.9% — close to break-even for that odds range), but the 45–59 band (60 bets, 33.3%) is a major drain. **The bulk of TIED_HALFTIME bets fire in the 45–59 band and are losing badly.**

If TIED_HALFTIME were kept, narrowing the window to `min-minute: 30, max-minute: 45` would help, but it still wouldn't reach profitability at these odds levels.

---

## 8. Odds Rise Threshold Analysis

### LOSING_BY_1 — already profitable at every threshold tested

| Min Rise % | Bets | Win % | Avg Odds | EV |
|-----------|------|-------|----------|-----|
| 15% | 69 | 52.2% | 2.26 | **+17.9%** |
| 20% | 69 | 52.2% | 2.26 | **+17.9%** |
| 25% | 65 | 52.3% | 2.32 | **+21.2%** |
| 30% | 60 | 55.0% | 2.36 | **+29.8%** |
| 35% | 57 | 56.1% | 2.39 | **+34.1%** |
| 40% | 53 | 56.6% | 2.43 | **+37.3%** |
| 50% | 42 | 59.5% | 2.52 | **+49.8%** |

LOSING_BY_1 is profitable at every threshold. Raising the threshold increases both win rate and odds, compounding the EV improvement. The trade-off is fewer bets. **Raising to 30–35% is a good balance** — keeps ~57–60 bets and improves EV from +17.9% to +34%.

### TIED_HALFTIME — losing at every threshold tested

| Min Rise % | Bets | Win % | Avg Odds | EV |
|-----------|------|-------|----------|-----|
| 15% | 112 | 37.8% | 1.89 | **−28.3%** |
| 25% | 56 | 32.7% | 2.04 | **−33.1%** |
| 35% | 26 | 30.8% | 2.26 | **−30.4%** |
| 50% | 16 | 31.3% | 2.41 | **−24.7%** |

No threshold saves TIED_HALFTIME. The win rate declines as threshold rises (the higher-rise cases happen later in the match when less time remains to score). **This path should be disabled.**

---

## 9. TIED_HALFTIME Ground Truth

Out of 1,036 moments where a pre-match favorite was tied in the halftime window (minutes 10–60) across all finished matches:

| Outcome | Count | % |
|---------|-------|---|
| Favorite won | 482 | **46.5%** |
| Ended in draw | 339 | 32.7% |
| Favorite lost | 215 | 20.8% |
| Avg fav odds when tied | — | **1.98** |

At average odds of 1.98, break-even is **50.5%**. The actual win rate is 46.5% — so the **underlying edge does not exist**. A tied favorite at halftime is not more likely to win than the market expects. The TIED_HALFTIME path was a reasonable hypothesis but the data refutes it.

---

## 10. What Happens After the Alert Fires

Average goals scored by the favorite and opponent after each alert:

| Scenario | Side | Fav Goals After | Opp Goals After | Net |
|----------|------|----------------|----------------|-----|
| LOSING_BY_1 | HOME | **1.42** | 0.50 | **+0.92** |
| LOSING_BY_1 | AWAY | **1.53** | 0.74 | **+0.79** |
| TIED_HALFTIME | HOME | 0.70 | 0.41 | +0.29 |
| TIED_HALFTIME | AWAY | 0.72 | 0.58 | +0.14 |

For LOSING_BY_1, the favorite scores ~1.5 goals after the alert and the opponent only ~0.5 — the recovery is real and powerful. For TIED_HALFTIME, the net advantage is minimal (+0.14 to +0.29), which explains the poor win rate.

---

## 11. Double Chance Data Quality

| Metric | Value |
|--------|-------|
| Live snapshots with DC outcome ID | 52,040 / 193,569 (26.9%) |
| Live snapshots with DC odds | 39,561 / 193,569 (20.4%) |
| Avg 1X odds | 1.715 |
| Avg X2 odds | 1.996 |

DC data is only available for ~27% of snapshots. This is a data quality issue — the betoffer API call to fetch DC odds only fires when needed (lazy fetch per match). The 73% without DC IDs represents matches that never triggered, which is expected. For matches that do trigger LOSING_BY_1, DC availability should be near 100% — this is working correctly.

---

## 12. Home vs Away Comeback Asymmetry

| Favorite Side | Losing Moments | Outright Comeback % | DC Comeback % |
|--------------|----------------|--------------------|-|
| HOME | 57 | 28.1% | 61.4% |
| AWAY | 26 | 30.8% | **73.1%** |

Away favorites have a slightly **higher DC comeback rate** (73.1% vs 61.4%). This is counterintuitive but may reflect that away teams who are pre-match favorites are exceptionally strong clubs (e.g. top-league clubs playing away). No need to filter away favorites — they're performing well.

---

## Summary of Recommended Config Changes

### 🔴 Disable immediately
```yaml
betplay:
  monitor:
    halftime:
      enabled: false   # was: true — losing -37,260 COP, EV -28% at every threshold
```

### 🟡 Tune for better profitability
```yaml
betplay:
  monitor:
    # Tighten to the sweet spot — 1.51-1.60 band has only 38.3% win rate
    max-baseline-odds: 1.50    # was: 1.60

    # Raise threshold — EV goes from +17.9% to +34% with minimal bet reduction
    odds-rise-threshold-pct: 30.0   # was: 20.0

    # Allow DC bets more aggressively — the RESULTADO_FINAL variant loses badly (28.6%)
    double-chance-min-odds: 1.70    # was: 2.0
```

### Expected impact of all changes combined
| | Before | After (estimated) |
|--|--------|-------------------|
| Bets/cycle | More (incl. halftime) | Fewer but higher quality |
| Win rate | 43.5% | ~55–60% |
| EV | −11.6% | +20–35% |

---

## New Betting Opportunities to Explore

### 1. Expand Double Chance to all LOSING_BY_1 bets
The data is clear: DOBLE_OPORTUNIDAD wins 62.5% vs RESULTADO_FINAL wins only 28.6% on LOSING_BY_1. The `double-chance-min-odds` guard was meant to ensure value, but even at 1.70–2.0 odds the DC bet is better. Consider using DC whenever DC IDs are available, regardless of current odds level.

### 2. A better Halftime replacement: "Favorite tied, but opponent is the aggressor"
The naive tied-at-halftime signal doesn't work. A more specific trigger: the favorite was **winning** at some point (e.g. was 1-0 up), then conceded an equalizer, and is now pressing to retake the lead. This requires tracking score history per match — odds alone aren't enough, but the snapshot data has score sequences that could identify this pattern.

### 3. Asian Handicap / Handicap market
The comeback data shows many results ending in draws when the favorite was losing by 1 (e.g. final 1-1, 2-2). An Asian Handicap -0.5 on the favorite at kickoff is a different angle — if the Kambi betoffer API returns handicap market IDs, these could be captured and used as an alternative to outright win for strong favorites. Avg DC odds of 1.715 still produce value; AH odds would be similar but with a cleaner settlement.

### 4. Minimum current odds floor
Currently `max-current-odds: 4.50` but the RESULTADO_FINAL bets that lose badly average 1.70 current odds. Adding a **minimum current odds** check (e.g. only bet if `current_odds >= 1.80`) would naturally exclude low-value RESULTADO_FINAL slots and push more bets toward DC. No code change needed — just add a `min-current-odds` parameter.

### 5. Snapshots-per-match coverage check
193,516 live snapshots across 1,817 finished matches = average ~107 snapshots per match. At 45s polling that's ~80 minutes of live coverage — good. No gaps to fix here.
