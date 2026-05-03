package com.sportbets.discovery

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import okhttp3.OkHttpClient
import okhttp3.Request
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component
import java.util.concurrent.TimeUnit

/**
 * Sports Discovery Tool
 * ============================================================
 * Run with the "discover-sports" profile to find all sports
 * available on BetPlay's Kambi offering (no browser needed).
 *
 * How to run:
 *   ./gradlew bootRun --args="--spring.profiles.active=discover-sports"
 *
 * What it does:
 *   1. Sweeps all known Kambi sport slugs against the BetPlay endpoint
 *   2. Reports which sports have upcoming and/or live events
 *   3. Prints event counts, competition names, and sample bet offer types
 *   4. Saves full results to sports-discovery.txt
 * ============================================================
 */
@Component
@Profile("discover-sports")
class SportsDiscoveryRunner(
    private val objectMapper: ObjectMapper,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    private val baseUrl = "https://na-offering-api.kambicdn.net"
    private val commonParams = "lang=es_CO&market=CO&client_id=2&channel_id=1&useCombined=true"

    // Known Kambi sport slugs — covers virtually all sports offered globally
    private val sportSlugs = listOf(
        "football",
        "basketball",
        "tennis",
        "baseball",
        "american_football",
        "ice_hockey",
        "volleyball",
        "rugby_union",
        "rugby_league",
        "esports",
        "boxing",
        "mixed_martial_arts",
        "cycling",
        "golf",
        "handball",
        "table_tennis",
        "athletics",
        "cricket",
        "darts",
        "snooker",
        "motorsport",
        "water_polo",
        "futsal",
        "beach_volleyball",
        "swimming",
        "badminton",
        "field_hockey",
        "floorball",
        "bandy",
        "bowls",
        "netball",
        "aussie_rules",
    )

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val req = chain.request().newBuilder()
                .header("Accept", "application/json")
                .header("Accept-Language", "es-CO,es;q=0.9")
                .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                .header("Referer", "https://betplay.com.co/")
                .build()
            chain.proceed(req)
        }
        .build()

    override fun run(args: ApplicationArguments) {
        log.info("=== BETPLAY SPORTS DISCOVERY ===")
        log.info("Probing {} sport slugs against the BetPlay Kambi offering...", sportSlugs.size)

        val results = sportSlugs.map { slug ->
            val upcoming = probe(slug, "matches")
            val live = probe(slug, "in-play")
            SportResult(slug, upcoming, live).also { r ->
                if (r.hasAny) log.info("[FOUND] {:25} — upcoming: {:3}  live: {:3}  competitions: {}",
                    slug, r.upcomingCount, r.liveCount,
                    r.competitions.take(3).joinToString(", "))
                else log.debug("[    ] {}", slug)
            }
        }

        printReport(results)
    }

    private fun probe(sport: String, endpoint: String): JsonNode? {
        val url = "$baseUrl/offering/v2018/betplay/listView/$sport/all/all/all/$endpoint.json?$commonParams"
        return try {
            val request = Request.Builder().url(url).get().build()
            httpClient.newCall(request).execute().use { response ->
                if (response.code == 404 || response.code == 400) return null
                if (!response.isSuccessful) return null
                val body = response.body?.string() ?: return null
                val tree = objectMapper.readTree(body)
                // Kambi returns {events: [...]} — treat empty array as no result
                if (tree.path("events").size() == 0) null else tree
            }
        } catch (_: Exception) { null }
    }

    private fun printReport(results: List<SportResult>) {
        val active = results.filter { it.hasAny }.sortedByDescending { it.upcomingCount + it.liveCount }
        val output = StringBuilder()

        output.appendLine("=".repeat(70))
        output.appendLine("BETPLAY SPORTS DISCOVERY — ${active.size} active sports found (of ${results.size} probed)")
        output.appendLine("=".repeat(70))
        output.appendLine()

        if (active.isEmpty()) {
            output.appendLine("No sports found. Check network access or Kambi client_id.")
        } else {
            output.appendLine("%-30s %8s %6s  COMPETITIONS".format("SPORT SLUG", "UPCOMING", "LIVE"))
            output.appendLine("-".repeat(70))
            active.forEach { r ->
                output.appendLine("%-30s %8d %6d  %s".format(
                    r.slug, r.upcomingCount, r.liveCount,
                    r.competitions.take(5).joinToString(", ")
                        .let { if (r.competitions.size > 5) "$it … (+${r.competitions.size - 5} more)" else it }
                ))
            }
        }

        output.appendLine()
        output.appendLine("=".repeat(70))
        output.appendLine("SAMPLE application.yml PATHS FOR ACTIVE SPORTS")
        output.appendLine("=".repeat(70))
        active.forEach { r ->
            output.appendLine("""
  # ${r.slug} (${r.upcomingCount} upcoming, ${r.liveCount} live)
  events-path: /offering/v2018/betplay/listView/${r.slug}/all/all/all/matches.json?lang=es_CO&market=CO&client_id=2&channel_id=1&useCombined=true
  live-path:   /offering/v2018/betplay/listView/${r.slug}/all/all/all/in-play.json?lang=es_CO&market=CO&client_id=2&channel_id=1
""".trimIndent())
        }

        output.appendLine()
        output.appendLine("Inactive slugs: ${results.filter { !it.hasAny }.joinToString(", ") { it.slug }}")

        println(output)

        try {
            java.io.File("sports-discovery.txt").writeText(output.toString())
            log.info("Results saved to sports-discovery.txt")
        } catch (e: Exception) {
            log.warn("Could not save results file: {}", e.message)
        }
    }

    private data class SportResult(
        val slug: String,
        val upcomingJson: JsonNode?,
        val liveJson: JsonNode?,
    ) {
        val upcomingCount: Int get() = upcomingJson?.path("events")?.size() ?: 0
        val liveCount: Int get() = liveJson?.path("events")?.size() ?: 0
        val hasAny: Boolean get() = upcomingCount > 0 || liveCount > 0

        val competitions: List<String> get() {
            val nodes = sequenceOf(upcomingJson, liveJson)
                .filterNotNull()
                .flatMap { it.path("events").asSequence() }
            return nodes
                .mapNotNull { it.path("event").path("group").textValue()
                    ?: it.path("event").path("path")?.lastOrNull()?.path("name")?.textValue() }
                .distinct()
                .sorted()
                .toList()
        }
    }
}
