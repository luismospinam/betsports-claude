package com.sportbets.model

import jakarta.persistence.*
import java.time.LocalDateTime

enum class MatchStatus {
    UPCOMING,   // Match not yet started
    LIVE,       // Match in progress — odds are being monitored
    FINISHED,   // Match ended
    CANCELLED
}

@Entity
@Table(name = "matches")
data class Match(

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    /** Betplay's internal match ID */
    @Column(name = "external_id", unique = true, nullable = false)
    val externalId: String = "",

    @Column(name = "home_team", nullable = false)
    val homeTeam: String = "",

    @Column(name = "away_team", nullable = false)
    val awayTeam: String = "",

    @Column(name = "competition")
    val competition: String = "",

    /** Scheduled kickoff time */
    @Column(name = "match_date", nullable = false)
    val matchDate: LocalDateTime = LocalDateTime.now(),

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false)
    val status: MatchStatus = MatchStatus.UPCOMING,

    /** Betplay URL slug or deep link to the match page */
    @Column(name = "betplay_url")
    val betplayUrl: String? = null,

    /** Final score — set when the match is marked FINISHED */
    @Column(name = "final_home_score")
    val finalHomeScore: Int? = null,

    @Column(name = "final_away_score")
    val finalAwayScore: Int? = null,

    @Column(name = "created_at", nullable = false)
    val createdAt: LocalDateTime = LocalDateTime.now(),

    @Column(name = "updated_at", nullable = false)
    val updatedAt: LocalDateTime = LocalDateTime.now()
)
