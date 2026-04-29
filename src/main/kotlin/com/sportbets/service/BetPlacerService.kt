package com.sportbets.service

import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service

sealed class BetResult {
    data class Placed(val stake: Long) : BetResult()
    data class DryRun(val stake: Long) : BetResult()
    data object Failed  : BetResult()
    data object Skipped : BetResult()
}

@Service
class BetPlacerService(
    private val browserBetPlacer: BrowserBetPlacerService,
    @Value("\${betplay.betting.enabled:false}") private val bettingEnabled: Boolean,
    @Value("\${betplay.betting.stake-cop:2000}") private val stakeCop: Long,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun placeBet(
        outcomeId: Long?,
        oddsDecimal: Double,
        matchDesc: String,
        externalId: String,
        favoriteSide: String,
        betMarket: String = "RESULTADO_FINAL",
    ): BetResult {
        if (outcomeId == null) {
            log.warn("Cannot place bet for {} — outcomeId not available", matchDesc)
            return BetResult.Skipped
        }

        if (!bettingEnabled) {
            log.info("[DRY RUN] {} | outcomeId={} odds={} stake={}COP market={} — set betplay.betting.enabled=true to activate",
                matchDesc, outcomeId, "%.2f".format(oddsDecimal), stakeCop, betMarket)
            return BetResult.DryRun(stakeCop)
        }

        return browserBetPlacer.placeBet(externalId, outcomeId, favoriteSide, matchDesc, oddsDecimal, betMarket)
    }
}
