@echo off
echo ============================================================
echo SportBets — Initial Setup Script (Windows)
echo ============================================================
echo.

REM Check Java 17+
java -version 2>nul
if errorlevel 1 (
    echo ERROR: Java not found. Install Java 17+ from https://adoptium.net/
    exit /b 1
)

REM Check Gradle
gradle -v 2>nul
if errorlevel 1 (
    echo ERROR: Gradle not found. Install Gradle 8+ from https://gradle.org/install/
    echo Or install via SDKMAN / Scoop / Chocolatey
    exit /b 1
)

echo.
echo [1/3] Generating Gradle wrapper...
gradle wrapper
if errorlevel 1 (
    echo ERROR: Failed to generate Gradle wrapper
    exit /b 1
)

echo.
echo [2/3] Creating PostgreSQL database...
echo Make sure PostgreSQL is running on localhost:5432
echo Creating database 'sportbets'...
psql -U postgres -c "CREATE DATABASE sportbets;" 2>nul
if errorlevel 1 (
    echo NOTE: Database may already exist, continuing...
)

echo.
echo [3/3] Installing Playwright browsers (Chromium)...
call gradlew.bat -q dependencies --configuration runtimeClasspath
REM Install Playwright browsers
call gradlew.bat -q bootRun --args="--spring.profiles.active=discover" -x bootRun 2>nul
mvn exec:java -e -D exec.mainClass=com.microsoft.playwright.CLI -D exec.args="install chromium" 2>nul

echo.
echo ============================================================
echo Setup complete!
echo.
echo Next steps:
echo   1. Edit src\main\resources\application.yml
echo      - Set your PostgreSQL password
echo      - Set your Discord webhook URL
echo.
echo   2. Run API discovery to find Betplay endpoints:
echo      gradlew.bat bootRun --args="--spring.profiles.active=discover"
echo      Then update betplay.api.* in application.yml
echo.
echo   3. Start the monitor:
echo      gradlew.bat bootRun
echo ============================================================
