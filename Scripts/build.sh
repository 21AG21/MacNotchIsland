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

# --- Toolchain ---------------------------------------------------------------
# On current SDKs SwiftUI implements @State as a compiler macro (SwiftUIMacros), and the
# macro plugin ships only inside Xcode. A Command Line Tools-only install therefore cannot
# compile the app. Prefer a full Xcode when one is present, without touching the
# system-wide xcode-select setting; an explicit DEVELOPER_DIR always wins.
CLT="/Library/Developer/CommandLineTools"
find_xcode() {
  local candidate
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app \
                   /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then echo "$candidate"; return 0; fi
  done
  candidate="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$candidate" && -d "$candidate/Contents/Developer" ]]; then echo "$candidate"; return 0; fi
  return 1
}
XCODE=""
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT"* ]]; then
  if XCODE="$(find_xcode)"; then
    export DEVELOPER_DIR="$XCODE/Contents/Developer"
    echo "Using $XCODE instead of the Command Line Tools."
  fi
fi

explain_failure() {
  if grep -q "xcodebuild -license" "$BUILD_LOG"; then
    cat >&2 <<'MSG'

Xcode needs its license accepted once before it can build anything:

    sudo xcodebuild -license accept

MSG
  elif grep -q "plugin for module 'SwiftUIMacros' not found" "$BUILD_LOG"; then
    if [[ -n "$XCODE" ]]; then
      cat >&2 <<MSG

The build used $XCODE, but its toolchain lacks the SwiftUI macro plugin this
SDK needs. Update Xcode to the version that matches this macOS (App Store, or the beta
from developer.apple.com/download) and run "make clean && make install" again.

MSG
    else
      cat >&2 <<'MSG'

Xcode is not installed, and the Command Line Tools cannot compile this app: on this SDK,
SwiftUI's @State is a compiler macro whose plugin (SwiftUIMacros) ships only inside Xcode.

  Either install Xcode from the App Store (or the beta that matches this macOS from
  developer.apple.com/download) and run "make clean && make install" again; the script
  finds Xcode on its own.

  Or skip building: open the latest run at https://github.com/21AG21/MacNotchIsland/actions,
  download the MacNotchIsland artifact, then in Terminal:

      cd ~/Downloads && unzip -o MacNotchIsland.zip
      ditto -x -k MacNotchIsland.app.zip /Applications
      xattr -dr com.apple.quarantine /Applications/MacNotchIsland.app
      open /Applications/MacNotchIsland.app

MSG
    fi
  fi
}

# --- Build -------------------------------------------------------------------
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/macnotchisland-build.XXXXXX")"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c "$CONFIG" 2>&1 | tee "$BUILD_LOG"; then
  explain_failure
  exit 1
fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP"

# --- Bundle ------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
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
