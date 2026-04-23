package com.sportbets.service

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import okhttp3.OkHttpClient
import okhttp3.Request
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import java.util.concurrent.TimeUnit

/**
 * HTTP client for the Betplay/Kambi API (na-offering-api.kambicdn.net).
 *
 * Endpoints are configured in application.yml under betplay.api.*.
 * Odds values in Kambi responses are in milliunits — divide by 1000 for decimal odds.
 */
@Component
class BetplayApiClient(
    private val objectMapper: ObjectMapper,
    @Value("\${betplay.api.base-url}") private val baseUrl: String,
    @Value("\${betplay.api.events-path}") private val eventsPath: String,
    @Value("\${betplay.api.odds-path}") private val oddsPath: String,
    @Value("\${betplay.api.live-path}") private val livePath: String,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        // Betplay requires these headers — adjust after discovery if needed
        .addInterceptor { chain ->
            val request = chain.request().newBuilder()
                .header("Accept", "application/json")
                .header("Accept-Language", "es-CO,es;q=0.9")
                .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                .header("Referer", "https://betplay.com.co/")
                .build()
            chain.proceed(request)
        }
        .build()

    fun fetchUpcomingMatches(): JsonNode? {
        val url = "$baseUrl$eventsPath&ncid=${System.currentTimeMillis()}"
        return getJson(url)
    }

    fun fetchOdds(externalMatchId: String): JsonNode? {
        val url = "$baseUrl${oddsPath.replace("{eventId}", externalMatchId)}"
        return getJson(url)
    }

    /**
     * Returns all live soccer matches.
     * Each element in events[] is a wrapper: {event, betOffers, liveData}
     * liveData contains: score {home, away}, matchClock {minute, second, periodId, running}, statistics
     */
    fun fetchLiveMatches(): JsonNode? {
        val url = "$baseUrl$livePath&ncid=${System.currentTimeMillis()}"
        return getJson(url)
    }

    private fun getJson(url: String): JsonNode? {
        return try {
            log.debug("GET {}", url)
            val request = Request.Builder().url(url).get().build()
            httpClient.newCall(request).execute().use { response ->
                if (response.code == 404) throw EventNotFoundException(url)

                if (!response.isSuccessful) {
                    log.warn("Betplay API returned {} for {}", response.code, url)
                    return null
                }

                val body = response.body?.string() ?: return null
                objectMapper.readTree(body)
            }
        } catch (e: EventNotFoundException) {
            throw e
        } catch (e: Exception) {
            log.error("Failed to call Betplay API at {}: {}", url, e.message)
            null
        }
    }
}
