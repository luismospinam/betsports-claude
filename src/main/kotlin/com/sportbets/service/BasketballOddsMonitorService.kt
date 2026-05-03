package com.sportbets.service

import com.fasterxml.jackson.databind.JsonNode
import com.sportbets.model.BettingAlert
import com.sportbets.model.Match
import com.sportbets.model.MatchStatus
import com.sportbets.model.OddsSnapshot
import com.sportbets.repository.BettingAlertRepository
import com.sportbets.repository.MatchRepository
import com.sportbets.repository.OddsSnapshotRepository
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

/**
 * Live odds monitoring and betting strategy for basketball.
 *
 * Strategy — BASKETBALL_COMEBACK:
 *   Pre-match favorite (moneyline "Prórroga incluida" ≤ maxBaselineOdds) is losing
 *   by [minPointDeficit, maxPointDeficit] points during an allowed period
 *   (HALFTIME, QUARTER3, or QUARTER4) and their live moneyline odds have risen
 *   ≥ oddsRiseThresholdPct from the pre-match baseline.
 *
 * Market: "Prórroga incluida" (outright winner including OT) — catId=2.
 *   OT_ONE = home win, OT_TWO = away win. No draw for basketball.
 *
 * Note: the listView in-play endpoint only returns the handicap market in the
 * liveWrapper. The moneyline ("Prórroga incluida") must always be fetched via
 * the per-match betoffer endpoint.
 */
