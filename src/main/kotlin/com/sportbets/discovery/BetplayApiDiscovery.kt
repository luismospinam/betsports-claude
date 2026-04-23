package com.sportbets.discovery

import com.microsoft.playwright.*
import com.microsoft.playwright.options.WaitUntilState
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

/**
 * Betplay API Discovery Tool
 * ============================================================
 * Run this ONCE with the "discover" Spring profile to intercept
 * all network requests that betplay.com.co makes in a real browser.
 *
 * This tells you the real API endpoint URLs so you can fill in
 * application.yml (betplay.api.*).
 *
 * How to run:
 *   ./gradlew bootRun --args="--spring.profiles.active=discover"
 *
 * Or from IntelliJ: add VM arg  -Dspring.profiles.active=discover
 *
 * What it does:
 *   1. Launches a visible Chromium browser (headed mode)
 *   2. Navigates to betplay.com.co → sports/football section
 *   3. Intercepts ALL XHR and Fetch requests for 60 seconds
 *   4. Prints a summary of API-like endpoints found
 *   5. Saves full results to betplay-api-discovery.txt
 *
 * Look for URLs containing: /api/, /events, /odds, /sports, /live
 * ============================================================
 */
@Component
@Profile("discover")
class BetplayApiDiscovery : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    private val excludePatterns = listOf(
        ".css", ".js", ".png", ".jpg", ".svg", ".ico", ".woff",
        "google", "facebook", "analytics", "hotjar", "sentry",
        "cloudfront", "static", "cookieyes", "sitescout", "spotify",
        "trafficguard", "kwai", "rtmark", "adnxs", "bidr.io", "adsrvr",
        "mythad", "connextra", "containermedia", "kumulos", "byads"
    )

    private val includeKeywords = listOf(
        "/api/", "/rest/", "/v1/", "/v2/", "/v3/", "/offering/",
        "kambi", "shapegames",
        "events", "odds", "sports", "live", "fixture",
        "match", "market", "bet", "soccer", "football", "futbol"
    )

    override fun run(args: ApplicationArguments) {
        log.info("=== BETPLAY API DISCOVERY MODE ===")
        log.info("Launching browser. This will open a visible Chrome window...")
        log.info("You have 90 seconds. Navigate around the soccer section.")
        log.info("Press Ctrl+C when done to see the results.")

        val capturedRequests = mutableListOf<CapturedRequest>()

        Playwright.create().use { playwright ->
            val browser = playwright.chromium().launch(
                BrowserType.LaunchOptions()
                    .setHeadless(false)  // visible browser so you can navigate manually
                    .setSlowMo(0.0)
            )
            val context = browser.newContext(
                Browser.NewContextOptions()
                    .setLocale("es-CO")
                    .setTimezoneId("America/Bogota")
                    .setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            )
            val page = context.newPage()

            // Intercept all requests
            page.onRequest { request ->
                val url = request.url()
                val method = request.method()
                if (isApiLike(url)) {
                    val captured = CapturedRequest(
                        method  = method,
                        url     = url,
                        headers = request.headers()
                    )
                    synchronized(capturedRequests) {
                        if (capturedRequests.none { it.url == url }) {
                            capturedRequests.add(captured)
                            log.info("[CAPTURED] {} {}", method, url)
                        }
                    }
                }
            }

            // Intercept responses to see JSON structure
            page.onResponse { response ->
                val url = response.url()
                if (isApiLike(url) && response.headers()["content-type"]?.contains("json") == true) {
                    try {
                        val body = response.text()
                        synchronized(capturedRequests) {
                            val req = capturedRequests.find { it.url == url }
                            if (req != null && req.responsePreview == null) {
                                req.responsePreview = body.take(500)
                            }
                        }
                    } catch (_: Exception) { }
                }
            }

            log.info("Navigating to betplay.com.co/apuestas#sports-hub/football...")
            try {
                page.navigate(
                    "https://betplay.com.co/apuestas#sports-hub/football",
                    Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(30000.0)
                )
            } catch (e: Exception) {
                log.warn("Navigation timeout (normal for heavy JS sites): {}", e.message)
            }

            log.info("Page loaded. Waiting 90 seconds for you to browse around...")
            log.info("Navigate to: soccer matches, live games, any match details page")
            Thread.sleep(90_000)

            browser.close()
        }

        // Print and save results
        printResults(capturedRequests)
    }

    private fun printResults(requests: List<CapturedRequest>) {
        val output = StringBuilder()
        output.appendLine("=".repeat(70))
        output.appendLine("BETPLAY API DISCOVERY RESULTS - ${requests.size} unique endpoints found")
        output.appendLine("=".repeat(70))
        output.appendLine()

        val grouped = requests.groupBy { extractBaseUrl(it.url) }
        grouped.forEach { (base, reqs) ->
            output.appendLine("BASE: $base")
            reqs.forEach { r ->
                output.appendLine("  [${r.method}] ${r.url}")
                if (r.responsePreview != null) {
                    output.appendLine("  RESPONSE: ${r.responsePreview?.take(300)}")
                }
            }
            output.appendLine()
        }

        output.appendLine()
        output.appendLine("=".repeat(70))
        output.appendLine("SUGGESTED application.yml values (UPDATE these with real values):")
        output.appendLine("=".repeat(70))

        val eventsUrl = requests.firstOrNull {
            it.url.contains("event", true) || it.url.contains("fixture", true)
        }?.url
        val oddsUrl = requests.firstOrNull {
            it.url.contains("odd", true) || it.url.contains("market", true)
        }?.url
        val liveUrl = requests.firstOrNull {
            it.url.contains("live", true) && (it.url.contains("event", true) || it.url.contains("match", true))
        }?.url

        val baseUrl = eventsUrl?.let { extractBaseUrl(it) } ?: "https://betplay.com.co"

        output.appendLine("""
            betplay:
              api:
                base-url: $baseUrl
                events-path: ${eventsUrl?.removePrefix(baseUrl) ?: "/api/sports/events  # UPDATE ME"}
                odds-path: ${oddsUrl?.removePrefix(baseUrl) ?: "/api/sports/events/{eventId}/odds  # UPDATE ME"}
                live-path: ${liveUrl?.removePrefix(baseUrl) ?: "/api/sports/live  # UPDATE ME"}
        """.trimIndent())

        println(output)

        // Save to file
        try {
            java.io.File("betplay-api-discovery.txt").writeText(output.toString())
            log.info("Results saved to betplay-api-discovery.txt")
        } catch (e: Exception) {
            log.warn("Could not save results file: {}", e.message)
        }
    }

    private fun isApiLike(url: String): Boolean {
        val lower = url.lowercase()
        if (excludePatterns.any { lower.contains(it) }) return false
        return includeKeywords.any { lower.contains(it) }
    }

    private fun extractBaseUrl(url: String): String {
        return try {
            val uri = java.net.URI(url)
            "${uri.scheme}://${uri.host}"
        } catch (_: Exception) {
            url.take(50)
        }
    }

    data class CapturedRequest(
        val method: String,
        val url: String,
        val headers: Map<String, String>,
        var responsePreview: String? = null
    )
}
