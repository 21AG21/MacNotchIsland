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
| Now Playing: artwork on the left, artwork-tinted audio bars on the right; expanded scrubber, title, artist, transport controls | Same, for any app playing through the system player (Music, Spotify, Safari, Podcasts…). Hover or click for the Now Playing section: scrubber, transport, an output picker, time-synced lyrics from LRCLIB. A track that starts peeks into the pill for a moment with its title and artist. Swipe sideways on the pill to skip tracks. |
| Timer countdown in orange, expanded pause / cancel, "timer done" state | Same, with 1–60 min presets in the Home panel and menu bar, or `notchctl timer 5`. |
| Stopwatch Live Activity (iOS 17) with laps | Same: Home panel, menu bar, or `notchisland://stopwatch`. |
| Call: green phone glyph and running duration | Detected from microphone use by FaceTime, Zoom, Teams, Slack, Discord, Webex, Meet. |
| Charging bolt and percentage when you plug in; low-battery alert; "charged" | Same, from IOKit power-source events. Low Power Mode on/off too. |
| AirPods / Bluetooth connect with battery | IOBluetooth connection events: a brief pill with the level as a device connects, the card with left, right and case one click away, read from the IORegistry. |
| Focus on / off with the Focus symbol | Watches macOS's Focus assertion database. |
| Silent / ring switch, volume | Turn on "Replace the system volume and brightness bezel" (event tap, needs Accessibility) and the volume, mute and brightness keys are answered in the island instead — a level bar that also names where the sound is going, which the system's bezel never does. There is only ever one display: a key the island cannot answer, or whose display you have switched off, goes straight back to macOS and its own bezel. Scroll on the island to change volume. |
| Privacy indicators inside the island (orange mic, green camera) | Same, from CoreAudio and CoreMediaIO "running somewhere" properties. |
| Face ID unlock animation | "Unlocked" when the Mac unlocks. |
| Live Activities from apps (deliveries, rides, builds…) | `notchisland://` URL scheme and `Scripts/notchctl`, usable from Shortcuts, scripts and CI. |
| Two activities: one in the island, one in the detached bubble; tap to swap | Same, including the bubble swap: the most recently started activity owns the island, a call or a timer that just rang always does, and the shelf waits in the bubble while something plays. Alerts are ranked so a volume tick never hides a low-battery warning. |
| Upcoming calendar event | Optional: next event 10 minutes out with a Join button when a meeting link is found. The Today section lists the next 24 hours and today's reminders. |
| Long-press to expand, tap to open | Rest the pointer on the island to peek at the panel; click to keep it open, click anywhere else (or press Escape) to close it. What you open stays open across desktops. A global shortcut (⌃⌥Space by default) toggles it, the same modifiers with Tab step through every section and with Shift + Tab step back. The island never covers a menu title or status item: it only widens into menu bar space that is free. |
| — | One panel for everything. A switcher beside the notch holds the live activities on the left and the sections on the right: Now Playing, Today (events, reminders, weather), Windows, the shelf (multi-select, AirDrop, share, trash, auto-expiry), clipboard history with pins and search, actions that run your Shortcuts, a notes scratchpad, and system stats. Under every section a control rail: volume, light/dark, Keep Awake and Settings always; brightness, Wi-Fi and Bluetooth where the Mac has them; where the sound is going as soon as there is more than one place it could go; the camera mirror and AirDrop for the shelf when there is something to point them at. Files dropped on the notch also show as their own activity, with a count, until the shelf is empty. |
| — | Windows: every open window as a live tile. Click one to bring it forward; the zones on it send it to a half of the screen, fill the screen, centre it or close it. Pictures need Screen Recording, moving needs Accessibility; without them the windows are still listed by app. |
| — | Trackpad gestures: swipe sideways on the pill to skip tracks, on the panel to step between sections; scroll for volume, and hold Option while scrolling for brightness. A customizable global shortcut. Optional audio-reactive bars driven by a system audio tap. |
| — | The panel answers the keyboard while it is open, with nothing held down: ← and → step between views, 1 to 9 go straight to a slot of the switcher, Space plays and pauses, ↑ and ↓ move the volume. Only while it is pinned open, and never while Notes or the clipboard search is showing. |
| — | A shelf that takes anything: files, a picture, a link or selected text dragged onto the notch. Drag the whole selection back out in one go, Quick Look any of it, AirDrop or share it. |
| — | Clipboard history that pastes: pick an item and it goes straight into whatever you were typing — or drag one out of the panel and into a document, a message or a folder. |
| — | Keep Awake from the control rail or the menu bar: the Mac and its display stay on until you switch it off again. |
| — | Hide the island for an hour from the menu bar, or automatically while a full-screen app is in front. A daily check against GitHub releases tells you when a new version is out. |
| — | Downloads: Safari, Chrome and Firefox downloads in ~/Downloads become Live Activities with progress, then a "Download complete" alert. Caps Lock pill. |
| — | Energy discipline: animations slow on battery and stop in Low Power Mode or sleep; every poller backs off; idle CPU stays near zero. |
| — | Hide the island automatically while chosen apps are in front (Keynote, a game, a screen-sharing client). Screenshots land on the shelf with a brief thumbnail alert. |
| — | Full VoiceOver support: every state, tab, control and shelf item is labelled and reads naturally. |
| — | On a Mac without a notch, or on an external display, the island floats at the top centre with the same morphs. |

