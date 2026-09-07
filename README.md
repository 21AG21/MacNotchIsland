# Notch Island

The iPhone's Dynamic Island, rebuilt for the MacBook notch. Built and tuned for the
15-inch MacBook Air (M5) but it detects the notch on any notched MacBook and can simulate
an island on external displays.

The island lives in a transparent panel over the notch. Idle, it *is* the notch. When
something happens it grows out of the notch with the same spring, the same three states,
and the same content layout as iOS.

## What it does

| iPhone Dynamic Island | Notch Island on the Mac |
| --- | --- |
| Now Playing: artwork on the left, artwork-tinted audio bars on the right; expanded scrubber, title, artist, transport controls | Same, for any app playing through the system player (Music, Spotify, Safari, Podcasts…). Hover to expand, click to open the app, drag the scrubber to seek, swipe sideways on the island to skip tracks. Time-synced lyrics from LRCLIB under the title. |
| Timer countdown in orange, expanded pause / cancel, "timer done" state | Same, with 1–60 min presets in the Home panel and menu bar, or `notchctl timer 5`. |
| Stopwatch Live Activity (iOS 17) with laps | Same: Home panel, menu bar, or `notchisland://stopwatch`. |
| Call: green phone glyph and running duration | Detected from microphone use by FaceTime, Zoom, Teams, Slack, Discord, Webex, Meet. |
| Charging bolt and percentage when you plug in; low-battery alert; "charged" | Same, from IOKit power-source events. Low Power Mode on/off too. |
| AirPods / Bluetooth connect with battery | IOBluetooth connection events, AirPods left / right / case battery rings from the IORegistry. |
| Focus on / off with the Focus symbol | Watches macOS's Focus assertion database. |
| Silent / ring switch, volume | Mute shows the bell; volume and brightness changes show a level bar. Optionally the island *replaces* the system bezel entirely (event tap, needs Accessibility). Scroll on the island to change volume. |
| Privacy indicators inside the island (orange mic, green camera) | Same, from CoreAudio and CoreMediaIO "running somewhere" properties. |
| Face ID unlock animation | "Unlocked" when the Mac unlocks. |
| Live Activities from apps (deliveries, rides, builds…) | `notchisland://` URL scheme and `Scripts/notchctl`, usable from Shortcuts, scripts and CI. |
| Two activities: one in the island, one in the detached bubble; tap to swap | Same, including the bubble swap. Alerts are ranked so a volume tick never hides a low-battery warning. |
| Upcoming calendar event | Optional: next event 10 minutes out with a Join button when a meeting link is found. |
| Long-press to expand, tap to open | Hover to expand, click to open, ⌃⌥Space from anywhere, Escape to close. Trackpad haptics on state changes. |
| — | Home panel when nothing is live: mini player and timer presets, a file shelf (multi-select, AirDrop, share, trash, auto-expiry), clipboard history, quick actions that run your Shortcuts, camera mirror, system stats, and weather. |
| — | Trackpad gestures: swipe sideways on the island to skip tracks or switch Home tabs, scroll for volume. A customizable global shortcut. Optional audio-reactive bars driven by a system audio tap. |
| — | Hide the island for an hour from the menu bar, or automatically while a full-screen app is in front. A daily check against GitHub releases tells you when a new version is out. |
| — | Downloads: Safari, Chrome and Firefox downloads in ~/Downloads become Live Activities with progress, then a "Download complete" alert. Caps Lock pill. |
| — | Energy discipline: animations slow on battery and stop in Low Power Mode or sleep; every poller backs off; idle CPU stays near zero. |

## Build

Requires macOS 14 Sonoma or later and Xcode 15+ (or the Command Line Tools with a Swift 5.9
toolchain).

```sh
git clone https://github.com/21AG21/MacNotchIsland.git
cd MacNotchIsland
make            # builds build/MacNotchIsland.app
make run        # builds and launches
make install    # copies to /Applications
```

