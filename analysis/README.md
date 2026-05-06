# SportBets — Analysis

## Folder structure

```
analysis/
├── betting_stats.sql          # Shared — Sections 1–3 all sports; 4–13 football; 14–15 basketball
├── README.md                  # This file
│
├── football/
│   ├── findings.md            # Config decisions and EV analysis (football)
│   ├── report.md              # P&L report generated 2026-04-28
│   ├── followup_report.md     # TIED_HALFTIME deep dive + opportunity research notes
│   └── opportunity_research.sql  # Exploratory queries for new football betting paths
│
└── basketball/
    └── findings.md            # Strategy overview and parameters to evaluate (basketball)
```

Shared files (root) are sport-agnostic or span both sports.
Sport-specific files live under their folder and should only query `m.sport = 'FOOTBALL'` or `m.sport = 'BASKETBALL'` respectively.

---

## betting_stats.sql — Section Guide

Run each section independently. Sections 1–3 work across all sports; 4–13 are football-only; 14–15 are basketball-only.

### Shared (all sports)

| Section | Question answered |
|---------|-------------------|
| **1 — Data Snapshot** | How many matches, snapshots, and alerts per sport? |
| **2 — Bet Outcome Per Alert** | Did each bet win or lose? (raw table, includes `sport` column) |
| **3 — P&L Summary** | Win rate and net COP grouped by sport → scenario → market |

### Football (Sections 4–13)

| Section | Question answered |
|---------|-------------------|
| **4 — Odds Rise Bands** | Do bets with higher rise % perform better? → tune `odds-rise-threshold-pct` |
| **5 — Minute Bands** | Which match minute windows have best win rate? → tune `min/max-match-minute` |
| **6 — Baseline Odds Bands** | Do very strong favorites (≤1.40) recover more? → tune `max-baseline-odds` |
| **7 — Comeback Rate** | Ground truth: of ALL times a favorite was losing by 1, how often did they recover? |
| **8 — Near-Misses** | Matches where conditions were close but no alert fired — were they comebacks? |
| **9 — DC Data Quality** | How complete is the Double Chance odds/ID coverage? |
| **10 — Halftime Path** | Is the TIED_HALFTIME path (Path B) worth keeping? |
| **11 — Odds Drift Timeline** | Odds before and after each alert — are we catching the move early enough? |
| **12 — Untapped Opportunities** | Finished matches with comebacks we never bet on (false negatives) |
| **13 — Config Tuning Cheat Sheet** | Simulates different `odds-rise-threshold-pct` and `max-baseline-odds` values |

### Basketball (Sections 14–15)

| Section | Question answered |
|---------|-------------------|
| **14 — Basketball P&L by Period + Deficit** | Win rate and net units grouped by period (Q3/Q4/HT) and point-deficit band |
| **15 — Basketball Comeback Rate** | Ground truth: of ALL times a basketball favorite was trailing in a monitored period, how often did they win? |

### Key metric: `expected_value_pct` (Section 13A / future basketball equivalent)
```
EV% = (win_rate / 100 * avg_odds - 1) * 100
```
Positive EV% = profitable long-term. Use this to pick the threshold that maximises EV, not just win rate.

---

## football/opportunity_research.sql — Section Guide

Exploratory queries for new football betting paths. Require ≥20 matches per cell to be meaningful.

| Section | Potential new path |
|---------|-------------------|
| **OPP-1 — Leading Favorite Stability** | Bet on a leading favorite to hold their halftime lead |
| **OPP-2 — Over 2.5 Goals** | Early goal + open game → more goals likely |
| **OPP-3 — Multi-Goal Deficit** | Is losing by 2 ever recoverable at a good price? |
| **OPP-4 — Competition Breakdown** | Which leagues have the best comeback rates? |
| **OPP-5 — Home vs Away Asymmetry** | Are away favorites worse comeback candidates? |
| **OPP-6 — Odds Speed** | How fast do odds move after a goal? Are we too slow? |
| **OPP-7 — Post-Alert Goals** | After our alert fires, how many goals does the favorite actually score? |

---

## How outcomes are determined

### Football
- `LOSING_BY_1` + `current_odds >= 2.0` → **DOBLE_OPORTUNIDAD**: HOME = 1X (win or draw), AWAY = X2 (draw or win)
- All other football scenarios → **RESULTADO_FINAL** (outright win)

### Basketball
- `BASKETBALL_COMEBACK` → **PRORROGA_INCLUIDA** (outright win including OT, no draw):
  HOME wins if `final_home_score > final_away_score`, AWAY wins if `final_away_score > final_home_score`

Rows where `final_home_score IS NULL` = match still in progress or score not captured → shown as `PENDING`.
