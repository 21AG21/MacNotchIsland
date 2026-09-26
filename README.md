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
| Now Playing: artwork on the left, artwork-tinted audio bars on the right; expanded scrubber, title, artist, transport controls | Same, for any app playing through the system player (Music, Spotify, Safari, Podcasts…). Hover or click for the Now Playing section: scrubber, transport, an output picker, time-synced lyrics from LRCLIB. A track that starts peeks into the pill for a moment with its title and artist. Swipe sideways on the pill to skip tracks. Up to two more buttons either side of play, chosen under Media: shuffle, repeat (off, all, one), favourite, and back or forward 15 seconds for podcasts — lit while shuffle or repeat is on, dimmed when the player in front does not offer them. |
| Clock app alarm | Type a time on the Actions section — 7:30, 19:05, 7:30pm — and Return sets an alarm for the next time the clock reads it; type a number instead and it is a timer of that many minutes. An alarm waits in the timer row, the menu bar and the island's menu, survives a relaunch, and rings the way a timer does, with Snooze. `notchctl alarm 07:30 Wake`. It rings only while the Mac is awake: waking a sleeping Mac needs root. |
| Timer countdown in orange, expanded pause / cancel, "timer done" state | Same: 1, 5, 10 and 25 minutes and a Pomodoro in the Actions section, or any number of minutes typed there; eight presets from a minute to an hour in the menu bar; or `notchctl timer 5`. Another minute is one click on the card, a scroll up on the pill, or `notchctl timer add`; a scroll down takes one off. |
| Stopwatch Live Activity (iOS 17) with laps | Same: the Actions section, the menu bar, or `notchisland://stopwatch`. |
| Call: green phone glyph and running duration | Detected from microphone use by FaceTime, Zoom, Teams, Slack, Discord, Webex, Meet, Skype and Loom. The card mutes the microphone for every app at once — the input device itself, not one app's idea of it — and opens Control Centre's Video Effects and Mic Mode; while it is muted the pill's glyph is a red microphone with a line through it. |
| Charging bolt and percentage when you plug in; low-battery alert; "charged" | Same, from IOKit power-source events. Low Power Mode on/off too. |
| AirPods / Bluetooth connect with battery | IOBluetooth connection events: a brief pill with the level as a device connects, the card with left, right and case one click away, read from the IORegistry. |
| Noise Control for AirPods in Control Centre | Off, Transparency, Adaptive and Noise Cancellation as a row of pills on the AirPods card and under the pair's row in Controls (click the row to open it), whichever of them the pair has. Through AVFoundation's private `AVOutputContext` and `AVOutputDevice`, looked up by name; where a macOS does not have them, or keeps the system's audio context from an app without its entitlement, the pills are simply not there. |
| Focus on / off with the Focus symbol | Watches macOS's Focus assertion database — and quietens the island while one is on: alerts that arrive on their own wait, and anything you did yourself still shows. |
| Choosing a Focus in Control Centre | The rail's Focus disc opens a list of this Mac's Focus modes, read from the same database, with the one that is on filled in its colour, and Off. macOS gives apps no way to set a Focus, so a pick runs a shortcut you make once, named “Set Focus”, handed a text file holding the mode's name or “Off”; until it exists the list says so and opens Shortcuts. Right-click the disc for Focus settings. |
| Silent / ring switch, volume | Turn on "Answer the volume and brightness keys" under Activities (event tap, needs Accessibility) and the volume, mute, brightness and keyboard backlight keys are answered in the island instead — a level bar that also names where the sound is going, which the system's bezel never does. There is only ever one display: a key the island cannot answer, or whose display you have switched off, goes straight back to macOS and its own bezel. Scroll on the island to change volume. |
| Privacy indicators inside the island (orange mic, green camera) | Same, from CoreAudio and CoreMediaIO "running somewhere" properties. |
| Face ID unlock animation | "Unlocked" when the Mac unlocks. |
| Live Activities from apps (deliveries, rides, builds…) | `notchisland://` URL scheme and `Scripts/notchctl`, usable from Shortcuts, scripts and CI. |
| Two activities: one in the island, one in the detached bubble; tap to swap | Same, including the bubble swap: the most recently started activity owns the island, a call or a timer that just rang always does, and the shelf waits in the bubble while something plays. Alerts are ranked so a volume tick never hides a low-battery warning. |
| Upcoming calendar event | Optional: next event 10 minutes out with a Join button when a meeting link is found. The Today section lists the rest of today's events and today's open reminders. |
| Long-press to expand, tap to open | Rest the pointer on the island to peek at the panel; click to keep it open, click anywhere else (or press Escape) to close it. What you open stays open across desktops. A global shortcut (⌃⌥Space by default, or ⌃⌥I where macOS uses that to switch input sources) toggles it, the same modifiers with Tab step through every section and with Shift + Tab step back. The island never covers a menu title or status item: it only widens into menu bar space that is free. |
| — | A URL scheme and `notchctl` for scripts: push your own Live Activity with a title, a progress ring and up to two named buttons that open a link, or run a Shortcut once "Let pushed cards run Shortcuts" is on under Settings > Media (it is off out of the box). |
| — | Ask from a script: `notchctl ask "Deploy to production?"` holds the question on the island with two buttons (Yes and No, or names of your own) until you click one or press Control-Y or Control-N, or its time runs out. It prints yes, no or timeout and exits 0, 1 or 2, so `if notchctl ask "Deploy?"; then …` does what it says. |
| — | Tell me when the battery has had enough charge: pick 70, 80, 85 or 90 per cent and the island says so once per charge, which is the thing macOS never does. |
| — | A sleep timer: right-click the island while something is playing and the music stops in fifteen minutes, or an hour, or whenever you say. A real countdown with a card — it just does not ring. |
| — | Controls: the networks in range, the devices you are paired with, and where the sound goes and comes from — three lists, each with its own switch. Join a known network, connect a pair of headphones, move the sound to the AirPods or pick a different microphone, and mute, without opening System Settings. Every connected device carries its charge, the emptier ear first, red under ten per cent. HomePods, Apple TVs and AirPlay speakers get a group of their own, here and in the rail's output menu, where CoreAudio's AirPlay device lists them; the Sound list always ends in the system's own AirPlay picker, for when it does not. |
| — | The panel opens on Home: a grid of tiles, Control Centre style. What is playing takes a wide tile with a play button on it; every other section is a tile with its name and a glimpse of what is inside — the next thing in your day, how many files are on the shelf, the first line of your notes. |
| — | One panel for everything. A switcher beside the notch holds the live activities on the left and the sections on the right: Now Playing, Today (events, reminders, weather), Windows, the shelf (multi-select, AirDrop, share, trash, auto-expiry), clipboard history with pins and search, Actions (your favourite apps and Shortcuts, timers, alarms and the stopwatch), a notes scratchpad, and system stats whose every reading opens the place macOS keeps it — Activity Monitor for the processor and the memory, Storage for the disk, Network for the network, and Battery for the battery on a Mac that has one. Under every section a control rail: the volume, and the brightness where the Mac has one; where the sound is going as soon as there is more than one place it could go; then the controls you have chosen, in your order, with Settings last — out of the box Wi-Fi and Bluetooth where the Mac has them, the Display popover, Keep Awake, the camera mirror, AirDrop for the shelf when there is something to point it at, and the keyboard backlight. Files dropped on the notch also show as their own activity, with a count, until the shelf is empty. |
| — | Windows: the windows on this desktop as live tiles, minimised ones and a hidden app's dimmed after the rest. Click one to bring it forward; the zones on it send it to a half of the screen, fill the screen, centre it or move it to the next display, and the two corner buttons minimise or close it. Pictures need Screen Recording; moving windows, and finding the ones put away, needs Accessibility; without them the windows on screen are still listed by app. |
| — | Command-click several window tiles and tile them together: two side by side, three across, four in quarters, or a grid beyond that. |
| — | Trackpad gestures: swipe sideways on the pill to skip tracks, on the panel to step between sections; scroll for volume, hold Option while scrolling for brightness, and Control for the keyboard backlight. Or have the vertical swipe open and close instead: down on the island opens the panel, up on the panel closes it, once a swipe, with a sensitivity slider for how far a swipe has to go. A scroll on a timer's pill gives it another minute a step, or takes one off; a swipe that opens the panel puts back whatever it moved on the way. A customisable global shortcut. Optional audio-reactive bars driven by a system audio tap. |
| — | The panel answers the keyboard while it is open, with nothing held down: ← and → step between views, 1 to 9 go straight to a view, in Tab's order — the live activities first, then the sections — so a running timer is 1 and anything past the ninth has no digit (on Actions they type a timer instead), Space plays and pauses (on a Shelf with anything on it, Space is Quick Look instead, of what is selected or of the whole shelf, as in Finder), ↑ and ↓ move the volume. Only while it is pinned open, and never while Notes is showing. |
| A–Z | Start typing on Windows, the Clipboard, the Shelf or Notifications and a find opens with that letter in it, narrowing the list as you type. ↑ and ↓ walk the matches, Return takes the one you are on, Escape leaves the find. |
| — | Notifications: the banners that came past while you were not looking, kept as a history the Mac has never had — grouped by app, newest first, with a find and a Clear. Off out of the box; switch it on in Home Panel. It reads the banners with Accessibility, keeps the last 200 for three days in Notch Island's own folder on this Mac, and sends nothing anywhere. |
| — | Motion: every spring in the island from one place, under Settings > Motion. Faithful is the phone's own timing, Calm keeps it and never overshoots, Instant is half the time with no overshoot, or set Duration and Bounce yourself — with an island in the pane opening and closing on the very curves it uses. With Reduce Motion on, the island fades instead. |
| — | Screenshots: the capture you just took, as a card with the picture on it. Drag it straight into a message, copy the picture, copy the words in it (read with Vision, offered only when there are any), open a QR code's link (the host is written under the title), or open the file. |
| Screen recording from Control Centre, a red pill while it runs | Record Screen from the island's right-click menu: Apple's own `screencapture`, a red dot and the time on the pill, Stop on its card, and the finished movie saved where screenshots go and handed back as a capture card. Needs Screen Recording; the island says so, and where to turn it on, if it is off. |
| — | Mute Microphone, Screenshot, Lock Screen and Sleep Display in the island's right-click menu. The lock is the call the menu bar's own Lock Screen makes, looked up by name in a private framework; where that is missing or refuses, Control-Command-Q is typed on whichever key types Q (with Accessibility), and failing both the display is put to sleep. Sleep Display is `pmset displaysleepnow`; Screenshot opens Apple's toolbar. |
| — | Keep the island out of a screen share: out of the box it is left out of screen sharing, recordings and screenshots while a call is live, and a switch under Privacy hides it all the time — the panel can hold what you copied, your notes and your notification history. Sharing built on ScreenCaptureKit may still show it on macOS 15 and later. |
| — | External disks: a card when a drive is plugged in, with its name, how full it is and an Eject button on it — and a word when one is unplugged, whether or not it was ejected first. Right-clicking the island ejects any of them at any time. |
| — | Put the panel's sections in your own order: drag them in Home Panel and the switcher, the swipe, Tab and the digit keys all follow. |
| — | Arrange the control rail the same way: switch any of its controls on or off in Home Panel — Wi-Fi, Bluetooth, Display, Keep Awake, Camera Mirror, AirDrop the Shelf, Focus, Mute Microphone, Lock Screen, Sleep Display, Screenshot, Record Screen and Keyboard Backlight — and drag them into your own order. What does not fit the rail waits in a row at the top of the Controls section, so nothing you switched on is ever simply gone. |
| — | The keyboard backlight, which macOS gives no app a way to set: its keys answered in the island with the same level display as the volume's (with the bezel replaced, on a keyboard that has the keys), a disc on the rail that opens its slider, and Control-scroll on the island. Through CoreBrightness's private keyboard client, the one Control Centre talks to, looked up by name; on a Mac with no backlight, or a macOS that has changed the client, none of it shows and the keys stay macOS's. |
| — | A Display popover behind the rail's sun, laid out like Control Centre's Display module: a brightness slider for every display that takes one — a Studio Display on the desk as well as the Mac's own — then Dark Mode, Night Shift and True Tone. Right-click Night Shift for its warmth and to turn it on until tomorrow. Private DisplayServices and CoreBrightness calls, each looked up by name; a switch this Mac has no call for is not drawn. |
| — | The switcher's slots are spring-loaded: drag a file onto the island, rest it on a slot, and the panel goes there — so a file can reach a quick action or a window tile without being put down first. |
| — | Drop a file on a quick action and the shortcut runs with that file as its input — the Actions row is a rack of droplets. Drop one on a window tile and it opens in that app. |
| — | A shelf that takes anything: files, a picture, a link or selected text dragged onto the notch. Drag the whole selection back out in one go, Quick Look any of it, AirDrop or share it. |
| — | Drop targets: files held over the island split the shelf's well into Shelf, AirDrop and Share, the one under the pointer lit and a tap under the finger as it changes. Let go on AirDrop and they go straight to AirDrop; on Share, the share menu opens from the well — neither stops on the shelf on the way, unless the send cannot happen. |
| — | Clipboard history that pastes: pick an item and it goes straight into whatever you were typing — or drag one out of the panel and into a document, a message or a folder. |
| — | Keep Awake from the control rail or the menu bar: the Mac and its display stay on until you switch it off again. |
| — | Hide the island for an hour from the menu bar, or automatically while a full-screen app is in front. A daily check against GitHub releases tells you when a new version is out. |
| — | Downloads: Safari, Chrome and Firefox downloads in ~/Downloads become Live Activities with progress, then a "Download complete" alert. Caps Lock pill. |
| — | Energy discipline: animations slow on battery and stop in Low Power Mode or sleep; every poller backs off; idle CPU stays near zero. |
| — | Hide the island automatically while chosen apps are in front (Keynote, a game, a screen-sharing client). Screenshots land on the shelf as well as on their card. |
| — | VoiceOver labels: the pill says in one line what it is showing — the track, the time left, the charge — and the panel's buttons, sliders and tiles carry names of their own. Not every corner has been through VoiceOver yet. |
| — | On a Mac without a notch, or on an external display, the island floats at the top centre with the same morphs — just under the top edge when the menu bar hides itself. On a Mac with no notch at all, out of the box it hides in full-screen apps and opens from the bare pill on a click rather than a resting pointer; a MacBook's notch keeps its own defaults with a monitor plugged in. |

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
demo menu (hold Option), and Quit — or right-click the island itself for the short version of the same menu.
Reload Island in the menu bar's menu builds the island again without quitting, with the shelf, the timer
and the clipboard history left as they were, and Copy Diagnostics puts a report on the pasteboard to
send with a bug. Turn on "Open at login" under General in Settings once you're happy with it.
Press ⌃⌥Space anywhere to summon the island — or ⌃⌥I where macOS uses ⌃⌥Space to switch input
sources; Settings shows which — and with it open, the arrows, the digits and Space drive it
without a modifier.

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

