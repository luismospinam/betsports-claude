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
 * Core odds monitoring logic.
 *
 * For each LIVE match:
 *  1. Fetch current odds from Betplay/Kambi
 *  2. Store an OddsSnapshot
 *  3. Compare with the pre-match baseline
 *  4. If the favorite's odds have risen above [oddsRiseThresholdPct], fire an alert
 *
 * Kambi odds response: {"betOffers": [{"criterion": {"englishLabel": "Full Time"}, "outcomes": [...]}]}
 * Outcome types: OT_ONE (home), OT_CROSS (draw), OT_TWO (away)
 * Odds are in milliunits — divide by 1000 for decimal odds (e.g. 1850 → 1.85)
 */
@Service
class OddsMonitorService(
    private val apiClient: BetplayApiClient,
    private val matchRepository: MatchRepository,
    private val oddsSnapshotRepository: OddsSnapshotRepository,
    private val bettingAlertRepository: BettingAlertRepository,
    private val betPlacerService: BetPlacerService,
    @Value("\${betplay.monitor.odds-rise-threshold-pct:20.0}") private val oddsRiseThresholdPct: Double,
    @Value("\${betplay.monitor.max-alerts-per-match:3}") private val maxAlertsPerMatch: Int,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    /**
     * Called by scheduler — captures pre-match odds for UPCOMING matches
     * that are close to kickoff (within 30 minutes).
     */
    @Transactional
    fun capturePreMatchOdds() {
        // Capture pre-match baseline for all upcoming matches that don't have one yet.
        // No time window restriction — odds are captured as soon as the match is synced,
        // so a baseline exists even if the app restarts close to or after kickoff.
        val upcoming = matchRepository.findByStatus(MatchStatus.UPCOMING)
        for (match in upcoming) {
            if (oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id).isEmpty()) {
                try {
                    captureOddsSnapshot(match, isPreMatch = true)
                    log.info("Captured pre-match odds for {} vs {}", match.homeTeam, match.awayTeam)
                } catch (e: EventNotFoundException) {
                    matchRepository.save(match.copy(status = MatchStatus.FINISHED, updatedAt = LocalDateTime.now()))
                    log.info("Match {} vs {} no longer exists in Kambi - marked as FINISHED", match.homeTeam, match.awayTeam)
                }
            }
        }
    }

    /**
     * Called by scheduler — polls in-play endpoint once, then processes all tracked live matches.
     * Using in-play.json instead of per-match betoffer calls gives us odds + score + minute in one request.
     */
    @Transactional
    fun monitorLiveOdds() {
        val liveMatches = matchRepository.findByStatus(MatchStatus.LIVE)
        if (liveMatches.isEmpty()) {
            log.debug("No live matches to monitor")
            return
        }

        val liveJson = apiClient.fetchLiveMatches()
        val liveDataByEventId: Map<String, com.fasterxml.jackson.databind.JsonNode> =
            liveJson?.get("events")
                ?.filter { it.has("liveData") }
                ?.associateBy { it["event"]["id"].asText() }
                ?: emptyMap()

        log.info("Monitoring {} live match(es)...", liveMatches.size)
        for (match in liveMatches) {
            try {
                processLiveMatch(match, liveDataByEventId[match.externalId])
            } catch (e: EventNotFoundException) {
                matchRepository.save(match.copy(status = MatchStatus.FINISHED, updatedAt = LocalDateTime.now()))
                log.info("Live match {} vs {} no longer exists in Kambi - marked as FINISHED", match.homeTeam, match.awayTeam)
            }
        }
    }

    private fun processLiveMatch(match: Match, liveWrapper: com.fasterxml.jackson.databind.JsonNode?) {
        val snapshot = captureOddsSnapshot(match, isPreMatch = false, liveWrapper = liveWrapper) ?: return

        // Skip alerting if too many alerts already sent for this match
        val existingAlerts = bettingAlertRepository.countByMatchId(match.id)
        if (existingAlerts >= maxAlertsPerMatch) {
            log.debug("Max alerts ({}) reached for match {}", maxAlertsPerMatch, match.id)
            return
        }

        // Get the pre-match baseline
        val baselines = oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id)
        if (baselines.isEmpty()) {
            log.warn("No pre-match baseline for match {} vs {}. Skipping alert check.", match.homeTeam, match.awayTeam)
            return
        }
        val baseline = baselines.last()

        checkAndFireAlert(match, baseline, snapshot)
    }

    private fun checkAndFireAlert(match: Match, baseline: OddsSnapshot, current: OddsSnapshot) {
        // Identify the original favorite (lowest odds pre-match)
        val favoriteSide = baseline.favoriteSide()

        val baselineOdds = when (favoriteSide) {
            "HOME" -> baseline.homeWinOdds
            "AWAY" -> baseline.awayWinOdds
            else   -> baseline.drawOdds
        }
        val currentOdds = when (favoriteSide) {
            "HOME" -> current.homeWinOdds
            "AWAY" -> current.awayWinOdds
            else   -> current.drawOdds
        }

        if (baselineOdds <= 0) return

        val risePct = ((currentOdds - baselineOdds) / baselineOdds) * 100.0

        log.debug(
            "{} vs {}: {} odds {:.2f} → {:.2f} ({:.1f}% rise)",
            match.homeTeam, match.awayTeam, favoriteSide, baselineOdds, currentOdds, risePct
        )

        if (risePct >= oddsRiseThresholdPct) {
            val score = if (current.homeScore != null && current.awayScore != null)
                "${current.homeScore}-${current.awayScore}" else "?"
            val minute = current.matchMinute?.let { "${it}'" } ?: "?"

            val outcomeId = when (favoriteSide) {
                "HOME" -> current.homeOutcomeId
                "AWAY" -> current.awayOutcomeId
                else   -> current.drawOutcomeId
            }

            // Place bet first so the result is included in the alert message
            val betResult = betPlacerService.placeBet(
                outcomeId    = outcomeId,
                oddsDecimal  = currentOdds,
                matchDesc    = "${match.homeTeam} vs ${match.awayTeam} ($score $minute)",
                externalId   = match.externalId,
                favoriteSide = favoriteSide,
            )

            val message = buildAlertMessage(match, favoriteSide, baselineOdds, currentOdds, risePct, score, minute, betResult)

            val alert = BettingAlert(
                match            = match,
                suggestedBet     = favoriteSide,
                currentOdds      = currentOdds,
                baselineOdds     = baselineOdds,
                oddsIncreasePct  = risePct,
                scoreAtAlert     = score,
                message          = message,
                notified         = false,
                betPlaced        = betResult is BetResult.Placed,
                betStatus        = when (betResult) {
                    is BetResult.Placed -> "PLACED"
                    is BetResult.DryRun -> "DRY_RUN"
                    BetResult.Failed    -> "FAILED"
                    BetResult.Skipped   -> "SKIPPED"
                },
                triggeredAt      = LocalDateTime.now()
            )
            bettingAlertRepository.save(alert)
            log.info("ALERT: {}", message)
        }
    }

    private fun captureOddsSnapshot(
        match: Match,
        isPreMatch: Boolean,
        liveWrapper: com.fasterxml.jackson.databind.JsonNode? = null
    ): OddsSnapshot? {
        // For live matches use the in-play wrapper (has odds + score + minute).
        // For pre-match use the dedicated betoffer endpoint.
        val oddsJson = if (liveWrapper != null) liveWrapper else apiClient.fetchOdds(match.externalId) ?: return null
        val odds = parseOdds(oddsJson) ?: return null

        val liveData = liveWrapper?.get("liveData")
        val score = liveData?.get("score")
        val clock = liveData?.get("matchClock")

        val snapshot = OddsSnapshot(
            match          = match,
            homeWinOdds    = odds.homeWinOdds,
            drawOdds       = odds.drawOdds,
            awayWinOdds    = odds.awayWinOdds,
            homeOutcomeId  = odds.homeOutcomeId,
            drawOutcomeId  = odds.drawOutcomeId,
            awayOutcomeId  = odds.awayOutcomeId,
            isPreMatch     = isPreMatch,
            homeScore      = score?.get("home")?.asInt(),
            awayScore      = score?.get("away")?.asInt(),
            matchMinute    = clock?.get("minute")?.asInt(),
            capturedAt     = LocalDateTime.now()
        )
        return oddsSnapshotRepository.save(snapshot)
    }

    private data class ParsedOdds(
        val homeWinOdds: Double,
        val drawOdds: Double,
        val awayWinOdds: Double,
        val homeOutcomeId: Long?,
        val drawOutcomeId: Long?,
        val awayOutcomeId: Long?,
    )

    // Works for both sources:
    //   betoffer endpoint:  {"betOffers": [...]}
    //   in-play wrapper:    {"event": {...}, "betOffers": [...], "liveData": {...}}
    // Finds the Full Time (1X2) bet offer and extracts OT_ONE/OT_CROSS/OT_TWO.
    // Odds are milliunits — divide by 1000. Outcome IDs are needed for coupon placement.
    private fun parseOdds(json: JsonNode, matchDesc: String = "?"): ParsedOdds? {
        return try {
            val betOffers = json["betOffers"] ?: return null
            val fullTimeBo = betOffers.firstOrNull {
                it["criterion"]?.get("englishLabel")?.asText() == "Full Time"
            } ?: return null

            val outcomes = fullTimeBo["outcomes"] ?: return null
            val homeNode = outcomes.firstOrNull { it["type"]?.asText() == "OT_ONE"   } ?: return null
            val drawNode = outcomes.firstOrNull { it["type"]?.asText() == "OT_CROSS" } ?: return null
            val awayNode = outcomes.firstOrNull { it["type"]?.asText() == "OT_TWO"   } ?: return null

            // odds field is null when Kambi suspends the market mid-match — skip silently
            val homeOdds = homeNode["odds"]?.asDouble()?.div(1000) ?: run {
                log.debug("Market suspended (no odds) for {} - skipping snapshot", matchDesc)
                return null
            }
            val drawOdds = drawNode["odds"]?.asDouble()?.div(1000) ?: return null
            val awayOdds = awayNode["odds"]?.asDouble()?.div(1000) ?: return null

            ParsedOdds(
                homeWinOdds   = homeOdds,
                drawOdds      = drawOdds,
                awayWinOdds   = awayOdds,
                homeOutcomeId = homeNode["id"]?.asLong(),
                drawOutcomeId = drawNode["id"]?.asLong(),
                awayOutcomeId = awayNode["id"]?.asLong(),
            )
        } catch (e: Exception) {
            log.warn("Failed to parse odds for {} from Kambi JSON: {}", matchDesc, e.message)
            null
        }
    }

    private fun buildAlertMessage(
        match: Match,
        favoriteSide: String,
        baselineOdds: Double,
        currentOdds: Double,
        risePct: Double,
        score: String,
        minute: String,
        betResult: BetResult,
    ): String {
        val favoriteTeam = when (favoriteSide) {
            "HOME" -> match.homeTeam
            "AWAY" -> match.awayTeam
            else   -> "Draw"
        }
        val betLine = when (betResult) {
            is BetResult.Placed -> "✅ Bet placed: ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)}"
            is BetResult.DryRun -> "🔕 Dry run — ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)} (enable betting to activate)"
            BetResult.Failed    -> "❌ Bet failed — check browser/CDP logs"
            BetResult.Skipped   -> "⚠️ Bet skipped — outcome ID not available"
        }
        return """
            ⚽ BET OPPORTUNITY DETECTED
            🏟️ ${match.homeTeam} vs ${match.awayTeam}
            📊 Score: $score  |  ⏱️ $minute
            🎯 Suggested bet: $favoriteSide ($favoriteTeam)
            📈 Odds: ${"%.2f".format(baselineOdds)} → ${"%.2f".format(currentOdds)} (+${"%.1f".format(risePct)}%)
            $betLine
            🕒 ${LocalDateTime.now()}
        """.trimIndent()
    }
}
