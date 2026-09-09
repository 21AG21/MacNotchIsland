# Architecture

Notch Island is a single SwiftPM executable target (macOS 14+) with no third-party
dependencies. Everything is arranged around one state machine that decides what the island
shows, one layout function that turns that into geometry, and a set of independent services
that feed it.

```
Services/*  ──►  ActivityCenter  ──►  IslandLayout  ──►  IslandRootView / NotchPanel
 (monitors)      (state machine)      (pure geometry)    (SwiftUI in an NSPanel)
```

## Core

- **`Core/ActivityCenter.swift`** — the source of truth. It holds *live activities*
  (things with a lifetime: Now Playing, a timer, a call, a download, a Live Activity posted
  through the URL scheme) ordered the way the iPhone orders them (`ordered`: pinned, then
  urgent, then the most recently started kind, ambient things like the shelf last), plus a
  queue of *transient alerts* (a volume tick, "AirPods connected", a low-battery warning)
  ranked by `alertRank` so a louder alert never hides a quieter one that matters more. The
  user's *pinned view* (`openView`, an `IslandView`: an activity or a section of the panel,
  set by a click, the switcher or the keyboard ring and cleared by a click elsewhere, Escape
  or the shortcut), the *peek* (`peekView`, the same while the pointer merely rests on the
  island), press and drag state per panel, forced expansion, and the pause / full-screen /
  hidden-app suppression flags all live here. `presentation(for:)` reduces all of that to
  one of: idle, compact (optionally with a detached bubble), a system card, the panel on a
  view, shelf. `ring` is the one ordered list of activity cards and available sections that
  the switcher, Tab, the swipes and the URL scheme all step through; `Core/HomeSection.swift`
  is the list of sections and which of them the user has switched on.
- **`Core/NotchPanel.swift`** — the transparent, non-activating panel over the notch. Its
  frame follows the island's footprint (`refit`): it grows the instant something opens, with
  room for the spring to overshoot, and shrinks back after the closing animation, so at rest
  there is no invisible canvas over the menu bar or the windows beside the notch.
- **`Services/MenuBarClearance.swift`** — how much of the menu bar is free either side of the
  notch: status items from the window list, the frontmost app's menu titles through
  Accessibility when granted. `IslandLayout` only widens the compact island into free room,
  falling back to a glyph, a ring or a count, and drops the bubble when it would not fit.
- **`Core/IslandLayout.swift`** — `IslandLayout.make(presentation:geometry:)` is a pure
  function from a presentation and the screen's notch geometry to sizes, corner radii, ear
  width, top inset and the hit-test rectangle. Because it is pure it is unit-tested on
  Linux-free CI and shared by the SwiftUI body and the AppKit click-through test.
- **`Shapes/NotchShape.swift`** — the outline: outward-curving top "ears" so the black
  blends into the bezel, Apple-style continuous corners, and a `floating` variant for
  displays without a notch. `isPill` is passed explicitly so the bottom never flips
  between capsule and rounded-rect mid-animation.
- **`Core/IslandMotion.swift`** — the spring curves. One root `.animation` drives every
  morph; content swaps use `.blurReplace` and matched geometry through `IslandNamespace`.
- **`Core/NotchPanel.swift` / `NotchHostingView.swift`** — a non-activating `NSPanel`
  above the menu bar and full-screen apps on every Space. The hosting view answers
  `hitTest` from the layout's hit rectangle so everything outside the island is
  click-through, accepts first mouse, routes scroll and swipe to `GestureRouter`, and
  turns a right-click into "hold open".
- **`Core/EnergyPolicy.swift`** — observes sleep, Low Power Mode and battery power and
  publishes an animation interval and a polling multiplier that every animated view and
  every poller respects. Idle CPU is the number we protect.