Nothing is required up front. macOS asks for each of these when the feature that needs it
first runs, and Bluetooth, the calendar and the Downloads and screenshot folders not before
the welcome tour is done; the tour says which of its choices will ask. Nothing is asked
because the pointer crossed the notch or a section was peeked at. Settings > Privacy lists
every one of them but system audio, with whether it is granted and a way straight to its
pane in System Settings.

- **Bluetooth**: for AirPods and other devices as they connect, with their battery, and for
  the Bluetooth switch and paired list in Controls. On out of the box, so it is asked for as
  soon as the tour is done.
- **Calendars and Reminders**: for Today and the card before a meeting. Today is on out of
  the box, so the calendar is asked for as soon as the tour is done, and reminders the first
  time you open the panel on Home or Today (a peek under a resting pointer does not ask).
- **Files and Folders (Downloads, and the screenshots folder)**: for the download and
  screenshot cards and the shelf. Both are on out of the box, so each folder is asked for as
  soon as the tour is done. The screenshots folder is the Desktop unless you have moved it.
- **Location**: for the weather in Today (off out of the box) and for the names of the
  networks in the Controls section's Wi-Fi list, which macOS keeps from an app until
  Location allows it. The list asks only when you press Allow Location there.
- **Accessibility**: answering the volume and brightness keys, pasting a clipboard item where
  you were typing, moving windows, telling a full-screen app from a zoomed window on the
  display with the notch, keeping clear of app menus, and reading the banners the
  Notifications section keeps.
