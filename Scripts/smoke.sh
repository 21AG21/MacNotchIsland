#!/usr/bin/env bash
# Smoke test on a real macOS session (CI): launch the built app, click the island, click it
# again, click somewhere else, and print what the app logged about each, with screenshots.
# The island on a display without a notch is the floating pill at the top centre.
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/MacNotchIsland.app
ID=com.macnotchisland.app
OUT=build/smoke
mkdir -p "$OUT"

swiftc -O -o "$OUT/click" Scripts/click.swift || exit 1
defaults write "$ID" hasSeenWelcome -bool true
defaults write "$ID" hapticsEnabled -bool false
defaults write "$ID" updateChecksEnabled -bool false
defaults write "$ID" screenshotsToShelfEnabled -bool false

START=$(date '+%Y-%m-%d %H:%M:%S')
"$APP/Contents/MacOS/MacNotchIsland" > "$OUT/app.log" 2>&1 &
APP_PID=$!
sleep 6

echo "--- click 1: the idle island (should open Home)"; "$OUT/click" mid 21; sleep 2.5
screencapture -x "$OUT/1-after-open.png"
echo "--- click 2: the open panel (should stay open)"; "$OUT/click" mid 21; sleep 1.5
screencapture -x "$OUT/2-after-second-click.png"
echo "--- click 3: far away (should close)"; "$OUT/click" 120 500; sleep 1.5
screencapture -x "$OUT/3-after-outside-click.png"

if pgrep -x MacNotchIsland >/dev/null; then echo "--- app alive: yes"; else echo "--- app alive: NO, it died"; fi
echo "--- unified log"
log show --start "$START" --predicate "subsystem == \"$ID\"" --info --style compact 2>&1 | tail -n 200
echo "--- app stderr"; tail -n 40 "$OUT/app.log"
echo "--- crash reports"
for f in $(ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i notch | head -1); do
  head -n 60 ~/Library/Logs/DiagnosticReports/"$f"
done
kill "$APP_PID" 2>/dev/null

# A strip across the top of each screenshot, small enough to read back from the job log.
for shot in 1-after-open 2-after-second-click 3-after-outside-click; do
  [ -f "$OUT/$shot.png" ] || continue
  W=$(sips -g pixelWidth "$OUT/$shot.png" | awk '/pixelWidth/ {print $2}')
  OFF=$(( W / 2 - 500 )); [ "$OFF" -lt 0 ] && OFF=0
  sips -c 260 1000 --cropOffset 0 "$OFF" "$OUT/$shot.png" --out "$OUT/$shot-strip.png" >/dev/null 2>&1
  sips -s format jpeg -s formatOptions 55 "$OUT/$shot-strip.png" --out "$OUT/$shot-strip.jpg" >/dev/null 2>&1
  echo "--- strip $shot (base64 jpeg)"
  base64 -i "$OUT/$shot-strip.jpg" | fold -w 400
done
echo "--- done"
