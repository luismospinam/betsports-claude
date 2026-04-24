package com.sportbets.repository

import com.sportbets.model.BettingAlert
import com.sportbets.model.Match
import com.sportbets.model.MatchStatus
import com.sportbets.model.OddsSnapshot
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.stereotype.Repository
import java.time.LocalDateTime

@Repository
interface MatchRepository : JpaRepository<Match, Long> {

    fun findByExternalId(externalId: String): Match?

    fun findByStatus(status: MatchStatus): List<Match>

    /** Upcoming matches in a given date window (e.g. next 7 days) */
    fun findByStatusAndMatchDateBetween(
        status: MatchStatus,
        from: LocalDateTime,
        to: LocalDateTime
    ): List<Match>

    fun existsByExternalId(externalId: String): Boolean
}

@Repository
interface OddsSnapshotRepository : JpaRepository<OddsSnapshot, Long> {

    fun findByMatchIdOrderByCapturedAtAsc(matchId: Long): List<OddsSnapshot>

    /** The most recent snapshot for a match */
    fun findTopByMatchIdOrderByCapturedAtDesc(matchId: Long): OddsSnapshot?

    /** The pre-match baseline snapshot(s) */
    fun findByMatchIdAndIsPreMatchTrue(matchId: Long): List<OddsSnapshot>

    /** Live snapshots ordered oldest first — used to find the first live snapshot as fallback baseline */
    fun findByMatchIdAndIsPreMatchFalse(matchId: Long): List<OddsSnapshot>

    /** Count live snapshots taken since match started */
    fun countByMatchIdAndIsPreMatchFalse(matchId: Long): Long
}

@Repository
interface BettingAlertRepository : JpaRepository<BettingAlert, Long> {

    fun findByMatchId(matchId: Long): List<BettingAlert>

    /** Alerts that haven't been sent to Discord yet */
    fun findByNotifiedFalse(): List<BettingAlert>

    /** How many alerts have been fired for this match already */
    fun countByMatchId(matchId: Long): Long
}
