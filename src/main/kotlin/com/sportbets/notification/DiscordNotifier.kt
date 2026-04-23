package com.sportbets.notification

import com.fasterxml.jackson.databind.ObjectMapper
import com.sportbets.model.BettingAlert
import com.sportbets.repository.BettingAlertRepository
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component

/**
 * Sends betting alerts to Discord using the bot API so that @mentions
 * trigger push notifications on mobile (webhooks do not).
 */
@Component
class DiscordNotifier(
    private val objectMapper: ObjectMapper,
    private val alertRepository: BettingAlertRepository,
    @Value("\${discord.webhook.enabled:true}") private val enabled: Boolean,
    @Value("\${discord.bot.token}") private val botToken: String,
    @Value("\${discord.bot.channel-id}") private val channelId: String,
    @Value("\${discord.bot.mention-id:}") private val mentionId: String,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val client = OkHttpClient()
    private val jsonMediaType = "application/json".toMediaType()
    private val botApiUrl = "https://discord.com/api/v10/channels/$channelId/messages"

    fun sendPendingAlerts() {
        if (!enabled) return

        val pending = alertRepository.findByNotifiedFalse()
        if (pending.isEmpty()) return

        log.info("Sending {} pending alert(s) to Discord...", pending.size)
        for (alert in pending) {
            if (sendToDiscord(alert)) {
                alertRepository.save(alert.copy(notified = true))
            }
        }
    }

    private fun sendToDiscord(alert: BettingAlert): Boolean {
        val payload = buildPayload(alert)
        return try {
            val body = objectMapper.writeValueAsString(payload).toRequestBody(jsonMediaType)
            val request = Request.Builder()
                .url(botApiUrl)
                .header("Authorization", "Bot $botToken")
                .post(body)
                .build()

            val response = client.newCall(request).execute()
            if (response.isSuccessful) {
                log.info("Discord alert sent for match ID {}", alert.match.id)
                true
            } else {
                log.error("Discord bot returned {} for alert {}: {}", response.code, alert.id, response.body?.string())
                false
            }
        } catch (e: Exception) {
            log.error("Failed to send Discord alert {}: {}", alert.id, e.message)
            false
        }
    }

    private fun buildPayload(alert: BettingAlert): Map<String, Any> {
        val match = alert.match

        val betStatusLabel = when (alert.betStatus) {
            "PLACED"  -> "✅ Placed"
            "DRY_RUN" -> "🔕 Dry run"
            "FAILED"  -> "❌ Failed"
            "SKIPPED" -> "⚠️ Skipped"
            else      -> "—"
        }
        val embedColor = when (alert.betStatus) {
            "PLACED"  -> 0x2ECC71  // green
            "FAILED"  -> 0xE74C3C  // red
            else      -> 0xF5A623  // orange (dry-run / skipped)
        }

        val embed = mapOf(
            "title"       to "Bet Opportunity Detected!",
            "color"       to embedColor,
            "description" to alert.message,
            "fields"      to listOf(
                mapOf("name" to "Match",         "value" to "${match.homeTeam} vs ${match.awayTeam}", "inline" to true),
                mapOf("name" to "Competition",   "value" to match.competition.ifBlank { "Soccer" },   "inline" to true),
                mapOf("name" to "Bet Side",      "value" to alert.suggestedBet,                        "inline" to true),
                mapOf("name" to "Baseline Odds", "value" to "%.2f".format(alert.baselineOdds),         "inline" to true),
                mapOf("name" to "Current Odds",  "value" to "%.2f".format(alert.currentOdds),          "inline" to true),
                mapOf("name" to "Odds Rise",     "value" to "+%.1f%%".format(alert.oddsIncreasePct),   "inline" to true),
                mapOf("name" to "Score",         "value" to (alert.scoreAtAlert ?: "N/A"),             "inline" to true),
                mapOf("name" to "Bet Status",    "value" to betStatusLabel,                            "inline" to true),
                mapOf("name" to "Stake",         "value" to if (alert.betPlaced == true || alert.betStatus == "DRY_RUN") "1,000 COP" else "—", "inline" to true),
            ),
            "footer"    to mapOf("text" to "SportBets Monitor"),
            "timestamp" to alert.triggeredAt.toString() + "Z"
        )

        val content = if (mentionId.isNotBlank()) "@everyone <@$mentionId>" else "@everyone"

        return mapOf("content" to content, "embeds" to listOf(embed))
    }
}
