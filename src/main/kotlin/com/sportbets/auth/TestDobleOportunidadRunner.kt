package com.sportbets.auth

import com.sportbets.service.BrowserBetPlacerService
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

/**
 * Places a Doble Oportunidad bet directly, bypassing the normal alert pipeline.
 * Use this to verify the "Doble Oportunidad" browser section and outcome selection work.
 *
 * Run with:
 *   ./gradlew bootRun --args="--spring.profiles.active=test-doble-oportunidad \
 *       --external-id=1024136870 \
 *       --outcome-id=4142278301 \
 *       --side=HOME"
 *
 * --external-id  Kambi event ID (used to navigate to the match page)
 * --outcome-id   The 1X or X2 outcome ID to click (get from Kambi betoffer API)
 * --side         HOME (1X) or AWAY (X2) — controls position fallback if id not found
 */
@Component
@Profile("test-doble-oportunidad")
class TestDobleOportunidadRunner(
    private val browserBetPlacer: BrowserBetPlacerService,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    override fun run(args: ApplicationArguments) {
        log.info("=== TEST DOBLE OPORTUNIDAD ===")

        val externalId = args.getOptionValues("external-id")?.firstOrNull()
            ?: run { log.error("--external-id is required"); return }
        val outcomeId = args.getOptionValues("outcome-id")?.firstOrNull()?.toLongOrNull()
            ?: run { log.error("--outcome-id is required (Long)"); return }
        val side = args.getOptionValues("side")?.firstOrNull()?.uppercase() ?: "HOME"

        log.info("externalId={} | outcomeId={} | side={}", externalId, outcomeId, side)
        log.info("Launching browser in 3 seconds... (Ctrl+C to abort)")
        Thread.sleep(3_000)

        val result = browserBetPlacer.placeBet(
            externalId   = externalId,
            outcomeId    = outcomeId,
            favoriteSide = side,
            matchDesc    = "TEST Doble Oportunidad (externalId=$externalId)",
            triggerOdds  = 1.0,
            betMarket    = "DOBLE_OPORTUNIDAD",
        )

        log.info("=== TEST RESULT: {} ===", result)
    }
}