- **Screen Recording**: the pictures of windows in the Windows section, and Record Screen.
- **Camera**: the mirror on the control rail, the first time it is opened. A Mac with no
  camera has no mirror on the rail, and is never asked.
- **Notifications**: a banner when a timer or an alarm goes off, or an alarm was missed, while
  the island cannot be seen.
- **System audio**: the audio-reactive visualizer, off out of the box, which follows the level
  of what is playing and records nothing.
- **Automation (Music, Spotify, System Events)**: for the players, only if the MediaRemote
  helper can't run. On macOS 15.4 and later Apple stopped delivering system-wide Now Playing
  data to third-party apps, so the build bundles a tiny helper (`Adapter/MediaRemoteAdapter.m`)
  that runs inside `/usr/bin/perl`, an Apple-signed host, and streams Now Playing data to the
  app. If that ever fails, Notch Island falls back to asking Music and Spotify directly with
  AppleScript, which prompts once per app. The same prompt can come the first time you press
  shuffle, repeat or favourite beside play in Music or Spotify, when MediaRemote has not said
  whether the player takes it. Settings > Privacy says which player has allowed or refused it.
  System Events is asked once, the first time you use the Dark Mode switch in the Display
  popover, since that is how the switch changes the appearance.
- **Full Disk Access** (optional): macOS may keep the Focus database from the app without
  it, and then Focus alerts and holding alerts back during a Focus do nothing. Activities
  says so under the Focus switch, with a way to the pane.

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
Scripts/notchctl timer pomodoro --work 50 --rest 10 --cycles 3 --long 20    # left out: 25, 5, 4 and 15
Scripts/notchctl stopwatch                                                   # stopwatch lap | stop | reset
Scripts/notchctl sleep 45                                                    # stop what is playing in 45 minutes; sleep cancel
Scripts/notchctl alarm 07:30 Wake up                                         # or 7:30am, 19:30, 7pm
Scripts/notchctl alarm cancel
Scripts/notchctl shelf add ~/Downloads/report.pdf
Scripts/notchctl home clipboard                                              # open the panel on a section; collapse closes it
Scripts/notchctl settings privacy                                            # open Settings on a pane
Scripts/notchctl ask "Deploy to production?" --yes Deploy --no Wait --timeout 2m   # yes → 0, no → 1, timeout → 2
```

The underlying URLs:

```
notchisland://activity?id=…&title=…&subtitle=…&symbol=…&tint=…&progress=0–1&trailing=…&body=…&url=…&ttl=seconds&expanded=1&ring=1&priority=70
  …&action=Retry&action_url=https://…&action_symbol=arrow.clockwise&action2=Ship&action2_shortcut=Deploy   (buttons, see below)
