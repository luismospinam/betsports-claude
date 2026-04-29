package com.sportbets.service

import com.microsoft.playwright.*
import com.microsoft.playwright.options.WaitUntilState
import com.sportbets.util.BrowserLock
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicLong

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
    @Value("\${betplay.credentials.username:}") private val username: String,
    @Value("\${betplay.credentials.password:}") private val password: String,
    @Value("\${betplay.betting.max-odds-deviation-pct:15.0}") private val maxOddsDeviationPct: Double,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val lastCookieClearMs = AtomicLong(0L)
    private val cookieClearIntervalMs = 12 * 60 * 60 * 1_000L // 12 hours

    fun placeBet(externalId: String, outcomeId: Long?, favoriteSide: String, matchDesc: String, triggerOdds: Double, betMarket: String = "RESULTADO_FINAL"): BetResult {
        log.info("[Browser] Starting browser bet: {} {} outcomeId={} market={}", matchDesc, favoriteSide, outcomeId, betMarket)
        val tag = "${LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"))}-$externalId"

        BrowserLock.acquire("BrowserBetPlacer")
        return try {
            Playwright.create().use { playwright ->
                val context = connectViaCdp(playwright) ?: return BetResult.Failed
                val page = context.newPage()
                try {
                    executeBet(page, externalId, outcomeId, favoriteSide, matchDesc, tag, triggerOdds, betMarket)
                } finally {
                    page.close()
                }
            }
        } catch (e: Exception) {
            log.error("[Browser] Unexpected error placing bet for {}: {}", matchDesc, e.message)
            BetResult.Failed
        } finally {
            BrowserLock.release("BrowserBetPlacer")
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
        tag: String,
        triggerOdds: Double,
        betMarket: String = "RESULTADO_FINAL",
    ): BetResult {
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

        if (!ensureLoggedIn(page)) {
            screenshot(page, "logs/bet-browser-$tag-fail-login.png")
            return BetResult.Failed
        }

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

        if (!clickOutcome(page, outcomeId, favoriteSide, matchDesc, betMarket)) {
            screenshot(page, "logs/bet-browser-$tag-fail-outcome.png")
            return BetResult.Failed
        }

        page.waitForTimeout(1_500.0)
        screenshot(page, "logs/bet-browser-$tag-2-betslip.png")

        // Verify betslip odds haven't drifted too far from trigger odds.
        // A large change means the match situation changed during the market suspension
        // (e.g. another goal scored), making this bet invalid.
        val betslipOdds = readBetslipOdds(page)
        if (betslipOdds != null) {
            val deviationPct = Math.abs(betslipOdds - triggerOdds) / triggerOdds * 100.0
            if (deviationPct > maxOddsDeviationPct) {
                log.warn(
                    "[Browser] Betslip odds {} differ from trigger {} by {}% (max {}%) — match situation changed, skipping",
                    "%.2f".format(betslipOdds), "%.2f".format(triggerOdds),
                    "%.1f".format(deviationPct), "%.1f".format(maxOddsDeviationPct)
                )
                clearBetSlip(page)
                screenshot(page, "logs/bet-browser-$tag-fail-odds-drift.png")
                return BetResult.Skipped
            }
            log.info("[Browser] Betslip odds {} within {}% of trigger {} — proceeding",
                "%.2f".format(betslipOdds), "%.1f".format(deviationPct), "%.2f".format(triggerOdds))
        } else {
            log.warn("[Browser] Could not read betslip odds — proceeding without deviation check")
        }

        if (!enterStake(page, matchDesc)) {
            screenshot(page, "logs/bet-browser-$tag-fail-stake.png")
            return BetResult.Failed
        }

        page.waitForTimeout(500.0)

        if (!confirmBet(page, matchDesc)) {
            screenshot(page, "logs/bet-browser-$tag-fail-confirm.png")
            return BetResult.Failed
        }

        page.waitForTimeout(2_000.0)
        screenshot(page, "logs/bet-browser-$tag-3-done.png")
        log.info("[Browser] BET PLACED via browser for {}", matchDesc)
        return BetResult.Placed(stakeCop)
    }

    private fun readBetslipOdds(page: Page): Double? {
        // Kambi renders current odds in the betslip in several possible elements.
        // We try each selector and parse the first decimal number we find.
        val selectors = listOf(
            "[class*='bet-slip'] [class*='odds']",
            "[class*='betSlip'] [class*='price']",
            "[class*='bet-slip-outcome'] [class*='price']",
            "[class*='KambiBC-bet-slip'] [class*='odds']",
            "[class*='coupon'] [class*='odds']",
        )
        for (selector in selectors) {
            val el = page.locator(selector).first()
            if (el.count() > 0) {
                val text = runCatching { el.textContent()?.trim() }.getOrNull() ?: continue
                val odds = text.replace(",", ".").let {
                    Regex("""(\d+\.\d+)""").find(it)?.groupValues?.get(1)?.toDoubleOrNull()
                }
                if (odds != null && odds > 1.0) {
                    return odds
                }
            }
        }
        // Fallback: parse "@ X.XX" from the betslip header text
        val header = page.locator("[class*='bet-slip'], [class*='betSlip'], [class*='coupon']").first()
        if (header.count() > 0) {
            val text = runCatching { header.textContent() }.getOrNull() ?: return null
            return Regex("""@\s*(\d+\.\d+)""").find(text)?.groupValues?.get(1)?.toDoubleOrNull()
        }
        return null
    }

    private fun isLoggedIn(page: Page): Boolean {
        // Positive indicators: user balance, account menu, or logout button
        val loggedInSelectors = listOf(
            "[class*='balance' i]",
            "[class*='user-balance' i]",
            "[class*='account' i][class*='menu' i]",
            "button:has-text('Cerrar sesión')",
            "a:has-text('Cerrar sesión')",
            "[aria-label*='balance' i]",
        )
        for (sel in loggedInSelectors) {
            if (page.locator(sel).count() > 0) return true
        }
        // Negative indicator: login form visible
        val loginInput = page.locator("input[placeholder*='Usuario'], input[placeholder*='Cédula'], input[placeholder*='usuario' i]")
        if (loginInput.count() > 0) return false
        // Ambiguous — no login form but no confirmed logged-in element either
        return false
    }

    private fun ensureLoggedIn(page: Page, attempt: Int = 1): Boolean {
        // Always do a fresh navigation so the page generates a new betplaycaptcha token.
        // Betplay embeds a time-sensitive CAPTCHA token in the login button's CSS class at
        // page-load time. If the page was loaded too long ago (>90s) the server rejects
        // the login JWT with 401 even when credentials are correct. A fresh navigate
        // guarantees a fresh token.
        try {
            page.navigate("https://betplay.com.co",
                Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(20_000.0))
        } catch (_: Exception) {}
        page.waitForTimeout(3_000.0)

        // Dismiss cookie consent banner ("Valoramos tu privacidad") if present
        dismissCookieBanner(page)

        if (isLoggedIn(page)) {
            log.info("[Browser] Already logged in to Betplay")
            return true
        }

        if (username.isBlank() || password.isBlank()) {
            log.error("[Browser] Not logged in and no credentials configured — set betplay.credentials.username/password")
            return false
        }

        log.info("[Browser] Not logged in — attempting automatic login (attempt {})", attempt)
        return try {
            // Clear Betplay cookies and storage every 12 hours to reset fraud-detection
            // flags that accumulate from repeated automated login attempts.
            // Incognito always works because it has no such accumulated state — periodic
            // clearing mimics that clean slate without doing it on every attempt.
            val now = System.currentTimeMillis()
            if (now - lastCookieClearMs.get() >= cookieClearIntervalMs) {
                runCatching { page.context().clearCookies(BrowserContext.ClearCookiesOptions().setDomain("betplay.com.co")) }
                runCatching { page.evaluate("localStorage.clear(); sessionStorage.clear();") }
                lastCookieClearMs.set(now)
                log.info("[Browser] Cleared Betplay cookies and storage (12h interval)")
            }

            // Re-navigate so the page generates a fresh betplaycaptcha token
            try {
                page.navigate("https://betplay.com.co",
                    Page.NavigateOptions().setWaitUntil(WaitUntilState.DOMCONTENTLOADED).setTimeout(20_000.0))
            } catch (_: Exception) {}

            // Cookie clear resets consent — banner reappears on fresh load, must dismiss again
            dismissCookieBanner(page)

            // Wait for the login button's betplaycaptcha class — confirms page JS has
            // written a fresh CAPTCHA token before we submit.
            try {
                page.waitForSelector("button.betplaycaptcha",
                    Page.WaitForSelectorOptions().setTimeout(8_000.0))
            } catch (_: Exception) {
                log.debug("[Browser] betplaycaptcha class not found — proceeding anyway")
            }

            val loginInput = page.locator("input[placeholder*='Usuario'], input[placeholder*='Cédula'], input[placeholder*='usuario' i]")
            loginInput.first().fill(username)
            page.locator("input[placeholder*='Contraseña'], input[type='password']").first().fill(password)
            // CookieYes initializes asynchronously — by the time we've filled credentials
            // the Angular app is fully booted and the overlay may have appeared. Dismiss again.
            dismissCookieBanner(page)
            // Click by ID to avoid accidentally matching multiple submit buttons
            val loginBtn = page.locator("#btnLoginPrimary")
            if (loginBtn.count() > 0) loginBtn.click()
            else page.locator("button.betplaycaptcha").first().click()

            page.waitForTimeout(4_000.0)

            if (isLoggedIn(page)) {
                log.info("[Browser] Login successful")
                true
            } else if (attempt < 2) {
                log.warn("[Browser] Login attempt {} failed — retrying with fresh page load", attempt)
                page.waitForTimeout(2_000.0)
                ensureLoggedIn(page, attempt + 1)
            } else {
                log.error("[Browser] Login failed after {} attempts", attempt)
                false
            }
        } catch (e: Exception) {
            log.error("[Browser] Exception during login: {}", e.message)
            false
        }
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

    private fun dismissCookieBanner(page: Page) {
        // CookieYes (cky-* classes) is Betplay's consent provider. The overlay blocks all
        // pointer events until accepted. Removing the DOM node via JS gets re-created
        // immediately by the Angular framework — the only reliable dismiss is to click
        // the accept button, which makes CookieYes register consent and remove the overlay
        // itself. We use page.evaluate() so the click bypasses Playwright's pointer-event
        // interception check (the button is clickable; only the overlay behind it is the issue).
        val jsResult = runCatching {
            page.evaluate("""
                () => {
                    const acceptSelectors = [
                        '.cky-btn-accept',
                        '[class*="cky-btn-accept"]',
                        '.cky-notice-btn-accept',
                    ];
                    for (const sel of acceptSelectors) {
                        const btn = document.querySelector(sel);
                        if (btn) { btn.click(); return 'clicked-' + sel; }
                    }
                    // Banner not present yet — nothing to dismiss
                    return 'not-found';
                }
            """).toString()
        }.getOrNull() ?: "error"

        if (jsResult.startsWith("clicked-")) {
            log.info("[Browser] Dismissed cookie consent banner via JS click ({})", jsResult)
            page.waitForTimeout(600.0)
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

    private fun clickOutcome(page: Page, outcomeId: Long?, favoriteSide: String, matchDesc: String, betMarket: String = "RESULTADO_FINAL"): Boolean {
        // Timeout for a single click attempt — short so we don't spam 60 retries when the
        // market is suspended (e.g. after a goal). Playwright retries every 500ms internally.
        val clickTimeout = Locator.ClickOptions().setTimeout(120_000.0)

        // Double Chance (Doble Oportunidad): 3-button layout — 1X at 0, 12 at 1, X2 at 2.
        // Outright win (Resultado Final): 3-button layout — HOME=0, DRAW=1, AWAY=2.
        val positionIndex = if (betMarket == "DOBLE_OPORTUNIDAD") {
            when (favoriteSide) {
                "HOME" -> 0  // 1X: home win or draw
                "AWAY" -> 2  // X2: away win or draw (position 1 is "12" — home or away, no draw)
                else   -> 0
            }
        } else {
            when (favoriteSide) {
                "HOME" -> 0
                "DRAW" -> 1
                "AWAY" -> 2
                else   -> 0
            }
        }

        val sectionLabel = if (betMarket == "DOBLE_OPORTUNIDAD") "Doble Oportunidad" else "Resultado Final"

        if (betMarket == "DOBLE_OPORTUNIDAD") {
            // Scroll to trigger lazy rendering of all sections
            runCatching { page.evaluate("window.scrollTo(0, document.body.scrollHeight)") }
            page.waitForTimeout(600.0)

            // "Tiempo reglamentario" can appear two ways depending on the match:
            //   A) As a TAB in the second tab row (click tab → filtered view with DC section)
            //   B) As a COLLAPSED GROUP in the default "Apuestas Seleccionadas" view
            //      (scroll down → expand group → DC section visible inside)
            // Strategy: first try to expand the group in the current view (case B).
            // If "Doble Oportunidad" is still not found after that, fall back to clicking
            // the "Tiempo reglamentario" tab (case A).
            runCatching {
                page.evaluate("""
                    () => {
                        const all = Array.from(document.querySelectorAll('*')).reverse();
                        const grpHeader = all.find(el =>
                            el.offsetParent !== null &&
                            (el.innerText || '').trim().split('\n')[0].trim() === 'Tiempo reglamentario'
                        );
                        if (!grpHeader) return;
                        // If the group already shows visible outcome buttons, it's expanded — skip
                        let probe = grpHeader.parentElement;
                        for (let i = 0; i < 6; i++) {
                            if (!probe || probe === document.body) break;
                            const visible = Array.from(probe.querySelectorAll('button, li, [role="button"]'))
                                .filter(b => b.offsetParent !== null);
                            if (visible.length > 3) return;
                            probe = probe.parentElement;
                        }
                        // Collapsed — click to expand
                        let t = grpHeader;
                        for (let i = 0; i < 6; i++) {
                            const tag = t.tagName.toLowerCase();
                            if (tag === 'button' || tag === 'a' || t.getAttribute('role') === 'button'
                                    || getComputedStyle(t).cursor === 'pointer') {
                                t.click(); return;
                            }
                            if (!t.parentElement || t.parentElement === document.body) break;
                            t = t.parentElement;
                        }
                        grpHeader.click();
                    }
                """)
                page.waitForTimeout(700.0)
            }

            runCatching { page.evaluate("window.scrollTo(0, 0)") }
            page.waitForTimeout(300.0)

            // Check if "Doble Oportunidad" is now visible. If not, try the tab approach.
            val dcFoundInDefault = runCatching {
                page.evaluate("""
                    () => {
                        const all = Array.from(document.querySelectorAll('*'));
                        return all.some(el =>
                            el.offsetParent !== null &&
                            (el.innerText || '').trim().split('\n')[0].trim() === 'Doble Oportunidad'
                        );
                    }
                """).toString() == "true"
            }.getOrDefault(false)

            if (!dcFoundInDefault) {
                log.info("[Browser] 'Doble Oportunidad' not in default view — trying 'Tiempo reglamentario' tab")
                val tabSelectors = listOf(
                    "button:has-text('Tiempo reglamentario')",
                    "[class*='tab']:has-text('Tiempo reglamentario')",
                    "li:has-text('Tiempo reglamentario')",
                    "a:has-text('Tiempo reglamentario')",
                )
                for (sel in tabSelectors) {
                    val tab = page.locator(sel)
                    if (tab.count() > 0) {
                        try {
                            tab.first().click()
                            page.waitForTimeout(1_000.0)
                            log.info("[Browser] Switched to 'Tiempo reglamentario' tab ({})", sel)
                            break
                        } catch (_: Exception) {}
                    }
                }
                // Scroll again after tab switch
                runCatching { page.evaluate("window.scrollTo(0, document.body.scrollHeight)") }
                page.waitForTimeout(500.0)
                runCatching { page.evaluate("window.scrollTo(0, 0)") }
                page.waitForTimeout(300.0)
            }
        } else {
            // Scroll to bottom so lazy-rendered sections enter the DOM
            runCatching { page.evaluate("window.scrollTo(0, document.body.scrollHeight)") }
            page.waitForTimeout(500.0)
            runCatching { page.evaluate("window.scrollTo(0, 0)") }
            page.waitForTimeout(300.0)
        }

        // Use JavaScript to find the section header by its visible text (innerText).
        // We use innerText (not textContent) to match what the user sees, ignoring hidden
        // nodes and icon characters. We search in reverse so the innermost matching
        // element is found first (e.g. the label span inside the header, not its container).
        // Accordion headers always have child elements (chevron icons) so we cannot
        // require el.children.length === 0.
        val jsExpandResult = runCatching {
            page.evaluate("""
                (label) => {
                    const all = Array.from(document.querySelectorAll('*')).reverse();
                    const header = all.find(el =>
                        el.offsetParent !== null && (el.innerText || '').trim().split('\n')[0].trim() === label
                    );
                    if (!header) return 'header-not-found';
                    header.scrollIntoView({ block: 'center' });
                    // Check if section is already expanded (has visible outcome buttons nearby)
                    let probe = header.parentElement;
                    for (let i = 0; i < 8; i++) {
                        if (!probe || probe === document.body) break;
                        const btns = Array.from(probe.querySelectorAll(
                            'button[class*="outcome"], .KambiBC-outcome-list__outcome, [class*="OutcomeButton"], button'
                        )).filter(b => b.offsetParent !== null);
                        if (btns.length > 0) return 'already-expanded';
                        probe = probe.parentElement;
                    }
                    // Not expanded — click nearest clickable ancestor
                    let clickTarget = header;
                    for (let i = 0; i < 6; i++) {
                        const tag = clickTarget.tagName.toLowerCase();
                        if (tag === 'button' || tag === 'a' || clickTarget.getAttribute('role') === 'button'
                                || clickTarget.style.cursor === 'pointer'
                                || getComputedStyle(clickTarget).cursor === 'pointer') {
                            clickTarget.click();
                            return 'expanded';
                        }
                        if (!clickTarget.parentElement || clickTarget.parentElement === document.body) break;
                        clickTarget = clickTarget.parentElement;
                    }
                    header.click();
                    return 'expanded-fallback';
                }
            """, sectionLabel)
        }.getOrNull()?.toString()

        if (jsExpandResult == "header-not-found") {
            log.warn("[Browser] JS: '{}' section header not found in DOM", sectionLabel)
        } else {
            log.info("[Browser] JS: expanded '{}' section ({})", sectionLabel, jsExpandResult)
            page.waitForTimeout(700.0)

            val jsClicked = runCatching {
                page.evaluate("""
                    (args) => {
                        const [label, index] = args;
                        const all = Array.from(document.querySelectorAll('*')).reverse();
                        const header = all.find(el =>
                            el.offsetParent !== null && (el.innerText || '').trim().split('\n')[0].trim() === label
                        );
                        if (!header) return 'header-not-found';
                        let container = header.parentElement;
                        for (let i = 0; i < 8; i++) {
                            if (!container || container === document.body) break;
                            const btns = Array.from(container.querySelectorAll(
                                'button[class*="outcome"], .KambiBC-outcome-list__outcome, [class*="OutcomeButton"], button'
                            )).filter(b => b.offsetParent !== null);
                            if (btns.length > index) {
                                btns[index].scrollIntoView({ block: 'center' });
                                btns[index].click();
                                return 'clicked-' + btns.length;
                            }
                            container = container.parentElement;
                        }
                        return 'buttons-not-found';
                    }
                """, listOf(sectionLabel, positionIndex))
            }.getOrNull()?.toString()

            when {
                jsClicked != null && jsClicked.startsWith("clicked-") -> {
                    log.info("[Browser] JS clicked outcome index {} in '{}' section ({} visible buttons)", positionIndex, sectionLabel, jsClicked.removePrefix("clicked-"))
                    return true
                }
                jsClicked == "buttons-not-found" ->
                    log.warn("[Browser] JS: '{}' section expanded but no visible outcome buttons at index {}", sectionLabel, positionIndex)
                else ->
                    log.warn("[Browser] JS outcome click returned: {}", jsClicked)
            }
        }

        // Last resort: global positional search (no section scoping)
        val outcomeButtonSelectors = listOf(
            ".KambiBC-outcome-list__outcome",
            "[class*='outcome-list__outcome']",
            "[class*='OutcomeButton']",
            "[class*='outcomeButton']",
            "button[class*='outcome']",
        )
        for (selector in outcomeButtonSelectors) {
            val buttons = page.locator(selector)
            val count = buttons.count()
            if (count > positionIndex) {
                return try {
                    buttons.nth(positionIndex).click(clickTimeout)
                    log.warn("[Browser] Clicked outcome by GLOBAL position {} / {} — '{}' section not found, may be wrong market (selector={})", positionIndex, count, sectionLabel, selector)
                    true
                } catch (e: Exception) {
                    log.warn("[Browser] Outcome button found but not clickable (market suspended?) for {} — {}", matchDesc, e.message?.take(80))
                    false
                }
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
                val el = input.first()
                // Kambi uses React — fill() alone doesn't trigger React's synthetic onChange.
                // Click to focus, clear via triple-click, then type character by character.
                el.click()
                el.fill("")
                el.type(stakeCop.toString())
                page.waitForTimeout(500.0)
                val entered = el.inputValue()
                if (entered.isBlank() || entered == "0") {
                    log.warn("[Browser] Stake field did not accept value via type() — trying JS dispatch")
                    page.evaluate("""
                        (function() {
                            const sel = '$selector';
                            const input = document.querySelector(sel);
                            if (!input) return;
                            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                            setter.call(input, '$stakeCop');
                            input.dispatchEvent(new Event('input',  { bubbles: true }));
                            input.dispatchEvent(new Event('change', { bubbles: true }));
                        })();
                    """)
                    page.waitForTimeout(500.0)
                }
                log.info("[Browser] Entered stake {} COP (field value='{}')", stakeCop, el.inputValue())
                return true
            }
        }
        log.warn("[Browser] Stake input not found for {} — bet slip may not have opened", matchDesc)
        return false
    }

    private fun confirmBet(page: Page, matchDesc: String): Boolean {
        // If Betplay is showing an odds-change approval prompt, accept it first.
        // This happens in live markets when odds shift between outcome selection and stake entry.
        val oddsChangeBtn = page.locator("button:has-text('Aprobar Cambio De Cuotas')")
        if (oddsChangeBtn.count() > 0 && oddsChangeBtn.first().isEnabled) {
            log.info("[Browser] Odds changed — accepting new odds for {}", matchDesc)
            oddsChangeBtn.first().click()
            page.waitForTimeout(1_500.0)
        }

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

                    page.waitForTimeout(3_000.0)

                    // Check for explicit rejection — covers both the inline betslip error
                    // and the "Error al realizar apuesta" modal (odds changed / market suspended).
                    val errorLoc = page.locator(
                        ":text('no se ha efectuado'), :text('apuesta no realizada'), " +
                        ":text('Tu apuesta no'), :text('Error al realizar apuesta'), " +
                        ":text('cuotas cambiaron'), :text('se cerró o suspendió')"
                    )
                    if (errorLoc.count() > 0) {
                        val msg = runCatching { errorLoc.first().textContent()?.trim()?.take(120) }.getOrNull()
                        log.error("[Browser] Betplay rejected the bet for {} — {}", matchDesc, msg)
                        // Dismiss the error modal so Chrome is in a clean state for next bet
                        runCatching {
                            val backBtn = page.locator("button:has-text('ATRÁS'), button:has-text('Atrás'), button:has-text('Cerrar')")
                            if (backBtn.count() > 0) backBtn.first().click()
                        }
                        return false
                    }

                    // Require a positive confirmation — Betplay shows a receipt/confirmation
                    // after a successful bet. Without this, a silent rejection (e.g. session
                    // expired mid-flow) would be logged as a successful placement.
                    val successLoc = page.locator(
                        ":text('apuesta realizada'), :text('Apuesta realizada'), " +
                        ":text('Apuesta confirmada'), :text('apuesta confirmada'), " +
                        ":text('recibo'), :text('Recibo'), " +
                        "[class*='receipt' i], [class*='confirmation' i], [class*='bet-placed' i]"
                    )
                    if (successLoc.count() > 0) {
                        return true
                    }

                    // Re-check login — if session expired mid-flow the page may have redirected
                    if (!isLoggedIn(page)) {
                        log.error("[Browser] Session expired mid-bet for {} — bet was NOT placed", matchDesc)
                        return false
                    }

                    // No explicit success or failure signal — treat as success with a warning
                    log.warn("[Browser] No confirmation element found after confirm click for {} — assuming placed", matchDesc)
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
