package com.sportbets.auth

import com.sportbets.service.BrowserBetPlacerService
import org.slf4j.LoggerFactory
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.context.annotation.Profile
import org.springframework.stereotype.Component

/**
 * Verifies that the browser can connect to Chrome and authenticate with Betplay.
 * No bet is placed — use this to diagnose CDP connection and login failures.
 *
 * Run with:
 *   ./gradlew bootRun --args="--spring.profiles.active=test-login"
 */
@Component
@Profile("test-login")
class TestLoginRunner(
    private val browserBetPlacer: BrowserBetPlacerService,
) : ApplicationRunner {

    private val log = LoggerFactory.getLogger(javaClass)

    override fun run(args: ApplicationArguments) {
        log.info("=== LOGIN TEST — connecting to Chrome and verifying Betplay session ===")
        val ok = browserBetPlacer.testLogin()
        log.info("=== TEST RESULT: {} ===", if (ok) "PASSED" else "FAILED")
    }
}
