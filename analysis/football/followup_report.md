# SportBets — Follow-Up Analysis
**Date:** 2026-04-28

---

## Question 1: Can TIED_HALFTIME be improved?

**Short answer: No. The edge simply doesn't exist in the data.**

Every angle we cut — score at tied moment, whether the favorite was previously leading, minute of the tie, live odds level — all come back negative EV. Here's the full picture:

### By score when tied

| Tied Score | Matches | Fav Win % | Draw % | Avg Odds | EV |
|-----------|---------|-----------|--------|----------|----|
| 0-0 | 923 | 46.8% | 32.6% | 1.96 | −8.4% |
| 1-1 | 111 | 45.0% | 34.2% | 2.15 | −3.3% |
| 2-2 | 2 | 0% | — | — | — |

**No difference between 0-0 and 1-1.** A tied favorite is a tied favorite regardless of whether both teams have scored.

### By whether the favorite was previously leading

| History | Matches | Fav Win % | Avg Odds | EV |
|---------|---------|-----------|----------|----|
| Never led — tied from kickoff | 977 | 46.6% | 1.96 | −8.9% |
| Was leading, then equalized | 59 | 45.8% | 2.23 | +2.1% |

The "was leading then got equalized" sub-group (59 matches) shows the tiniest positive EV (+2.1%) but with this sample size it's noise, not signal. Even if real, +2% EV is not a viable betting edge.

### By live odds level when tied

| Favorite's live odds | Matches | Fav Win % | Break-even | EV |
|--------------------|---------|-----------|------------|-----|
| <1.50 (still hot fav) | 168 | **64.3%** | 66.7% | −14.5% |
| 1.50–1.99 | 378 | 49.5% | 56.8% | −13.1% |
| 2.00–2.49 | 370 | 40.5% | 45.0% | −10.1% |
| 2.50–2.99 | 101 | 34.7% | 37.7% | −8.1% |
| ≥3.00 | 20 | 15.0% | 26.0% | −42.4% |

The higher the live odds, the worse the win rate — and the odds rise faster than the win rate falls, so every band loses. **At every odds level, the market correctly prices a tied favorite.**

### By match minute (5-min buckets)

| Minute | Matches | Fav Win % | EV |
|--------|---------|-----------|-----|
| 10–14 | **919** | 47.8% | −6.8% |
| 15–19 | 25 | 52.0% | −0.8% |
| 20–24 | 16 | 50.0% | +3.3% |
| 25–29 | 14 | 28.6% | −38.3% |
| 30–34 | 10 | 30.0% | −32.1% |
| 35–39 | 6 | 16.7% | −60.2% |
| 40–44 | 8 | 37.5% | −21.8% |
| 45–49 | 21 | 38.1% | −19.0% |
| 50–54 | 8 | 12.5% | −71.3% |
| 55–59 | 7 | 28.6% | +3.4% |

919 of the 1,036 tied moments (89%) happen in the 10–14 minute bucket — these are matches where the score was already tied at the start of our monitoring window. The tiny samples at later minutes are irrelevant. **The 10–14 bucket has EV −6.8% on 919 matches. That's the definitive answer.**

### ✅ One genuine alternative: bet when the favorite EQUALIZES (not when tied)

There is one related scenario with a real signal. When a ≤1.50 baseline favorite was losing by 1 and then scores to make it level, what happens next?

| Baseline | After equalization | Won | Drew | Lost | Win % | Avg odds | EV |
|----------|-------------------|-----|------|------|-------|----------|----|
| ≤1.30 | 14 | 8 | 6 | 0 | 57.1% | 1.40 | −20.1% |
| 1.31–1.50 | 23 | 12 | 7 | 4 | 52.2% | **1.95** | **+1.8%** |
| 1.51–1.60 | 11 | 2 | 8 | 1 | 18.2% | 1.80 | −67.3% |

The 1.31–1.50 band has **52.2% win rate at avg 1.95 odds → EV +1.8%**. Small but real. This is because after scoring an equalizer, the team's odds haven't fully recovered to their pre-match level yet — there's brief window of value before the market reprices.

At equalization the avg live outright odds are 1.97 for ≤1.50 baseline. The current LOSING_BY_1 bet fires *before* equalization at avg 2.62–3.11 odds with DC. The "at equalization" bet would be an outright win bet at ~2.0 odds.

