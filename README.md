# SportBets — Soccer Odds Monitor

A Kotlin + Spring Boot background service that tracks pre-match and live odds on [betplay.com.co](https://betplay.com.co), detects when the favorite team's odds spike during a match, and sends alerts to Discord.

---

## How It Works

```
[Betplay API]
      │
      ▼
[Match Sync] ──► stores upcoming soccer matches in PostgreSQL
      │
      ▼
[Pre-Match Odds Capture] ──► stores baseline odds 30 min before kickoff
      │
      ▼
[Live Odds Monitor] ──► polls odds every 45s during the match
      │
      ▼  (if favorite's odds rise ≥ 20%)
[Alert Engine] ──► saves alert to DB ──► Discord webhook notification
```

**The logic:** When the favorite team starts losing, the bookmaker raises their odds (they become less likely to win). That's your window — the odds are now better than they were pre-match.

---

## Prerequisites

- Java 17+
- Gradle 8+
- PostgreSQL running on `localhost:5432`
- A Discord server with a webhook URL

---

## Quick Start

### 1. Database setup
```sql
-- Run in psql or pgAdmin
CREATE DATABASE sportbets;
```

### 2. Generate Gradle wrapper
```bash
gradle wrapper
```

### 3. Configure the app
Create `src/main/resources/application-local.yml` (gitignored — never committed):
```yaml
spring:
  datasource:
    password: "your_postgres_password"

betplay:
  credentials:
    username: "your_betplay_username_or_cedula"
    password: "your_betplay_password"

discord:
  webhook:
    url: "https://discord.com/api/webhooks/..."
  bot:
    token: "your_bot_token"
    channel-id: "your_channel_id"
    mention-id: "your_discord_user_id"
```
All other settings (thresholds, intervals, stake amount) are in `application.yml` and can be tuned there.

### 4. Discover the Betplay API endpoints ⚠️ REQUIRED FIRST
```bash
./gradlew bootRun --args="--spring.profiles.active=discover"
```
A Chrome window will open. Browse to the soccer/football section on betplay.com.co, click on a few matches. After 90 seconds the tool will print all intercepted API URLs and suggest values for `application.yml`. Update `betplay.api.*` with the real endpoints.

### 5. Start Chrome with remote debugging (required for bet placement)
```bash
# macOS
./start-chrome.sh

# Windows
start-chrome.bat
```
Log in to betplay.com.co in the Chrome window that opens. The session is saved, so you only need to do this once per profile. The app uses your logged-in session to place bets automatically.

### 6. Start the monitor
```bash
./gradlew bootRun
```

> **macOS only — prevent sleep from pausing the scheduler:**
> macOS pauses JVM timers when the system sleeps, which can cause the 4-hour match sync to be skipped.
> Use `caffeinate` to keep the system awake for as long as the app is running:
> ```bash
> caffeinate -i ./gradlew bootRun
> ```
> `caffeinate` is built into macOS — no installation needed. It only prevents idle system sleep; your screen can still turn off. This command is not needed on Windows.

---

## Configuration Reference

| Property | Default | Description |
|---|---|---|
| `betplay.monitor.odds-rise-threshold-pct` | `15.0` | Minimum % odds rise to trigger a bet |
| `betplay.monitor.odds-rise-max-pct` | `60.0` | Maximum % rise — above this suggests collapse |
| `betplay.monitor.max-alerts-per-match` | `1` | Max bets placed per match |
| `betplay.monitor.min-match-minute` | `25` | Don't bet before this minute |
| `betplay.monitor.max-match-minute` | `75` | Don't bet after this minute |
| `betplay.monitor.max-baseline-odds` | `1.80` | Only target genuine favorites |
| `betplay.monitor.max-current-odds` | `3.50` | Skip if market has given up on them |
| `betplay.betting.enabled` | `true` | Set to `false` for dry-run (no real bets) |
| `betplay.betting.stake-cop` | `1000` | Stake per bet in Colombian pesos |
| `betplay.betting.cdp-port` | `9222` | Chrome remote debugging port |
| `betplay.scheduler.live-odds-ms` | `45000` | Live odds poll interval (ms) |
| `betplay.scheduler.match-sync-ms` | `14400000` | Match list refresh interval (ms — 4 hours) |
| `discord.webhook.enabled` | `true` | Set to `false` to disable notifications |

---

## Project Structure

```
src/main/kotlin/com/sportbets/
├── SportBetsApplication.kt      Main entry point
├── config/
│   └── AppConfig.kt             Jackson ObjectMapper config
├── model/
│   ├── Match.kt                 JPA entity — soccer match
│   ├── OddsSnapshot.kt          JPA entity — point-in-time odds
│   └── BettingAlert.kt          JPA entity — fired alerts
├── repository/
│   └── Repositories.kt          Spring Data JPA repos
├── service/
│   ├── BetplayApiClient.kt      HTTP client for Betplay
│   ├── MatchSyncService.kt      Fetches & stores matches
│   └── OddsMonitorService.kt    Core alert logic
├── scheduler/
│   └── Schedulers.kt            @Scheduled jobs
├── notification/
│   └── DiscordNotifier.kt       Discord webhook sender
└── discovery/
    └── BetplayApiDiscovery.kt   Playwright API discovery tool
```

---

## After API Discovery

Once you've run the discovery tool and found the real endpoints, update `application.yml`:

```yaml
betplay:
  api:
    base-url: https://betplay.com.co
    events-path: /REAL/ENDPOINT/HERE        # from discovery results
    odds-path: /REAL/ENDPOINT/{eventId}/HERE
    live-path: /REAL/LIVE/ENDPOINT/HERE
```

Then update the JSON field names in:
- `MatchSyncService.kt` → `parseMatch()` method
- `OddsMonitorService.kt` → `parseOdds()` method

Both have clear `⚠️ UPDATE` comments.

---

## Discord Webhook Setup

1. Open Discord → your server
2. Right-click the channel → **Edit Channel**
3. **Integrations** → **Webhooks** → **Create Webhook**
4. Give it a name (e.g. "SportBets Bot")
5. Click **Copy Webhook URL**
6. Paste it into `application.yml` under `discord.webhook.url`

---

## Roadmap

- [ ] Auto-place bets via Betplay (future phase)
- [ ] Telegram bot notifications
- [ ] Web dashboard for odds history
- [ ] Support more sports / markets
- [ ] Backtesting mode on historical odds