The app has no Dock icon. Use the capsule in the menu bar for Settings, the timer, the
demo menu, and Quit. Turn on "Launch at login" in Settings once you're happy with it.
Press ⌃⌥Space anywhere to summon the island.

`Scripts/make-dmg.sh` builds a drag-to-Applications disk image; pushing a `v*` tag runs the
Release workflow, which attaches the DMG and a zip to a GitHub Release. Every push also
uploads a fresh `MacNotchIsland.app` as a build artifact on the Actions tab.

## First launch of a downloaded build

Builds from the Actions tab and the Release page are ad-hoc signed, not notarized (that
needs a paid Apple Developer ID). Gatekeeper will refuse to open them until you either
right-click the app and choose Open, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/MacNotchIsland.app
```

Building from source with `make` has no such step.

## Permissions

Nothing is required up front. macOS asks for these lazily:

- **Automation (Music, Spotify)**: only if the MediaRemote helper can't run. On macOS 15.4
  and later Apple stopped delivering system-wide Now Playing data to third-party apps, so
  the build bundles a tiny helper (`Adapter/MediaRemoteAdapter.m`) that runs inside
  `/usr/bin/perl`, an Apple-signed host, and streams Now Playing data to the app. If that
  ever fails, Notch Island falls back to asking Music and Spotify directly with AppleScript,
  which prompts once per app.
- **Calendars**: only if you turn on "Upcoming calendar events".

The microphone and camera indicators read the devices' *in-use* state; no audio or video is
ever captured.

## Automation

Any script or Shortcut (via "Open URLs") can push a Live Activity:

```sh
Scripts/notchctl activity build --title "Building" --subtitle "xcodebuild" --symbol hammer.fill --tint blue --progress 0.4 --ring
Scripts/notchctl activity build --title "Building" --progress 0.9           # update in place
Scripts/notchctl end build
Scripts/notchctl alert "Deployed" --symbol checkmark.circle.fill --tint green
Scripts/notchctl timer 25 --label Focus
Scripts/notchctl shelf add ~/Downloads/report.pdf
```

The underlying URLs:

```
notchisland://activity?id=…&title=…&subtitle=…&symbol=…&tint=…&progress=0–1&trailing=…&body=…&url=…&ttl=seconds&expanded=1&ring=1&priority=70
notchisland://activity/end?id=…
notchisland://alert?title=…&symbol=…&tint=…&duration=3&expanded=1
notchisland://timer?minutes=5&label=Tea    notchisland://timer/cancel | pause | resume
notchisland://stopwatch                    notchisland://stopwatch/lap | stop | reset
notchisland://shelf/add?path=…             notchisland://shelf/clear
notchisland://home | collapse | settings
```

`tint` accepts the iOS system colour names (red, orange, yellow, green, mint, teal, cyan,
blue, indigo, purple, pink, brown, gray, white) or a hex value. `symbol` is any SF Symbol.

## How it's put together

- `Core/ActivityCenter.swift` owns live activities and transient alerts and derives the
  current presentation (idle, compact with optional bubble, expanded, home, shelf).
- `Core/IslandLayout.swift` turns a presentation plus the screen's notch geometry into
  concrete sizes and corner radii; the same function drives the click-through hit test.
- `Shapes/NotchShape.swift` is the outline with outward-curving top corners so the black
  blends into the bezel like the physical notch.
- `Core/NotchPanel.swift` is the non-activating panel above the menu bar and full-screen
  apps; `NotchHostingView` keeps everything outside the island click-through.
- `Services/` holds one monitor per data source. Each is independent and toggled from
  Settings.
- The Settings window follows the house monochrome style: flat ground, big type, hairlines,
  no accent colour. The island itself keeps iOS's semantic colours (orange timer, green call
  and charging, artwork-tinted visualizer) because that is what it is cloning.

## Notes

- macOS still shows its own volume / brightness bezel; suppressing it requires disabling a
  system service, which this app does not do.
- The island stays above full-screen apps and on every Space. On a Mac without a notch (or
  an external display with "Show on every display" on) a simulated island is drawn at the
  top centre.
