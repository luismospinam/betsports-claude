@echo off
echo Stopping Chrome and restarting with remote debugging on port 9222...
powershell -NonInteractive -command "Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' -ArgumentList '--remote-debugging-port=9222', '--user-data-dir=C:\Users\lmosp\AppData\Local\Google\Chrome\User Data', '--no-first-run', '--no-default-browser-check'"
echo Done. Chrome is starting - log in to betplay.com.co then run the app.
pause