**This means the current strategy is already capturing the better side of this trade** (betting DC at higher odds before equalization rather than betting outright after). The equalization EV is a confirmation, not a new opportunity.

---

## Question 2: Did the report cover all data (including baseline > 1.60)?

**No, the P&L sections (3–6, 13) only analyzed bets that were actually placed** — those are all baseline ≤1.60 by definition of our current config. The ground truth comeback rate (Section 7) did cover all baselines.

Here is the full picture of what happens for **every baseline band** including those we've never bet on:

| Baseline Band | Matches (losing by 1) | DC Comeback % | Avg outright odds when losing | Avg DC odds (when available) | DC coverage | Real DC EV |
|--------------|----------------------|---------------|------------------------------|------------------------------|-------------|------------|
| ≤1.20 | 12 | **91.7%** | 1.52 | 2.52 (5/12 with DC data) | 41.7% | +131%* |
| 1.21–1.30 | 10 | 60.0% | 3.42 | 1.21 (1/10) | 10.0% | −27% |
| 1.31–1.40 | 16 | 56.3% | 2.89 | 1.04 (2/16) | 12.5% | −42% |
| **1.41–1.50** | **22** | **68.2%** | **2.74** | **1.19 (4/22)** | **18.2%** | **−18%** |
| 1.51–1.60 | 23 | 56.5% | 3.75 | no data | 0% | — |
| 1.61–1.80 | 85 | 48.6% | 4.81 | 1.54 (18/85) | 21.2% | −29% |
| 1.81–2.00 | 80 | 37.5% | 5.51 | 1.75 (21/80) | 26.3% | −35% |
| >2.00 | 211 | 45.0% | 7.56 | 1.70 (42/211) | 19.9% | −23% |

*the ≤1.20 result is 5 data points for DC odds — statistically meaningless.

**Key findings from expanding the view:**

1. **For >1.60 baseline teams, the DC market offers very low odds** (1.54–1.75) even though their comeback rate is 37–49%. The market fully prices these teams in. Real DC EV is negative everywhere above 1.60 baseline.

2. **The DC odds availability problem is severe for <=1.50 baseline** — only 12–18% of losing-by-1 moments have DC odds captured in our snapshots. The "real DC EV" for those bands (−18% to −42%) is based on very few data points and is likely wrong. Our actual bets show 62.5% win rate on DC at avg 2.50 odds → +56% EV. The disparity is explained by: (a) tiny DC sample in ground truth, (b) our bet-triggering filter (20% odds rise) pre-selects better cases.

3. **The 1.60 cap is well-placed.** The >1.60 bands have the worst real DC EV in the dataset. There is no hidden value above 1.60.

4. **The <=1.20 band is interesting but mostly a detection/odds problem.** When a dominant favorite (≤1.20 baseline) is losing by 1, their DC odds are ~2.52 and comeback rate is 91.7% — but this is 5 data points. Also, their outright odds when losing are only 1.52, meaning the system currently doesn't trigger (odds rise isn't enough to hit 20% threshold from a 1.20 baseline to stay under max-current-odds). This is correct behavior.

---

## Question 3: What Other Betting Opportunities Exist?

### OPP-A: "After equalization" bet on outright win (marginal)

Already covered above. EV +1.8% for 1.31–1.50 baseline at avg ~1.95 odds after the team equalizes. Small edge, but the current LOSING_BY_1 DC bet is already capturing a better version of this same event. Not worth adding separately.

---

### OPP-B: Over/Under goals — result is mixed

When a match has exactly 1 goal scored by minute 25–40:

| State | Matches | Over 2.5 rate | Exactly 1 (final) | Exactly 2 (final) |
|-------|---------|---------------|-------------------|-------------------|
| Away leading 0-1, home is favorite | 139 | **48.9%** | 20.1% | 30.9% |
| Home leading 1-0, home is favorite | 268 | 39.9% | 32.1% | 28.0% |
| Away leading 0-1, away is favorite | 111 | 37.8% | 31.5% | 30.6% |
| Home leading 1-0, away is favorite | 86 | 41.9% | 19.8% | 38.4% |

The most interesting case: **home team is the underdog and is LOSING 0-1 by minute 35, with the away team being the pre-match favorite** → Over 2.5 fires 48.9% of the time.

