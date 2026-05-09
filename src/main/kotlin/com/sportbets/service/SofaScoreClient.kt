package com.sportbets.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.microsoft.playwright.Browser
import com.microsoft.playwright.BrowserType
import com.microsoft.playwright.Page
import com.microsoft.playwright.Playwright
import com.microsoft.playwright.options.WaitUntilState
import jakarta.annotation.PostConstruct
import jakarta.annotation.PreDestroy
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

@Service
class SofaScoreClient(
    @Value("\${betplay.sofascore.enabled:true}") private val enabled: Boolean,
    @Value("\${betplay.sofascore.headless:true}") private val headless: Boolean,
    private val objectMapper: ObjectMapper,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val lock = ReentrantLock()

    private var playwright: Playwright? = null
    private var page: Page? = null

    @PostConstruct
    fun start() {
        if (!enabled) { log.info("SofaScore integration disabled"); return }
        try {
            playwright = Playwright.create()
            val browser = playwright!!.chromium().launch(
                BrowserType.LaunchOptions().setHeadless(headless)
            )
            val context = browser.newContext(
                Browser.NewContextOptions()
                    .setUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
                    .setLocale("en-US")
                    .setTimezoneId("America/Bogota")
            )
            page = context.newPage()
            // Navigate to the root — sofascore.com is a SPA; any page on the domain
            // gives us the session context needed for fetch() calls to /api/v1/*
            page!!.navigate(
                "https://www.sofascore.com",
                Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(30000.0)
            )
            log.info("SofaScore browser ready (headless={})", headless)
        } catch (e: Exception) {
            log.warn("SofaScore browser failed to start — stats will be unavailable: {}", e.message)
        }
    }

    @PreDestroy
    fun stop() {
        try { playwright?.close() } catch (_: Throwable) {}
    }

    /**
     * Looks up the SofaScore event ID for a live match by fuzzy-matching team names
     * against the current live football events list.
     * Returns null if no match is found or the browser is unavailable.
     */
    fun findEventId(homeTeam: String, awayTeam: String): String? {
        val json = evalFetch("/api/v1/sport/football/events/live") ?: return null
        return try {
            val root = objectMapper.readTree(json)
            if (root["httpError"] != null) {
                log.warn("SofaScore live events HTTP {}", root["httpError"].asInt())
                return null
            }
            val events = root["events"] ?: return null
            for (event in events) {
                val sfHome = event["homeTeam"]?.get("name")?.asText() ?: continue
                val sfAway = event["awayTeam"]?.get("name")?.asText() ?: continue
                if (namesMatch(homeTeam, sfHome) && namesMatch(awayTeam, sfAway)) {
                    val id = event["id"]?.asText()
                    log.debug("SofaScore match found for {} vs {}: id={}", homeTeam, awayTeam, id)
                    return id
                }
            }
            log.info("SofaScore: no match found for {} vs {} in live events", homeTeam, awayTeam)
            null
        } catch (e: Exception) {
            log.warn("SofaScore: failed to parse live events: {}", e.message)
            null
        }
    }

    /**
     * Fetches live statistics for the given SofaScore event ID.
     * Returns null if stats are unavailable or the browser is down.
     */
    fun fetchStats(sofaScoreId: String, homeTeam: String = "", awayTeam: String = ""): SofaScoreStats? {
        val json = evalFetch("/api/v1/event/$sofaScoreId/statistics") ?: return null
        return try {
            val root = objectMapper.readTree(json)
            if (root["httpError"] != null) {
                log.info("SofaScore stats unavailable (HTTP {}) for id={} [{} vs {}]",
                    root["httpError"].asInt(), sofaScoreId, homeTeam, awayTeam)
                return null
            }
            if (root["error"] != null) return null

            val allPeriod = root["statistics"]
                ?.firstOrNull { it["period"]?.asText() == "ALL" } ?: return null

            val values = mutableMapOf<String, Pair<Int?, Int?>>()
            allPeriod["groups"]?.forEach { group ->
                group["statisticsItems"]?.forEach { item ->
                    val key = item["key"]?.asText() ?: return@forEach
                    values[key] = item["homeValue"]?.asInt() to item["awayValue"]?.asInt()
                }
            }

            val stats = SofaScoreStats(
                homePossession     = values["ballPossession"]?.first,
                awayPossession     = values["ballPossession"]?.second,
                homeShotsOnTarget  = values["shotsOnGoal"]?.first,
                awayShotsOnTarget  = values["shotsOnGoal"]?.second,
                homeShotsOffTarget = values["shotsOffGoal"]?.first,
                awayShotsOffTarget = values["shotsOffGoal"]?.second,
            )
            log.debug("SofaScore stats ok [{} vs {}] id={}: poss {}:{} shots-on {}:{} shots-off {}:{}",
                homeTeam, awayTeam, sofaScoreId,
                stats.homePossession, stats.awayPossession,
                stats.homeShotsOnTarget, stats.awayShotsOnTarget,
                stats.homeShotsOffTarget, stats.awayShotsOffTarget)
            stats
        } catch (e: Exception) {
            log.warn("SofaScore: failed to parse stats for id={}: {}", sofaScoreId, e.message)
            null
        }
    }

    private fun evalFetch(path: String): String? {
        val p = page ?: return null
        val url = "https://api.sofascore.com$path"
        return try {
            lock.withLock {
                p.evaluate("""
                    async () => {
                        const r = await fetch('$url', {
                            headers: {
                                'Accept': 'application/json',
                                'Referer': 'https://www.sofascore.com/',
                                'Origin': 'https://www.sofascore.com'
                            }
                        });
                        if (!r.ok) return JSON.stringify({httpError: r.status});
                        return await r.text();
                    }
                """.trimIndent()) as? String
            }
        } catch (e: Exception) {
            log.warn("SofaScore fetch {} failed: {} — attempting reconnect", path, e.message)
            tryReconnect()
            null
        }
    }

    private fun tryReconnect() {
        try {
            page?.navigate(
                "https://www.sofascore.com",
                Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(15000.0)
            )
            log.info("SofaScore browser reconnected")
        } catch (e: Exception) {
            log.warn("SofaScore reconnect failed: {}", e.message)
        }
    }

    // Normalise: lowercase, strip accents, keep only alphanumeric + spaces
    private fun normalise(s: String): String =
        java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFD)
            .replace(Regex("[^\\p{ASCII}]"), "")
            .lowercase()
            .replace(Regex("[^a-z0-9 ]"), "")
            .replace(Regex("\\s+"), " ")
            .trim()

    private fun namesMatch(a: String, b: String): Boolean {
        val na = normalise(a)
        val nb = normalise(b)
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    data class SofaScoreStats(
        val homePossession: Int?,
        val awayPossession: Int?,
        val homeShotsOnTarget: Int?,
        val awayShotsOnTarget: Int?,
        val homeShotsOffTarget: Int?,
        val awayShotsOffTarget: Int?,
    )
}
