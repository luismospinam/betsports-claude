package com.sportbets.util

import org.slf4j.LoggerFactory
import java.io.File

/**
 * File-based lock that coordinates Chrome CDP access between this app and daily-stock-analyzer.
 * Both apps share the same Chrome instance on port 9222, so only one should drive it at a time.
 *
 * Lock file: /tmp/chrome-cdp.lock (contains the PID of the holder)
 * If the holder process is dead the lock is treated as stale and overridden.
 */
object BrowserLock {
    private val log = LoggerFactory.getLogger(javaClass)
    private val lockFile = File("/tmp/chrome-cdp.lock")
    private const val POLL_INTERVAL_MS = 2_000L
    private const val MAX_WAIT_MS = 60_000L

    fun acquire(caller: String) {
        val deadline = System.currentTimeMillis() + MAX_WAIT_MS
        while (lockFile.exists()) {
            val holderPid = lockFile.readText().trim().toLongOrNull()
            if (holderPid != null && !isProcessAlive(holderPid)) {
                log.warn("[BrowserLock] Stale lock from dead PID {} — overriding", holderPid)
                break
            }
            if (System.currentTimeMillis() > deadline) {
                log.warn("[BrowserLock] Timed out waiting for lock after {}s — forcing acquire", MAX_WAIT_MS / 1000)
                break
            }
            log.info("[BrowserLock] {} waiting for Chrome lock (held by PID {})...", caller, holderPid)
            Thread.sleep(POLL_INTERVAL_MS)
        }
        val pid = ProcessHandle.current().pid()
        lockFile.writeText(pid.toString())
        log.info("[BrowserLock] {} acquired lock (PID {})", caller, pid)
    }

    fun release(caller: String) {
        lockFile.delete()
        log.info("[BrowserLock] {} released lock", caller)
    }

    private fun isProcessAlive(pid: Long): Boolean =
        ProcessHandle.of(pid).map { it.isAlive }.orElse(false)
}