@Service
class BasketballOddsMonitorService(
    private val apiClient: BetplayApiClient,
    private val matchRepository: MatchRepository,
    private val oddsSnapshotRepository: OddsSnapshotRepository,
    private val bettingAlertRepository: BettingAlertRepository,
    private val betPlacerService: BetPlacerService,
    @Value("\${betplay.basketball.monitor.odds-rise-threshold-pct:30.0}") private val oddsRiseThresholdPct: Double,
    @Value("\${betplay.basketball.monitor.odds-rise-max-pct:120.0}") private val oddsRiseMaxPct: Double,
    @Value("\${betplay.basketball.monitor.max-alerts-per-match:1}") private val maxAlertsPerMatch: Int,
    @Value("\${betplay.basketball.monitor.max-baseline-odds:1.60}") private val maxBaselineOdds: Double,
    @Value("\${betplay.basketball.monitor.max-current-odds:4.00}") private val maxCurrentOdds: Double,
    @Value("\${betplay.basketball.monitor.min-point-deficit:1}") private val minPointDeficit: Int,
    @Value("\${betplay.basketball.monitor.max-point-deficit:15}") private val maxPointDeficit: Int,
    @Value("\${betplay.basketball.monitor.bet-periods:HALFTIME,QUARTER3,QUARTER4}") private val betPeriodsStr: String,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    private val betPeriods: Set<String> by lazy { betPeriodsStr.split(",").map { it.trim() }.toSet() }

    @Transactional
    fun capturePreMatchOdds() {
        val upcoming = matchRepository.findByStatusAndSport(MatchStatus.UPCOMING, "BASKETBALL")
        for (match in upcoming) {
            if (oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id).isEmpty()) {
                try {
                    val snapshot = captureSnapshot(match, isPreMatch = true)
                    if (snapshot != null)
                        log.info("Captured basketball pre-match odds for {} vs {} (home={} away={})",
                            match.homeTeam, match.awayTeam,
                            "%.2f".format(snapshot.homeWinOdds), "%.2f".format(snapshot.awayWinOdds))
                    else
                        log.debug("No 'Prórroga incluida' market yet for {} vs {} — will retry", match.homeTeam, match.awayTeam)
                } catch (e: EventNotFoundException) {
                    matchRepository.save(match.copy(status = MatchStatus.FINISHED, updatedAt = LocalDateTime.now()))
                    log.info("Basketball match {} vs {} no longer exists — marked FINISHED", match.homeTeam, match.awayTeam)
                }
            }
        }
    }

    @Transactional
    fun monitorLiveOdds() {
        val liveMatches = matchRepository.findByStatusAndSport(MatchStatus.LIVE, "BASKETBALL")
        if (liveMatches.isEmpty()) { log.debug("No live basketball matches to monitor"); return }

        // liveWrapper gives us score + clock; moneyline odds must be fetched per-match
        val liveJson = apiClient.fetchBasketballLiveMatches()
        val liveWrapperById: Map<String, JsonNode> =
            liveJson?.path("events")
                ?.filter { it.has("liveData") }
                ?.associateBy { it["event"]["id"].asText() }
                ?: emptyMap()

        log.info("Monitoring {} live basketball match(es)...", liveMatches.size)
        for (match in liveMatches) {
            try {
                processLiveMatch(match, liveWrapperById[match.externalId])
            } catch (e: EventNotFoundException) {
                val lastSnapshot = oddsSnapshotRepository.findTopByMatchIdOrderByCapturedAtDesc(match.id)
                matchRepository.save(match.copy(
                    status         = MatchStatus.FINISHED,
                    finalHomeScore = lastSnapshot?.homeScore,
                    finalAwayScore = lastSnapshot?.awayScore,
                    updatedAt      = LocalDateTime.now()
                ))
                log.info("Basketball match {} vs {} ended — marked FINISHED", match.homeTeam, match.awayTeam)
            }
        }
    }

    private fun processLiveMatch(match: Match, liveWrapper: JsonNode?) {
        val snapshot = captureSnapshot(match, isPreMatch = false, liveWrapper = liveWrapper) ?: return

        val placedAlerts = bettingAlertRepository.countByMatchIdAndBetStatusIn(match.id, listOf("PLACED", "DRY_RUN"))
        if (placedAlerts >= maxAlertsPerMatch) return

        val failedAlerts = bettingAlertRepository.countByMatchIdAndBetStatusIn(match.id, listOf("FAILED", "SKIPPED"))
        if (failedAlerts >= 3) return

        val baselines = oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id)
        val baseline = if (baselines.isNotEmpty()) {
            baselines.last()
        } else {
            val firstLive = oddsSnapshotRepository.findByMatchIdAndIsPreMatchFalse(match.id).firstOrNull()
            if (firstLive == null) {
                oddsSnapshotRepository.save(snapshot.copy(isPreMatch = true))
                log.info("No pre-match baseline for basketball {} vs {} — using first live snapshot", match.homeTeam, match.awayTeam)
                return
            }
            firstLive
        }

        checkAndFireAlert(match, baseline, snapshot)
    }

    private fun checkAndFireAlert(match: Match, baseline: OddsSnapshot, current: OddsSnapshot) {
        // Favorite = side with lower pre-match moneyline odds (no draw in basketball)
        val favoriteSide = if (baseline.homeWinOdds <= baseline.awayWinOdds) "HOME" else "AWAY"
        val baselineOdds = if (favoriteSide == "HOME") baseline.homeWinOdds else baseline.awayWinOdds
        val currentOdds  = if (favoriteSide == "HOME") current.homeWinOdds  else current.awayWinOdds

        if (baselineOdds <= 0 || currentOdds <= 0) return

        val risePct = ((currentOdds - baselineOdds) / baselineOdds) * 100.0
        val favoriteScore = if (favoriteSide == "HOME") current.homeScore else current.awayScore
        val opponentScore = if (favoriteSide == "HOME") current.awayScore else current.homeScore
        val periodId = current.periodId
        val minute = current.matchMinute

        log.debug("{} vs {}: {} odds {}→{} ({}%) period={} score={}-{}",
            match.homeTeam, match.awayTeam, favoriteSide,
            "%.2f".format(baselineOdds), "%.2f".format(currentOdds), "%.1f".format(risePct), periodId, favoriteScore, opponentScore)

        if (risePct < oddsRiseThresholdPct) return
        if (risePct > oddsRiseMaxPct) {
            log.info("Basketball skip {} vs {} — odds rose {}% exceeds max (possible collapse)", match.homeTeam, match.awayTeam, "%.1f".format(risePct))
            return
        }
        if (baselineOdds > maxBaselineOdds) {
            log.info("Basketball skip {} vs {} — baseline {} above max {}", match.homeTeam, match.awayTeam, "%.2f".format(baselineOdds), "%.2f".format(maxBaselineOdds))
            return
        }
        if (currentOdds > maxCurrentOdds) {
            log.info("Basketball skip {} vs {} — current odds {} above max {}", match.homeTeam, match.awayTeam, "%.2f".format(currentOdds), "%.2f".format(maxCurrentOdds))
            return
        }
        if (periodId == null || !betPeriods.contains(periodId)) {
            log.debug("Basketball skip {} vs {} — period {} not in bet window {}", match.homeTeam, match.awayTeam, periodId, betPeriods)
            return
        }
        if (favoriteScore == null || opponentScore == null) {
            log.info("Basketball skip {} vs {} — score not available", match.homeTeam, match.awayTeam)
            return
        }
        val deficit = opponentScore - favoriteScore
        if (deficit < minPointDeficit || deficit > maxPointDeficit) {
            log.info("Basketball skip {} vs {} — deficit {} not in [{},{}]", match.homeTeam, match.awayTeam, deficit, minPointDeficit, maxPointDeficit)
            return
        }

        val outcomeId = if (favoriteSide == "HOME") current.homeOutcomeId else current.awayOutcomeId
        val score     = "${current.homeScore}-${current.awayScore}"
        val clockStr  = if (minute != null) "${minute}' ($periodId)" else periodId ?: "?"

        val betResult = betPlacerService.placeBet(
            outcomeId    = outcomeId,
            oddsDecimal  = currentOdds,
            matchDesc    = "${match.homeTeam} vs ${match.awayTeam} ($score $clockStr)",
            externalId   = match.externalId,
            favoriteSide = favoriteSide,
            betMarket    = "PRORROGA_INCLUIDA",
        )

        val favoriteTeam = if (favoriteSide == "HOME") match.homeTeam else match.awayTeam
        val message = buildMessage(match, favoriteSide, favoriteTeam, baselineOdds, currentOdds, risePct, score, clockStr, deficit, betResult)

        bettingAlertRepository.save(BettingAlert(
            match           = match,
            suggestedBet    = favoriteSide,
            currentOdds     = currentOdds,
            baselineOdds    = baselineOdds,
            oddsIncreasePct = risePct,
            scoreAtAlert    = score,
            message         = message,
            notified        = false,
            betPlaced       = betResult is BetResult.Placed,
            betStatus       = when (betResult) {
                is BetResult.Placed -> "PLACED"
                is BetResult.DryRun -> "DRY_RUN"
                BetResult.Failed    -> "FAILED"
                BetResult.Skipped   -> "SKIPPED"
            },
            triggerScenario = "BASKETBALL_COMEBACK",
            triggeredAt     = LocalDateTime.now()
        ))
        log.info("BASKETBALL ALERT: {}", message)
    }

    private fun captureSnapshot(
        match: Match,
        isPreMatch: Boolean,
        liveWrapper: JsonNode? = null,
    ): OddsSnapshot? {
        // Always use the betoffer endpoint — the listView liveWrapper only has handicap, not moneyline
        val oddsJson = apiClient.fetchOdds(match.externalId) ?: return null
        val parsed   = parseMoneylineOdds(oddsJson, "${match.homeTeam} vs ${match.awayTeam}") ?: return null

        val liveData = liveWrapper?.path("liveData")
        val score    = liveData?.path("score")
        val clock    = liveData?.path("matchClock")

        return oddsSnapshotRepository.save(OddsSnapshot(
            match         = match,
            homeWinOdds   = parsed.homeOdds,
            drawOdds      = 0.0,         // basketball has no draw; sentinel so NOT NULL is satisfied
            awayWinOdds   = parsed.awayOdds,
            homeOutcomeId = parsed.homeOutcomeId,
            drawOutcomeId = null,
            awayOutcomeId = parsed.awayOutcomeId,
            isPreMatch    = isPreMatch,
            homeScore     = score?.path("home")?.asText()?.toIntOrNull(),
            awayScore     = score?.path("away")?.asText()?.toIntOrNull(),
            matchMinute   = clock?.path("minute")?.asInt(),
            periodId      = clock?.path("periodId")?.asText()?.takeIf { it.isNotEmpty() },
            capturedAt    = LocalDateTime.now()
        ))
    }

    private data class MoneylineOdds(
        val homeOdds: Double,
        val awayOdds: Double,
        val homeOutcomeId: Long?,
        val awayOutcomeId: Long?,
    )

    /**
     * Finds the "Prórroga incluida" market in a betOffers response.
     * Matches by criterion label (Spanish) since basketball does not use englishLabel="Full Time".
     * OT_ONE = home win, OT_TWO = away win — no OT_CROSS.
     */
    private fun parseMoneylineOdds(json: JsonNode, matchDesc: String): MoneylineOdds? {
        return try {
            val betOffers = json.path("betOffers")
            val moneylineBo = betOffers.firstOrNull { offer ->
                val label    = offer.path("criterion").path("label").asText("")
                val engLabel = offer.path("criterion").path("englishLabel").asText("")
                val suspended = offer.path("suspended").asBoolean(false)
                !suspended && (label == "Prórroga incluida" || engLabel.equals("Full Time", ignoreCase = true))
                    && offer.path("outcomes").any { it.path("type").asText() == "OT_ONE" }
                    && offer.path("outcomes").none { it.path("type").asText() == "OT_CROSS" }
            } ?: run {
                log.debug("No 'Prórroga incluida' moneyline for {} — skipping snapshot", matchDesc)
                return null
            }

            val outcomes = moneylineBo.path("outcomes")
            val homeNode = outcomes.firstOrNull { it.path("type").asText() == "OT_ONE" } ?: return null
            val awayNode = outcomes.firstOrNull { it.path("type").asText() == "OT_TWO" } ?: return null

            val homeOdds = homeNode.path("odds").asDouble().takeIf { it > 0 }?.div(1000) ?: return null
            val awayOdds = awayNode.path("odds").asDouble().takeIf { it > 0 }?.div(1000) ?: return null

            MoneylineOdds(
                homeOdds      = homeOdds,
                awayOdds      = awayOdds,
                homeOutcomeId = homeNode.path("id").asLong().takeIf { it > 0 },
                awayOutcomeId = awayNode.path("id").asLong().takeIf { it > 0 },
            )
        } catch (e: Exception) {
            log.warn("Failed to parse basketball moneyline for {}: {}", matchDesc, e.message)
            null
        }
    }

    private fun buildMessage(
        match: Match, favoriteSide: String, favoriteTeam: String,
        baselineOdds: Double, currentOdds: Double, risePct: Double,
        score: String, clock: String, deficit: Int, betResult: BetResult,
    ): String {
        val betLine = when (betResult) {
            is BetResult.Placed -> "✅ Bet placed: ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)}"
            is BetResult.DryRun -> "🔕 Dry run — ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)}"
            BetResult.Failed    -> "❌ Bet failed — check browser/CDP logs"
            BetResult.Skipped   -> "⚠️ Bet skipped — outcome ID not available"
        }
        return """
            🏀 BASKETBALL — FAVORITE LOSING (comeback)
            🏟️ ${match.homeTeam} vs ${match.awayTeam}
            📊 Score: $score  |  ⏱️ $clock  |  Deficit: -$deficit pts
            🎯 Suggested bet: $favoriteSide ($favoriteTeam)
            📈 Odds: ${"%.2f".format(baselineOdds)} → ${"%.2f".format(currentOdds)} (+${"%.1f".format(risePct)}%)
            $betLine
            🕒 ${LocalDateTime.now()}
        """.trimIndent()
    }
}
