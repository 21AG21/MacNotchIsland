# Changelog

All notable changes to Notch Island. Versions follow the app's `CFBundleShortVersionString`;
the unreleased section is what the next tag will ship.

## Unreleased

### Fixed
- An open panel no longer closes on its own: switching desktops (a three-finger swipe) kept
  collapsing it, an alert that had been clicked open closed itself when the alert timed out,
  and a momentary empty report from the music player ended the Now Playing card (and the
  expanded view with it) between tracks. What the user opens now stays until a click
  elsewhere, Escape or the shortcut.
- A click on an open panel no longer closes it; only its controls react, as in a popover.
- An alert that arrives while the panel is open (a finished download, a paired device, a
  volume key, a battery warning) is a banner in the panel's control rail for a moment
  instead of yanking the panel away. A louder alert replacing a quieter one hands back to
  it when it expires, so nothing is missed.
- Clicking a volume or brightness HUD no longer opens a card.
- Launching the app while an older copy is still running quits the old copy, instead of
  drawing two islands on the same notch.
- A full-screen app hiding the menu bar no longer rebuilds the island windows.
- The reasons a panel opens or closes are written to the unified log under
  `com.macnotchisland.app`, so a report from another Mac can be diagnosed.
- A track reporting an infinite duration or an unmeasured position (a live stream, a radio
  station) no longer crashes the app the moment the Now Playing card opens; such times read
  as zero.
- The island's window changes size without forcing a synchronous layout of its content, and
  refuses a frame that lost touch with the screen.
- The click-outside check no longer runs a view hit test from the event monitor; it checks
  the island's footprint arithmetically.

### Changed
- One panel for everything. The expanded views, the Home drawer and its tab bar are gone;
  in their place is a single 680 pt panel with a switcher in the band beside the notch (live
  activities on the left, sections on the right), one section or one activity under it, and
  a control rail at the bottom with volume and brightness sliders, Keep Awake, the camera
  mirror, AirDrop for the shelf, and Settings. Stepping between views never resizes the island.
- Peek and pin. Resting the pointer on the island opens the panel on what is playing or
  running; it closes when the pointer leaves. A click pins it until a click elsewhere,
  Escape or the shortcut. The shortcut's modifiers with Tab (and Shift + Tab) or with the
  arrow keys, a sideways swipe on the panel, or the switcher step through the same list
  everywhere.
- The compact pill reads like the iPhone's: a coloured glyph in a 34 pt slot on the left, a
  white value on the right (red only for a battery warning), thinner bars blended toward
  white, a 4 pt HUD bar. A key-press HUD over a live activity keeps that activity's glyph.
- Alerts that used to open a card stay compact: AirPods connecting, low and critical battery,
  unlock. The full card is one click away. Cards that the system does put up (a finished
  timer, a call) are 440 pt wide, one or two rows, with no switcher.
- No haptic for a click, ever: the trackpad has already clicked under the finger. Haptics
  remain for alerts, a ringing timer, drag targeting and swipes.

### Added
- Sections: Today (the next 24 hours of events, today's reminders with a checkbox, the
  weather in the header), Notes (a scratchpad kept on disk), and Stats beside the shelf,
  clipboard and actions. Now Playing is a section too, so it is reachable while anything
  else is live. The list is one enum, `HomeSection`, read by the switcher, the keyboard
  ring, the swipes, the URL scheme (`notchisland://home/notes`) and Settings.
- Sneak peek: a track that starts widens the pill for a moment with its title and artist.
- Output picker under Now Playing, backed by CoreAudio: the devices that can play, the one
  that is, and a live volume slider that follows it.
- Keep Awake, in the control rail and the menu bar: a power assertion that holds the Mac
  and its display awake until switched off, and ends with the app.
- A first-run picker after the welcome page chooses which sections the panel shows and
  whether the island replaces the system bezel.
- The island shrinks slightly while pressed.
- The shelf is a live activity while it holds files: a tray glyph and a count in the island,
  its strip on click, the bubble while something else is live.
