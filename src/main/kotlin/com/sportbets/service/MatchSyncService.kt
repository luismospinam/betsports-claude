package com.sportbets.service

import com.fasterxml.jackson.databind.JsonNode
import com.sportbets.model.Match
import com.sportbets.model.MatchStatus
import com.sportbets.repository.MatchRepository
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * Fetches upcoming and live soccer matches from Betplay/Kambi and syncs them to the DB.
 *
 * Kambi response shape: {"events": [{"event": {...}, "betOffers": [...]}]}
 * Event state values: NOT_STARTED, STARTED, FINISHED, CANCELLED, POSTPONED
 */
@Service
class MatchSyncService(
    private val apiClient: BetplayApiClient,
    private val matchRepository: MatchRepository
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @Transactional
    fun syncUpcomingMatches() {
        log.info("Syncing upcoming soccer matches from Betplay...")
        val json = apiClient.fetchUpcomingMatches() ?: run {
            log.warn("No data received from Betplay for upcoming matches")
            return
        }

        val events = json["events"]
        if (events == null || !events.isArray) {
            log.warn("Unexpected response structure: {}", json.toString().take(200))
            return
        }

        var created = 0
        var skipped = 0
        for (wrapper in events) {
            val match = parseMatch(wrapper) ?: continue
            if (matchRepository.existsByExternalId(match.externalId)) {
                skipped++
            } else {
                matchRepository.save(match)
                created++
                log.info("Saved match: {} vs {} on {}", match.homeTeam, match.awayTeam, match.matchDate)
            }
        }
        log.info("Match sync complete - created: {}, skipped (already exist): {}", created, skipped)
    }

    @Transactional
    fun syncLiveMatchStatuses() {
        val json = apiClient.fetchLiveMatches() ?: return
        val events = json["events"] ?: return
        if (!events.isArray) return

        for (wrapper in events) {
            val externalId = wrapper["event"]?.get("id")?.asText() ?: continue
            val match = matchRepository.findByExternalId(externalId) ?: continue
            if (match.sport != "FOOTBALL") continue
            if (match.status != MatchStatus.LIVE) {
                val liveData = wrapper["liveData"]
                val score = liveData?.get("score")
                val clock = liveData?.get("matchClock")
                val homeScore = score?.get("home")?.asInt()
                val awayScore = score?.get("away")?.asInt()
                val minute = clock?.get("minute")?.asInt()
                val period = clock?.get("periodId")?.asText()
                matchRepository.save(match.copy(status = MatchStatus.LIVE, updatedAt = LocalDateTime.now()))
                val scoreStr = if (homeScore != null && awayScore != null) "$homeScore:$awayScore" else "score pending"
                val clockStr = if (minute != null) "min $minute ($period)" else "clock pending"
                log.info("Match {} vs {} is now LIVE - {} {}", match.homeTeam, match.awayTeam, scoreStr, clockStr)
            }
        }
    }

    /**
     * Promote UPCOMING matches whose scheduled time has passed to LIVE.
     * Fallback in case the live API doesn't return all matches.
     */
    @Transactional
    fun markStartedMatchesAsLive(sport: String = "FOOTBALL") {
        val now = LocalDateTime.now()
        val upcoming = matchRepository.findByStatusAndSport(MatchStatus.UPCOMING, sport)
        val started = upcoming.filter { it.matchDate.isBefore(now) }
        started.forEach {
            matchRepository.save(it.copy(status = MatchStatus.LIVE, updatedAt = now))
            log.info("Auto-promoted match {} vs {} to LIVE (past kickoff time)", it.homeTeam, it.awayTeam)
        }
    }

    // -------------------------------------------------------------------------
    // Basketball
    // -------------------------------------------------------------------------

    @Transactional
    fun syncUpcomingBasketballMatches() {
        log.info("Syncing upcoming basketball matches from Betplay...")
        val json = apiClient.fetchBasketballUpcomingMatches() ?: run {
            log.warn("No data received for upcoming basketball matches")
            return
        }
        val events = json["events"] ?: return
        if (!events.isArray) return
        var created = 0; var skipped = 0
        for (wrapper in events) {
            val match = parseMatch(wrapper, sport = "BASKETBALL") ?: continue
            if (matchRepository.existsByExternalId(match.externalId)) { skipped++ }
            else { matchRepository.save(match); created++
                log.info("Saved basketball match: {} vs {} on {}", match.homeTeam, match.awayTeam, match.matchDate) }
        }
        log.info("Basketball sync complete - created: {}, skipped: {}", created, skipped)
    }

    @Transactional
    fun syncLiveBasketballStatuses() {
        val json = apiClient.fetchBasketballLiveMatches() ?: return
        val events = json["events"] ?: return
        if (!events.isArray) return
        for (wrapper in events) {
            val externalId = wrapper["event"]?.get("id")?.asText() ?: continue
            val match = matchRepository.findByExternalId(externalId) ?: continue
            if (match.sport != "BASKETBALL") continue
            if (match.status != MatchStatus.LIVE) {
                matchRepository.save(match.copy(status = MatchStatus.LIVE, updatedAt = LocalDateTime.now()))
                log.info("Basketball match {} vs {} is now LIVE", match.homeTeam, match.awayTeam)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Shared helpers
    // -------------------------------------------------------------------------

    // Each item in Kambi's events array is a wrapper: {"event": {...}, "betOffers": [...]}
    private fun parseMatch(wrapper: JsonNode, sport: String = "FOOTBALL"): Match? {
        return try {
            val e = wrapper["event"] ?: return null
            // Esports matches have termKey "esports_football" in their path — skip them
            val path = e["path"]
            if (path != null && path.any { it["termKey"]?.asText()?.contains("esport", ignoreCase = true) == true }) {
                return null
            }
            Match(
                externalId  = e["id"]?.asText()       ?: return null,
                homeTeam    = e["homeName"]?.asText()  ?: e["name"]?.asText() ?: "Unknown",
                awayTeam    = e["awayName"]?.asText()  ?: "Unknown",
                competition = e["group"]?.asText()     ?: "",
                matchDate   = parseDate(e["start"]?.asText()),
                betplayUrl  = null,
                sport       = sport,
                status      = MatchStatus.UPCOMING,
                createdAt   = LocalDateTime.now(),
                updatedAt   = LocalDateTime.now()
            )
        } catch (e: Exception) {
            log.warn("Failed to parse match event: {} - {}", wrapper.toString().take(200), e.message)
            null
        }
    }

    private fun parseDate(raw: String?): LocalDateTime {
        if (raw == null) return LocalDateTime.now().plusDays(1)
        return try {
            // Try ISO format first, then epoch millis
            if (raw.contains("T")) {
                LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME)
            } else {
                LocalDateTime.ofEpochSecond(raw.toLong() / 1000, 0, java.time.ZoneOffset.UTC)
            }
        } catch (e: Exception) {
            log.warn("Could not parse date '{}': {}", raw, e.message)
            LocalDateTime.now().plusDays(1)
        }
    }
}
