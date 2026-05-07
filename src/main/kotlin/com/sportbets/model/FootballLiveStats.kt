package com.sportbets.model

import jakarta.persistence.*

@Entity
@Table(name = "football_live_stats")
data class FootballLiveStats(

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @OneToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "odds_snapshot_id", nullable = false, unique = true)
    val snapshot: OddsSnapshot = OddsSnapshot(),

    @Column(name = "home_corners")
    val homeCorners: Int? = null,

    @Column(name = "away_corners")
    val awayCorners: Int? = null,

    @Column(name = "home_yellow_cards")
    val homeYellowCards: Int? = null,

    @Column(name = "away_yellow_cards")
    val awayYellowCards: Int? = null,

    @Column(name = "home_red_cards")
    val homeRedCards: Int? = null,

    @Column(name = "away_red_cards")
    val awayRedCards: Int? = null,
)