## Build

Requires macOS 14 Sonoma or later and Xcode 15 or later. The Command Line Tools on their own
are not enough on current SDKs: SwiftUI's `@State` is a compiler macro there, and the macro
plugin ships only inside Xcode. The build script uses an installed Xcode automatically; if
the build stops with `plugin for module 'SwiftUIMacros' not found`, install Xcode and
select it:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make clean
```

```sh
git clone https://github.com/21AG21/MacNotchIsland.git
cd MacNotchIsland
make            # builds build/MacNotchIsland.app
make run        # builds and launches
make install    # copies to /Applications
make test       # runs the test suite
make dmg        # builds a drag-to-Applications disk image
```

The app has no Dock icon. Use the capsule in the menu bar for Settings, the timer, the
demo menu, and Quit — or right-click the island itself for the short version of the same menu. Turn on "Launch at login" in Settings once you're happy with it.
Press ⌃⌥Space anywhere to summon the island; with it open, the arrows, the digits and Space
drive it without a modifier.

`Scripts/make-dmg.sh` builds a drag-to-Applications disk image; pushing a `v*` tag runs the
Release workflow, which attaches the DMG and a zip to a GitHub Release.

### Without a toolchain

Every push also builds the app on GitHub, so nothing needs to be installed locally. Open the
latest run on the [Actions tab](https://github.com/21AG21/MacNotchIsland/actions), download
the `MacNotchIsland` artifact (sign-in required), then in Terminal:

```sh
cd ~/Downloads
unzip -o MacNotchIsland.zip                          # GitHub's wrapper, yields MacNotchIsland.app.zip
pkill -x MacNotchIsland; ditto -x -k MacNotchIsland.app.zip /Applications   # quit the old copy; keep permissions and signature
xattr -dr com.apple.quarantine /Applications/MacNotchIsland.app
open /Applications/MacNotchIsland.app
```

## First launch of a downloaded build

Builds from the Actions tab and the Release page are ad-hoc signed, not notarized (that
needs a paid Apple Developer ID), so Gatekeeper refuses to open them. Since macOS 15,
right-click and Open no longer bypasses that. Either clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/MacNotchIsland.app
```

or open the app once, dismiss the warning, then click Open Anyway under System Settings >
Privacy & Security.

Building from source with `make` has no such step.

macOS ties a permission to the exact copy of the app it was granted to, and an ad-hoc
signature is a different copy every build. So replacing the app with a newer one starts
Accessibility, Screen Recording and the rest from nothing again, and the features that need
them go quiet until they are granted a second time. Settings > Privacy lists what is granted
right now, with a way straight to each pane of System Settings. A notarized build would keep
them; that needs a paid Developer ID.

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
notchisland://home[/music|today|shelf|clipboard|actions|notes|stats] | collapse | settings
```

`tint` accepts the iOS system colour names (red, orange, yellow, green, mint, teal, cyan,
blue, indigo, purple, pink, brown, gray, white) or a hex value. `symbol` is any SF Symbol.

## How it's put together

- `Core/ActivityCenter.swift` owns live activities and transient alerts and derives the
  current presentation (idle, compact with optional bubble, a system card, the panel on a
  section or an activity, the shelf while files are dragged over the island).
- `Core/HomeSection.swift` is the one list of panel sections that the switcher, the keyboard
  ring, the swipes and the URL scheme all read.
- `Core/IslandLayout.swift` turns a presentation plus the screen's notch geometry into
  concrete sizes and corner radii; the same function drives the click-through hit test.
- `Shapes/NotchShape.swift` is the outline with outward-curving top corners so the black
  blends into the bezel like the physical notch.
- `Core/NotchPanel.swift` is the non-activating panel above the menu bar and full-screen
  apps; `NotchHostingView` keeps everything outside the island click-through.
- `Services/` holds one monitor per data source. Each is independent and toggled from
  Settings.
- Windows follow native macOS conventions (a System Settings-style sidebar, grouped forms,
  standard controls, an Apple-style welcome) in a monochrome palette. The island itself keeps
  the iPhone's: white values, coloured glyphs (orange timer, green call and charging),
  artwork-tinted bars. See `ARCHITECTURE.md` for the full map.

## Notes

- macOS shows its own volume / brightness bezel unless "Replace the system volume and
  brightness bezel" is on under Activities, which needs Accessibility access for the key tap.
- The island stays above full-screen apps and on every Space. On a Mac without a notch (or
  an external display with "Show on every display" on) a simulated island is drawn at the
  top centre.
