#!/bin/bash
# Chrome requires a non-default user-data-dir for remote debugging.
# First run: log in to betplay.com.co — session is saved in this profile.
PROFILE_DIR="$HOME/Library/Application Support/Google/ChromeDebug"

echo "Stopping Chrome and restarting with remote debugging on port 9222..."
killall "Google Chrome" 2>/dev/null
sleep 2
# caffeinate -i keeps macOS from suspending Chrome during sleep — without it, the CDP
# remote debugging server on port 9222 goes offline when the machine sleeps, causing
# the betting service to fail with a misleading "cannot connect" error on wake.
caffeinate -i "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --user-data-dir="$PROFILE_DIR" \
  --no-first-run \
  --no-default-browser-check \
  > /dev/null 2>&1 &
echo "Done. Chrome is starting with debug profile at: $PROFILE_DIR"
echo "Log in to betplay.com.co (only needed once), then run the app."
