package com.sportbets.service

import com.microsoft.playwright.*
import com.microsoft.playwright.options.WaitUntilState
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * Places bets by automating the Betplay UI in your running Chrome via CDP.
 *
 * REQUIRED SETUP: run start-chrome.bat in the project root before starting the app.
 * This kills any existing Chrome and reopens it with --remote-debugging-port=9222
 * so the app can connect to your live logged-in session.
 *
 * Screenshots are saved to logs/bet-browser-*.png at each step.
 */
@Service
class BrowserBetPlacerService(
    @Value("\${betplay.betting.stake-cop:2000}") private val stakeCop: Long,
    @Value("\${betplay.betting.cdp-port:9222}") private val cdpPort: Int,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun placeBet(externalId: String, outcomeId: Long?, favoriteSide: String, matchDesc: String): Boolean {
        log.info("[Browser] Starting browser bet: {} {} outcomeId={}", matchDesc, favoriteSide, outcomeId)
        val tag = "${LocalDateTime.now().format(DateTimeFormatter.ofPattern("HHmmss"))}-$externalId"

        return try {
            Playwright.create().use { playwright ->
                val context = connectViaCdp(playwright) ?: return false
                val page = context.newPage()
                try {
                    executeBet(page, externalId, outcomeId, favoriteSide, matchDesc, tag)
                } finally {
                    page.close()
                }
            }
        } catch (e: Exception) {
            log.error("[Browser] Unexpected error placing bet for {}: {}", matchDesc, e.message)
            false
        }
    }

    private fun connectViaCdp(playwright: Playwright): BrowserContext? {
        return try {
            val browser = playwright.chromium().connectOverCDP("http://localhost:$cdpPort")
            browser.contexts().firstOrNull()?.also {
                log.info("[Browser] Connected to Chrome on port {}", cdpPort)
            } ?: run {
                log.error("[Browser] Connected to Chrome but found no open window")
                null
            }
        } catch (_: Exception) {
            log.error(
                "[Browser] Cannot connect to Chrome on port {}. Run start-chrome.bat first.",
                cdpPort
            )
            null
        }
    }

    private fun executeBet(
        page: Page,
        externalId: String,
        outcomeId: Long?,
        favoriteSide: String,
        matchDesc: String,
        tag: String
    ): Boolean {
        // Wipe any stale bet slip selections Kambi may restore from localStorage
        page.addInitScript("""
            (() => {
                try {
                    for (let i = localStorage.length - 1; i >= 0; i--) {
                        const k = localStorage.key(i);
                        if (k && /betslip|bet\.slip|coupon|outcome/i.test(k)) {
                            localStorage.removeItem(k);
                        }
                    }
                } catch(e) {}
            })();
        """)

        val url = "https://betplay.com.co/apuestas#event/$externalId"
        log.info("[Browser] Navigating to {}", url)
        try {
            page.navigate(url, Page.NavigateOptions()
                .setWaitUntil(WaitUntilState.DOMCONTENTLOADED)
                .setTimeout(30_000.0)
            )
        } catch (e: Exception) {
            log.warn("[Browser] Navigation timeout (normal for heavy JS): {}", e.message)
        }

        // Wait until Kambi's outcome buttons are rendered (replaces fixed 4s sleep)
        try {
            page.waitForSelector("button[class*='outcome'], .KambiBC-outcome-list__outcome",
                Page.WaitForSelectorOptions().setTimeout(20_000.0))
        } catch (_: Exception) {
            log.warn("[Browser] Outcome buttons not detected within 20s — proceeding anyway")
        }
        dismissPopups(page)
        clearBetSlip(page)
        screenshot(page, "logs/bet-browser-$tag-1-loaded.png")

        if (!clickOutcome(page, outcomeId, favoriteSide, matchDesc)) {
            screenshot(page, "logs/bet-browser-$tag-fail-outcome.png")
            return false
        }

        page.waitForTimeout(1_500.0)
        screenshot(page, "logs/bet-browser-$tag-2-betslip.png")

        if (!enterStake(page, matchDesc)) {
            screenshot(page, "logs/bet-browser-$tag-fail-stake.png")
            return false
        }

        page.waitForTimeout(500.0)

        if (!confirmBet(page, matchDesc)) {
            screenshot(page, "logs/bet-browser-$tag-fail-confirm.png")
            return false
        }

        page.waitForTimeout(2_000.0)
        screenshot(page, "logs/bet-browser-$tag-3-done.png")
        log.info("[Browser] BET PLACED via browser for {}", matchDesc)
        return true
    }

    private fun dismissPopups(page: Page) {
        for (selector in listOf(
            "button:has-text('DESPUÉS')",
            "button:has-text('Después')",
            "button:has-text('ACEPTAR')",
            "[class*='close' i][class*='notification' i]",
            "[aria-label='Close']",
            "[aria-label='Cerrar']",
        )) {
            try {
                val btn = page.locator(selector)
                if (btn.count() > 0 && btn.first().isVisible) {
                    btn.first().click()
                    log.debug("[Browser] Dismissed popup via {}", selector)
                    page.waitForTimeout(500.0)
                }
            } catch (_: Exception) {}
        }
    }

    private fun clearBetSlip(page: Page) {
        val selector = ".mod-KambiBC-betslip-outcome__close-btn, [aria-label^='Eliminar resultado']"
        var removed = 0
        repeat(10) {
            val btn = page.locator(selector)
            if (btn.count() > 0) {
                btn.first().click()
                page.waitForTimeout(400.0)
                removed++
            }
        }
        if (removed > 0) log.info("[Browser] Cleared {} selection(s) from bet slip", removed)
        else log.debug("[Browser] Bet slip was already empty")
    }

    private fun clickOutcome(page: Page, outcomeId: Long?, favoriteSide: String, matchDesc: String): Boolean {
        if (outcomeId != null) {
            for (selector in listOf(
                "[data-outcome-id='$outcomeId']",
                "[data-id='$outcomeId']",
                "[id='$outcomeId']",
            )) {
                val el = page.locator(selector)
                if (el.count() > 0) {
                    el.first().click()
                    log.info("[Browser] Clicked outcome by data attribute (id={})", outcomeId)
                    return true
                }
            }
        }

        val positionIndex = when (favoriteSide) {
            "HOME" -> 0
            "DRAW" -> 1
            "AWAY" -> 2
            else   -> 0
        }

        for (selector in listOf(
            ".KambiBC-outcome-list__outcome",
            "[class*='outcome-list__outcome']",
            "[class*='OutcomeButton']",
            "[class*='outcomeButton']",
            "button[class*='outcome']",
        )) {
            val buttons = page.locator(selector)
            val count = buttons.count()
            if (count > positionIndex) {
                buttons.nth(positionIndex).click()
                log.info("[Browser] Clicked outcome by position {} / {} (selector={})", positionIndex, count, selector)
                return true
            }
        }

        log.error("[Browser] Could not locate outcome button for {} on {}", favoriteSide, matchDesc)
        return false
    }

    private fun enterStake(page: Page, matchDesc: String): Boolean {
        for (selector in listOf(
            "input[class*='stake' i]",
            "input[class*='Stake']",
            "[class*='bet-slip'] input[type='number']",
            "[class*='betSlip'] input[type='number']",
            "[class*='BetSlip'] input[type='number']",
            "[class*='bet-slip'] input[type='text']",
        )) {
            val input = page.locator(selector)
            if (input.count() > 0) {
                input.first().fill(stakeCop.toString())
                log.info("[Browser] Entered stake {} COP", stakeCop)
                return true
            }
        }
        log.warn("[Browser] Stake input not found for {} — bet slip may not have opened", matchDesc)
        return false
    }

    private fun confirmBet(page: Page, matchDesc: String): Boolean {
        for (selector in listOf(
            "button[class*='place-bets' i]",
            "button[class*='placeBets' i]",
            "button[class*='PlaceBets']",
            "[class*='bet-slip'] button[type='submit']",
            "button:has-text('Realizar apuesta')",
            "button:has-text('Apostar')",
            "button:has-text('Confirmar apuesta')",
            "button:has-text('Confirmar')",
        )) {
            val btn = page.locator(selector)
            if (btn.count() > 0) {
                val first = btn.first()
                if (first.isEnabled) {
                    first.click()
                    log.info("[Browser] Clicked confirm button ({})", selector)
                    return true
                } else {
                    log.warn("[Browser] Confirm button found but disabled — stake may be below minimum")
                }
            }
        }
        log.error("[Browser] Confirm button not found for {}", matchDesc)
        return false
    }

    private fun screenshot(page: Page, path: String) {
        try {
            page.screenshot(Page.ScreenshotOptions().setPath(File(path).toPath()).setFullPage(false))
        } catch (_: Exception) {}
    }
}