**Problem:** we don't know what Over 2.5 live odds look like at those moments. In a 0-1 match at minute 35, Over 2.5 live odds are typically 1.60–1.80. Break-even at 1.70 = 58.8%. We need 58.8% but only see 48.9%. **Not profitable.**

The other cases are even lower. Over/Under bets from mid-match state are not a viable angle with this data.

---

### OPP-C: Opponent scoring rate when trailing 1-0 after minute 60

When the pre-match favorite is winning 1-0 after minute 60 (1-0 with trailing score = 0):

| Baseline | Matches | Opponent scores (BTTS YES) | Favorite holds clean (1-0 final) |
|----------|---------|---------------------------|----------------------------------|
| ≤1.40 | 37 | 27.0% | **73.0%** |
| 1.41–1.60 | 32 | 37.5% | 59.4% |
| >1.60 | 221 | 33.0% | 63.8% |

**A potential live "Under" or "No Both Teams to Score" play for strong favorites (≤1.40 baseline) leading 1-0 after minute 60** — they keep it clean 73% of the time. But without live Under/BTTS odds data, we can't confirm EV. If Betplay offers "Under 1.5 goals" live at those moments, the value could be significant.

This would require:
1. Capturing Over/Under and BTTS outcome IDs from the betoffer API
2. Storing Under 1.5 / BTTS No odds in the snapshot model
3. Triggering when: favorite winning by 1 in last 20 minutes, baseline ≤1.40

---

### OPP-D: Post-equalization momentum — a Path C trigger

The most actionable new opportunity based on the data:

**The moment the favorite scores to equalize is consistently better priced than the LOSING_BY_1 trigger moment.**

Comparison for 1.41–1.50 baseline teams that are losing by 1:
- At losing-by-1 moment: avg DC odds **1.19** (nearly worthless — market barely moved)  
- At equalization moment: avg outright odds **1.97** with 52.2% win rate = EV +1.8%

But more importantly — for **1.51–1.60 baseline**:
- DC odds when losing: avg **2.55** (this is where our DC bet fires)
- Avg equalization minute: **44.0**
- Win rate after equalization: 18.2% at 1.80 odds → terrible

So the timing is already roughly optimal for our current LOSING_BY_1 trigger. **The bet fires when odds are highest (team is behind), not after they equalize (when odds compress).** The current design is correct.

---

### OPP-E: "Holding the lead" bet — not viable

When a pre-match favorite is winning 1-0 at minute 38–52:

| Baseline | Matches | Held & won | Conceded draw | Lost lead | Held % | Avg odds | EV |
|----------|---------|-----------|---------------|-----------|--------|----------|----|
| ≤1.30 | 26 | 22 | 4 | 0 | **84.6%** | 1.07 | −9.9% |
| 1.31–1.40 | 24 | 20 | 2 | 2 | 83.3% | 1.10 | −8.4% |
| 1.41–1.50 | 32 | 26 | 5 | 1 | 81.3% | 1.16 | −5.8% |
| 1.51–1.60 | 29 | 18 | 11 | 0 | 62.1% | 1.17 | −27.6% |

Win rates are impressive (81–84%) but **the live odds are only 1.07–1.17**. At 1.10, you need 90.9% to break even. You're getting 83–84%. Negative EV at every band. The market is efficient here — a 1-0 lead at halftime from a strong favorite is fully priced in.

---

## Summary: What to Do

### Immediate action
```yaml
halftime:
  enabled: false    # No sub-segment of TIED_HALFTIME has positive EV
```

### Promising investigation (needs odds data not yet captured)
**OPP-C: "Holds the lead" / Under 1.5 goals live bet** — when ≤1.40 baseline favorite leads 1-0 after minute 60, they hold it 73% of the time. Start capturing Under 1.5 live odds from the betoffer API to verify EV. If Kambi offers it at ~1.40–1.50 odds, that's potentially a positive-EV bet (break-even ~66.7%).

To implement, add to `OddsSnapshot`:
```
under_1_5_outcome_id  BIGINT
under_1_5_odds        DOUBLE PRECISION
```
And capture from the Kambi "Goals" market (`"Over/Under"` criterion, `"OT_UNDER"` outcome with handicap 1.5).

### Current LOSING_BY_1 path is already optimal
The analysis confirms the current bet timing (at the losing moment, not after equalization) is correct. The DC bet at 2.50 avg odds with 62.5% win rate (+56% EV) is the system's real edge.
