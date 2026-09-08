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
swiftc -O -o "$OUT/topgap" Scripts/topgap.swift || exit 1
defaults write "$ID" hasSeenWelcome -bool true
defaults write "$ID" hapticsEnabled -bool false
defaults write "$ID" updateChecksEnabled -bool false
defaults write "$ID" screenshotsToShelfEnabled -bool false

DIED=0

run_case() {  # name, click y, extra env
  local name=$1 y=$2 env=${3:-}
  echo "=== case $name"
  local start; start=$(date '+%Y-%m-%d %H:%M:%S')
  env $env "$APP/Contents/MacOS/MacNotchIsland" > "$OUT/$name-app.log" 2>&1 &
  local pid=$!
  sleep 6
  echo "--- click 1: the island (should open)"; "$OUT/click" mid "$y"; sleep 2.5
  screencapture -x "$OUT/$name-1-after-open.png"
  echo "--- click 2: the open panel (should stay open)"; "$OUT/click" mid "$y"; sleep 1.5
  screencapture -x "$OUT/$name-2-after-second-click.png"
  echo "--- click 3: far away (should close)"; "$OUT/click" 120 500; sleep 1.5
  screencapture -x "$OUT/$name-3-after-outside-click.png"
  if kill -0 "$pid" 2>/dev/null; then echo "--- app alive: yes"; else echo "--- app alive: NO, it died"; DIED=1; fi
  echo "--- unified log"
  log show --start "$start" --predicate "subsystem == \"$ID\"" --info --style compact 2>&1 | tail -n 120
  echo "--- errors and faults from the process"
  log show --start "$start" --predicate "process == \"MacNotchIsland\" AND (messageType == error OR messageType == fault)" --style compact 2>&1 | tail -n 40
  # The island is fused to the top of the screen: its black must start on the very first row.
  # A seam here is what a user sees as "it sits a couple of pixels too low".
  if [ "$name" != "floating" ]; then
    for shot in 1-after-open 3-after-outside-click; do
      local png="$OUT/$name-$shot.png"
      [ -f "$png" ] || continue
      local gap; gap=$("$OUT/topgap" "$png")
      echo "--- topgap $name-$shot: $gap px"
      if [ "$gap" -gt 4 ]; then echo "SMOKE FAILED: the island sits ${gap}px below the top of the screen"; DIED=1; fi
    done
  fi
  echo "--- app stderr"; tail -n 20 "$OUT/$name-app.log"
  echo "--- crash reports"
  for f in $(ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i notch | head -1); do
    local report=~/Library/Logs/DiagnosticReports/"$f"
    echo "$f"
    head -n 1 "$report"
    grep -o '"termination"[^}]*}' "$report" | head -1
    grep -o '"exception"[^}]*}' "$report" | head -1
    grep -o '"asi"[^}]*}' "$report" | head -1
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
# The path users take most: a track is playing, the compact island shows it, a click opens
# the Now Playing card. Simulated notch and a made-up track, so the runner needs no player.
run_case nowplaying 16 "NOTCH_SIMULATE=1 NOTCH_FAKE_TRACK=1"
echo "--- done"
if [ "$DIED" -ne 0 ]; then echo "SMOKE FAILED: see the failures above"; exit 1; fi
