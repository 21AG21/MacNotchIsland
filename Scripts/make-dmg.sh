#!/usr/bin/env bash
# Packages build/MacNotchIsland.app into a drag-to-Applications DMG.
#   Scripts/make-dmg.sh [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/MacNotchIsland.app"
OUT="${1:-build/MacNotchIsland.dmg}"
[ -d "$APP" ] || Scripts/build.sh
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The one thing every first launch of a build like this runs into, said where somebody is
# already looking. Ad-hoc signed is not notarized, and since macOS 15 right-click and Open no
# longer gets past that — so without this the first thing the app does is refuse to open.
cat > "$STAGE/First Launch.txt" <<'TXT'
Notch Island — first launch
===========================

This build is signed ad-hoc rather than notarized (notarizing needs a paid
Apple Developer ID), so macOS refuses to open it the first time. Nothing is
wrong with the app; this is what an unnotarized build looks like.

  1. Drag Notch Island to Applications.
  2. Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/MacNotchIsland.app

  3. Open it from Applications.

Or open it once, dismiss the warning, and click Open Anyway under
System Settings > Privacy & Security.

macOS ties every permission to the exact copy of the app it was granted to,
and an ad-hoc signature is a different copy every build — so replacing this
with a newer one starts Accessibility, Screen Recording and the rest from
nothing again. Settings > Privacy lists what is granted right now.

There is no Dock icon. The capsule in the menu bar has Settings, timers, a
demo of every alert, and Quit. Press Control-Option-Space anywhere to summon
the island; rest the pointer on the notch to peek at it.
TXT
rm -f "$OUT"
hdiutil create -volname "Notch Island" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Wrote $OUT"
