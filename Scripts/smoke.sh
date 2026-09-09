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
swiftc -O -o "$OUT/notify" Scripts/notify.swift || exit 1
swiftc -O -o "$OUT/windowid" Scripts/windowid.swift || exit 1
swiftc -O -o "$OUT/key" Scripts/key.swift || exit 1
defaults write "$ID" hasSeenWelcome -bool true
defaults write "$ID" hapticsEnabled -bool false
defaults write "$ID" updateChecksEnabled -bool false
defaults write "$ID" screenshotsToShelfEnabled -bool false
# EventKit's permission sheet opens in the middle of the screen and stays there, unanswered,
# for the rest of the run — it has been standing over every screenshot this test has ever
# taken. Nothing here tests the calendar.
defaults write "$ID" calendarEnabled -bool false

DIED=0
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

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
  # Step between sections the way a user does: click two of the switcher's slots beside the
  # cutout. The panel must move to each one and must not resize or die doing it.
  #
  # The offsets are slot centres, not guesses: with NOTCH_SIMULATE the cutout is 200 wide and
  # the band keeps 10 either side of it, so the sections start 110 right of the notch centre
  # and run at a 26 pt slot every 30 pt. That puts slot 1 at 123 and slot 3 at 183. Clicking
  # 2 pt inside a slot's edge, which is where the old 172 landed once the slots grew, is a
  # test that passes on the arithmetic rather than on the thing it is checking.
  if [ "$name" != "floating" ]; then
    for offset in 123 183; do
      echo "--- click switcher slot at mid+$offset"; "$OUT/click" "mid+$offset" 17; sleep 1.2
    done
    screencapture -x "$OUT/$name-4-after-switcher.png"
    # Escape closes it. The app registers a global hot key for that the moment something
    # opens, and nothing had ever pressed it.
    echo "--- Escape"; "$OUT/key" 53; sleep 1.2
  fi
  echo "--- click 3: far away (should close)"; "$OUT/click" 120 500; sleep 1.5
  screencapture -x "$OUT/$name-3-after-outside-click.png"
  if kill -0 "$pid" 2>/dev/null; then
    echo "--- app alive: yes"; echo "alive $name: yes" >> "$SUMMARY"
  else
    echo "--- app alive: NO, it died"; echo "alive $name: NO" >> "$SUMMARY"; DIED=1
  fi
  # One `log show` per case: it is the slowest command here, and both the printout and the
  # navigation check read the same capture.
  local logfile="$OUT/$name-unified.log"
  log show --start "$start" --predicate "subsystem == \"$ID\"" --info --style compact > "$logfile" 2>&1
  echo "--- unified log"
  tail -n 120 "$logfile"
  echo "--- errors and faults from the process"
  log show --start "$start" --predicate "process == \"MacNotchIsland\" AND (messageType == error OR messageType == fault)" --style compact 2>&1 | tail -n 40
  # The island is fused to the top of the screen: its black must start on the very first row.
  # A seam here is what a user sees as "it sits a couple of pixels too low".
  if [ "$name" != "floating" ]; then
    # Which sections the panel actually opened, from what the app logged.
    local sections
    sections=$(grep -o 'home(tab: "[a-z]*")' "$logfile" | sort -u | wc -l | tr -d ' ')
    echo "--- sections opened: $sections"
    echo "sections $name: $sections" >> "$SUMMARY"
    if [ "$sections" -lt 2 ]; then
      echo "SMOKE FAILED: clicking the switcher did not step between sections"; DIED=1
    fi
    local escaped; escaped=$(grep -c ': escape' "$logfile" || true)
    echo "--- escape closed it: $escaped"
    echo "escape $name: $escaped" >> "$SUMMARY"
    if [ "$escaped" -lt 1 ]; then echo "SMOKE FAILED: Escape did not close the panel"; DIED=1; fi
    for shot in 1-after-open 3-after-outside-click; do
      local png="$OUT/$name-$shot.png"
      [ -f "$png" ] || continue
      local gap; gap=$("$OUT/topgap" "$png")
      echo "--- topgap $name-$shot: $gap px"
      echo "topgap $name-$shot: $gap px" >> "$SUMMARY"
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
  for shot in 1-after-open 2-after-second-click 4-after-switcher 3-after-outside-click; do
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

