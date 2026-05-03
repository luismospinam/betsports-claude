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
import java.util.concurrent.ConcurrentHashMap

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
    @Value("\${betplay.monitor.odds-rise-threshold-pct:15.0}") private val oddsRiseThresholdPct: Double,
    @Value("\${betplay.monitor.odds-rise-max-pct:60.0}") private val oddsRiseMaxPct: Double,
    @Value("\${betplay.monitor.max-alerts-per-match:1}") private val maxAlertsPerMatch: Int,
    @Value("\${betplay.monitor.min-match-minute:25}") private val minMatchMinute: Int,
    @Value("\${betplay.monitor.max-match-minute:75}") private val maxMatchMinute: Int,
    @Value("\${betplay.monitor.max-baseline-odds:1.80}") private val maxBaselineOdds: Double,
    @Value("\${betplay.monitor.max-current-odds:3.50}") private val maxCurrentOdds: Double,
    @Value("\${betplay.monitor.double-chance-min-odds:2.0}") private val doubleChanceMinOdds: Double,
    @Value("\${betplay.monitor.double-chance-max-odds:9999.0}") private val doubleChanceMaxOdds: Double,
    @Value("\${betplay.monitor.halftime.enabled:true}") private val halftimeEnabled: Boolean,
    @Value("\${betplay.monitor.halftime.min-minute:35}") private val halftimeMinMinute: Int,
    @Value("\${betplay.monitor.halftime.max-minute:50}") private val halftimeMaxMinute: Int,
    @Value("\${betplay.monitor.halftime.odds-rise-threshold-pct:10.0}") private val halftimeOddsRiseThresholdPct: Double,
    @Value("\${betplay.monitor.halftime.max-current-odds:4.00}") private val halftimeMaxCurrentOdds: Double,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    // Per-match DC cache. Outcome IDs never change so they are cached indefinitely.
    // Odds drift during the match — we re-fetch them every dcOddsRefreshMs so each
    // snapshot stores a reasonably live value without hitting the API every 45s.
    private data class DCCache(
        val homeDrawOutcomeId: Long?,
        val awayDrawOutcomeId: Long?,
        val homeDrawOdds: Double?,
        val awayDrawOdds: Double?,
        val oddsLastFetchedMs: Long,
    )
    private val dcCache = ConcurrentHashMap<Long, DCCache>()

    @Value("\${betplay.monitor.dc-odds-refresh-ms:180000}")
    private val dcOddsRefreshMs: Long = 180_000L

    /**
     * Called by scheduler — captures pre-match odds for UPCOMING matches
     * that are close to kickoff (within 30 minutes).
     */
    @Transactional
    fun capturePreMatchOdds() {
        // Capture pre-match baseline for all upcoming matches that don't have one yet.
        // No time window restriction — odds are captured as soon as the match is synced,
        // so a baseline exists even if the app restarts close to or after kickoff.
        val upcoming = matchRepository.findByStatusAndSport(MatchStatus.UPCOMING, "FOOTBALL")
        for (match in upcoming) {
            if (oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id).isEmpty()) {
                try {
                    val snapshot = captureOddsSnapshot(match, isPreMatch = true)
                    if (snapshot != null) {
                        log.info("Captured pre-match odds for {} vs {}", match.homeTeam, match.awayTeam)
                    } else {
                        log.warn("No Full Time (1X2) market available yet for {} vs {} — will retry next cycle",
                            match.homeTeam, match.awayTeam)
                    }
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
        val liveMatches = matchRepository.findByStatusAndSport(MatchStatus.LIVE, "FOOTBALL")
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
                val lastSnapshot = oddsSnapshotRepository.findTopByMatchIdOrderByCapturedAtDesc(match.id)
                matchRepository.save(match.copy(
                    status         = MatchStatus.FINISHED,
                    finalHomeScore = lastSnapshot?.homeScore,
                    finalAwayScore = lastSnapshot?.awayScore,
                    updatedAt      = LocalDateTime.now()
                ))
                val finalScore = if (lastSnapshot?.homeScore != null) "${lastSnapshot.homeScore}-${lastSnapshot.awayScore}" else "score unknown"
                log.info("Live match {} vs {} no longer exists in Kambi - marked as FINISHED ({})", match.homeTeam, match.awayTeam, finalScore)
            }
        }
    }

    private fun processLiveMatch(match: Match, liveWrapper: com.fasterxml.jackson.databind.JsonNode?) {
        val snapshot = captureOddsSnapshot(match, isPreMatch = false, liveWrapper = liveWrapper) ?: return

        // Skip if a real bet was already placed for this match (FAILED/SKIPPED don't count)
        val placedAlerts = bettingAlertRepository.countByMatchIdAndBetStatusIn(match.id, listOf("PLACED", "DRY_RUN"))
        if (placedAlerts >= maxAlertsPerMatch) {
            log.debug("Max alerts ({}) reached for match {}", maxAlertsPerMatch, match.id)
            return
        }

        // Stop retrying after 3 consecutive failures to avoid spamming Discord
        val failedAlerts = bettingAlertRepository.countByMatchIdAndBetStatusIn(match.id, listOf("FAILED", "SKIPPED"))
        if (failedAlerts >= 3) {
            log.debug("Max failed attempts (3) reached for match {} — giving up", match.id)
            return
        }

        // Get the pre-match baseline — fall back to first live snapshot if none was captured pre-match
        val baselines = oddsSnapshotRepository.findByMatchIdAndIsPreMatchTrue(match.id)
        val baseline = if (baselines.isNotEmpty()) {
            baselines.last()
        } else {
            val firstLive = oddsSnapshotRepository.findByMatchIdAndIsPreMatchFalse(match.id).firstOrNull()
            if (firstLive == null) {
                // First poll for this match — save current snapshot as baseline and wait for next cycle
                oddsSnapshotRepository.save(snapshot.copy(isPreMatch = true))
                log.info("No pre-match baseline for {} vs {} — using first live snapshot as baseline",
                    match.homeTeam, match.awayTeam)
                return
            }
            log.debug("Using first live snapshot as baseline for {} vs {}", match.homeTeam, match.awayTeam)
            firstLive
        }

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
        val minute = current.matchMinute
        val favoriteScore = if (favoriteSide == "HOME") current.homeScore else current.awayScore
        val opponentScore = if (favoriteSide == "HOME") current.awayScore else current.homeScore

        log.debug(
            "{} vs {}: {} odds {} → {} ({}% rise) min={} score={}-{}",
            match.homeTeam, match.awayTeam, favoriteSide,
            "%.2f".format(baselineOdds), "%.2f".format(currentOdds), "%.1f".format(risePct),
            minute, favoriteScore, opponentScore
        )

        // --- Betting filters ---
        // 1. Odds must have risen enough to be meaningful.
        // Use the lower of the two path thresholds so halftime matches (10%) aren't
        // silently killed before path evaluation when Path A requires 15%.
        val minThreshold = minOf(oddsRiseThresholdPct, halftimeOddsRiseThresholdPct)
        if (risePct < minThreshold) return

        // 2. Odds rise must not indicate a true collapse (red card, injury, 2+ goals down)
        if (risePct > oddsRiseMaxPct) {
            log.info("Skipping {} vs {} — odds rose {}% exceeds max {}% (possible collapse)",
                match.homeTeam, match.awayTeam, "%.1f".format(risePct), "%.1f".format(oddsRiseMaxPct))
            return
        }

        // 3. Only bet on genuine pre-match favorites
        if (baselineOdds > maxBaselineOdds) {
            log.info("Skipping {} vs {} — baseline odds {} above max {} (not a strong favorite)",
                match.homeTeam, match.awayTeam, "%.2f".format(baselineOdds), "%.2f".format(maxBaselineOdds))
            return
        }

        // 4. Don't bet if the market has truly given up on them
        if (currentOdds > maxCurrentOdds) {
            log.info("Skipping {} vs {} — current odds {} above max {} (market gave up)",
                match.homeTeam, match.awayTeam, "%.2f".format(currentOdds), "%.2f".format(maxCurrentOdds))
            return
        }

        // Require score and minute to be known before evaluating either path
        if (minute == null || favoriteScore == null || opponentScore == null) {
            log.info("Skipping {} vs {} — score/minute not yet available", match.homeTeam, match.awayTeam)
            return
        }
        val deficit = opponentScore - favoriteScore

        // --- Path A: favorite losing by exactly 1 goal ---
        val scenario: String = when {
            deficit == 1
                && risePct >= oddsRiseThresholdPct
                && minute >= minMatchMinute && minute <= maxMatchMinute
                && currentOdds <= maxCurrentOdds -> "LOSING_BY_1"

            // --- Path B: favorite tied near halftime ---
            halftimeEnabled
                && deficit == 0
                && minute >= halftimeMinMinute && minute <= halftimeMaxMinute
                && risePct >= halftimeOddsRiseThresholdPct
                && currentOdds <= halftimeMaxCurrentOdds -> "TIED_HALFTIME"

            else -> {
                log.info(
                    "Skipping {} vs {} — no path matched (deficit={} min={} rise={}% currentOdds={})",
                    match.homeTeam, match.awayTeam, deficit, minute,
                    "%.1f".format(risePct), "%.2f".format(currentOdds)
                )
                return
            }
        }

        val score = "${current.homeScore}-${current.awayScore}"
        val minuteStr = "${minute}'"

        // Path A market selection — three cases based on current outright odds:
        //   [below min]     team still likely to win outright → bet RESULTADO_FINAL
        //   [min, max)      DC window where EV analysis shows DC beats outright → bet DOBLE_OPORTUNIDAD
        //   [max and above] high odds, outright EV dominates (54%+ win rate at 2.0+ odds) → bet RESULTADO_FINAL
        // Path B always bets outright win — tied team needs to score, a draw adds no value.
        val outcomeId: Long?
        val betMarket: String
        if (scenario == "LOSING_BY_1") {
            val outrightId = when (favoriteSide) { "HOME" -> current.homeOutcomeId; "AWAY" -> current.awayOutcomeId; else -> current.drawOutcomeId }
            val inDcWindow = currentOdds >= doubleChanceMinOdds && currentOdds < doubleChanceMaxOdds
            if (inDcWindow) {
                val dcId = when (favoriteSide) {
                    "HOME" -> current.homeDrawOutcomeId
                    "AWAY" -> current.awayDrawOutcomeId
                    else   -> null
                }
                if (dcId != null) {
                    outcomeId = dcId
                    betMarket = "DOBLE_OPORTUNIDAD"
                    log.info("Path A [DC window {}-{}]: {} vs {} odds={} → DOBLE_OPORTUNIDAD (win-or-draw)",
                        "%.2f".format(doubleChanceMinOdds), "%.2f".format(doubleChanceMaxOdds),
                        match.homeTeam, match.awayTeam, "%.2f".format(currentOdds))
                } else {
                    log.warn("Path A [DC window {}-{}]: {} vs {} odds={} — DC outcomeId missing, falling back to RESULTADO_FINAL",
                        "%.2f".format(doubleChanceMinOdds), "%.2f".format(doubleChanceMaxOdds),
                        match.homeTeam, match.awayTeam, "%.2f".format(currentOdds))
                    outcomeId = outrightId
                    betMarket = "RESULTADO_FINAL"
                }
            } else if (currentOdds < doubleChanceMinOdds) {
                log.info("Path A [below DC min {}]: {} vs {} odds={} → RESULTADO_FINAL (team still likely to win outright)",
                    "%.2f".format(doubleChanceMinOdds), match.homeTeam, match.awayTeam, "%.2f".format(currentOdds))
                outcomeId = outrightId
                betMarket = "RESULTADO_FINAL"
            } else {
                // currentOdds >= doubleChanceMaxOdds — above DC window
                log.info("Path A [above DC max {}]: {} vs {} odds={} → RESULTADO_FINAL (outright EV dominates at high odds)",
                    "%.2f".format(doubleChanceMaxOdds), match.homeTeam, match.awayTeam, "%.2f".format(currentOdds))
                outcomeId = outrightId
                betMarket = "RESULTADO_FINAL"
            }
        } else {
            outcomeId = when (favoriteSide) { "HOME" -> current.homeOutcomeId; "AWAY" -> current.awayOutcomeId; else -> current.drawOutcomeId }
            betMarket = "RESULTADO_FINAL"
        }

        // Place bet first so the result is included in the alert message
        val betResult = betPlacerService.placeBet(
            outcomeId    = outcomeId,
            oddsDecimal  = currentOdds,
            matchDesc    = "${match.homeTeam} vs ${match.awayTeam} ($score $minuteStr)",
            externalId   = match.externalId,
            favoriteSide = favoriteSide,
            betMarket    = betMarket,
        )

        val message = buildAlertMessage(match, favoriteSide, baselineOdds, currentOdds, risePct, score, minuteStr, betResult, scenario, betMarket)

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
            triggerScenario  = scenario,
            triggeredAt      = LocalDateTime.now()
        )
        bettingAlertRepository.save(alert)
        log.info("ALERT [{}]: {}", scenario, message)
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

        // The live-path wrapper only contains the 1X2 market — Double Chance is absent.
        // We fetch DC data from the betoffer endpoint and cache it per match:
        //   - Outcome IDs: cached indefinitely (they never change during a match)
        //   - Odds: refreshed every dcOddsRefreshMs (default 3 min) so snapshots store
        //     live values for historical analysis without hitting the API every 45s.
        val homeDrawOutcomeId: Long?
        val awayDrawOutcomeId: Long?
        val homeDrawOdds: Double?
        val awayDrawOdds: Double?
        if (liveWrapper != null) {
            val now = System.currentTimeMillis()
            val cached = dcCache[match.id]
            if (cached != null && now - cached.oddsLastFetchedMs < dcOddsRefreshMs) {
                // Odds are still fresh — use cached values entirely
                homeDrawOutcomeId = cached.homeDrawOutcomeId
                awayDrawOutcomeId = cached.awayDrawOutcomeId
                homeDrawOdds      = cached.homeDrawOdds
                awayDrawOdds      = cached.awayDrawOdds
            } else {
                // Odds expired (or first fetch) — call betoffer for fresh data
                val fullOdds = apiClient.fetchOdds(match.externalId)?.let { parseOdds(it) }
                // Keep existing IDs from cache if available (avoids null if API is slow)
                homeDrawOutcomeId = cached?.homeDrawOutcomeId ?: fullOdds?.homeDrawOutcomeId
                awayDrawOutcomeId = cached?.awayDrawOutcomeId ?: fullOdds?.awayDrawOutcomeId
                homeDrawOdds      = fullOdds?.homeDrawOdds
                awayDrawOdds      = fullOdds?.awayDrawOdds
                dcCache[match.id] = DCCache(homeDrawOutcomeId, awayDrawOutcomeId, homeDrawOdds, awayDrawOdds, now)
                if (cached == null) {
                    if (homeDrawOutcomeId != null || awayDrawOutcomeId != null)
                        log.info("Fetched Double Chance IDs for {} vs {} (1X={} | X2={})",
                            match.homeTeam, match.awayTeam, homeDrawOutcomeId, awayDrawOutcomeId)
                    else
                        log.debug("No Double Chance market in betoffer for {} vs {}", match.homeTeam, match.awayTeam)
                }
            }
        } else {
            homeDrawOutcomeId = odds.homeDrawOutcomeId
            awayDrawOutcomeId = odds.awayDrawOutcomeId
            homeDrawOdds      = odds.homeDrawOdds
            awayDrawOdds      = odds.awayDrawOdds
        }

        val liveData = liveWrapper?.get("liveData")
        val score = liveData?.get("score")
        val clock = liveData?.get("matchClock")

        val snapshot = OddsSnapshot(
            match               = match,
            homeWinOdds         = odds.homeWinOdds,
            drawOdds            = odds.drawOdds,
            awayWinOdds         = odds.awayWinOdds,
            homeOutcomeId       = odds.homeOutcomeId,
            drawOutcomeId       = odds.drawOutcomeId,
            awayOutcomeId       = odds.awayOutcomeId,
            homeDrawOutcomeId   = homeDrawOutcomeId,
            awayDrawOutcomeId   = awayDrawOutcomeId,
            homeDrawOdds        = homeDrawOdds,
            awayDrawOdds        = awayDrawOdds,
            isPreMatch          = isPreMatch,
            homeScore           = score?.get("home")?.asInt(),
            awayScore           = score?.get("away")?.asInt(),
            matchMinute         = clock?.get("minute")?.asInt(),
            capturedAt          = LocalDateTime.now()
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
        val homeDrawOutcomeId: Long?,   // 1X double chance outcome ID
        val awayDrawOutcomeId: Long?,   // X2 double chance outcome ID
        val homeDrawOdds: Double?,      // 1X decimal odds
        val awayDrawOdds: Double?,      // X2 decimal odds
    )

    // Works for both sources:
    //   betoffer endpoint:  {"betOffers": [...]}
    //   in-play wrapper:    {"event": {...}, "betOffers": [...], "liveData": {...}}
    // Finds the Full Time (1X2) bet offer and extracts OT_ONE/OT_CROSS/OT_TWO.
    // Also finds the Double Chance offer for 1X (OT_ONE_X) and X2 (OT_X_TWO).
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

            // Parse Double Chance market for Path A (LOSING_BY_1) bets.
            // Kambi uses OT_ONE_X (1X) and OT_X_TWO (X2) as outcome types.
            // With lang=es_CO the API may return "Doble Oportunidad" in the label field
            // rather than "Double Chance" in englishLabel — match both.
            val doubleChanceBo = betOffers.firstOrNull {
                val eng = it["criterion"]?.get("englishLabel")?.asText() ?: ""
                val loc = it["criterion"]?.get("label")?.asText() ?: ""
                eng.contains("Double Chance", ignoreCase = true) ||
                loc.contains("Doble Oportunidad", ignoreCase = true)
            }
            if (doubleChanceBo == null) {
                val labels = betOffers.mapNotNull { it["criterion"]?.get("englishLabel")?.asText() }
                log.debug("No Double Chance market found for {} — available criteria: {}", matchDesc, labels)
            }
            val dcOutcomes = doubleChanceBo?.get("outcomes")
            val homeDrawNode = dcOutcomes?.firstOrNull {
                val t = it["type"]?.asText() ?: ""
                t == "OT_ONE_X" || t == "OT_HOME_DRAW" || t == "OT_ONE_OR_CROSS"
            }
            val awayDrawNode = dcOutcomes?.firstOrNull {
                val t = it["type"]?.asText() ?: ""
                t == "OT_X_TWO" || t == "OT_DRAW_AWAY" || t == "OT_CROSS_OR_TWO"
            }

            ParsedOdds(
                homeWinOdds       = homeOdds,
                drawOdds          = drawOdds,
                awayWinOdds       = awayOdds,
                homeOutcomeId     = homeNode["id"]?.asLong(),
                drawOutcomeId     = drawNode["id"]?.asLong(),
                awayOutcomeId     = awayNode["id"]?.asLong(),
                homeDrawOutcomeId = homeDrawNode?.get("id")?.asLong(),
                awayDrawOutcomeId = awayDrawNode?.get("id")?.asLong(),
                homeDrawOdds      = homeDrawNode?.get("odds")?.asDouble()?.div(1000),
                awayDrawOdds      = awayDrawNode?.get("odds")?.asDouble()?.div(1000),
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
        scenario: String,
        betMarket: String,
    ): String {
        val favoriteTeam = when (favoriteSide) {
            "HOME" -> match.homeTeam
            "AWAY" -> match.awayTeam
            else   -> "Draw"
        }
        val header = when {
            scenario == "TIED_HALFTIME"      -> "⏱️ BET OPPORTUNITY — FAVORITE TIED AT HALFTIME"
            betMarket == "DOBLE_OPORTUNIDAD" -> "⚽ BET OPPORTUNITY — DOBLE OPORTUNIDAD (comeback)"
            else                             -> "⚽ BET OPPORTUNITY — FAVORITE LOSING (comeback)"
        }
        val betLine = when (betResult) {
            is BetResult.Placed -> "✅ Bet placed: ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)}"
            is BetResult.DryRun -> "🔕 Dry run — ${"%,d".format(betResult.stake)} COP @ ${"%.2f".format(currentOdds)} (enable betting to activate)"
            BetResult.Failed    -> "❌ Bet failed — check browser/CDP logs"
            BetResult.Skipped   -> "⚠️ Bet skipped — outcome ID not available"
        }
        return """
            $header
            🏟️ ${match.homeTeam} vs ${match.awayTeam}
            📊 Score: $score  |  ⏱️ $minute
            🎯 Suggested bet: $favoriteSide ($favoriteTeam)
            📈 Odds: ${"%.2f".format(baselineOdds)} → ${"%.2f".format(currentOdds)} (+${"%.1f".format(risePct)}%)
            $betLine
            🕒 ${LocalDateTime.now()}
        """.trimIndent()
    }
}