- The compact island keeps clear of menu bar text: it only widens into space that is free
  beside the notch, measured from the status items and, with Accessibility granted, the
  frontmost app's menus.
- Several timers at once, stacked in the expanded view with the soonest-to-finish owning the
  island, and a Pomodoro mode (focus, break, long break every fourth session) from the Home
  panel, the menu bar and `notchisland://timer/pomodoro`.
- Battery panel shows time remaining or time to full, charge or discharge wattage, cycle
  count and health, read from IOKit when the alert appears.
- Hide the island automatically while chosen apps are in front; the list lives in Settings.
- Screenshots land on the shelf with a brief thumbnail alert.
- Copy Diagnostics (menu bar) includes the newest crash reports macOS wrote for the app, the
  errors and faults logged around it, and whether the previous run quit on request (and by
  whom) or simply vanished. A `kill` counts as a request.
- A Settings window laid out like System Settings: sidebar of panes, grouped forms,
  standard controls, sentence-case labels and footers.
- A Welcome window in Apple's onboarding pattern with the live shortcut in it.
- A menu bar extra that behaves like Apple's: a state header, items validated against live
  state, an Option-key alternate for the demo menu, a standard About panel.
- VoiceOver labels for every island state, Home tab, shelf item and control.
- A floating island on Macs without a notch and on external displays.
- Audio-reactive Now Playing bars driven by a Core Audio process tap.
- Weather tab (CoreLocation and Open-Meteo), Stats tab, camera Mirror tab.
- Customizable global shortcut with a native recorder.
- Trackpad gestures: swipe to skip tracks or switch tabs, scroll for volume.
- Daily update check against GitHub releases.
- `ARCHITECTURE.md`.

### Fixed
- Compact content could sit under the physical notch: the island's body was centred on the
  screen although its trailing slot is wider than its leading one, which pushed the notch
  gap sideways by up to 22 pt (the volume bar, "Unlocked"). The gap now stays on the notch,
  glyphs sit toward the open end of their slot, and a width or height override can only
  enlarge the island.
- The panel was a fixed 760 by 340 point canvas that swallowed clicks around the notch; it
  now hugs the island, so menu bar items and windows beside the notch stay clickable, and
  it is cut asymmetrically so the bubble never leaves an invisible strip left of the notch.
- Play/pause flipped twice while MediaRemote caught up; the user's state now wins for 1.2 s.
- Live activities are ordered like the iPhone's: newest kind first, a call or a ringing
  timer always first, the shelf last.
- Building with the Command Line Tools alone failed on current SDKs because SwiftUI's `@State`
  macro plugin ships only inside Xcode. The build script now uses an installed Xcode
  automatically and explains the fix when none is present.

### Changed
- Compact content morphs into its expanded counterpart through a shared matched-geometry
  namespace; the shape picks its capsule or rounded bottom from the target layout so it never
  flips mid-animation.
- Island and app icon are drawn with Apple-style continuous corners.
- Timer ticker stays at 1 Hz so countdowns ring on time regardless of power state.

### Fixed
- Battery temperature was read as hundredths of a kelvin; Apple silicon reports hundredths
  of a degree Celsius.
- Suppression (full screen, hidden app, pause) clears hover and drag state so the island
  never reappears expanded.
- Camera preview teardown race, AppleScript watchdog race, MediaRemote health latch, adapter
  artwork race, hot key double registration while recording, weather delegate callbacks
  after stop, audio tap rebuild on output device change.

## 1.0.0

- First release: Now Playing with artwork-tinted bars, scrubber and lyrics; timer and
  stopwatch; calls; battery, Low Power Mode, Bluetooth and AirPods; Focus; silent, volume and
  brightness HUDs with optional bezel replacement; privacy indicators; unlock; calendar;
  downloads; Caps Lock; file shelf with AirDrop, share and expiry; clipboard history; quick
  actions that run Shortcuts; the `notchisland://` URL scheme and `notchctl`; the detached
  bubble for a second activity; hover, click, drag and haptics; energy policy that keeps idle
  CPU near zero; menu bar extra; DMG packaging and a tag-triggered release workflow.