- **`Core/IslandLog.swift`** — one `Logger` per part of the app that can fail on its own
  (`island`, `panel`, `media`, `keys`, `audio`, `display`, `store`, `network`), all under the
  bundle identifier as the subsystem. Nothing uses `NSLog`: a line with no subsystem cannot
  be asked for by one, and `App/Diagnostics.swift` — the support report on the menu bar —
  reads the log back by subsystem and by process.

## Services

One class per data source under `Services/`, each with `start()` / `stop()`, each toggled
from `App/ServiceHub.swift` by a preference, each safe to start twice or stop when not
running. They talk to `ActivityCenter` only through `upsert`, `end`, `showAlert` and the
suppression flags. Event-driven where the OS allows it (IOKit power sources, IOBluetooth,
CoreAudio and CoreMediaIO property listeners, `DispatchSource` directory watchers,
NSWorkspace notifications, Carbon hot keys, a CGEvent tap for media keys); polled only
where it does not (Caps Lock, Focus, full-screen detection) and never above 2 Hz.

Now Playing has three backends chosen at runtime: a MediaRemote adapter (a small dylib
compiled by `Scripts/build.sh`, hosted out-of-process and spoken to over JSON), the
in-process MediaRemote framework where it still works, and AppleScript for Music and
Spotify as a last resort. `ArtworkFetcher` fills in a cover none of them supplied, by
name, once per track.

Three services are driven by a view being on screen rather than by `ServiceHub`, and count
their viewers: `WindowsMonitor` (the window list, its ScreenCaptureKit thumbnails, and the
Accessibility calls that raise, snap and close a window), `SystemToggles` (Wi-Fi through
CoreWLAN, Bluetooth through IOBluetooth's undeclared power switch, appearance through
System Events) and `BrightnessControl`. Each one costs nothing while the panel is closed.

## Views

`Views/IslandBodyView.swift` picks the idle, compact, card, panel or shelf body, draws the
shape and applies the shared transition. Compact leading / trailing content lives in
`CompactContentView`. The panel is under `Views/Panel/`: `PanelView` stacks the
`SwitcherBand` (activities left of the cutout, sections right of it, a close button when
pinned), one section (`MusicSectionView`, `TodaySectionView`, the rest in `Sections.swift`)
or one activity's card content, and the `ControlRail`; `AlertBanner` draws a transient alert
over an open panel. Every panel view shares one content identity (`IslandPresentation.contentID`),
so stepping between sections moves the section and leaves the band and the rail mounted.
`WindowsSectionView` draws the window switcher over `Services/WindowsMonitor.swift`, which
lists windows from the window server, captures each with ScreenCaptureKit, and raises, snaps
or closes one through Accessibility. The system cards and the section bodies they share live
under `Views/Expanded/`; shared pieces (artwork, progress ring, scrubber, slider, marquee,
visualizer bars, privacy dots) under `Views/Components/`. The island keeps the iPhone's
palette (white values, coloured glyphs, artwork-tinted bars); windows (Settings, Welcome)
follow native macOS conventions in a monochrome palette.

## Integration points

- `Services/LiveActivityAPI.swift` handles the `notchisland://` URL scheme; `Scripts/notchctl`
  wraps it for Shortcuts and shell scripts.
- `App/StatusItemController.swift` is the menu bar extra; `App/Preferences.swift` is the
  single `ObservableObject` behind Settings, persisted in `UserDefaults`.
- `Scripts/build.sh` produces the `.app` bundle (Info.plist, icon, adapter dylib, ad-hoc
  signature); `Scripts/make-dmg.sh` wraps it for release; `.github/workflows` build, test
  and publish.

## Testing

`Tests/MacNotchIslandTests` covers the pure parts: layout maths, shape decisions, alert
ranking and queueing, gesture routing, formatting, parsers (lyrics, weather, media keys,
URL scheme), store logic (shelf, clipboard) and every service's static helpers. Anything
that needs a display, a device or a permission is kept behind a static function so the
decision is testable even when the effect is not.