# The Settings window is the app's other face and nothing has ever looked at it: the gallery
# renders SwiftUI into an image and this is a real NavigationSplitView in a real window, which
# only a real screen can show. So the smoke opens a couple of its panes and photographs them.
# Cropped around the middle of the screen, where a new window lands, and scaled down: the job
# log is read back through an API that truncates it, and the island's own gallery is in there
# too.
# One window, photographed by its own number rather than cropped out of a picture of the
# screen: it is a quarter of the bytes, and it does not depend on guessing where the window
# landed. The job log these come back through has the island's whole gallery in it too.
shoot() {  # name
  local name=$1 id
  id=$("$OUT/windowid" MacNotchIsland 200) || { echo "--- $name: no window to photograph"; return; }
  screencapture -x -o -l"$id" "$OUT/$name.png" || return
  sips -Z 720 "$OUT/$name.png" >/dev/null 2>&1
  sips -s format jpeg -s formatOptions 50 "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1
  echo "--- strip $name (base64 jpeg)"
  base64 -i "$OUT/$name.jpg" | fold -w 400
}

# The welcome tour is what a new Mac sees first, and nothing has ever looked at that either.
# It comes up on its own when the app has not been seen before, so this case simply says it
# has not.
run_welcome() {
  echo "=== case welcome"
  defaults delete "$ID" hasSeenWelcome 2>/dev/null
  "$APP/Contents/MacOS/MacNotchIsland" > "$OUT/welcome-app.log" 2>&1 &
  local pid=$!
  sleep 7
  shoot "welcome-1"
  # The second page: the switches a new Mac is offered. Continue is the window's default
  # button, so Return presses it wherever the window happens to have landed.
  "$OUT/key" 36
  sleep 1
  shoot "welcome-2"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  defaults write "$ID" hasSeenWelcome -bool true
  sleep 1
}

run_settings() {
  echo "=== case settings"
  local start; start=$(date '+%Y-%m-%d %H:%M:%S')
  "$APP/Contents/MacOS/MacNotchIsland" > "$OUT/settings-app.log" 2>&1 &
  local pid=$!
  sleep 6
  for pane in general island activities home media shortcuts privacy about; do
    "$OUT/notify" "notchisland://settings/$pane"
    sleep 2
    shoot "settings-$pane"
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "alive settings: yes" >> "$SUMMARY"
  else
    echo "alive settings: NO" >> "$SUMMARY"; DIED=1
  fi
  # Whether the window ever came up, from what the app logged about the URLs it was sent.
  local logfile="$OUT/settings-unified.log"
  log show --start "$start" --predicate "subsystem == \"$ID\"" --info --style compact > "$logfile" 2>&1
  echo "--- unified log"
  grep -c . "$logfile" >/dev/null 2>&1 && tail -n 40 "$logfile"
  local opened; opened=$(grep -c 'settings window opened' "$logfile" || true)
  echo "--- settings opened: $opened"
  echo "--- windows the app had"; grep 'app windows:' "$logfile" | tail -n 3
  echo "settings opened: $opened" >> "$SUMMARY"
  if [ "$opened" -lt 1 ]; then echo "SMOKE FAILED: notchisland://settings never opened the window"; DIED=1; fi
  # Being told a window opened is not a window. The app has its status bar item and nothing
  # else until Settings is up, so a count above one is the window itself.
  local windows; windows=$(grep -c 'app windows: [2-9]' "$logfile" || true)
  echo "--- settings windows seen: $windows"
  echo "settings windows: $windows" >> "$SUMMARY"
  if [ "$windows" -lt 1 ]; then echo "SMOKE FAILED: the settings window was never actually there"; DIED=1; fi
  echo "--- app stderr"; tail -n 20 "$OUT/settings-app.log"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 1
}

run_case floating 21
run_case notch 16 "NOTCH_SIMULATE=1"
# The path users take most: a track is playing, the compact island shows it, a click opens
# the Now Playing card. Simulated notch and a made-up track, so the runner needs no player.
run_case nowplaying 16 "NOTCH_SIMULATE=1 NOTCH_FAKE_TRACK=1"
run_settings
run_welcome
echo "--- done"
if [ "$DIED" -ne 0 ]; then echo "SMOKE FAILED: see the failures above"; exit 1; fi
