# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
./gradlew build

# Run the service (normal mode)
caffeinate -i ./gradlew bootRun          # macOS — caffeinate prevents JVM timer pauses on sleep

# Dry-run mode (no bets placed, just logs)
# Set betplay.betting.enabled=false in application-local.yml, then:
./gradlew bootRun

# API discovery (Playwright opens Chrome — browse Betplay to capture real API endpoints)
./gradlew bootRun --args="--spring.profiles.active=discover"

# Sports discovery (HTTP sweep — finds all sports active on BetPlay's Kambi offering, no browser needed)
./gradlew bootRun --args="--spring.profiles.active=discover-sports"
# Output: console table + sports-discovery.txt with event counts, competition names, and ready-to-use API paths

# Sport offers inspector (dumps liveData structure, all bet offer types, and outcome labels for any sport)
./gradlew bootRun --args="--spring.profiles.active=inspect-sport --sport=basketball"
# Output: console + sport-inspect-{sport}.txt — use this before implementing a new sport strategy

# Test browser automation on a live match without triggering odds logic
./gradlew bootRun --args="--spring.profiles.active=test-browser-bet"
./gradlew bootRun --args="--spring.profiles.active=test-browser-bet --external-id=1027380893 --side=HOME"

# Test DC bet placement specifically
./gradlew bootRun --args="--spring.profiles.active=test-doble-oportunidad"

# Test basketball bet placement (Prórroga incluida market)
./gradlew bootRun --args="--spring.profiles.active=test-browser-bet-basketball"
./gradlew bootRun --args="--spring.profiles.active=test-browser-bet-basketball --external-id=1027380893 --side=HOME"

# Run tests
./gradlew test

# Start Chrome with CDP remote debugging (required before running with betting enabled)
./start-chrome.sh    # macOS
```

## Architecture

This is a **pure background service** (no HTTP server). All work is driven by Spring `@Scheduled` tasks.

### Scheduler → Service flow

```
Schedulers (every N ms)
  ├─ syncMatches()          → MatchSyncService.syncUpcomingMatches()
  ├─ syncLiveStatus()       → MatchSyncService.markStartedMatchesAsLive()
  │                         → MatchSyncService.syncLiveMatchStatuses()
  ├─ capturePreMatchOdds()  → OddsMonitorService.capturePreMatchOdds()
  ├─ monitorLiveOdds()      → OddsMonitorService.monitorLiveOdds()
  └─ sendDiscordAlerts()    → DiscordNotifier.sendPendingAlerts()
```

### Bet placement chain

`OddsMonitorService` fires → `BetPlacerService` (dry-run gate) → `BrowserBetPlacerService` (Playwright CDP)

`BetPlacerService` is the only gate for `betplay.betting.enabled`. If false, it returns `BetResult.DryRun` immediately and `BrowserBetPlacerService` is never called.

### Data flow for a live match

1. `OddsMonitorService.monitorLiveOdds()` calls `apiClient.fetchLiveMatches()` once — gets all live events in one request (odds + score + minute).
2. For each LIVE match in DB, `processLiveMatch()` is called with the event's JSON wrapper.
3. `captureOddsSnapshot()` saves an `OddsSnapshot`. For live matches, Double Chance odds are fetched from the separate betoffer endpoint and cached per-match (default 3-min TTL in `dcCache`).
4. `checkAndFireAlert()` compares the current snapshot against the pre-match baseline (`isPreMatch=true`). If no pre-match baseline exists, the first live snapshot is saved as baseline and the cycle is skipped.
5. If conditions are met, a bet is placed and a `BettingAlert` is saved with `notified=false`.
6. `DiscordNotifier` drains the `notified=false` queue every 30s.

### Betting strategy (current active config)

**Path A — LOSING_BY_1**: favorite is losing by exactly 1 goal, odds rose ≥40% from baseline, minute 1–80, baseline odds ≤1.55, current odds ≤3.00.

Market selection within Path A is a bounded DC window:
- `currentOdds < 1.50` → RESULTADO_FINAL (outright win — rare, team still heavy favorite)
- `1.50 ≤ currentOdds < 3.00` → DOBLE_OPORTUNIDAD (1X or X2 Double Chance)
- `currentOdds ≥ 3.00` → RESULTADO_FINAL (outright win — market assigns +25% EV here)

**Path B — TIED_HALFTIME**: disabled (`halftime.enabled: false`). EV analysis across 1,036 matched moments showed −28% EV at every sub-segment; no configuration produced positive EV.

### Kambi API notes

- Base URL: `https://na-offering-api.kambicdn.net`
- Odds are returned in **milliunits** — divide by 1000 for decimal odds (e.g. 1850 → 1.85)
- Outcome types: `OT_ONE` (home), `OT_CROSS` (draw), `OT_TWO` (away)
- Double Chance outcome types: `OT_ONE_X` (1X), `OT_X_TWO` (X2) — also seen as `OT_HOME_DRAW`, `OT_ONE_OR_CROSS`, etc.
- `fetchLiveMatches()` returns `{events: [{event, betOffers, liveData}]}` — liveData has score and matchClock
- `fetchOdds(eventId)` returns `{betOffers: [...]}` — used for pre-match baseline and DC odds refresh
- A 404 from either endpoint means the match no longer exists; the app marks it FINISHED

