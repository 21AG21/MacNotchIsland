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
rm -f "$OUT"
hdiutil create -volname "Notch Island" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "Wrote $OUT"
