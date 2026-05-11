package com.sportbets.model

import jakarta.persistence.*

@Entity
@Table(name = "basketball_live_stats")
data class BasketballLiveStats(

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @OneToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "odds_snapshot_id", nullable = false, unique = true)
    val snapshot: OddsSnapshot = OddsSnapshot(),

    // Scoring — made + attempted
    @Column(name = "home_free_throws_made")         val homeFreeThrowsMade: Int? = null,
    @Column(name = "home_free_throws_attempted")    val homeFreeThrowsAttempted: Int? = null,
    @Column(name = "away_free_throws_made")         val awayFreeThrowsMade: Int? = null,
    @Column(name = "away_free_throws_attempted")    val awayFreeThrowsAttempted: Int? = null,

    @Column(name = "home_two_pointers_made")        val homeTwoPointersMade: Int? = null,
    @Column(name = "home_two_pointers_attempted")   val homeTwoPointersAttempted: Int? = null,
    @Column(name = "away_two_pointers_made")        val awayTwoPointersMade: Int? = null,
    @Column(name = "away_two_pointers_attempted")   val awayTwoPointersAttempted: Int? = null,

    @Column(name = "home_three_pointers_made")      val homeThreePointersMade: Int? = null,
    @Column(name = "home_three_pointers_attempted") val homeThreePointersAttempted: Int? = null,
    @Column(name = "away_three_pointers_made")      val awayThreePointersMade: Int? = null,
    @Column(name = "away_three_pointers_attempted") val awayThreePointersAttempted: Int? = null,

    @Column(name = "home_field_goals_made")         val homeFieldGoalsMade: Int? = null,
    @Column(name = "home_field_goals_attempted")    val homeFieldGoalsAttempted: Int? = null,
    @Column(name = "away_field_goals_made")         val awayFieldGoalsMade: Int? = null,
    @Column(name = "away_field_goals_attempted")    val awayFieldGoalsAttempted: Int? = null,

    // Other
    @Column(name = "home_rebounds")                 val homeRebounds: Int? = null,
    @Column(name = "away_rebounds")                 val awayRebounds: Int? = null,
    @Column(name = "home_defensive_rebounds")       val homeDefensiveRebounds: Int? = null,
    @Column(name = "away_defensive_rebounds")       val awayDefensiveRebounds: Int? = null,
    @Column(name = "home_offensive_rebounds")       val homeOffensiveRebounds: Int? = null,
    @Column(name = "away_offensive_rebounds")       val awayOffensiveRebounds: Int? = null,
    @Column(name = "home_assists")                  val homeAssists: Int? = null,
    @Column(name = "away_assists")                  val awayAssists: Int? = null,
    @Column(name = "home_turnovers")                val homeTurnovers: Int? = null,
    @Column(name = "away_turnovers")                val awayTurnovers: Int? = null,
    @Column(name = "home_steals")                   val homeSteals: Int? = null,
    @Column(name = "away_steals")                   val awaySteals: Int? = null,
    @Column(name = "home_blocks")                   val homeBlocks: Int? = null,
    @Column(name = "away_blocks")                   val awayBlocks: Int? = null,
    @Column(name = "home_total_fouls")              val homeTotalFouls: Int? = null,
    @Column(name = "away_total_fouls")              val awayTotalFouls: Int? = null,
    @Column(name = "home_timeouts")                 val homeTimeouts: Int? = null,
    @Column(name = "away_timeouts")                 val awayTimeouts: Int? = null,

    // Lead
    @Column(name = "home_max_points_in_a_row")      val homeMaxPointsInARow: Int? = null,
    @Column(name = "away_max_points_in_a_row")      val awayMaxPointsInARow: Int? = null,
    @Column(name = "home_time_spent_in_lead_sec")   val homeTimeSpentInLeadSec: Int? = null,
    @Column(name = "away_time_spent_in_lead_sec")   val awayTimeSpentInLeadSec: Int? = null,
    @Column(name = "home_lead_changes")             val homeLeadChanges: Int? = null,
    @Column(name = "away_lead_changes")             val awayLeadChanges: Int? = null,
    @Column(name = "home_biggest_lead")             val homeBiggestLead: Int? = null,
    @Column(name = "away_biggest_lead")             val awayBiggestLead: Int? = null,
)
