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
 * Manually triggers browser-based bet placement on a real live match.
 * Bypasses the odds-rise check — use this to verify the browser automation works.
 *
 * Run with:
 *   ./gradlew bootRun --args="--spring.profiles.active=test-browser-bet"
 *
 * Optional args:
 *   --external-id=1027380893   target a specific match by its Kambi event ID
 *   --side=HOME                which outcome to click: HOME, DRAW, or AWAY (default: HOME)
 */
@Component
@Profile("test-browser-bet")
class TestBrowserBetRunner(
    private val matchRepository: MatchRepository,
    private val oddsSnapshotRepository: OddsSnapshotRepository,
    private val browserBetPlacer: BrowserBetPlacerService,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    override fun run(args: ApplicationArguments) {
        log.info("=== BROWSER BET TEST ===")

        val externalIdArg = args.getOptionValues("external-id")?.firstOrNull()
        val side = args.getOptionValues("side")?.firstOrNull()?.uppercase() ?: "HOME"

        val match = if (externalIdArg != null) {
            matchRepository.findByExternalId(externalIdArg)
                ?: run { log.error("No match found with external-id={}", externalIdArg); return }
        } else {
            val liveMatches = matchRepository.findByStatus(MatchStatus.LIVE)
            if (liveMatches.isEmpty()) {
                log.error("No LIVE matches in DB. Check that the app has been syncing matches.")
                return
            }
            log.info("Available LIVE matches:")
            liveMatches.forEach { log.info("  [{}] {} vs {} (externalId={})", it.id, it.homeTeam, it.awayTeam, it.externalId) }
            liveMatches.first()
        }

        // Pick outcomeId from the latest snapshot if available
        val snapshot = oddsSnapshotRepository.findTopByMatchIdOrderByCapturedAtDesc(match.id)
        val outcomeId = when (side) {
            "AWAY" -> snapshot?.awayOutcomeId
            "DRAW" -> snapshot?.drawOutcomeId
            else   -> snapshot?.homeOutcomeId
        }

        log.info("Target: {} vs {} | externalId={} | side={} | outcomeId={}",
            match.homeTeam, match.awayTeam, match.externalId, side, outcomeId)
        log.info("Launching browser in 3 seconds... (Ctrl+C to abort)")
        Thread.sleep(3_000)

        val result = browserBetPlacer.placeBet(
            externalId   = match.externalId,
            outcomeId    = outcomeId,
            favoriteSide = side,
            matchDesc    = "${match.homeTeam} vs ${match.awayTeam}",
            triggerOdds  = 1.0,  // test runner — no deviation check intended
        )

        log.info("=== TEST RESULT: {} ===", result)
    }
}
