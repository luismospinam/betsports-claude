package com.sportbets.model

import jakarta.persistence.*
import java.time.LocalDateTime

/**
 * A point-in-time snapshot of the 1X2 odds for a match.
 * Multiple snapshots are stored over time to track changes.
 *
 * Odds interpretation (1X2 market):
 *  - homeWinOdds  → odds for home team win
 *  - drawOdds     → odds for draw
 *  - awayWinOdds  → odds for away team win
 *
 * The FAVORITE is the side with the LOWEST odds (most likely to win).
 * When the favorite starts losing, their odds RISE — that's our trigger.
 */
@Entity
@Table(name = "odds_snapshots")
data class OddsSnapshot(

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "match_id", nullable = false)
    val match: Match = Match(),

    @Column(name = "home_win_odds", nullable = false)
    val homeWinOdds: Double = 0.0,

    @Column(name = "draw_odds", nullable = false)
    val drawOdds: Double = 0.0,

    @Column(name = "away_win_odds", nullable = false)
    val awayWinOdds: Double = 0.0,

    /** True = this snapshot was taken before match started (baseline) */
    @Column(name = "is_pre_match", nullable = false)
    val isPreMatch: Boolean = false,

    /** Home team score at time of snapshot (null if pre-match) */
    @Column(name = "home_score")
    val homeScore: Int? = null,

    /** Away team score at time of snapshot (null if pre-match) */
    @Column(name = "away_score")
    val awayScore: Int? = null,

    /** Match minute at time of snapshot (null if pre-match) */
    @Column(name = "match_minute")
    val matchMinute: Int? = null,

    /** Kambi outcome IDs for the 1X2 market — needed to reference the outcome in a coupon/bet request */
    @Column(name = "home_outcome_id")
    val homeOutcomeId: Long? = null,

    @Column(name = "draw_outcome_id")
    val drawOutcomeId: Long? = null,

    @Column(name = "away_outcome_id")
    val awayOutcomeId: Long? = null,

    @Column(name = "captured_at", nullable = false)
    val capturedAt: LocalDateTime = LocalDateTime.now()
) {
    /** Returns the minimum (favorite) odds across all three outcomes */
    fun favoriteOdds(): Double = minOf(homeWinOdds, drawOdds, awayWinOdds)

    /** Returns which side is the favorite */
    fun favoriteSide(): String = when (favoriteOdds()) {
        homeWinOdds -> "HOME"
        awayWinOdds -> "AWAY"
        else -> "DRAW"
    }
}
