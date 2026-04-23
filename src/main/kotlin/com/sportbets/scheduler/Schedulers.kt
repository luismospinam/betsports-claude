package com.sportbets.scheduler

import com.sportbets.notification.DiscordNotifier
import com.sportbets.service.MatchSyncService
import com.sportbets.service.OddsMonitorService
import org.slf4j.LoggerFactory
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

/**
 * All scheduled tasks.
 *
 * Intervals are configurable via application.yml (betplay.scheduler.*).
 * Defaults:
 *   - matchSync     : every 4 hours
 *   - liveSync      : every 60 seconds (updates match statuses to LIVE)
 *   - preMatchOdds  : every 5 minutes (captures baseline odds)
 *   - liveOdds      : every 45 seconds (monitors live match odds)
 *   - discordAlerts : every 30 seconds (drains alert queue to Discord)
 */
@Component
class Schedulers(
    private val matchSyncService: MatchSyncService,
    private val oddsMonitorService: OddsMonitorService,
    private val discordNotifier: DiscordNotifier,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    /** Sync upcoming matches from Betplay (every 4 hours) */
    @Scheduled(fixedRateString = "\${betplay.scheduler.match-sync-ms:14400000}")
    fun syncMatches() {
        log.info("=== Scheduled: Match Sync ===")
        matchSyncService.syncUpcomingMatches()
    }

    /** Promote matches past kickoff time to LIVE and check live API (every 60s) */
    @Scheduled(fixedRateString = "\${betplay.scheduler.live-sync-ms:60000}")
    fun syncLiveStatus() {
        matchSyncService.markStartedMatchesAsLive()
        matchSyncService.syncLiveMatchStatuses()
    }

    /** Capture pre-match baseline odds for matches starting within 30 min (every 5 min) */
    @Scheduled(fixedRateString = "\${betplay.scheduler.pre-match-odds-ms:300000}")
    fun capturePreMatchOdds() {
        log.info("=== Scheduled: Pre-Match Odds Capture ===")
        oddsMonitorService.capturePreMatchOdds()
    }

    /** Poll live match odds and check for betting opportunities (every 45s) */
    @Scheduled(fixedRateString = "\${betplay.scheduler.live-odds-ms:45000}")
    fun monitorLiveOdds() {
        log.info("=== Scheduled: Live Odds Monitor ===")
        oddsMonitorService.monitorLiveOdds()
    }

    /** Send queued Discord alerts (every 30s) */
    @Scheduled(fixedRateString = "\${betplay.scheduler.discord-send-ms:30000}")
    fun sendDiscordAlerts() {
        discordNotifier.sendPendingAlerts()
    }
}
