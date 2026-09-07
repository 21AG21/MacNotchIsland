#!/usr/bin/env bash
# Builds MacNotchIsland with SwiftPM and assembles a runnable .app bundle.
#   Scripts/build.sh            # release build -> build/MacNotchIsland.app
#   Scripts/build.sh --run      # build and launch
#   Scripts/build.sh --install  # build and copy into /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="MacNotchIsland"
OUT="build/$APP.app"
CONFIG="release"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# MediaRemote helper: a small ObjC dylib loaded by /usr/bin/perl so Now Playing keeps
# working on macOS 15.4+ (see Adapter/MediaRemoteAdapter.m).
if [ -f Adapter/MediaRemoteAdapter.m ]; then
  clang -fobjc-arc -O2 -dynamiclib -framework Foundation \
    -Wl,-install_name,@rpath/MediaRemoteAdapter.dylib \
    -o "$OUT/Contents/Resources/MediaRemoteAdapter.dylib" Adapter/MediaRemoteAdapter.m
  codesign --force --sign - "$OUT/Contents/Resources/MediaRemoteAdapter.dylib" >/dev/null 2>&1 || true
fi

# Ad-hoc sign so macOS keeps TCC grants (Automation, Calendar) stable between builds.
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || true

# Register the notchisland:// URL scheme with LaunchServices.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$OUT" >/dev/null 2>&1 || true

echo "Built $OUT"

case "${1:-}" in
  --run)
    open "$OUT" ;;
  --install)
    rm -rf "/Applications/$APP.app"
    cp -R "$OUT" "/Applications/$APP.app"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "/Applications/$APP.app" >/dev/null 2>&1 || true
    echo "Installed /Applications/$APP.app" ;;
esac
