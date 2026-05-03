package com.sportbets.auth

import com.sportbets.model.MatchStatus
import com.sportbets.repository.MatchRepository
import com.sportbets.repository.OddsSnapshotRepository
import com.sportbets.service.BrowserBetPlacerService
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

/**
 * Manually triggers browser-based bet placement on a real live basketball match.
 * Bypasses the odds-rise check — use this to verify the "Prórroga incluida" section
 * and HOME/AWAY outcome selection work correctly in the Betplay UI.
 *
 * Run with:
 *   ./gradlew bootRun --args="--spring.profiles.active=test-browser-bet-basketball"
 *
 * Optional args:
 *   --external-id=1027380893   target a specific match by its Kambi event ID
 *   --side=HOME                which outcome to click: HOME or AWAY (default: HOME)
 */
@Component
@Profile("test-browser-bet-basketball")
class TestBrowserBetBasketballRunner(
    private val matchRepository: MatchRepository,
    private val oddsSnapshotRepository: OddsSnapshotRepository,
    private val browserBetPlacer: BrowserBetPlacerService,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    override fun run(args: ApplicationArguments) {
        log.info("=== BROWSER BET TEST — BASKETBALL ===")

        val externalIdArg = args.getOptionValues("external-id")?.firstOrNull()
        val side = args.getOptionValues("side")?.firstOrNull()?.uppercase() ?: "HOME"

        val match = if (externalIdArg != null) {
            matchRepository.findByExternalId(externalIdArg)
                ?: run { log.error("No match found with external-id={}", externalIdArg); return }
        } else {
            val liveMatches = matchRepository.findByStatusAndSport(MatchStatus.LIVE, "BASKETBALL")
            if (liveMatches.isEmpty()) {
                log.error("No LIVE basketball matches in DB. Sync matches first or pass --external-id.")
                return
            }
            log.info("Available LIVE basketball matches:")
            liveMatches.forEach { log.info("  [{}] {} vs {} (externalId={})", it.id, it.homeTeam, it.awayTeam, it.externalId) }
            liveMatches.first()
        }

        val snapshot = oddsSnapshotRepository.findTopByMatchIdOrderByCapturedAtDesc(match.id)
        val outcomeId = when (side) {
            "AWAY" -> snapshot?.awayOutcomeId
            else   -> snapshot?.homeOutcomeId
        }

        log.info("Target: {} vs {} | externalId={} | side={} | outcomeId={}",
            match.homeTeam, match.awayTeam, match.externalId, side, outcomeId)
        log.info("Market: Prórroga incluida (basketball moneyline)")
        log.info("Launching browser in 3 seconds... (Ctrl+C to abort)")
        Thread.sleep(3_000)

        val result = browserBetPlacer.placeBet(
            externalId   = match.externalId,
            outcomeId    = outcomeId,
            favoriteSide = side,
            matchDesc    = "${match.homeTeam} vs ${match.awayTeam}",
            triggerOdds  = 1.0,
            betMarket    = "PRORROGA_INCLUIDA",
        )

        log.info("=== TEST RESULT: {} ===", result)
    }
}
