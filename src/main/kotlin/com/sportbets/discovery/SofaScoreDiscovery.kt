package com.sportbets.discovery

import com.microsoft.playwright.*
import com.microsoft.playwright.options.WaitUntilState
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

/**
 * SofaScore API Discovery Tool
 * ============================================================
 * Run with the "discover-sofascore" profile to intercept real API calls
 * made by sofascore.com in a live browser session.
 *
 * How to run:
 *   ./gradlew bootRun --args="--spring.profiles.active=discover-sofascore"
 *
 * What it does:
 *   1. Launches a headed browser and navigates to sofascore.com/football/live
 *   2. Intercepts all JSON calls to api.sofascore.com
 *   3. Captures full response bodies for stats/event endpoints
 *   4. Waits for you to click into live matches
 *   5. Saves results to sofascore-discovery.txt
 *
 * What to look for:
 *   Navigate to any live match → click "Statistics" tab.
 *   The tool will capture the endpoint + full JSON with shots, possession, etc.
 * ============================================================
 */
@Component
@Profile("discover-sofascore")
class SofaScoreDiscovery : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    private val statsKeywords = listOf(
        "/statistics", "/events/live", "/sport/football",
        "sofascore", "/event/", "/incidents", "/lineups"
    )

    override fun run(args: ApplicationArguments) {
        val waitSeconds = args.getOptionValues("wait")?.firstOrNull()?.toLongOrNull() ?: 180L
        log.info("=== SOFASCORE API DISCOVERY — {}s window ===", waitSeconds)
        log.info("A browser will open. Navigate to a live match and click the Statistics tab.")

        val captured = mutableMapOf<String, CapturedEntry>()

        try { Playwright.create().use { playwright ->
            val browser = playwright.chromium().launch(
                BrowserType.LaunchOptions()
                    .setHeadless(false)
                    .setSlowMo(0.0)
            )
            val context = browser.newContext(
                Browser.NewContextOptions()
                    .setLocale("en-US")
                    .setTimezoneId("America/Bogota")
                    .setUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
            )
            val page = context.newPage()

            page.onRequest { request ->
                val url = request.url()
                if (isRelevant(url)) {
                    synchronized(captured) {
                        if (!captured.containsKey(url)) {
                            captured[url] = CapturedEntry(method = request.method(), url = url, headers = request.headers())
                            log.info("[REQUEST] {} {}", request.method(), url)
                        }
                    }
                }
            }

            page.onResponse { response ->
                val url = response.url()
                if (isRelevant(url) && response.headers()["content-type"]?.contains("json") == true) {
                    try {
                        val body = response.text()
                        synchronized(captured) {
                            captured[url]?.let { entry ->
                                if (entry.responseBody == null) {
                                    entry.responseBody = body
                                    log.info("[RESPONSE] {} bytes from {}", body.length, url.take(80))
                                }
                            }
                        }
                    } catch (_: Exception) { }
                }
            }

            log.info("Navigating to sofascore.com/football/live ...")
            try {
                page.navigate(
                    "https://www.sofascore.com/football/live",
                    Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(30000.0)
                )
            } catch (e: Exception) {
                log.warn("Navigation timeout (normal): {}", e.message)
            }

            log.info("Browser ready. Waiting 15s for page to fully load before fetching stats...")
            Thread.sleep(15_000)

            // Fetch live events list from within the browser context (has session cookies)
            log.info("Fetching live football events via in-browser fetch...")
            val liveEventsJson = try {
                page.evaluate("""
                    async () => {
                        const r = await fetch('/api/v1/sport/football/events/live');
                        return await r.text();
                    }
                """.trimIndent()) as? String
            } catch (e: Exception) {
                log.warn("Live events fetch failed: {}", e.message); null
            }

            if (liveEventsJson != null) {
                log.info("Live events response ({} chars) — parsing event IDs...", liveEventsJson.length)
                // Event IDs are 7-8 digit numbers; sport/category/tournament IDs are much smaller
                val eventIds = Regex(""""id"\s*:\s*(\d{7,})""").findAll(liveEventsJson)
                    .map { it.groupValues[1] }
                    .distinct().take(5).toList()
                log.info("Sampling statistics for event IDs: {}", eventIds)

                eventIds.forEach { eventId ->
                    val statsJson = try {
                        page.evaluate("""
                            async () => {
                                const r = await fetch('/api/v1/event/$eventId/statistics');
                                if (!r.ok) return null;
                                return await r.text();
                            }
                        """.trimIndent()) as? String
                    } catch (e: Exception) { null }

                    if (statsJson != null) {
                        log.info("[STATS eventId={}] {} chars captured", eventId, statsJson.length)
                        synchronized(captured) {
                            captured["https://www.sofascore.com/api/v1/event/$eventId/statistics"] =
                                CapturedEntry("GET", "https://www.sofascore.com/api/v1/event/$eventId/statistics",
                                    emptyMap(), statsJson)
                        }
                    } else {
                        log.info("[STATS eventId={}] no stats available (match may not have started)", eventId)
                    }
                }

                synchronized(captured) {
                    captured["https://www.sofascore.com/api/v1/sport/football/events/live"] =
                        CapturedEntry("GET", "https://www.sofascore.com/api/v1/sport/football/events/live",
                            emptyMap(), liveEventsJson.take(3000))
                }
            }

            log.info("You still have {}s to click into matches for additional captures...", waitSeconds)
            Thread.sleep(waitSeconds * 1_000)
            try { browser.close() } catch (_: Throwable) { }
        } } finally { saveResults(captured) }
    }

    private fun isRelevant(url: String): Boolean {
        val lower = url.lowercase()
        if (!lower.contains("sofascore")) return false
        if (statsKeywords.none { lower.contains(it) }) return false
        if (lower.contains(".js") || lower.contains(".css") || lower.contains(".png")) return false
        return true
    }

    private fun saveResults(captured: Map<String, CapturedEntry>) {
        val sb = StringBuilder()
        sb.appendLine("=".repeat(70))
        sb.appendLine("SOFASCORE API DISCOVERY — ${captured.size} endpoints captured")
        sb.appendLine("=".repeat(70))
        sb.appendLine()

        captured.values.forEach { entry ->
            sb.appendLine("[${entry.method}] ${entry.url}")
            entry.responseBody?.let { body ->
                sb.appendLine("  RESPONSE (${body.length} bytes):")
                sb.appendLine(body.take(2000).prependIndent("    "))
            }
            sb.appendLine()
        }

        val file = java.io.File("sofascore-discovery.txt")
        file.writeText(sb.toString())
        log.info("Results saved to {} ({} endpoints)", file.absolutePath, captured.size)
    }

    data class CapturedEntry(
        val method: String,
        val url: String,
        val headers: Map<String, String>,
        var responseBody: String? = null,
    )
}
