#!/usr/bin/env bash
# Smoke test on a real macOS session (CI): launch the built app, click the island, click it
# again, click somewhere else, and print what the app logged about each, with screenshots.
# Runs twice: as the floating pill a plain display gets, and with NOTCH_SIMULATE=1, which
# makes the display behave as if it had a MacBook notch, the geometry real users have.
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

run_case() {  # name, click y, extra env
  local name=$1 y=$2 env=${3:-}
  echo "=== case $name"
  local start; start=$(date '+%Y-%m-%d %H:%M:%S')
  env $env "$APP/Contents/MacOS/MacNotchIsland" > "$OUT/$name-app.log" 2>&1 &
  local pid=$!
  sleep 6
  echo "--- click 1: the idle island (should open Home)"; "$OUT/click" mid "$y"; sleep 2.5
  screencapture -x "$OUT/$name-1-after-open.png"
  echo "--- click 2: the open panel (should stay open)"; "$OUT/click" mid "$y"; sleep 1.5
  screencapture -x "$OUT/$name-2-after-second-click.png"
  echo "--- click 3: far away (should close)"; "$OUT/click" 120 500; sleep 1.5
  screencapture -x "$OUT/$name-3-after-outside-click.png"
  if kill -0 "$pid" 2>/dev/null; then echo "--- app alive: yes"; else echo "--- app alive: NO, it died"; fi
  echo "--- unified log"
  log show --start "$start" --predicate "subsystem == \"$ID\"" --info --style compact 2>&1 | tail -n 120
  echo "--- app stderr"; tail -n 20 "$OUT/$name-app.log"
  echo "--- crash reports"
  for f in $(ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i notch | head -1); do
    head -n 60 ~/Library/Logs/DiagnosticReports/"$f"
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 1
  # A strip across the top of each screenshot, small enough to read back from the job log.
  for shot in 1-after-open 2-after-second-click 3-after-outside-click; do
    local png="$OUT/$name-$shot.png"
    [ -f "$png" ] || continue
    local w off; w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')
    off=$(( w / 2 - 500 )); [ "$off" -lt 0 ] && off=0
    sips -c 260 1000 --cropOffset 0 "$off" "$png" --out "$OUT/$name-$shot-strip.png" >/dev/null 2>&1
    sips -s format jpeg -s formatOptions 55 "$OUT/$name-$shot-strip.png" --out "$OUT/$name-$shot-strip.jpg" >/dev/null 2>&1
    echo "--- strip $name-$shot (base64 jpeg)"
    base64 -i "$OUT/$name-$shot-strip.jpg" | fold -w 400
  done
}

run_case floating 21
run_case notch 16 "NOTCH_SIMULATE=1"
echo "--- done"
