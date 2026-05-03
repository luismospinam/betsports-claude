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
 * Sport Offers Inspector
 * ============================================================
 * Dumps the full Kambi API structure for a given sport so you
 * know exactly what liveData fields, bet offer categories, and
 * outcome types are available before implementing a strategy.
 *
 * How to run (basketball example):
 *   ./gradlew bootRun --args="--spring.profiles.active=inspect-sport --sport=basketball"
 *
 * Other sports: tennis, baseball, table_tennis, esports, etc.
 * Output saved to sport-inspect-{sport}.txt
 * ============================================================
 */
@Component
@Profile("inspect-sport")
class SportOffersInspector(
    private val objectMapper: ObjectMapper,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)
    private val baseUrl = "https://na-offering-api.kambicdn.net"
    private val commonParams = "lang=es_CO&market=CO&client_id=2&channel_id=1&useCombined=true"

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            chain.proceed(
                chain.request().newBuilder()
                    .header("Accept", "application/json")
                    .header("Accept-Language", "es-CO,es;q=0.9")
                    .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                    .header("Referer", "https://betplay.com.co/")
                    .build()
            )
        }
        .build()

    override fun run(args: ApplicationArguments) {
        val sport = args.getOptionValues("sport")?.firstOrNull() ?: "basketball"
        log.info("=== SPORT OFFERS INSPECTOR: {} ===", sport)

        val output = StringBuilder()
        output.appendLine("=".repeat(70))
        output.appendLine("SPORT OFFERS INSPECTOR — $sport")
        output.appendLine("=".repeat(70))

        // 1. Fetch live events
        val liveJson = getJson("$baseUrl/offering/v2018/betplay/listView/$sport/all/all/all/in-play.json?$commonParams")
        val liveEvents = liveJson?.path("events")?.toList() ?: emptyList()
        output.appendLine("\nLIVE EVENTS: ${liveEvents.size}")

        if (liveEvents.isNotEmpty()) {
            output.appendLine("\n--- LIVE EVENT SAMPLE (first event) ---")
            val first = liveEvents.first()
            appendEventSummary(output, first, live = true)

            // Full betoffer detail — compare client_id=2 vs client_id=200 to see if more markets appear
            val eventId = first.path("event").path("id").asText()
            if (eventId.isNotBlank()) {
                val offers2   = getJson("$baseUrl/offering/v2018/betplay/betoffer/event/$eventId.json?lang=es_CO&market=CO&client_id=2&channel_id=1&includeParticipants=true")
                val offers200 = getJson("$baseUrl/offering/v2018/betplay/betoffer/event/$eventId.json?lang=es_CO&market=CO&client_id=200&channel_id=1&includeParticipants=true")
                appendBetOffers(output, offers2,   label = "LIVE EVENT $eventId [client_id=2]")
                appendBetOffers(output, offers200, label = "LIVE EVENT $eventId [client_id=200]")
            }
        }

        // 2. Fetch upcoming events
        val upcomingJson = getJson("$baseUrl/offering/v2018/betplay/listView/$sport/all/all/all/matches.json?$commonParams")
        val upcomingEvents = upcomingJson?.path("events")?.toList() ?: emptyList()
        output.appendLine("\nUPCOMING EVENTS: ${upcomingEvents.size}")

        if (upcomingEvents.isNotEmpty()) {
            output.appendLine("\n--- UPCOMING EVENT SAMPLE (first event) ---")
            val first = upcomingEvents.first()
            appendEventSummary(output, first, live = false)

            val eventId = first.path("event").path("id").asText()
            if (eventId.isNotBlank()) {
                val offersJson = getJson("$baseUrl/offering/v2018/betplay/betoffer/event/$eventId.json?lang=es_CO&market=CO&client_id=200&channel_id=1&includeParticipants=true")
                appendBetOffers(output, offersJson, label = "UPCOMING EVENT $eventId")
            }

            // Also inspect a second upcoming event for variety
            if (upcomingEvents.size > 1) {
                val second = upcomingEvents[1]
                val secondId = second.path("event").path("id").asText()
                if (secondId.isNotBlank()) {
                    val offersJson = getJson("$baseUrl/offering/v2018/betplay/betoffer/event/$secondId.json?lang=es_CO&market=CO&client_id=200&channel_id=1&includeParticipants=true")
                    appendBetOffers(output, offersJson, label = "UPCOMING EVENT $secondId (2nd sample)")
                }
            }
        }

        // 3. Aggregate all bet offer criterion labels and outcome types seen across all events
        output.appendLine("\n=".repeat(70))
        output.appendLine("AGGREGATE: all criterion labels + outcome types seen across ${minOf(upcomingEvents.size, 10)} upcoming events")
        output.appendLine("=".repeat(70))
        val allCriteria = mutableMapOf<String, MutableSet<String>>() // criterion label → set of outcome type labels
        upcomingEvents.take(10).forEach { wrapper ->
            val eid = wrapper.path("event").path("id").asText()
            if (eid.isBlank()) return@forEach
            val offersJson = getJson("$baseUrl/offering/v2018/betplay/betoffer/event/$eid.json?lang=es_CO&market=CO&client_id=200&channel_id=1&includeParticipants=true")
            offersJson?.path("betOffers")?.forEach { offer ->
                val label = offer.path("criterion").path("label").asText("?")
                val outcomes = offer.path("outcomes").map { it.path("type").asText("?") }.toSet()
                allCriteria.getOrPut(label) { mutableSetOf() }.addAll(outcomes)
            }
        }
        allCriteria.entries.sortedBy { it.key }.forEach { (label, outcomes) ->
            output.appendLine("  %-45s → %s".format(label, outcomes.sorted().joinToString(", ")))
        }

        println(output)
        val filename = "sport-inspect-$sport.txt"
        try {
            java.io.File(filename).writeText(output.toString())
            log.info("Results saved to {}", filename)
        } catch (e: Exception) {
            log.warn("Could not save file: {}", e.message)
        }
    }

    private fun appendEventSummary(out: StringBuilder, wrapper: JsonNode, live: Boolean) {
        val event = wrapper.path("event")
        out.appendLine("  id:          ${event.path("id").asText()}")
        out.appendLine("  name:        ${event.path("name").asText()}")
        out.appendLine("  group:       ${event.path("group").asText()}")
        out.appendLine("  start:       ${event.path("start").asText()}")
        out.appendLine("  state:       ${event.path("state").asText()}")

        val participants = event.path("participants")
        if (participants.isArray) {
            participants.forEach { p ->
                out.appendLine("  participant: ${p.path("name").asText()} (${p.path("type").asText()})")
            }
        }

        if (live) {
            val ld = wrapper.path("liveData")
            if (!ld.isMissingNode) {
                out.appendLine("  --- liveData ---")
                out.appendLine("  liveData raw:\n${objectMapper.writerWithDefaultPrettyPrinter().writeValueAsString(ld).prependIndent("    ")}")
            }
        }

        // Inline betOffers from the listView response
        val betOffers = wrapper.path("betOffers")
        if (betOffers.isArray && betOffers.size() > 0) {
            out.appendLine("  --- betOffers in listView response (${betOffers.size()} offers) ---")
            betOffers.forEach { offer ->
                val criterion = offer.path("criterion").path("label").asText("?")
                val outcomes = offer.path("outcomes").map {
                    "${it.path("type").asText("?")} odds=${it.path("odds").asLong()}"
                }
                out.appendLine("    [$criterion]  ${outcomes.joinToString("  |  ")}")
            }
        }
    }

    private fun appendBetOffers(out: StringBuilder, offersJson: JsonNode?, label: String) {
        if (offersJson == null) { out.appendLine("\n[$label] — failed to fetch"); return }
        val offers = offersJson.path("betOffers").toList()
        out.appendLine("\n[$label] — ${offers.size} bet offers")
        offers.forEach { offer ->
            val criterion = offer.path("criterion").path("label").asText("?")
            val categoryId = offer.path("betOfferType").path("id").asLong()
            val suspended = offer.path("suspended").asBoolean()
            val outcomes = offer.path("outcomes").map {
                val type    = it.path("type").asText("?")
                val odds    = it.path("odds").asLong()
                val label2  = it.path("label").asText("")
                val line    = it.path("line").asText("")        // handicap line value e.g. -8500
                val handicap = it.path("handicap").asText("")   // may also carry the spread
                val id      = it.path("id").asLong()
                "id=$id $type(${if (label2.isNotBlank()) label2 else "?"}) odds=$odds" +
                    (if (line.isNotBlank()) " line=$line" else "") +
                    (if (handicap.isNotBlank()) " handicap=$handicap" else "")
            }
            out.appendLine("  [catId=$categoryId${if (suspended) " SUSPENDED" else ""}] $criterion")
            outcomes.forEach { out.appendLine("      $it") }
        }
    }

    private fun getJson(url: String): JsonNode? {
        return try {
            log.debug("GET {}", url)
            val request = Request.Builder().url(url).get().build()
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) { log.warn("HTTP {} for {}", response.code, url); return null }
                val body = response.body?.string() ?: return null
                objectMapper.readTree(body)
            }
        } catch (e: Exception) {
            log.error("Failed: {} — {}", url, e.message)
            null
        }
    }
}
