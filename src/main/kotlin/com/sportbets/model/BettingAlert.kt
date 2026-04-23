package com.sportbets.model

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "betting_alerts")
data class BettingAlert(

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "match_id", nullable = false)
    val match: Match = Match(),

    /** Which side to bet on (HOME / AWAY / DRAW) */
    @Column(name = "suggested_bet", nullable = false)
    val suggestedBet: String = "",

    /** Odds at the time of the alert */
    @Column(name = "current_odds", nullable = false)
    val currentOdds: Double = 0.0,

    /** Pre-match baseline odds for the same outcome */
    @Column(name = "baseline_odds", nullable = false)
    val baselineOdds: Double = 0.0,

    /** Percentage increase: (currentOdds - baselineOdds) / baselineOdds * 100 */
    @Column(name = "odds_increase_pct", nullable = false)
    val oddsIncreasePct: Double = 0.0,

    /** Current score when alert fired */
    @Column(name = "score_at_alert")
    val scoreAtAlert: String? = null,

    /** Human-readable description sent to Discord */
    @Column(name = "message", columnDefinition = "TEXT")
    val message: String = "",

    /** Whether the Discord notification was sent successfully */
    @Column(name = "notified", nullable = false)
    val notified: Boolean = false,

    @Column(name = "triggered_at", nullable = false)
    val triggeredAt: LocalDateTime = LocalDateTime.now()
)
