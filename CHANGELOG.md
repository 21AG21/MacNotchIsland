# Changelog

All notable changes to Notch Island. Versions follow the app's `CFBundleShortVersionString`;
the unreleased section is what the next tag will ship.

## Unreleased

### Added
- Several timers at once, stacked in the expanded view with the soonest-to-finish owning the
  island, and a Pomodoro mode (focus, break, long break every fourth session) from the Home
  panel, the menu bar and `notchisland://timer/pomodoro`.
- Battery panel shows time remaining or time to full, charge or discharge wattage, cycle
  count and health, read from IOKit when the alert appears.
- Hide the island automatically while chosen apps are in front; the list lives in Settings.
- Screenshots land on the shelf with a brief thumbnail alert.
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