notchisland://activity/end?id=…
notchisland://alert?title=…&symbol=…&tint=…&duration=3&expanded=1   (duration in seconds, up to 60 s; longer is cut to 60)
notchisland://timer?minutes=5&label=Tea    notchisland://timer/cancel | pause | resume
notchisland://timer?seconds=90             (with minutes= as well, the two are added up)
notchisland://timer/add?minutes=1          (or seconds=; a length below nought takes time off)
notchisland://timer/pomodoro?work=25&rest=5&cycles=4&long=15   (minutes; these are what is left out)
notchisland://sleep?minutes=30             notchisland://sleep/cancel   (stops what is playing; 30 unless told)
notchisland://alarm?at=07:30&label=Wake    notchisland://alarm/cancel[?at=07:30 | ?id=…]
notchisland://stopwatch                    notchisland://stopwatch/lap | stop | reset
notchisland://shelf/add?path=…             notchisland://shelf/clear
notchisland://ask?title=…&detail=…&yes=Yes&no=No&timeout=5–600&reply=/tmp/…/answer&token=…   (the answer is written to reply)
notchisland://ask/cancel?token=…           (takes that question down unanswered)
notchisland://home[/music|today|windows|shelf|controls|clipboard|actions|notes|stats|notifications] | collapse | settings[/pane]
```

A card has room for two buttons. `action` names the first, and it opens `action_url` (an
`http`, `https` or `mailto` link) or runs the Shortcut `action_shortcut` names, with
`action_symbol` as its SF Symbol; `action2`, `action2_url`, `action2_shortcut` and
`action2_symbol` are the second. `alert` takes them too. A button with no name, or nothing to
do, is left off. A Shortcut runs only while "Let pushed cards run Shortcuts" is on under
Settings > Media, which it is not out of the box: anything on this Mac can push a card, and a
Shortcut can run a shell script. With it off, a button that would only run a Shortcut is left
off the card.

`token` on `ask` is a secret of the script's own, 16 to 128 letters, digits and hyphens;
`ask/cancel` with the same token takes the question down unanswered, which is what `notchctl ask`
does when it is interrupted. A question put up without one cannot be taken down that way.

`reply` has to be a file the island may create: an absolute path (so no `~`) with no `.` or
`..` in it, to a file that is not there yet (the island never writes over one), in a folder of
your own that only you can open (mode 0700, which is what `mktemp -d` makes), inside `/tmp` or
`$TMPDIR`, never in your home folder. The folder's links are followed before it is checked,
and a file directly in `/tmp` or `$TMPDIR`, rather than in a folder of your own there, is
refused. A refused `reply` means no question goes up at all; the refusal is only logged
(`log stream --predicate 'subsystem == "com.macnotchisland.app"'`). Make the folder with
`mktemp -d /tmp/ask.XXXXXX`, as `notchctl ask` does. `Scripts/notchctl --help` lists every exit
status, including 64 for bad usage and 69 when Notch Island could not be reached.

`tint` accepts the iOS system colour names (red, orange, yellow, green, mint, teal, cyan,
blue, indigo, purple, pink, brown, gray, white) or a hex value. `symbol` is any SF Symbol.
Lengths are numbers in the unit the field is counted in — minutes for `minutes`, `work`, `rest`
and `long`; seconds for `seconds`, `ttl`, `duration` and `timeout` — or numbers with a unit of
their own: `45m`, `90s`, `1.5h`.

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

- macOS shows its own volume / brightness bezel unless "Answer the volume and brightness
  keys" is on under Activities, which needs Accessibility access for the key tap.
- The island stays above full-screen apps and on every Space. On a Mac without a notch (or
  an external display with "Show on all displays" on) a simulated island is drawn at the
  top centre.