### Database

PostgreSQL with Flyway migrations (V1–V10 in `src/main/resources/db/migration/`). Schema is validated by Hibernate at startup (`ddl-auto: validate`). Add new columns via new migration files — never modify existing ones.

Key DB invariant: each match should have at most one `isPreMatch=true` snapshot. If the app restarts after kickoff without having captured a pre-match snapshot, the first live snapshot is saved with `isPreMatch=true` as a fallback baseline.

### Spring profiles

| Profile | Purpose |
|---|---|
| *(none)* | Normal monitoring mode |
| `discover` | Playwright opens Chrome to intercept and print real Betplay API endpoints |
| `discover-sports` | HTTP sweep of Kambi sport slugs — prints which sports are active on BetPlay with event counts and ready-to-use API paths |
| `inspect-sport` | Dumps liveData structure, all bet offer criterion labels, and outcome types for a given sport (`--sport=basketball`) |
| `test-browser-bet` | Tests Playwright bet automation on a live soccer match (bypasses odds logic) |
| `test-browser-bet-basketball` | Tests Playwright bet automation on a live basketball match (Prórroga incluida market) |
| `test-doble-oportunidad` | Tests DC bet placement specifically |
| `auth` | (excluded from Schedulers via `@Profile("!auth & !discover")`) |

### Configuration

Secrets go in `src/main/resources/application-local.yml` (gitignored). All thresholds and intervals are in `application.yml`. The analysis behind every threshold value is documented in `analysis/findings.md`.

### Browser automation (BrowserBetPlacerService)

Connects to a running Chrome instance via CDP (`localhost:9222`). Chrome must be started with `./start-chrome.sh` first using a dedicated debug profile (`~/Library/Application Support/Google/ChromeDebug`).

Key implementation details:
- The service uses `BrowserLock` (a singleton mutex) so concurrent scheduler ticks never race to place bets simultaneously.
- Login is checked on every bet attempt; Betplay uses a time-sensitive CAPTCHA token in the login button's CSS class, so a fresh page navigation is always performed before submitting credentials.
- Cookies and localStorage are cleared every 12 hours to reset accumulated fraud-detection flags.
- After clicking the outcome, betslip odds are compared to trigger odds; if drift exceeds `max-odds-deviation-pct` (default 15%), the bet is cancelled and returns `BetResult.Skipped`.
- Screenshots are saved to `logs/bet-browser-<timestamp>-<eventId>-<step>.png` at each step for debugging.

### Analysis

`analysis/` contains SQL queries and findings from backtesting against real match data. `findings.md` is the source of truth for why each config parameter is set to its current value — consult it before changing thresholds.
