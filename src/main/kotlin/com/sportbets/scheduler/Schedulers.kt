package com.sportbets.scheduler

import com.sportbets.notification.DiscordNotifier
import com.sportbets.service.BasketballOddsMonitorService
import com.sportbets.service.MatchSyncService
import com.sportbets.service.OddsMonitorService
import org.slf4j.LoggerFactory
import org.springframework.context.annotation.Profile
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
@Profile("!auth & !discover & !discover-sports & !inspect-sport & !test-browser-bet & !test-browser-bet-basketball & !test-doble-oportunidad")
class Schedulers(
    private val matchSyncService: MatchSyncService,
    private val oddsMonitorService: OddsMonitorService,
    private val basketballOddsMonitorService: BasketballOddsMonitorService,
    private val discordNotifier: DiscordNotifier,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    // -------------------------------------------------------------------------
    // Football
    // -------------------------------------------------------------------------

    @Scheduled(fixedRateString = "\${betplay.scheduler.match-sync-ms:14400000}")
    fun syncMatches() {
        log.info("=== Scheduled: Football Match Sync ===")
        matchSyncService.syncUpcomingMatches()
    }

    @Scheduled(fixedRateString = "\${betplay.scheduler.live-sync-ms:60000}")
    fun syncLiveStatus() {
        matchSyncService.markStartedMatchesAsLive("FOOTBALL")
        matchSyncService.syncLiveMatchStatuses()
    }

    @Scheduled(fixedRateString = "\${betplay.scheduler.pre-match-odds-ms:300000}")
    fun capturePreMatchOdds() {
        log.info("=== Scheduled: Football Pre-Match Odds ===")
        oddsMonitorService.capturePreMatchOdds()
    }

    @Scheduled(fixedRateString = "\${betplay.scheduler.live-odds-ms:45000}")
    fun monitorLiveOdds() {
        log.info("=== Scheduled: Football Live Odds ===")
        oddsMonitorService.monitorLiveOdds()
    }

    // -------------------------------------------------------------------------
    // Basketball
    // -------------------------------------------------------------------------

    @Scheduled(fixedRateString = "\${betplay.basketball.scheduler.match-sync-ms:14400000}")
    fun syncBasketballMatches() {
        log.info("=== Scheduled: Basketball Match Sync ===")
        matchSyncService.syncUpcomingBasketballMatches()
    }

    @Scheduled(fixedRateString = "\${betplay.basketball.scheduler.live-sync-ms:60000}")
    fun syncBasketballLiveStatus() {
        matchSyncService.markStartedMatchesAsLive("BASKETBALL")
        matchSyncService.syncLiveBasketballStatuses()
    }

    @Scheduled(fixedRateString = "\${betplay.basketball.scheduler.pre-match-odds-ms:300000}")
    fun captureBasketballPreMatchOdds() {
        log.info("=== Scheduled: Basketball Pre-Match Odds ===")
        basketballOddsMonitorService.capturePreMatchOdds()
    }

    @Scheduled(fixedRateString = "\${betplay.basketball.scheduler.live-odds-ms:45000}")
    fun monitorBasketballLiveOdds() {
        log.info("=== Scheduled: Basketball Live Odds ===")
        basketballOddsMonitorService.monitorLiveOdds()
    }

    // -------------------------------------------------------------------------
    // Shared
    // -------------------------------------------------------------------------

    @Scheduled(fixedRateString = "\${betplay.scheduler.discord-send-ms:30000}")
    fun sendDiscordAlerts() {
        discordNotifier.sendPendingAlerts()
    }
}
