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
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "$CLT"* ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      echo "Using $candidate instead of the Command Line Tools."
      break
    fi
  done
fi

explain_toolchain_failure() {
  cat >&2 <<'MSG'

The Command Line Tools cannot compile this app: on this SDK, SwiftUI's @State is a
compiler macro whose plugin (SwiftUIMacros) ships only inside Xcode. Install Xcode from
the App Store (or the beta that matches this macOS from developer.apple.com), point the
toolchain at it, and build again:

    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    make clean && make install

MSG
}

# --- Build -------------------------------------------------------------------
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/macnotchisland-build.XXXXXX")"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c "$CONFIG" 2>&1 | tee "$BUILD_LOG"; then
  if grep -q "plugin for module 'SwiftUIMacros' not found" "$BUILD_LOG"; then
    explain_toolchain_failure
  fi
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
