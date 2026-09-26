# Changelog

All notable changes to Notch Island. Versions follow the app's `CFBundleShortVersionString`;
the unreleased section is what the next tag will ship.

## Unreleased

### Added
- **Pick a Focus from the rail.** The Focus disc opens a list of this Mac's Focus modes, read from the same database the island already watches, with the one that is on filled in its own colour, and Off. macOS gives no app a way to set a Focus, so a pick runs a shortcut you make once, named “Set Focus”, handed a text file with the mode's name or “Off”. Until it exists the list still says which Focus is on, and a line under it says how to make it, with a button to Shortcuts. Right-click the disc for Focus settings. Focus alerts wear the Focus's colour: the database names colours the UIKit way, and every one used to be drawn white.
- **Ask from a script.** `notchctl ask "Deploy to production?" [--yes Deploy] [--no Wait] [--timeout 60]` holds the question on the island until a click or Control-Y / Control-N, or until its time is up. It prints yes, no or timeout and exits 0, 1 or 2, so `if notchctl ask …; then` means what it says. Everything but a flat battery waits behind the card. A second question answers the first "timeout". The answer file must be new and in your home or /tmp, and only the card's own buttons and the keys can answer. `notchisland://ask?title=…&reply=…`.
- **Buttons beside play.** The transport was back, play and forward, which is all Music needs
  and not what a podcast needs. Settings > Media now has four places, two either side of the
  three, each holding nothing, shuffle, repeat, favourite, back 15 s or forward 15 s. They are
  empty out of the box, so the row nobody asked to change does not change; somebody who
  listens to podcasts will want the fifteen-second pair, somebody who listens to albums
  shuffle and repeat. They are drawn at the transport's size and weight on its 72-point
  pitch, blank places balance the shorter side so play stays in the middle, and choosing a
  button that is already in the row moves it rather than drawing it twice. Shuffle and repeat
  light up in the cover's colour with a dot under them while they are on, and repeat wears its
  1 for a single track; the heart fills once pressed. A button the player in front does not
  honour is drawn at a quarter strength and takes no click. Which buttons a player honours is
  worked out from whatever evidence there is: the list of supported commands MediaRemote gives
  the helper (asked for on its own time, so a list that never comes never holds up a
  payload), a shuffle or repeat mode the player reports, or AppleScript being able to do it —
  Music and Spotify for shuffle and repeat, Music alone for the favourite, since Spotify's
  dictionary has no way to save a track. The skips are a seek from where the playhead is,
  the same seek the scrubber makes, so anything with a length takes them and a live stream
  does not. The helper's protocol grew `shuffle`, `repeat` and `like` (setting the mode
  outright with `MRMediaRemoteSetShuffleMode` / `SetRepeatMode` where MediaRemote still
  exports them, advancing it a step otherwise) and a `supportedCommands` key in its payload;
  either side ignores what it does not know, so an older helper and a newer app still talk.
  Where MediaRemote has nothing to say about a button, Music and Spotify are asked with
  AppleScript, which macOS asks you to allow once for each.
- **Type a timer, or an alarm.** Start typing a number on the Actions section and a field opens
  with it, the way a letter opens a find on a list: Return starts a timer for that many
  minutes; a time on the clock — 7:30, 19:05, 7.30, 7:30pm, 7am, 12am for midnight — sets an
  alarm for the next time the clock reads it; Escape leaves. The field says what Return would
  do before it is pressed, so "7:30" can never become a seven-and-a-half-hour timer by
  surprise. On Actions the digits start the field instead of stepping the switcher; Tab and
  the arrows still step. Alarms are new: they wait in a list rather than on the island, where
  a countdown to seven in the morning would sit over the music all night, and they are shown
  in the timer row, the menu bar and the island's right-click menu, each with a way to take it
  back. They are written down and come back after a relaunch — timers never were, and are
  not, since a countdown's moment has passed by the time the app is back. When its time comes
  an alarm rings the way a timer does — the sound, its card taking the island, a banner if the
  island cannot be seen — with the time it rang for in place of a countdown and Snooze, nine
  minutes, in place of Repeat. One that came due while the Mac slept or the app was not
  running still rings if it is only a few minutes late and is reported as missed otherwise.
  The card that says an alarm is set also says what it cannot do: it rings only while the Mac
  is awake, because waking a sleeping Mac at a time of its own choosing is a power-management
  schedule, and that needs root. Scripts get `notchisland://alarm?at=07:30&label=…` and
  `notchctl alarm 07:30 [label]`, read with the same rule as the field.
- **A minute less, as well as a minute more.** A running or paused timer can now be shortened
  a minute at a time as well as lengthened — `notchisland://timer/add?minutes=-1` takes one
  off, where it used to be ignored. It is never shortened past the point of ringing:
  taking off more than is left leaves one second, and a timer at its last second, or one that
  has already rung, is left as it is.
- **AirPlay speakers, in the output picker and the Sound list.** Control Centre's Sound module
  lists the HomePod in the kitchen and the Apple TV under the television; the island listed only
  what CoreAudio calls a device, and on a Mac that is none of them. Both lists now have an AirPlay
  group, read the way the Sound pane used to read them: the data sources of the AirPlay device
  (`kAudioDevicePropertyDataSources` on the output side), each named through
  `kAudioDevicePropertyDataSourceNameForIDCFString`, and picking one makes the AirPlay device the
  output and then sets `kAudioDevicePropertyDataSource`. All public CoreAudio — but what the
  AirPlay device does with these properties on a current macOS is written down nowhere, so what
  is shown goes through one rule that a test holds: a source with no name, or named after the
  device itself, is not a receiver, a receiver listed twice is one row, and a tick means the sound
  is actually there. Every refusal is logged under `audio`. The list follows the device list and
  the AirPlay device's own changes as they happen. And because it may well come back empty, the
  Sound list always ends in "AirPlay…", AVKit's own `AVRoutePickerView` — the system's route
  picker, one click away whatever CoreAudio says. The rail keeps its width: the group is inside
  the menu the output disc already opens.
- **Noise Control for AirPods.** Off, Transparency, Adaptive and Noise Cancellation — whichever
  of them the pair has, in Control Centre's order — as a row of pills on the AirPods card under the
  readings, and under the pair's row in Controls, which now opens on a click rather than
  disconnecting (the disconnect moves to the end of the pills). None of it is public API: it is
  AVFoundation's private `AVOutputContext` (`sharedSystemAudioContext`, `outputDevices`) and
  `AVOutputDevice` (`availableBluetoothListeningModes`, `currentBluetoothListeningMode`,
  `setCurrentBluetoothListeningMode:error:`), the calls NoiseBuddy first used. Every class is found
  by name and every method is asked for, and has its return type checked, before it is called;
  anything missing and the pills are not drawn. AVFoundation also checks, in the app's own process,
  for an entitlement to the system's audio context that an ad-hoc signed app does not hold, and the
  island does not try to get round that check — so on a Mac where it refuses, nothing shows. The
  route is read every two seconds, slower on battery, and only while a card or the Controls section
  is on screen. Conversation Awareness and Spatial Audio are not here: neither is a property of
  the same device object.
- **Swipe down to open, up to close.** A new choice in the Island pane, "Vertical swipe on the
  island": Volume, which is what two fingers up and down have always done there, or Open and
  close. With the second, a swipe down on the island — bare, a pill, a card, or a panel only
  under the pointer — opens the panel on what a click there would open, on that display's
  island; a swipe up on the panel closes it. Once a swipe, however far the fingers go on, and
  never on inertia, with the same cooldown a track skip has. A sensitivity slider, shown only
  while it means something, sets how far a swipe has to travel, from half as far to twice.
  Sideways swipes keep their meaning, Option and Control still move the brightness and the
  keyboard's backlight, and a section that scrolls by itself keeps its scroll. It ships on
  Volume: nobody's scroll changes meaning under them.
- **Drop targets.** Holding files over the island used to leave one place to put them — the
  shelf — and sending them anywhere was a second trip. Now the shelf's well splits into three
  side by side as the drag arrives, Shelf, AirDrop and Share, with the one under the pointer lit
  and a tap under the finger each time that changes. Shelf does what it always did. AirDrop sends
  them straight there, the way the shelf's own AirDrop does, and does not park them on the shelf
  on the way; Share opens the share menu from the well and keeps the panel on the shelf while
  it is up. Should either send be impossible — AirDrop switched off, nothing on screen to show
  the menu from — the files go on the shelf instead, so nothing dropped is ever lost. Only a
  drag carrying files splits the well: a picture or a line of text has only the shelf to go to,
  and the well at rest is as it was.
- **Scroll a timer for another minute.** A scroll up on a running timer's pill adds a minute for
  every step, with a tap for each, and the digits roll to the new time the way they already
  did. With Open and close chosen, a small scroll still nudges and a swipe long enough opens the
  panel, decided by how far the gesture has gone. There is no minute off yet: the timer has no
  way to shorten itself, and a scroll down on the pill asks it for one it cannot give.
- **The island remembers what came past.** A notification history, in the panel: what arrived,
  from which app, when, still there an hour later, grouped by app and searchable by typing.
  The Mac has never had one — a banner you did not look up in time is gone, and Notification
  Centre only holds what each app chose to leave behind. **It ships switched off.** Everything
  else in this app watches the Mac; this one writes down what somebody's messages said, to a
  file on their disk, and that is not the app's to assume anybody wants. Nothing runs until it
  is turned on — no watcher, no reading of another process's window tree, no file — and
  Settings says plainly what is kept and gives you a button to erase it. It reads the
  Notification Centre process's accessibility tree, which is private system UI and will one day
  change shape; a banner it cannot read the words of still becomes a row with the app and the
  moment on it, because that failure was designed for rather than hoped against.
- **Mute the microphone for every app, from the call card.** Control Centre's Mic Mode chooses
  how the microphone sounds and never whether it is on, and every call app has a mute of its
  own that covers only itself — not the browser tab that also has the microphone, not the
  dictation nobody meant to leave running. The call card now mutes the input device itself,
  with CoreAudio's own mute, which is public API; a microphone that has no mute is turned down to
  nothing instead and put back where it was. It follows the system rather than remembering a
  click, so unmuting in the call app shows on the island at once, and a pair of AirPods that
  take over halfway through a call arrive muted if the island had muted the microphone before
  them. While it is muted the call pill's handset becomes a red microphone with a line through
  it, which is the one thing a glance at a call most needs to catch, and VoiceOver says it too.
  The same card opens Control Centre's Video Effects and Mic Mode panels (AVFoundation's
  `showSystemUserInterface`, public since macOS 12), which the menu bar otherwise hides until
  an app is using the camera or the microphone. It is in the island's right-click menu as well.
  There is no global shortcut for it yet: the shortcut service has one recordable combination,
  and a second needs a recorder of its own.
- **Record the screen from the island.** Record Screen in the island's right-click menu runs
  Apple's own `screencapture -v`, so the movie is the one macOS would have made, named the way
  macOS names it and saved wherever screenshots go. The pill shows a red dot and the time
  running; its card has Stop, which is the Control-C the tool asks for, and then the finished
  movie gets the capture card a screenshot gets. Without Screen Recording permission the island
  says so, with a button to the right pane of System Settings, rather than recording the desktop
  picture and nothing on it. Quitting the app stops the recording first, and a recorder that
  will not stop when asked is asked less politely: nothing is ever left running.
- **Lock Screen, Sleep Display and Screenshot, from the island's menu.** Three things the Mac
  does in one keystroke that hardly anybody remembers the keystroke for. The lock is the
  Control-Command-Q every Mac answers, posted as a keystroke, which needs Accessibility; without
  it, `SACLockScreenImmediate` from the private login framework, which is what the menu bar's
  own Lock Screen calls, looked up by name and walked past if a macOS has moved it — and failing
  both, the display is put to sleep, which locks every Mac that asks for a password at once.
  Sleep Display is `pmset displaysleepnow`, which any user may run; the Mac stays awake behind
  it. Screenshot opens Apple's own toolbar, with the island out of the way first.
- **The keyboard's backlight, in the island.** macOS gives no app a way to set it, which is why
  the island used to leave its keys alone and why a MacBook with no backlight keys on its
  keyboard sends you to Control Centre for it. It now has three ways in: the backlight keys are
  answered in the island with the same level display the volume gets, on the same sixteen steps
  with Shift-Option's quarter steps, whenever the bezel is replaced; a disc on the rail opens its
  slider and an Automatic switch, with automatic adjustment one right-click away as well; and
  Control-scroll on the island sets it the way Option-scroll sets the display. A "Keyboard
  backlight" switch under Activities sits beside Brightness and does the same two jobs. It goes
  through `KeyboardBrightnessClient`, the private CoreBrightness class Control Centre itself
  talks to — opened by path, found by name, every method asked for before it is called — so a
  Mac with no backlight, or a macOS that has changed the class, shows none of it and hands the
  keys straight back to macOS.
- **A Display popover, behind the rail's sun.** The sun used to switch between light and dark
  and nothing else. It now opens what Control Centre's Display module holds: a brightness slider
  for every display that takes one — the Studio Display on the desk as well as the Mac's own
  panel — then Dark Mode, Night Shift and True Tone as round switches. Right-click Night Shift
  for its warmth and to turn it on until tomorrow. None of it is public API: each display's
  brightness is DisplayServices', the call the brightness display already relied on (the built-in
  panel is still driven by the one service that owns it, never twice); Night Shift and True Tone
  are CoreBrightness's `CBBlueLightClient` and `CBTrueToneClient`. Each is looked up by name, a
  display that refuses the call gets no slider, and a switch this Mac has no call for is not
  drawn. It reads the displays only while it is open, every two seconds, slower on battery.
- **Arrange the control rail.** The rail was a fixed row, and every new thing somebody wanted
  within one click of the notch — lock the screen, mute the microphone, start a recording —
  had nowhere to go without pushing something else off. It is now a catalog, arranged in Home
  Panel the way the sections are: a switch on every control, drag to reorder, and a button to
  put it back as it ships. The seven buttons the rail always had are on out of the box, joined
  by the keyboard's backlight where there is one; Focus, microphone mute, Lock Screen,
  Sleep Display, Screenshot and screen recording wait to be asked for, so an update does not
  crowd a rail somebody has already learned. Settings has no switch and is always last. What
  does not fit waits in a row at the top of the Controls section, in the same order and the
  same discs, so a control that is switched on is never simply gone; the camera mirror's own
  button stays on the rail while the mirror is covering that section. A stored order that
  names a control this version does not have, or leaves out one it does, is made sound the way
  the sections' is.

### Changed
- **The island wakes about a quarter as often at idle.** The Now Playing tick is off while the helper answers, its watchdog looks every six seconds instead of two, Caps Lock is event-driven with Accessibility granted, the menu poll slows once a menu is found, the rail's switches and the media-key checks follow the energy policy, and capabilities are re-probed when the output or the displays change rather than every five seconds.
- **A locked, dark, screen-saver or switched-away Mac counts as unattended**: pollers slow eight times and animation stops, as they do in sleep, and everything comes back on unlock, wake or return.
- **Timers ring on the second** instead of up to 1.15 s late, with no wakeups while one runs.
- **Lyrics and the system audio tap run only while something on screen shows them**, and a paused title no longer scrolls.
- **Launch draws the island before starting its services**, which used to walk the cameras, the audio devices, the Downloads folder and the helper before the first frame.
- **Windows retakes only the pictures that changed**, and Focus reads its database once per burst of changes.
- **The clipboard history lasts until Notch Island quits, unless you keep it.** It is still on
  out of the box, with the same limit and pins; what changed is that it is held in memory. A new
  switch under Home Panel, "Keep history across relaunches", writes it to disk for anybody who
  wants it back after a restart, and turning it off erases what was written. See Security for
  why.
- **The weather no longer asks for the wind.** It was requested, decoded and cached with every
  reading, and shown nowhere. What is not drawn is not fetched.
- **The front door widens rather than leave a section off it.** The grid held eight tiles, and
  switching everything on now makes nine. That mattered more than it looks: the band beside the
  notch cannot hold every section at a size anybody can hit either, so a section with no tile
  *and* no slot is a section nobody would ever find. It goes to six columns when it has to —
  narrower tiles are a smaller price than an invisible one.
- **The switcher's slots are big enough to hit.** With every section switched on they came out
  at 21 pt — a couple of millimetres apiece, seven under Apple's floor for a control a pointer
  drives, in the menu bar, which is the least forgiving strip on the screen: the hand arrives
  at speed and the top of the display is right there to overshoot into. The row now keeps every
  target at 28 pt and drops a slot from the end rather than shrinking past it, because a
  section one step away on the ring beats ten you have to aim at twice. What is drawn can be
  smaller than what takes the click.
- **Lists say when there is more to see.** Every scrolling strip in the panel hid its scroller,
  so the Wi-Fi column showed four of the twenty networks in range and nothing said the other
  sixteen were there. The Mac's own scrollers are overlay ones that arrive under the hand and
  fade when it stops, so a strip with nothing hidden is no different for having them — and one
  with something hidden finally says so.

### Security
- **The island keeps out of a screen share while you are on a call.** The panel can be open on
  what you copied, your notes or your notification history, and a call is exactly when somebody
  else is looking at your screen. Out of the box the island's windows are now left out of screen
  sharing, recordings and screenshots for as long as a call is live, and a switch under Privacy
  hides them all the time. It is the window's own sharing type, which a share built on the
  older capture APIs honours; screen sharing built on ScreenCaptureKit may show it anyway on
  macOS 15 and later, and the pane says so rather than promising what it cannot keep.
- **What you copy is no longer written to disk unless you ask.** The clipboard history ships
  switched on, and it was saved to a file after every copy — every password, address and
  message that a password manager had not marked, kept across relaunches by default, in a file
  that outlived the moment it was copied for. That is not the app's to assume. The history is
  held in memory now and goes when the app quits; "Keep history across relaunches" writes it
  down for anybody who wants that, and turning it off erases the file. So does the first launch
  of this build, for the history an earlier one left behind.
- **A card pushed in from outside can no longer run a Shortcut unless you have said it may.**
  The rule for a pushed card's link was written carefully — web schemes only, because "a button
  that opened `file:` or another app's scheme would be a way to make somebody click on something
  they were never shown" — and then the field immediately beside it handed a name straight to
  `shortcuts run`, which is a shell script by another name. Anything on this Mac can push a
  card, and a card is drawn in the island's own hand, so its button reads as the island asking:
  "Update available / Install" is a sentence anybody would click. The reasoning was right; it
  just was not applied to the more dangerous half. Now it is, behind a switch that ships off.
- **A release page that is not a web page is not a release.** The update check took the link out
  of the response and opened it on a click without ever looking at its scheme, while the app's
  own rule for a link it did not write sat two files away. Both the release page and the
  download are held to it now.

### Added
- **A Motion pane, with a live island in it.** A real island, drawn with the app's own shape,
  opening and closing on a loop in the Settings window while you drag duration and bounce — the
  actual curves, read live, so a change is on the next cycle. Three presets: Faithful, which is
  the phone's own timing and what ships; Calm, with no bounce at all, which is the thing users
  of every competing app keep asking for; and Instant. The defaults reproduce the previous motion
  exactly, so nothing changes unless a slider is moved. No other notch app lets you watch the
  curve while you set it.
- **Reload Island, in the menu bar.** The most-repeated complaint about every app in this
  category is the island freezing or vanishing after sleep, with a force-quit as the only cure.
  The island now checks itself on wake, on the screens waking and on the session coming back,
  and rebuilds only when a display has actually changed or a panel has actually gone — never
  blindly, because an unneeded rebuild is a flicker. And there is a menu item for the case
  nobody predicted.
- **Now Playing says where its answer comes from.** The Media pane shows each of the three
  sources — the MediaRemote helper, MediaRemote itself, and AppleScript — with a plain status:
  live, answering with nothing playing, standing by, or not available on this Mac, and a
  Restart Helper button. This app is the only one in its category with a real answer to media
  detection breaking on a macOS point release, and until now it got no credit for it.

### Changed
- **No colour wash behind the Now Playing row.** The cover used to be blurred out into the
  black behind the section and masked off towards the bottom, the way the phone tints its card.
  On the island it read as a smear beside the artwork rather than as a colour. The island is
  black; the cover is the only colour in it, and it is enough.
- **Alerts stay for about the time the slider says.** The alert-duration preference was only the
  fallback for an alert that named no duration, and nearly every alert named one: the slider
  governed the Focus banner and almost nothing else. It is a scale now — the seconds are an
  ordinary alert's, and everything else stretches or shortens in step — and the pane says so.

### Fixed
- The weather follows the Temperature setting in System Settings and the region's own habit, so Puerto Rico reads Fahrenheit and Liberia Celsius, whatever the measurement system.
- The hour strip writes hours the way the Mac's region does ("17", "5 pm", "17 h"), in the forecast's own zone, VoiceOver reads them as times, and the strip no longer loses the hour that spring skips or shows the autumn hour twice.
- Times in Today, the calendar card, the alarms and the menu bar follow a change to the 24-hour clock, region or time zone without a relaunch.
- Today reads the whole of the 25-hour autumn day, an all-day event tomorrow reads "Tomorrow: Bank Holiday, all day", and a meeting's countdown says "Now" when it starts rather than up to 30 seconds later.
- A missed alarm says which day it was missed ("yesterday", or the date).
- `notchctl alarm 7:30 pm` sets half past seven in the evening instead of a morning alarm named "pm", and a time or a `--progress` the app would refuse is bad usage (exit 64) instead of a silent success.
- Text dropped on the shelf with a long Korean, Hindi or Tamil first line is no longer lost to the 255-byte file-name limit, and a drop's time stamp is always written in Western digits.
- Music and Spotify track length and position read correctly in regions that write "٫" as the decimal separator.
- Screenshots named with Arabic, Persian or other native digits, or under a custom `com.apple.screencapture name`, are picked up.
- Today no longer works out the day again for every row and hour on each redraw.
- The Music section no longer asks LaunchServices and the disk for the player's name on every redraw; the name is looked up once per player, and the section is no longer redrawn on every step of a volume drag on the rail or for things the island's centre publishes that it never shows.
- The Home grid no longer redraws every tile when the pointer crosses from one tile to the next or when a Now Playing report arrives, and the Notes tile reads only as far as the scratchpad's first line.
- The call card looks up its app's icon once, instead of on the first frame of its spring and again at every microphone mute change.
- A new track's album art is no longer decoded on the main thread just before the track-change animation: covers from MediaRemote, the helper and the artwork search are decoded off the main thread at no more than 240 pixels on the long side, with their accent colour worked out there, and reports still arrive in order.
- Typing to find in a list works with any letter the keyboard types, not only the 26 American letter keys: the French M, German Ö Ä Ü ß, Scandinavian Å Æ Ø, Spanish Ñ, Russian and Turkish letters now start a find, and the é è ç à on a French number row, or the Czech letters there, start a find instead of jumping the switcher.
- On Actions, a timer can be typed with Shift and the number row on a French or Czech keyboard, and with the numeric keypad; number-row keys typed without Shift are read as the figures printed on them.
- Shortcuts are shown by what their key types on the current layout: ⌃⌥Z on a German keyboard no longer reads ⌃⌥Y, ⌃⌥A on a French one no longer reads ⌃⌥Q, and the ISO § key has a name instead of "Key 0x0A".
- Where macOS uses ⌃⌥Space, the fallback shortcut is the key that types I, so a Dvorak or Colemak Mac gets the ⌃⌥I the tour and Settings name.
- With Pinyin, Japanese or Korean input on, typing opens the find empty and ready for the input method, instead of starting it with a stray Latin letter.
- The timer field accepts full-width and Arabic figures, and times written as 19h30 or 7h.
- Reopening the welcome tour no longer keeps the previous copy of its content alive.
- The Stats row, the battery card's watts, Settings' seconds and Motion figures, and the stopwatch's tenths use your region's decimal mark ("38,5 GB", "+34,2 W", "0,35 s", "01:05,3"), matching the network figures beside them.
- Settings writes percentages as "150%", like the rest of the app.
- VoiceOver hears ages and countdowns in words: "4 minutes ago" for clipboard, notification and shelf items, and "Standup, in 7 minutes" for the calendar pill, instead of "4m", which it read as metres.
- The pill's timer, stopwatch, call, recording and scrubber are spoken as durations ("4 minutes 59 seconds remaining"), as the cards already were, instead of clock digits read as a time of day.
- The Stats cells speak battery time, health, cycles and memory in words, without "h", "min", "·" or "slash", and a battery with one charge cycle says "1 cycle".
- The pill's countdowns and running clocks turn over on the second the figure does, not whenever the pill appeared, and its spoken sentence turns with them.
- Focus modes with accented or numbered names sort as Finder sorts them ("Écriture" among the E names, "Study 2" before "Study 10").
- The clipboard list no longer checks the Accessibility permission twice per row on each redraw, and no longer splits long copies into lines just to show their first line.
- Closing Settings really lets its view go: the window's title binding kept the first one alive with its pane's timers ticking.
- A keyboard backlight given up after a lid opening is looked for once more ten seconds later, rather than only at the next wake.
- A press on the Now Playing card no longer waits behind a poll sent after it. Its six-second limit is checked when it actually starts, and a pause, including the sleep timer's, is never dropped as too late.
- A stream that reports a timestamp but no position keeps its clock instead of going back to 0:00 each time the player stamps it.
- AppleScript goes back to its full rate when a track plays from any source, the card changes hands or ends, or a button beside play is pressed. A poll with no player open no longer counts toward slowing it down, so a newly opened Music is picked up within seconds.
- On macOS 15.3 and earlier, MediaRemote saying "nothing" slows the Music and Spotify fallback instead of stopping it, and no longer ends the fallback's card unless MediaRemote has shown a track lately. A MediaRemote stuck after a wake no longer leaves the island dark while Music plays.
- The helper sends a cover's bytes again only when the cover changes or nothing was playing, not after every advert or gap between tracks.
- The Dark Mode switch runs on the app's single script queue with a five-second timeout, and a switch that times out no longer opens the Automation pane.
- The Join button only unwraps a Safe Links or Google redirect to a real web link; an inner `httpfoo://zoom.us/…` is no longer handed to whatever app claims that scheme.
- A Teams meeting link that arrives through Outlook's Safe Links opens intact: the inner link is decoded a second time only when it was encoded as a whole, so its own `%26` and `%23` no longer split its query.
- Bluetooth that goes away while Controls is open (access taken back in Privacy, a USB radio pulled out) now goes off in the column and on the rail, and the paired list is no longer asked for every poll.
- A Mac whose Bluetooth access is restricted by a management profile is told Bluetooth access is off, not that it has no Bluetooth.
- A shelf drop on a disk without hard links gets the same file permissions as on any other disk.
- An alert's `duration=0`, or a card's `ttl=0`, is logged as "must be more than 0" instead of "is not a length".
- The mute button is dimmed on an output whose mute can be read but not set, instead of doing nothing when pressed.
- The keyboard backlight survives a lid opening: one empty answer from CoreBrightness no longer takes the disc away until the next wake. It looks again two seconds later and gives up only if the keyboard is still missing, and a keyboard that comes back under a new number is driven by that number.
- The brightness slider on a second display's island starts on that display's own level, rather than the MacBook's, when a rail has been on it before, and a display that misses one reading mid-drag keeps its slider.
- Wi-Fi event monitoring asks for every event even when the daemon refuses one.
- The README's rule for where `ask` may write its answer was backwards: it is a folder of your own that only you can open, in /tmp or $TMPDIR, never your home folder.
- `notchctl ask --timeout` takes a length the way every other flag does (90s, 2m), held to 5 to 600 seconds, as the island already did.
- The menu bar says "Hidden in full screen" when a full-screen app hides the island, instead of blaming an app on the hide list.
- A clipboard row's VoiceOver hint and tooltip say what a click really does: paste where you were typing, or copy it again.
- The shelf's VoiceOver hint says a click selects the file and Open is in the actions.
- The Privacy pane's Microphone row no longer reads "Not asked yet" for ever: nothing asks for the microphone, and the row says it needs no permission.
- The Downloads, Desktop and Documents folder prompts now say why Notch Island asks, and the Bluetooth prompt mentions its switch and connecting.
- Settings and the README say when calendar and reminders are really asked for, and that Automation also covers System Events for the Dark Mode switch.
- The rail's controls are named the way the menus name them: Mute Microphone, Record Screen, Keyboard Backlight.
- The Wi-Fi list's location pill is "Allow Location" whichever way it asks.
- The sleep timer's menu items and the window tile's zone items use title case like the rest of the menu.
- The README now lists the sleep, Pomodoro, seconds and ask-cancel URLs, the button parameters, Notifications, Motion, Reload Island and Copy Diagnostics.
- The Mirror lets go of the camera when the Mac goes to sleep, even with the Mirror still on screen; the camera and its green light used to stay on across sleep.
- "Check for Updates…" always answers: changing any setting while it was checking, with automatic checks off, used to cancel it silently. The hourly check no longer replaces one you asked for, and a replaced request no longer puts the row back to its old status while the new one is still out.
- Closing Settings stops the pane that was open from re-reading permissions, folders and Focus every few seconds for the rest of the session; it reopens on the same pane in the same place.
- Switching Notifications off and on quickly no longer leaves two watchers reading Notification Centre.
- The share picker lets go of the island's view once it closes.
- Restarting the Focus watch can no longer close the new watch's file descriptor.
- Rebuilding the islands (a display plugged in, waking, Reload Island) takes each island's view out of its window first, so the rail's controls, lyrics, level meter and camera see it go and stop polling.
- Live radio and streams no longer make the Now Playing helper restart over and over, which dropped every player but Music and Spotify.
- The Now Playing card goes away when the music stops, even after the helper was restarted or had gone quiet.
- A track whose cover matches the previous one keeps its cover after an advert or a gap between tracks.
- Seeking or pausing just before a track ends no longer carries over into the next track.
- The sleep timer sends a pause and can never start the music.
- With Music and Spotify both open and paused, pausing one no longer switches the card to the other.
- A player that stops responding no longer makes presses pile up: every Apple event in a script has a timeout, presses made meanwhile are folded together, and one that has waited too long is dropped rather than sent late.
- Volume, brightness and mute keys show their bezel during a new track's preview, and a queued preview is dropped rather than shown long after its track began.
- Long Hebrew and Arabic titles scroll from their beginning.
- The heart lights only when the favourite was sent: the script ran, or the helper took the command.
- Music and Spotify are no longer asked every two seconds for as long as nothing plays, and MediaRemote's "nothing is playing" is heard on macOS 15.3 and earlier.
- A Spotify cover that missed one poll's wait is asked for again on the next, and the playhead no longer runs behind by the time the cover took.
- Lyrics are looked up only while the lyrics line is on screen.
- A live stream that reports no playhead keeps the card's clock rather than jumping back to 0:00 on every report.
- A finished-download banner no longer blinks on and off when a question from notchctl comes back onto the island.
- Play, pause and the skips with no card up go to the helper when it is answering, and MediaRemote's own word on whether a player is playing is used where it gives one.
- Locking the screen or sleeping the display from the rail now closes the panel, so nothing keeps polling behind the lock.
- The rail's brightness, the Wi-Fi network list and the paired-device list now slow down on battery, in Low Power Mode and while nobody is looking, and Wi-Fi is no longer scanned while it is off.
- The paired Bluetooth list is read in the background, and not at all while Bluetooth is off.
- The rail's mute button is dimmed on outputs that cannot be muted, and a plain speaker is shown, rather than a muted one, when the output has no volume level.
- On a second display's island, the brightness slider now drives that display when it can, and otherwise says which display it drives.
- The Bluetooth card no longer shows "Case 0%" for a sleeping case, and the pill shows the same battery figure as the Controls list.
- The Automation permission prompt now also explains the Dark Mode switch, rather than mentioning only Music and Spotify.
- The keyboard-light disc now shows the right automatic setting after a change in System Settings, appears when the backlight becomes available after login or when the lid opens, and its automatic checkbox no longer snaps back.
- The battery card no longer shows a charging bolt while plugged in but not charging.
- Stats no longer shows battery health above 100%.
- The mirror button appears and disappears as cameras are plugged in or unplugged, and a MacBook camera with the lid shut is no longer used.
- After switching Wi-Fi on from the island, the network list fills in without waiting, and the list follows the radio when it is switched elsewhere.
- Clicking the Wi-Fi network you are already on no longer rejoins it.
- With Bluetooth access turned off for the app, Controls now says so and offers the Privacy settings, instead of "Not on this Mac".
- Night Shift, True Tone and warmth settings that macOS refuses now go back straight away.
- A slow Bluetooth radio no longer makes the switch flick back and forth while it powers on.
- The sound output picker can no longer push the rail past the panel's edge.
- The island no longer shows its brightness bezel next to the macOS one after Accessibility access has been removed.
- **The Now Playing visualizer no longer goes flat for the rest of the session after one failed start** (while AirPods connect, say): it tries again after 1, 3 and 10 seconds and whenever the output changes or playback starts, and pausing and resuming while the audio-capture permission sheet is up no longer leaves the bars flat.
- **Right after Accessibility is turned off, or while the key tap is briefly disabled, a volume key no longer shows the island's display beside the macOS one**; switching output right after moving the volume no longer leaves the rail on the old device's level; an input picked in System Settings is ticked in the Sound column and the rail menu at once; and the volume keys click only when "Play feedback when volume is changed" is on, as macOS does.
- **A timer started from a script with an absurd length no longer crashes the app** when its card is read aloud; a script's timer, or one addition to it, is limited to a day, as in Actions.
- **Security: `notchctl ask` answers are written only into a private folder in /tmp or the temporary folder**, never the home folder, so a link can no longer create a file such as `~/.zshenv`; and a calendar Join button uses only links whose host really is Zoom, Meet, Teams, Webex, FaceTime or Whereby, unwrapping Outlook Safe Links and Google redirects to reach it.
- **`notchctl` and the URL scheme accept lengths like `45m`, `90s` and `1.5h` and refuse values they cannot read** instead of quietly using a default (`sleep 45m` set 30 minutes and `--ttl 10m` never expired; an ask timeout or an alert duration that cannot be read falls back to its usual time, and says so in the log), `timer add 30s` adds thirty seconds rather than a minute, and `shelf add` works with CDPATH set and file names starting with a dash.
- **A `notchctl ask` question comes back on the island after a ringing timer or another expanded card has had its turn** instead of waiting out its time as a pill, and interrupting `notchctl ask` with Control-C, SIGTERM or its folder disappearing takes the question down and frees Control-Y and Control-N.
- **Alarms set from now on follow the clock when the time zone changes**, including across a relaunch; the stopwatch no longer jumps when the clock is set; cards with a time limit, and questions, go on time after the Mac wakes or the clock changes; and automatic update checks resume after the clock was once set ahead.
- **A script card with an empty body no longer has a black band under it**, `notchctl activity alert` no longer clashes with script alerts, two occurrences of a repeating event on the same day both show in Today, reminders show a due time that came without a calendar, Shortcuts whose names start with a dash run, and the hourly weather strip uses the forecast location's time zone.
- **Today no longer cuts off the hourly forecast** when the day is empty or calendar access is off: the hours show only under the list, and the empty state has the whole body.
- **The Home grid's Today tile no longer names tomorrow's event in the evening**, nor a reminder you just ticked off, and a new track's sneak peek over the Now Playing panel no longer makes the cover jump, its banner saying "New track" rather than repeating the title.
- **VoiceOver reads the current time on timer, stopwatch, call and recording pills** and on a pushed card's running clock, reads a muted volume as "Muted", announces the Wi-Fi, Bluetooth and Sound switches in Controls as named switches with their state, and can play or pause from the Home grid's Now Playing tile; turning the volume down while muted no longer unmutes or loses the previous level.
- **The Now Playing scrubber takes clicks 24 pt tall**, the welcome tour fades between pages under Reduce Motion, "now" and "4m" in Notifications and Clipboard keep counting while the panel is open, the compact pill no longer shows fragments of a word when the menu bar leaves no room on one side, and the Focus disc's tooltip in Settings says what it opens.
- **The Home grid and Actions no longer check each favourite app on disk every time they redraw**; the list is checked when it changes, when an app comes forward and when a disk is plugged in or out.
- **With two displays, a peek on one no longer asks for Calendars, Reminders or Location** because the panel is pinned open on the other.
- **Dropping two things with the same name at once keeps both** — two links to the same site, two unnamed pictures in the same second, two snippets with the same first line — and on the Mac's own disk a drop that runs out of space no longer leaves half a file on the shelf.
- **Compress works on several files at once**; it said "Could not compress" every time, and the archive unpacks the files as themselves, the way Finder's does.
- **A clipboard or notification history this version cannot read**, such as one written by a newer version, is kept beside it under a new name instead of being replaced by an empty one, and quitting or sleeping while the notes or notification history was being saved can no longer leave an older copy on disk.
- **A cancelled Firefox download is no longer announced as finished** or put on the shelf, and a Downloads folder the island cannot watch is logged with the reason.
- **A shortcut with one modifier no longer takes ⌃Tab, the word jumps, ⌘←/→ or ⇧Tab from every app.** The recorder asks for two of Control, Option and Command; one recorded before still opens the island, its Tab and arrow steps are left to the app in front, and Settings and the tour say so instead of listing steps that do nothing.
- **The pointer on the very top row of the screen counts as on the island**: a flick up into the notch opens the peek, an open peek stays, and a click on the top edge of the switcher no longer goes to the menu bar or closes the pinned panel.
- **With a film full screen on one display, a panel opened from the shortcut or the menu bar gives the keyboard to the island you can see**, not to the hidden one over the film.
- **A ringing timer's card, or a script's question, that replaces a peek no longer takes the click aimed at the peek**: that click opens the card instead of pressing Stop or answering. A quick second click after clicking a card open no longer lands on a switcher slot that grew under the pointer, and after a panel closes on its own the next hover opens on what is playing rather than on a leftover section.
- **The volume slider comes alive as soon as AirPods or an AirPlay speaker report a level**, instead of staying greyed out until the level moved some other way.
- **A game or video that goes full screen a few seconds after its app comes forward hides the island within a few seconds** (two on power, longer under the energy policy) rather than up to twenty; a slow answer from one app can no longer bring the island back over a full-screen window with an out-of-date reading; and on a display without a notch, zooming a window to fill the screen no longer hides the island once Accessibility is granted, while films and games still do.
- **Nothing leaves the Mac or asks because you looked, part two.** With "Find missing album art" off, the cover Spotify names for a track is no longer downloaded; right-clicking the island on a new Mac no longer asks for Bluetooth before the welcome tour; Music and Spotify are no longer sent a script, and so asked for Automation, before it; and peeking at Today no longer asks for Location, while a panel you pinned open still can.
- **A pushed card's Shortcut button stops working, and greys out, the moment "Let pushed cards run Shortcuts" is turned off**, rather than at the next push.
- **Turning on "Pause animations on battery" while unplugged takes effect at once**, and the sound monitor's listeners no longer come back after it is turned off.
- **Settings says which display carries the island** when "Show on all displays" is off: the notched one, otherwise the main display with the menu bar.
- **A tagged release no longer publishes when its tests fail**, `Scripts/build.sh` stops a release build when signing fails and only warns on a local one, `Scripts/gallery.sh` fails when its tests do, `Scripts/smoke.sh` clicks the floating island where it actually hangs and checks that it opens and closes and fails when no island is measured at the top of the screen, and `notchctl ask` exits 73 rather than 1 ("no") when it cannot make its temporary folder.
- **The full-screen watch no longer reads every window every two seconds.** It looks when the desktop changes or an app comes forward or quits, every two seconds only while something is covered, and every twenty otherwise.
- **Volume keys taken over by the island no longer go back to macOS for the session** when a HomePod, an AirPlay target or AirPods offer volume control late (up to a minute after they became the output); Caps Lock is back to answering within half a minute of Accessibility being revoked without a word; the display popover shows the built-in slider as soon as the display answers.
- **On a Mac without a notch, the island hides in full-screen apps out of the box** instead of staying over every full-screen video, and resting the pointer on the bare pill no longer opens Home on its way to a tab (a live activity still opens under the pointer, and a click still opens Home). Both defaults follow the island until you set them yourself, and switch back when the island moves into a notch, for example when the lid is opened. A MacBook's notch keeps its own defaults with a monitor plugged in, whether or not "Show on all displays" is on.
- **With the menu bar set to hide automatically, the floating pill sits just under the top edge** instead of 28 pt down under a menu bar that is not there, and moves as soon as the setting is switched.
- **Lyrics follow along again after the Mac wakes.** The ticker read the sleep flag before the new value was stored, so going to sleep left it running and waking stopped it until the next track report.
- **A player that refused Automation shows as not answering in Settings**, and the Now Playing buttons' tooltips say why. The rail no longer asks for Bluetooth before the tour, and a Mac without a Bluetooth radio shows no Bluetooth switch.
- **Nothing asks before the tour.** Bluetooth waited for nobody and was the first thing a new Mac saw; it now waits for the welcome tour like the calendar, and Settings > Privacy lists it, with the Downloads and screenshots folders and which player allowed or refused Automation.
- **A shortcut that works.** Where macOS switches between two or more input sources with ⌃⌥Space, the island ships on ⌃⌥I; a Mac with one keyboard layout keeps ⌃⌥Space. It is chosen once, the first time the app runs, so adding or removing an input source later no longer moves it; the tour names whichever it got, and the shortcut recorder says when macOS has the combination.
- **Nothing asks because you looked.** A peek no longer asks for Reminders (a peek reads whatever has been granted, and only a panel pinned open asks, so a new Mac's Home no longer says "Nothing today" over a day of meetings), Controls asks for Location only from an "Allow Location" pill, and the mirror checks for a camera first and is left off a Mac with none.
- **Settings tell the truth.** "Open at login" shows what macOS registered and says when it waits for approval, Focus says when Full Disk Access is missing, and the battery settings grey out on a Mac without one.
- **The tour tells the truth.** No notch is promised on a Mac without one, the shelf's real expiry is given, the folder prompts are announced, the sections page two leaves out are named, and a reopened tour starts on page one.
- **The calendar card stops waiting on somebody's mail server.** The next-event check ran on the main thread every minute and on every calendar change, a network fetch for a CalDAV or Exchange account; it reads on a queue now, like Today.
- **A hung app cannot freeze the island.** Accessibility questions get half a second instead of six, and raising, snapping, minimising and closing a window happen off the main thread.
- **Downloads is no longer listed on the main thread.** That included once a second while a download ran. Only the partial files are ever looked at.
- **Copying a screenshot does not stall the island.** Pictures are converted and measured off the main thread, putting one back no longer builds an uncompressed TIFF, and the history keeps at most 64 MB of pictures.
- **Opening the panel does not enumerate audio devices mid-animation.** Sound devices and brightness are read on queues.
- **A release carries its own version.** Every bundle said 1.0.0 whatever its tag, so a fresh install of a new release was told to update to itself. The build stamps the tag's version and a build number into the bundle, a tag that is not a version stops the release, and pre-releases are ordered properly. The build reads `NOTCH_VERSION` and `NOTCH_BUILD_NUMBER`, so a `VERSION` exported for something else no longer breaks a local build.
- **Notes that cannot be saved say so.** A failed write only went to the log, and a relaunch brought back the old text. The Notes header shows "Not saved" with the reason, a click tries again, and a notes file that cannot be read is set aside as `notes.txt.unreadable-…` instead of being written over.
- **`notchctl --help` lists every exit status and exits 0.** Bad usage exits 64 everywhere, a command that cannot reach the island exits 69, and `shelf add` without a path says how to use it. A question asked while the app is still starting shows its Control-Y / Control-N hint once the keys are ready.
- **The island no longer wakes every second.** Expiries and the end of a pause are timed to the moment they fall due, instead of a clock that looked once a second, forever.
- **A timer's ring no longer redraws at display rate for movement you cannot see.** On a long timer it steps once a second like the digits beside it, while short timers still sweep; it also stops sweeping while animations are paused and under Reduce Motion. Adding a minute, repeating a timer or moving to the next Pomodoro phase moves the ring with a short spring instead of a one-second sweep.
- **Moving the pointer near the island no longer rebuilds its outline two or three times per move.** The outline is built once for each layout and kept.
- **Minimised windows stay in Windows.** The minus on a tile, or "Hide Safari", took the window out of the strip with no way back. With Accessibility, windows in the Dock and a hidden app's windows are listed after the rest, dimmed, and a click brings them back. The count says "on this desktop", because windows on other desktops are not listed, and a same-named window on another desktop is never listed in place of the one in the Dock.
- **A find on Windows always shows its field.** With Screen Recording or Accessibility missing, typing narrowed the strip while the header showed only the permission pill. The field comes first now, with the pill beside it.
- **Old weather says how old it is.** After Location was refused, or offline, Today showed the last reading as the weather for good and never offered "Allow Location". A refusal clears the reading and shows the offer. After three missed refreshes the line gives the reading's age, and after a day it goes.
- **Today says what it left out.** With the weather on, one event fitted and the rest of the day went missing without a word. The header says "Today · 2 more" and the list scrolls. Only above the list: with Calendars refused the header says just "Today", and a scroll there is the volume.
- **Today ends at midnight on the days the clocks change.** An 11:30 PM meeting on the autumn change read as tomorrow's, and the last hour's reminders were left out.
- **All your Actions fit.** With six apps only two of eight favourite Shortcuts were drawn, and the Home tile counted them all. The row holds ten, Settings counts apps and Shortcuts against it together, and the tile counts what the row draws; an app on a disk that is not plugged in takes no room from the Shortcuts, still counts when adding an app, is listed in Settings to be removed, and the tally says when it is away.
- **Clear takes what the find is showing, keeps the pins, and can be taken back.** With "pdf" typed on a shelf of ten files and two showing, Clear emptied all ten, and the island's own snippets went to the Trash; on Clipboard it took pinned copies too. With a find up, Clear on Shelf, Clipboard and Notifications says how many it takes, "Clear 2", and takes only those; Clipboard's leaves the pins. For twelve seconds after, the pill is Undo Clear, as on Notes; a download or screenshot landing meanwhile stays in front of what comes back. The shelf trashes its own files only once the offer has gone, and a crash inside it no longer leaves them in Application Support.
- **A big drop no longer pushes the island's own files off the shelf.** Twenty-five files from Finder took a parked snippet, and the drop's own first file, off the shelf, and the snippet to the Trash, without a word. Room is made only from files that came from Finder; what still does not fit is turned away from the end of the drop, and the island says how many did not fit.
- **Controls stay under the pointer.** The stopwatch pill keeps its width when it says Stop or Reset, so the second click lands. The Actions timer glyph takes clicks 24 points wide and the rail's sliders 24 points tall; nothing is drawn differently.
- **Space previews what is picked out on the shelf.** It showed the whole shelf whatever was selected. With a find up, only what it shows; nothing when it matches nothing.
- **The timer card acts on the timer it shows.** With a second timer swapped onto the card, Cancel cancelled the other one, Pause paused it, and Resume did nothing. Repeat started the last timer started rather than the one that rang. The card and the menu's Repeat now restart that timer, in place, with its own name and length.
- **A stream's bar is not a seek to the start.** On a live radio stream or a browser podcast with no length, a click on the progress bar jumped to 0:00. The bar is a plain line there now.
- **The heart can be taken back.** In Music a second press removes the favourite. Where a player cannot be asked to (Spotify, the helper), the lit heart is dimmed and says where to do it. It empties once Music has done it; with Automation refused or Music not running it stays lit.
- **Settings that did nothing say so.** "Tell me at" sat under Downloads and stayed live with "Battery and charging" off, when nothing read it; it is under Battery now and greyed out with it. The shelf's switches for downloads and screenshots are greyed out while Downloads or Screenshots is off, and the pane names the switch. The Height slider ran from nothing, as Width once did; it starts at the notch's own height, and that end is Automatic.
- **Settings and the README say what the app does.** The digits follow Tab's order, live activities first, not the slots from the left; Notifications takes the letters too; a scroll down takes a minute off a timer; a copied picture is never kept across relaunches; checking for updates shows a card rather than opening a page; and Privacy names every feature each permission is for.
- **Smaller things.** Free disk space is in Finder's gigabytes, not about 7% under. The Bluetooth list refreshes every four seconds instead of restarting its clock on every redraw. Device batteries turn red at 20% in both Controls and the AirPods card. Controls' On/Off/Muted switches keep one width, so a second click lands. VoiceOver reads the AirPods card once, as a sentence and a button, and can reach its Connect/Disconnect button. The island's menu words Hide and Show the way the menu bar does.
- **A click on the pill opens the pill's panel.** A double click on a timer, or a click just after the peek grew under a pointer that had only just arrived, landed on the switcher's Home or Music slot, which starts where the pill's digits were, and took the keyboard with it. For 0.3 s after the island grows, and for the second click of a double click that opened it, a click goes to the panel itself.
- **Typing straight after Escape reaches the app in front.** The island kept the keyboard for a third of a second after closing (two thirds with Motion at twice the length), and the letters typed then were lost. A close from Escape or the shortcut hands the keyboard back at once.
- **Files can be carried past the island.** A file dragged from the Desktop across the notch made the window solid until the button came up, so a window under the notch could not take the drop, and the drag opened the peek on its way through. The same happened to a file, clipboard row or screenshot dragged out of the island. Only the island's own outline takes a drag now, so the shelf's well still does.
- **Full screen on one display leaves the other's panel.** With the pointer or a drag on the external display's island when a film went full screen there, the panel pinned on the MacBook closed as well. Only that island's pointer is forgotten now.
- **A card under the pointer stays a card.** With the pointer opening the panel, as it does out of the box, a screenshot's card — or a finished download's, an update's, a shortcut's result, an alarm's — turned into the Home peek a quarter of a second after the pointer reached it. Copy and Open moved out from under the hand, and the alert shrank to a banner that ran out with the pointer on it. It stays up while the pointer rests there, for up to a minute, and a click opens it as before. A card that arrives while the pointer is already in the panel is a banner there, as before, rather than taking the panel from under the hand. With "Open from the empty notch too" off, a card arriving under a pointer resting on the bare notch is shown; nothing was drawn.
- **A ringing timer keeps its card.** A volume key, a copied line, Caps Lock or a track's sneak peek folded the eight-second card, Stop and all, to a pill; a call's card too. Anything short of a nearly flat battery waits behind it and has its turn after, and an alert that was already up comes back rather than running out unseen. A pointer on the card keeps it, for up to a minute, where it used to grow into the panel and move Stop. What waited behind it comes back at its own length, and is not dropped for having waited while a pointer held the card. A louder alert arriving while the queue is full takes the quietest place rather than being dropped, and an alert waiting behind a card the pointer holds is not dropped when it goes.
- **A track change leaves the bubble alone.** With files on the shelf, every sneak peek popped the bubble out and back and blurred the whole pill, cover included. The peek is drawn over Now Playing the way the volume HUD is.
- **One way to close.** After a sideways step the panel closed on a flat fade instead of its blur, and the first step blurred the old section while later ones only faded it. Both are the same every time.
- **Two displays: steps go where the keyboard is.** With the panel pinned on one display and the pointer resting on the other's island, Tab, the arrows and the digits stepped the other island's peek; a swipe there started from the pinned panel's place, and a drag there was judged by its section; a swipe up on that peek closed the pinned panel too. Crossing between islands could also leave one island refusing to peek, or peeking with nobody on it.
- **A sideways swipe scrolls the Shelf and Windows strips.** Every sideways swipe on them stepped to another section, so the files past the eighth and the windows past the fourth could not be reached. A strip with tiles out of sight takes the swipe; one with nothing hidden, a Shelf with two files, still steps. Tab, the arrows and the switcher step from anywhere.
- **A scroll on Controls scrolls its lists.** The networks, the devices and the Sound list changed the volume instead, or closed the panel with "Open and close" chosen. On Today, which has nothing to scroll, a scroll is the volume.
- **Escape is not lost after a step.** For 0.3 s after any step, find or slider, Escape was taken and thrown away, so leaving a find and then closing needed a third press, and Tab-Tab-Escape lost the Escape. It is measured from the open now, as the click outside already was.
- **A swipe that closes the panel stops there.** With the fingers still moving over the timer's pill the panel closed down to, the rest of the swipe moved the timer a minute per step.
- **Reduce Motion no longer scales or slides.** Opens, closes and steps cross-fade, and the switcher's disc fades across instead of travelling.
- **Smaller things.** A right-click inside the hover delay no longer grows the peek behind the menu. A click that opens nothing on one display no longer gives the keyboard to the other's panel. Closing an alert you were holding shows the ones that waited behind it. Escape stays with the app in front after a click on a control pins the panel, while the combo's arrows still step. Clicking a switcher slot moves the disc on the same spring as the section. Holding a file on a slot opens that island only and leaves the keyboard with the app in front. Clicking the bubble no longer presses the pill in. General notices an Accessibility grant every two seconds instead of restarting its clock on every redraw. The switcher shows no digit on Actions, where the digits type a timer, and the Island pane says so.
- **The island's space never draws over the lock screen or a screen saver.** A space made while the screen was locked — the app launched at the lock screen by `notchctl alert` — was shown at once, and the card was drawn over the login window. It starts hidden now and is shown on unlock. The screen saver hides it too, and it comes back when the saver stops, unless the screen is locked.
- **What the island opens is drawn over the island.** The rail's popovers and the island's right-click, shelf and window menus go into the island's own space while they are up, so they cannot open underneath it.
- **Full screen stays full screen when another app comes forward.** Only the frontmost app's windows were looked at, so clicking Safari on the MacBook brought the external display's island back over a film within two seconds. Every app's windows count now, as long as the window is at the front of its display or belongs to the app in front, so a utility's display-sized window behind Safari does not hide the island, and a window on the other display that overhangs the shared edge by a few points is not the front of this one; Accessibility is asked only of an app that could be full screen on the notched display.
- **Full screen on the notched display works without Accessibility.** There it never counted before. It counts once that display's menu bar has gone, and General says that granting Accessibility gives the exact answer.
- **Moving the menu bar to another display moves the floating island with it.** The panel is rebuilt when a display without a notch becomes, or stops being, the one with the menu bar.
- **The room beside the notch is measured on the notched display.** With the menu bar on an external display, the app's menu titles over there made the room come out as nothing, or as the whole desk.
- **One brightness slider per display with the lid shut.** In clamshell mode the rail and the Display popover both drove the external display; the popover now leaves the rail's display to the rail.
- **Lock Screen locks on every keyboard.** It pressed the key where a US keyboard has Q, which on a French keyboard is A and on Dvorak is an apostrophe, so it sent Control-Command-A and the Mac stayed unlocked; and since posting the keystroke counted as success, nothing else was tried. It now makes the Apple menu's own Lock Screen call first. The keystroke is only a fallback, pressed on whichever key types Q, skipped on a keyboard with no Q, and only if the screen has not locked within two seconds of the Apple menu's call, whatever it answered.
- **A missed alarm is seen by somebody.** It was reported with an eight-second card at wake, behind the lock screen, where nobody saw it. When the island cannot be seen a banner is posted too, as for an alarm that rings. Where Notifications have not been allowed yet, it does not ask at the lock screen; the card comes back after the unlock instead.
- **A timer rings on time with a menu open.** Its ticker stopped while a menu was held open, so a countdown that ran out then rang when the menu closed.
- **Waking the Mac leaves the Now Playing helper alone.** After any sleep longer than twelve seconds the helper's last message looked stale and a healthy helper was killed; each kill counted against its restart budget, and while it was down AppleScript asked Music and Spotify what was playing, which could raise an Automation prompt at the lock screen. A wake now restarts the helper's clock.
- **Moving the screenshot folder moves the card with it.** The folder was read once at start, so a new Save To location left the card silent until a relaunch.
- **`notchctl` sends accents and emoji intact.** "Café 😀" went out as `Caf%E9%20%1F600`, which does not decode. It is encoded byte by byte now.
- **A camera plugged in gets its dot at once.** New cameras were found only by a rescan every thirty seconds, or two minutes in Low Power Mode.
- **Shuffle and repeat switch off again in Music and Spotify.** Where the helper does not report these modes the press goes through AppleScript, and nothing reported the result back: shuffle could be turned on but never off, repeat always went to "all", and the button went dark a second later. The island remembers what it set in that player.
- **`notchctl alarm cancel` works when it launches the app.** The URL arrived before the saved alarms were loaded, so nothing was cancelled, and the alarm came back and rang.
- **Music on a headset is not the microphone.** AirPods and most USB headsets are one device for both directions, and the island asked whether that device was running — which it is for as long as it plays. So music lit the orange dot; a call started on the headset changed nothing the call card watched, so it got no card, and "Only during calls" left the island in the screen share. On macOS 14.2 and later the microphone is in use when some process is recording, and the island's own visualizer is not counted; on 14.0 and 14.1 only a device with nothing to play is believed. A call app that starts recording while something else already has the microphone gets its card, and a card ends when its app stops recording.
- **Unmuting gives back every microphone the mute reached.** Muted from the island, the mute moved to AirPods that connected mid-call; unmuting reached only the AirPods, and the Mac's own microphone was found still muted the moment they went. Every microphone the mute was put on is remembered and unmuted with it, and one that had gone by then is unmuted when it comes back, the first time it can say whether it is muted; one that never can is left alone after three changes of devices.
- **"Only during calls" no longer needs the Calls switch.** With Calls off in Activities nothing watched for a call, so the island was hidden from screen sharing during nothing. Calls are followed whenever either switch wants them; the card is still the Calls switch's to show.
- **The rail's microphone button waits for a microphone.** With no microphone the island can mute, it is dimmed and ignores clicks, as the menu item and the call card's button already did.
- **A receiver that says no leaves the sound where it was.** Picking an AirPlay speaker makes the AirPlay device the output and then points it at the speaker. When the speaker refused, the first half stayed done, and the sound went to whichever speaker AirPlay last played to, or nowhere. The output the Mac was playing through before is put back now.
- **No asking every two seconds for what will not be given.** Where AVFoundation refuses an app like this one the system's audio context, the AirPods listening modes stay hidden — but the route was still asked for them every two seconds for as long as Controls or a Bluetooth card was open. It stops after three refusals in a row, so a sound-system restart still recovers in a beat, and asks again when one of them opens.
- **A script's "end" ends only the script's cards.** `notchisland://activity/end` with no id
  ended every custom activity, the island's own screen recording among them: its card went, and
  with it the only Stop button, while `screencapture` went on recording. It now ends the cards a
  script pushed and nothing else.
- **The keyboard's backlight keeps its place on the rail.** Its slider took the room of two and a
  half buttons, so a single file on the shelf — which brings AirDrop — pushed it off into the
  Controls section, and it came back whenever the Shelf section was open, where AirDrop stands
  down: the strip that is meant to be the same under every section changed shape with the
  section. It is a disc now, like Display's, and its slider and Automatic switch are in the
  popover it opens; right-click still switches Automatic. And the rail is fitted with AirDrop on
  every section before the Shelf's takes it off, so the room it leaves there goes to nothing
  else.
- **Switching the Controls section off no longer loses the rail's overflow.** The controls the
  rail has no room for wait at the top of that section and nowhere else, so its switch took them
  with it. While anything is waiting there the section stays in the panel — on the switcher, the
  Home grid, the Tab ring and the `home/controls` link — whatever its switch says, and goes
  again once nothing is. The Home Panel pane says so.
- **The Wi-Fi list names the networks in range.** macOS 14 only tells an app the names of the
  networks around it once Location allows it, and nothing asked, so every network in the scan
  came back nameless and Controls said "Nothing in range" on a Mac sitting on a working
  network. The list asks the first time it is opened, and where Location has been refused it
  says so, with a button to the pane that allows it. Privacy lists Wi-Fi under Location too.
- **"Keep paused music for" keeps its word.** The helper repeats a paused track every five
  seconds, and each repeat was taken for news: the card came back five seconds after the limit
  took it away, with its clock started again, so it never really went — and with "Not at all"
  the pill blinked every five seconds. The paused track the limit removed stays removed until
  it plays again or something else does.
- **A failed lyrics lookup is not a track with no lyrics.** No network, a server error, or the
  cancel a track change sends to the request in flight were all filed as "no lyrics", in memory
  and on disk, for good. Only an answer with no match in it is filed now; a failure files
  nothing, and the track is asked about again the next time it plays.
- **"Download complete" means a file arrived.** Every partial download that disappeared was
  announced as finished, a cancelled one included, and so was Chrome's own rename of
  "Unconfirmed 123.crdownload" halfway through. Only a file that is actually in Downloads is
  announced now, and it goes onto the shelf only while the shelf is switched on, as a
  screenshot does.
- **A call card belongs to the app that has the microphone.** It went to the first call app
  running whenever the microphone came on, so an idle Slack in the background turned Dictation,
  a voice memo or a call in a browser tab into a "Slack" call at the island's highest priority.
  On macOS 14.2 and later the card goes to the call app actually recording — or its helper, or
  the system daemon recording for FaceTime; on 14.0 and 14.1, which cannot say who is
  recording, the call app has to be the one in front.
- **A new Mac's first sight of the app is the tour, not two folder prompts.** Downloads and
  screenshots started at launch, ahead of the welcome window, and both folders are guarded, so
  a new user was asked for them before being told what the app was — and a refusal left both
  cards dead. Both wait for the tour now, as the calendar already did.
- **Allowing the calendar later takes effect without a relaunch.** Access was read once, so
  granting it in System Settings after launch left Today saying "Calendar access is off", and
  the card before a meeting never started, its timer having only ever been started on a yes.
  Both read the permission again as they go and pick a grant up within the minute.
- **A script's card is held to what the island can draw.** "duration=inf" kept an alert up for
  good and "-1" took it down on arrival; a priority over 100 sat on top of a call; a title of
  spaces drew an empty card, and a misspelt symbol a hole in one. A length is now seconds, up to
  a minute; a card ranks below a call; a blank title is the default one; and a symbol SF Symbols
  does not have is the card's own. An alert's own length is taken as it stands, too, rather than
  stretched by the alert slider: with the slider at six seconds, "three seconds" came out at ten.
- **A timer only posts a banner when the island cannot be seen.** Every timer that rang also
  sent a macOS notification — and asked for Notifications the first time one did — although
  Privacy says the banner is for when the island is hidden or an app is full screen. That is
  when it comes now.
- **Turning Weather off with Today open stops the weather.** The section gave back its claim on
  the weather only if the switch was still on as it closed, so switching it off with Today on
  screen left the forecast being fetched for the rest of the session. And the next few hours are
  the ones still to come: the strip is cached as it was fetched, and a morning relaunch with no
  network showed last night's evening as the next six hours.
- **The Today tile says what is next.** It read the agenda without asking it to read the day,
  so it said "Nothing today" after every launch until Today itself had been opened, and later
  on named a meeting that had ended hours before.
- **Three days means three days on disk too.** Notifications older than that were dropped from
  the list at launch but left in the file until something new arrived to rewrite it, and nothing
  expired at all while nothing arrived. What has expired is written away at launch, and the
  expiry comes round every hour.
- **Stop stops the stopwatch.** The button in the Actions section said "Stop" and reset it, laps
  and all. It stops it now, and says "Reset" once it has.
- **A misspelt symbol no longer blanks a Quick Action tile.** The field saved on every keystroke
  with nothing to say whether the name was a symbol, so a half-typed or misspelt one drew
  nothing on the tile for good. It saves on Return, keeps only a name SF Symbols has, and goes
  back to the automatic symbol otherwise.
- **Auto-brightness no longer raises the brightness overlay.** Any change over 0.2% that the
  island had not made itself was announced, and the light sensor moves the panel by more than
  that all day. A reading has to move by a quarter notch — the smallest step anybody takes by
  hand — to count, and a slow drift is absorbed as it goes rather than adding up to one.
- **"Focus database: Readable" is found out by reading it.** The check asked about the file's
  permissions, which say yes while macOS refuses the read, so Privacy said Readable on the very
  Macs where no Focus was ever seen. It reads the file now, and offers Full Disk Access when it
  cannot.
- **Escape closes the panel with both keyboard switches off.** The key handler was only
  installed while the shortcut or the panel's own keys were on, so with both off Escape did
  nothing, while the Island pane said it closes whatever is open. The handler is always there
  now; the shortcut and the panel's keys are still only claimed while their switches are on.
- **Five settings that described something the app does not do.** The notch Width slider went
  down to nothing though an override can only widen the island; it starts at the width the
  island already has, and that end is Automatic. "Open from the empty notch too" and the hover
  delay stayed live with "Open when the pointer rests" off; they are greyed out with it. The
  shortcut was said to open Now Playing when nothing is playing; it opens the section last used,
  and now says so. Lowering "Items kept" changed nothing until the next copy; the history is
  trimmed the moment it is lowered. And the Today switch also turns off the card before a
  meeting and its Join button, which its help now says.
- **Today shows the next few hours again.** With the weather on, the rows were still counted
  against the whole section, so two events and a reminder pushed the hourly forecast off the
  bottom of it. They are counted against the room above the forecast now, and a row that does
  not fit is left out rather than drawn over it.
- **Every section has a slot in the switcher out of the box.** Ten sections are on by default and
  the right of the band holds eight at a size the pointer can hit, so Notes and Stats had no slot
  while the left of the band stood empty. The ones that do not fit go to the left of the cutout
  now, after anything live.
- **Cards are as tall as what is in them.** Each card's height is summed from what it stacks,
  where several borrowed a neighbour's: every card with a progress bar had 3 pt of black under
  it, a calendar card 6, and a script's card with a body 33.
- **A pushed activity's trailing words fit in the pill.** The slot was sized at 8 pt a character,
  a guess about Latin letters that clipped Japanese and Chinese and gave "iii" the room of
  "WWW". The words are measured in the face they are drawn in.
- **"AirPods Pro" fits on its own card.** With three battery readings and a button on the row,
  the name had 59 pt and needs about 85; the row is set closer so it has twice that.
- **The privacy dots stay off the pill's rounded end.** In the compact pill they sat flush
  against it, where the curve cut the second dot and the edge was drawn through it. They keep
  10 pt of room there now.
- **The sneak peek and a paused title end in an ellipsis.** The peek ran into the pill's curved
  end, and with animation paused a title too long for its slot was cut off mid-letter, in the
  pill and in Now Playing alike.
- **The first name in Actions is whole.** Each name is centred on its disc and overhangs it, and
  the section was cut at the column's edge, which left "stem Setti…". It is cut in the panel's
  margin now, still well inside the island.
- **No coloured glow beside the album cover.** The last of the cover's colour outside the cover
  itself, and the section's edge cut it off square above and to the left.
- **Now Playing's buttons stay in their row.** The row was 2 pt short of the section, and each
  button took its clicks in 42 pt that reached over the scrubber's times. The row fills the
  section and the buttons answer inside it.
- **The Home grid is centred, and its lines fit.** The rounding gave all the spare width to the
  right — 24 pt of margin on the left, 28 on the right at six columns — and six of the lines
  under the tile names ended in an ellipsis. They are shorter now.
- **Four window tiles reach the right edge.** Three gaps of 10 left each tile 160.5 pt, rounded
  down to 2 pt short of the column; with gaps of 8 they are 162 and fill it.
- **The line in Actions is sharp.** It fell between two pixels and was drawn as a smudge across
  both; the row above it is half a point taller so the line lands on one.
- **A floating island sits evenly in its outline.** The switcher's disc was 2 pt under the
  floating panel's lit top edge, and a floating card's content hung 24 pt from its top and 16
  from its bottom. Both are 16 now.
- **Small controls are easier to hit.** A header's pills and find glass, the find field's clear
  button, a window tile's corner buttons, a shelf tile's buttons, another timer's cancel and the
  mute glyph all take their clicks in at least 24 pt, and are drawn at the size they were.
- **Three small misalignments.** The Controls columns kept 6 pt under their headers where every
  section keeps 8, the shelf's empty state was spaced unlike every other, and an alert banner's
  glyph sat further from its end than the figure at the other end did from its own.
- **The island's corners are one shape from the pill to the panel.** A compact pill's ends are
  semicircles and an open panel's corners are Apple's continuous curve, and the outline used to
  pick one family or the other from where it was *going*, so the first frame of every morph
  swapped them: the pill's round ends became a squeezed squircle with a dent in it, and a closing
  panel's corners snapped to circular arcs. Apple's own continuous corners give up their smoothing
  as the room for it runs out, until with exactly one radius of room they are the circle. The
  island's do the same now, by one rule for every frame, so nothing changes family at all.
- **Closing the panel with the pointer on it closes it.** Escape, the shortcut, Stop on a card,
  picking a clipboard row or a window, or the switcher's close button: with the pointer resting
  on the panel, each closed it and the peek drew the same panel straight back. The island now
  shows nothing until the pointer has left and come back.
- **A click on any control in a peek pins it.** A click on one of AppKit's own controls — the
  output menu, the Notes editor, the find field, the shelf's drag handle — went straight to that
  control and never pinned the panel, so picking AirPods let the peek close under the menu, and
  typing into Notes from a peek typed into the app behind.
- **A click on a control does not take the keyboard.** Clicking pause in a peek while typing in
  Pages pinned the panel and, with the panel's keys on, moved the keyboard to the island: the
  letters beeped and every Space restarted the music. A click on the island's body, the shortcut
  or Tab asks for the keyboard; a click on a control does not.
- **Escape stays with Quick Look and Settings.** Escape closed the island from anywhere while the
  panel was open, including from a Quick Look opened off the shelf or the Settings window opened
  from the rail, which then needed a second Escape. It now leaves the key with whichever of the
  app's own windows has the keyboard.
- **The island's click area is its outline.** It was a rectangle round the island, which reached
  thirty points past an open panel's sides and down into its rounded corners; a click there to
  dismiss the panel hit nothing and the panel stayed. And the pointer's every move restarted the
  hover's grace, so a peek followed the pointer down into the page and stayed while it moved.
- **A drag out of the island no longer leaves it pressed.** Dragging a screenshot's thumbnail or
  a clipboard row out took the press's release with it: the pill stayed at its pressed scale and
  the window kept every click under the notch until the island itself was clicked.
- **A volume key over music leaves the bubble alone.** A key-press HUD over a live activity keeps
  that activity's glyph on the left, but it was drawn as a different thing: the bubble popped out
  and back and the glyph blurred out and in, on every press.
- **Every close forgets the last step's direction.** A card's Stop, an alert replaced or a timed
  Home left the sideways step in place, and the next open grew on the flat navigate spring with
  its content sliding in from the side. And Tab with nothing open is an open, not a step.
- **A drag over an open panel crosses to the shelf.** It tore the whole panel down — band,
  section and rail, with the rail's audio listeners — and built it again as the shelf, with no
  animation, and back again when the drag left.
- **The bubble's glyph crosses over when the two activities swap.** It cut.
- **The rim's fade is a fixed ten points.** As a fraction of the height it scaled with the growth:
  the lit rim ran up to the top row of the display along the ears on the way open, and pulled off
  the upper sides on the way closed.
- **The privacy dots grow with the island.** They ran ahead of the black edge on a shorter spring
  of their own and were clipped while they popped in.
- **The window waits for a slower spring.** With the Motion pane's duration turned up, the window
  narrowed around the island before its spring had settled and cut the shadow flat at the sides,
  and the keyboard hand-back cycled the window mid-close.
- **A click outside right after using a control closes the panel.** The guard against the tail
  of the opening click compared against the last interaction, which every slider and step moves.
- **Gestures follow the scroll-direction setting.** With natural scrolling off, two fingers up
  lowered the volume and a swipe to the left skipped back.
- **Clicks beside and under the island reach what they were aimed at.** The window behind the
  island is a canvas as tall as the tallest card and as wide as the island plus its slack, and
  AppKit hands every click inside a window's frame to that window, drawn on or not — the
  island's own hit test dropped the ones that missed it rather than passing them on. So a strip
  three hundred points deep under the notch swallowed clicks and scrolls: Safari's tabs did
  nothing, the page under them would not scroll, and a click there could not close the panel
  either, because the click-outside monitor only hears what other apps receive. The window is
  now transparent to the mouse whenever the pointer is off the island and solid the moment it
  arrives, and a slider dragged past the edge or a file dragged over the shelf keeps it solid
  until the button comes up.
- **The island stays put across a swipe.** A Space transition — between desktops, into or out
  of a full-screen app — slid the island sideways with the desktop and snapped it back after,
  and nothing in AppKit's collection behaviour keeps a window out of that slide. The island's
  windows now live in a window space of their own at the top of the stack, where the menu bar's
  do, and the swipe goes on underneath them. The space is hidden while the screen is locked, so
  nothing draws over the login window. It can be turned off under Displays, should a display
  arrangement turn out not to suit it.
- **A swipe no longer closes the panel.** Switching Space activates whatever is in front on the
  new desktop, and the panel took that for the user leaving for another app: a swipe onto a
  Space with a different app in front closed it, one with the same app left it open, and the
  difference looked like chance. An activation now waits for the Space's own word, and one that
  came with a Space change is not leaving.
- **Full screen hides the island on the display it happens on, and only there.** One flag stood
  for every island, so a film full screen on the external display hid the MacBook's island and
  closed the panel that was open on it. And a full-screen app on the MacBook's own display was
  never noticed at all: its window stops below the camera housing, and the check wanted the
  whole screen. Each display is now judged on its own, and on a notched display a window the app
  itself reports as full screen counts when it fills everything below the housing (an ordinary
  window zoomed under the menu bar has the same frame, so the app's word is required, which is
  what the Accessibility permission supplies).
- **A click opens the island it was clicked on.** With an island on every display, opening one
  expanded all of them. What is opened by a click or a press now belongs to that island; the
  shortcut, the menu bar and a URL still open every island at once, and stepping with the
  keyboard stays wherever the panel already is.
- **A pointer resting on the island when the panels were rebuilt was never forgotten.** The
  windows went, the hover did not, and the island counted as under a pointer that was nowhere
  near it: the shortcut closed nothing, Tab stepped an invisible peek, the sneak peeks stayed
  quiet — until the pointer happened to cross the new island. A rebuild now forgets the pointer.
- **A Mac with no notch anywhere keeps its island on the primary display.** It went on whichever
  display had keyboard focus, and the panels are checked against that on every screen change and
  wake, so clicking into the other display moved the island there a few seconds later.
- **A display that is briefly gone no longer tears every island down.** A screen-parameters
  change with no displays listed yet — the moment an external display takes to return from sleep
  — built zero panels and then built them all again when it was back, which is the flicker the
  wake path was written to avoid.
- **On a display with no menu bar, the floating pill sits at the top.** It hung a menu bar's
  height below the edge of a secondary display that, with "Displays have separate Spaces" off,
  has no menu bar to hang below.
- **The menu bar above a floating pill takes clicks again.** The pill's hit area was measured
  from the top of the screen and took the strip it hangs below along with it, a pill's width of
  the menu bar (the whole panel's width, open) that did nothing when clicked and showed press
  feedback on the pill instead.
- **The island opens from the notch.** It had been opening from a hundred points below it: the
  compact island appeared in mid-air, detached from the top of the screen, and grew about its
  own middle until its top edge caught up with the notch. The window's height used to follow
  the island, growing in the same turn of the run loop as the state that opens the panel, and
  SwiftUI, handed a root that had already changed size, committed the island's box at its final
  height and animated the contents inside it. The close never had the fault — its shrink was
  always deferred until the spring had settled, so its container was still — which is what gave
  it away. The window is now always as tall as the tallest thing it can show and only ever
  changes width, and a click in the clear part falls through exactly as it always did.
- **The onboarding tour no longer fires a system dialog on top of itself.** Switching on the
  volume-and-brightness keys started the media-key interceptor inside 150 ms, which asked macOS
  for Accessibility with a modal sheet — before Done had been pressed, and with no warning,
  unlike the calendar line right above it. The choice is held until the tour closes, and its
  line says "Asks for access" like the other one.
- **The Brightness switch is reachable and truthfully explained.** It was greyed out unless the
  key takeover was on, behind help text saying there is no way to change brightness from the
  island — while an Option-scroll on the island changed it and this switch was the only thing
  governing that HUD. Since the takeover ships off, the switch was unreachable out of the box.
- **Notifications offers the button it needs.** The section's empty state said Accessibility was
  required and offered no way to grant it, forever — and said the same thing when it was already
  granted and nothing had simply arrived. It now offers Open Settings when access is missing and
  says "Nothing yet" when it is not.
- **Refusing Reminders is no longer invisible.** Calendars and Reminders are separate grants, and
  the section only ever checked the first: grant one and refuse the other and it showed your
  events with "Nothing left today" underneath, as if there were none. It says so now, with a
  button to the right pane.
- **The shortcut recorder refuses a key it would take from every app on the Mac.** It accepted
  Shift alone with a letter, which claims that capital letter system-wide, and Tab or a sideways
  arrow with any modifiers, which collide with the island's own next-section shortcut. Both are
  refused with a sentence saying why.
- **A switch that governs nothing is a lie told to your face.** "Open from the empty notch too",
  in the Island pane, has had no reader behind it since the line that consulted it was deleted:
  it sat there saying "resting on the notch does nothing unless this is on" while resting on the
  notch worked either way, switch on or off. It governs the thing it names again. The keyboard
  shortcut deliberately ignores it — somebody who presses a key has said what they want; this is
  only about what the pointer does when it happens to pass by.
- **Settings no longer states a figure the app is not using.** The charge mark, how long a paused
  track is kept and the shelf's expiry all snapped a stored value to the nearest offered choice
  *for display only*. A number left behind by an older build, or edited into defaults by hand,
  left the pane reading "70%" while the battery went on alerting at 50. The app is brought into
  line with what it shows, the moment anybody looks at it.
- **The Focus tooltip is on the Focus row.** Two `.help` modifiers had been stacked on the row
  below it, so the outer one won: hovering "Quieten alerts during a Focus" explained a different
  switch, and the Focus switch had no explanation at all.
- **Today cannot freeze on yesterday.** The gate that stops two calendar reads overlapping was
  only ever released when the read answered, and EventKit's completion is not guaranteed to
  arrive — an account that never replies, or access revoked mid-flight, left it shut for the
  rest of the session: the section kept showing yesterday, every later refresh returned at the
  door, and a ticked reminder never resolved. A read that has not answered inside half a minute
  is given up on, and one that answers after that is ignored rather than allowed to publish
  stale results over the top.
- **The island can find its way back after a Space change.** `placeIfDrifted` — the correction
  for an island left in the wrong place by a Space transition or a display waking, which its own
  comment says nothing else was ever going to fix — has never once run. Its guard tested a piece
  of work that is set at the end of every refit and never cleared, so it was true from the first
  refit onwards.
- **The gallery cannot file a picture under the wrong name.** It is the only eye this project
  has — nobody working on it can run the app — and it was switching sections on from a
  hand-written list that had missed Controls. A section that is switched off is not drawn empty:
  the panel quietly resolves to the nearest one that is on, so `panel-controls` was liable to be
  a picture of a different section altogether, with a green build and not a yellow pixel in it.
  The switches come from the list of sections now, so a new one cannot be forgotten, and every
  scene that names a view is checked against the view actually on screen before the shutter goes.
  The leak that made it possible is closed too: a test that switched every section off wrote
  that straight through to the shared defaults domain and four of its five callers put nothing
  back.
- **Settings and Quick Look can be typed into again.** Making the pinned panel hold the keyboard
  — which is what stopped it taking keys out of other apps — had it taking the keyboard back off
  *its own* windows too: click the gear on the rail and Settings opened with a dead title bar
  that would not accept a keystroke, with no way out, because none of the three things that
  close the panel fire for our own windows. Wanting the keyboard is not the same as being owed
  it by Settings.
- **A silent Mac no longer wakes Music and Spotify every two seconds.** Half of the health
  rewrite reached MediaRemote and half did not: it counted itself as answering only when a real
  track came through, so with nothing playing the app fell back to AppleScript for as long as it
  was switched on. An empty payload is an answer — it says the Mac is silent, and there is
  nothing AppleScript can add to that.
- **Notes and the notification history stop being eaten by a second launch.** The fix that
  stopped this happening to the clipboard was not applied to the other two whole-file stores.
  All three are read once the older copy has actually gone now, rather than whenever something
  first touches the singleton.
- **The media keys come back when macOS takes the tap away.** A tap disabled behind the app's
  back was noticed every five seconds and then left disabled: the island quietly stopped
  answering the volume and brightness keys for the rest of the run, and because macOS draws its
  own bezel there was nothing to see. It is revived now, a bounded number of times, and if it
  truly cannot come back the island says so instead of failing silently.
- **The island cannot take a key that was meant for somebody else.** Its panel keys — the
  arrows, the digits, Space and, on a list, the whole alphabet — are registered with Carbon,
  which takes them from every application at once. They were claimed on the strength of the
  panel being open, and a pinned panel does not activate its app: clicking the island left Mail
  frontmost with the insertion point still blinking in a half-written reply, and every letter
  typed next went into a find in the island instead of into the reply. Space stopped the music
  mid-bar; a 3 typed into a form jumped the switcher. Now the panel takes the keyboard when it
  is pinned, and the keys are only claimed while it is actually holding it. Key status is the
  system's own answer to who the keyboard belongs to, it is visible — the window behind dims —
  and when it goes, the claim goes with it in the same turn.
- **Now Playing recovers instead of going dark for good.** Health was a one-way latch: a backend
  that answered once kept the credit until the app was relaunched, so the moment MediaRemote went
  quiet — which is exactly how this breaks, on the point release that moves it — the card cleared,
  the fallbacks stayed shut behind it, and nothing said a word. Health lapses now, on recency.
  A helper that stops writing without exiting is caught by a watchdog rather than believed
  forever. Deaths are counted as a rate, not a lifetime total of five, so a helper that dies once
  a day no longer runs out after five days. A helper already replaced no longer clears the handle
  to its successor and leave it running unowned. And a helper that is answering but has nothing
  to report is no longer mistaken for a dead one, which had a perfectly working Mac firing
  AppleScript at Music and Spotify every two seconds forever.
- **The rail stops standing in front of the opening spring.** Mounting it ran a CoreAudio device
  enumeration, a DisplayServices read and both radios synchronously, at the exact moment the
  island began to grow — so the first hundred milliseconds of every open dropped frames and the
  spring looked like it started late. That work now lands after the first frames rather than in
  front of them, the display check is a stored answer instead of a fresh enumeration on every
  redraw of the rail, and the rail assembles itself silently instead of sliding sideways on top
  of the growth when its readings arrive.
- **Today stops waiting on somebody's mail server.** EventKit was queried on the thread that
  draws — from the section's `onAppear` and again every sixty seconds — and with a CalDAV or
  Exchange account that is a network fetch on the main thread. Ticking a reminder saved and then
  re-read the whole agenda, also on main, inside the button handler. All of it happens on a
  queue now, and a tick shows at once and is put back only if the save fails.
- **The reminder tick box can be hit.** A 14 pt circle in a 16 pt box, for an action that feels
  irreversible — under a third of the area Apple gives a checkbox. The target is 28 pt now,
  taken from the empty air beside it, and nothing drawn has moved.
- **A calendar row answers the keyboard.** It was a bare tap gesture, so VoiceOver read the
  event and then offered nothing to do about it, and Return did nothing. It is a real button.

- **The clipboard stops asking the disk how it should look.** A row said whether its copied files
  were still there by going and finding out, from inside the code that draws it — a `stat` per
  file, per row, on every hover and every scroll of a fifty-entry history, on the thread doing
  the drawing. The question is put once now, off that thread, when the history changes and when
  the section opens. A file that vanishes while the panel is already open goes unnoticed until
  the next sweep, which is a fair trade: the row is honest again a moment later.
- **The screenshot watcher stops walking the Desktop on the main thread.** Every app that saves a
  file to the folder being watched wakes it, and answering meant reading the whole directory and
  asking the file system about each entry — hundreds of calls for something that is usually not a
  capture at all. All of it happens on the watcher's own queue now, and the main thread is asked
  only for the two things that need it: putting the file on the shelf and raising the card.
- **A switch you have just thrown is answered at once.** Reading the radios on a queue meant a
  second reading asked for while one was in the air stood down — right, because two sets of
  round trips give one answer, but it stood down and forgot. The ask that matters most is the
  one straight after a switch is thrown or a network joined, and dropping it left the tick
  against the wrong row until the next poll came round, which on the network list is twelve
  seconds. An ask that arrives during a reading is handed back when it finishes; however many
  arrive, they are one ask between them.
- **The panel stops waiting for the radios.** Opening it ran a burst of blocking system calls on
  the main thread during the very spring that opens it — CoreWLAN and IOBluetooth both answer
  over XPC, which is to say in their own time — and then kept polling both on a 1.5-second main
  timer for as long as any panel was on screen, because the control rail is under every section.
  Every reading now happens on a queue of its own, one pass at a time, and only what is shown is
  decided on the main thread. Throwing a switch no longer waits on the radio with the pointer
  still down.
- **Keep Awake says when it cannot.** The rail's button lights from one flag and nothing else,
  so an assertion macOS turned down left the press with no light, no words and no reason — the
  same nothing as a button that was never pressed. A refusal is one of the ways a press can end,
  so it is said aloud like the other two, in a sentence rather than an error code.
- **The sliders can be moved without a pointer.** The volume and the brightness are drawn from
  shapes and driven by a drag, so VoiceOver could read "Volume, 40 percent" and then offer no way
  to change it. They are adjustable now, a notch at a time — the same sixteenth the volume keys
  use, so one control does not answer to two ideas of a step.
- **The island opens cleanly.** Five things were wrong with the growth out of the notch, and
  the worst of them meant a click-to-open never used the opening curve at all. Nested
  animations in SwiftUI are innermost-wins, and the press feedback sat *outside* the frame, so
  it governed the frame too — and because the press always ends in the very same instant the
  panel opens, every click morphed the whole island on the press release's spring, 0.3 s at
  bounce 0.3, with the scale springing over the top of it. Two overshoots at once, and an open
  that looked nothing like the one hovering gives you. The rest: the window was still
  notch-sized when the first frames of the growth were drawn, so the panel was guillotined by a
  hard rectangle and then the crop snapped away; the content was cut to a square while the body
  is a 36 pt continuous curve, so slivers of the switcher and the section escaped at both
  bottom corners and sat on the wallpaper; the shadow was handed the final height on frame one
  and bloomed to full window size under a notch that was still a notch; and the rim's fade was
  measured as a fraction of a height it had not reached, putting a bright hairline along the
  top row of the display for the first half of the move.
- **Opening the same panel twice looks the same both times.** Which way the last step went is
  what picks the spring and the transition, and only opening and collapsing cleared it. A
  hover exit goes through neither, so once you had stepped sideways in a peeked panel, every
  hover-open after that grew on the flat navigate spring and pushed its content in from the
  side instead of crossing over. It healed only when something was clicked.
- **Going to another app closes the panel.** It claims the whole alphabet as global hot keys
  while it is open — that is what makes type-to-find work — and a click outside was the only
  thing that closed it. Command-Tab makes no click, so the panel stayed open over Mail with
  every letter still claimed, and a reply typed there went into a find in the island instead
  of into the reply. Leaving for another app is leaving.

### Added
- **Every reading in Stats is a door.** The processor and the memory open Activity Monitor, the
  disk opens Storage, the network opens Network — the whole column is the target, the way a
  Control Centre module is, not a small chevron in the corner of it. A number you can only look
  at is a decoration: the section said the disk was 84% full and then left you to go and find
  the window that does something about it. A Mac with no battery keeps its em dash and stays a
  reading, because a button that goes nowhere is worse than no button.
- **How much is left in the headphones.** Every connected Bluetooth device on the Controls list
  now carries its charge beside its glyph, and a pair of buds shows the ear that will run out
  first, because that is the one that ends the listening. Under ten per cent it turns red — the
  keyboard that is going to die mid-sentence this afternoon is the only reading anybody needed
  to be told about. One walk of the registry answers for the whole list and it happens off the
  main thread, so the panel never waits for the radio.
- **Sound, as a third list in Controls.** Where the sound goes *and* where it comes from, on
  the panel: every output the Mac has, then every input, each headed and the live one ticked,
  so switching to the AirPods or off the wrong microphone is one click rather than a trip to
  System Settings. The header carries a mute — the thing Control Centre never gave anyone,
  which is why muting a Mac has always meant dragging the slider to nothing and guessing
  afterwards where it had been.
- **The clipboard remembers where a copy came from.** Whichever app was in front when the
  pasteboard changed is written on the row, above the age, and searched along with the words —
  because a list of fifty snippets is scanned by memory ("the link from Safari") far more often
  than it is read line by line. Never this app's own name: reading the pasteboard does not
  change it, but putting an entry back does, and the island must not sign its name to somebody
  else's snippet.
- **Tell me when it has had enough charge.** A laptop that lives on its charger sits at a
  hundred per cent, which is where a lithium battery ages fastest, and macOS will not say a
  word about it. Pick a mark in Activities — 70, 80, 85 or 90 — and the island says "Enough
  Charge" once per charge when the battery crosses it. Once, not every reading: it resets when
  the charger comes out.
- **Move to…, on the shelf.** The shelf is a staging post — things land on it on the way
  somewhere — and "somewhere" was the one verb it did not have. Right-click a selection, pick a
  folder, and the files go there and come off the shelf. A move, not a copy: leaving a second
  version behind is how a Downloads folder becomes what a Downloads folder becomes. A name
  that is taken gets a number rather than an overwrite, a file that will not move is left
  where it is *and* on the shelf so nothing is lost between the two, and nothing goes to the
  Trash on the way — the files are somewhere else now, not gone.
- **A sleep timer.** The thing everybody sets on a phone at night, on the Mac at last: right-
  click the island while something is playing and pick how long — fifteen minutes to an hour and
  a half — and the music stops at the end of it. It is a real countdown with a real card, so
  you can see how long is left, pause it, add a minute or cancel it; it just does not ring,
  because waking somebody to tell them the music has stopped is the opposite of what they
  asked for. One at a time, and `notchctl sleep 30` for a script.
- **A window tile has a menu.** Right-click one for everything the zones on it do, in words —
  and the two they cannot: hiding the app and quitting it, both named, so nobody quits
  something by reaching for a glyph. Nothing else on the Mac lets you quit an app from a
  picture of one of its windows.
- **Compress, on the shelf.** The one thing everybody does to a pile of files before sending
  them, and the reason half of those piles go to the Desktop first. Right-click a selection and
  the archive lands beside the files it was made from and on the shelf, ready to AirDrop —
  named after the file when there is one and after their folder when there are several, the way
  Finder names its own, and never over the top of the last one. Made with `ditto`, which is
  what Finder's own Compress uses, so resource forks and extended attributes survive. An
  archive somebody asked for is theirs: clearing the shelf lets go of it and never deletes it.
- **The rest of the day, along the floor of Today.** Six hours across the width of the section
  — the hour, what it is doing and how warm it will be — under the events and reminders. The
  space under three appointments was the emptiest part of the panel, and what happens next
  outside is the one thing a section called Today was missing. Two days are asked for now
  rather than one, because "the next six hours" at nine in the evening is tomorrow.
- **Where the sound comes from, as well as where it goes.** The rail's sound button lists both
  halves of Control Centre's Sound module now — Output, and Input where there is more than one
  to choose from. Which microphone the Mac is listening to is the setting nobody can reach
  without opening System Settings, and it is the one that matters in the half-second before a
  call starts.
- **Controls: the two lists Control Centre has and a row of toggles cannot.** A new section
  holding the networks in range and the devices this Mac is paired with, each under its own
  switch. Click a network you have joined before and it joins again; click one you have not and
  it opens the pane of System Settings that can ask for a password, because a panel that closes
  when the pointer leaves has no honest way to. Click a device and it connects or disconnects.
  The list is read from the system's own last scan rather than sweeping the band every time
  somebody opens a panel, with a fresh sweep when the section appears and every twelve seconds
  it stays there — and only while somebody is looking at it. The rail below keeps the one-click
  toggles it always had; what it could never carry, in thirty-point discs, is a list.
- **Put your headphones back on from the island.** A Bluetooth device's card carries Connect or
  Disconnect now, and the island's menu lists everything this Mac is paired with — connected
  ones first, with a tick — so reconnecting a pair of AirPods is one click instead of a trip to
  System Settings. Both calls block until the radio answers, which for a device asleep in a
  case is seconds, so neither happens on the main thread.
- **A script can put buttons on its activity.** Anything that can reach the URL scheme —
  Shortcuts, a CI hook, a shell script — can now hand the island up to two named buttons
  alongside what it is showing: `--action Retry --action-url https://ci/retry --action2 Deploy
  --action2-shortcut "Ship it"`. Each opens a web link or runs a Shortcut by name, which are
  the two things the script could already do for itself — the difference is that they are now
  offered where the person is looking rather than where the script is running. A button with
  no name, or with nowhere to go, is dropped rather than drawn as something that does nothing,
  and a button's link is held to the same three schemes every other link a script pushes is:
  a button that opened `file:` would be a way to make somebody click on something they were
  never shown.
- **A Home for the panel.** The panel opens on a grid of tiles now, the way Control Centre is
  arranged: what is playing takes a wide tile with its cover and a play button on it, and every
  other section is a tile beside it carrying its name and a glimpse of what is in it — the next
  thing in your day, how many files are on the shelf, the first line of your notes. Click one
  and it opens. A row of small glyphs beside the notch says a section exists; it does not say
  what is in it, and somebody who has just installed the app has no way of finding out. The
  switcher is still there for going straight somewhere, and Home is the first slot on it.
- **Walk the matches with the arrow keys.** Type-to-find is the rest of the way to Spotlight
  now: type, press ↑ or ↓ to move through what is left — wrapping at both ends the way a menu
  does — and Return takes the one you are on rather than always the first. The row it is on
  wears the same mark a picked one does, so you can see where you are before committing to it,
  and every keystroke starts the walk again at the top, because pointing at the fourth of two
  rows is not somewhere anybody asked to be. A list that shrinks under the mark brings it back
  to the last row there is rather than pointing past the end.
- **A QR code in a screenshot is a link you can press.** The same look that reads the words in
  a capture now finds a code in it, and the card offers to open where it goes — with the host
  written on the line under the title, because a button that opens a stranger's link without
  saying where it goes is a button nobody should press. Only `http` and `https`: a `tel:`, a
  `mailto:` or a configuration profile is not something to hand a click to.
- **Eject a disk from the island's menu.** Right-clicking the island offers Eject for whatever
  is attached — the disk by name where there is one, a list where there are several, with Eject
  All at the foot of it — so getting a drive out safely no longer depends on its card being up.
- **Pick out several windows and lay them out together.** Command-click window tiles the way
  you would rows in Finder — each one gets a tick and an accent border — and the header offers
  to tile them: two side by side, three across, four in quarters, and beyond that a grid as
  square as it will go, with a short last row sharing the width rather than leaving a hole.
  They all go on the screen the first of them is on, minimised ones come back to do it, and any
  window Accessibility cannot reach is skipped rather than abandoning the rest. A plain click
  still just brings a window forward, and clears the selection; a window that closes leaves it.
- **Put the sections in your own order.** The panel's sections have always come in the order
  they were written in. Home Panel lists them now, the way Control Center is arranged: drag a
  row and the section moves everywhere at once — the switcher, a sideways swipe, Tab, and the
  digit that reaches it. Each section's switch is on its own row beside its name and its glyph,
  so what a section is and whether you want it are one line rather than two lists. Now Playing
  can be moved like the rest but says "Always on" where its switch would be, because it is what
  the island is for. An order written by an older version never hides a section a newer one
  adds: anything the stored list does not mention keeps its place at the end.
- **Carry a file to a section instead of putting it down first.** The switcher's slots are
  spring-loaded, the way a Finder window's folders are: drag a file onto the island, rest it on
  a slot for a moment, and the panel goes there — so a file picked up anywhere can reach a
  quick action's tile or a window's tile without a round trip through the shelf. Passing over a
  slot on the way somewhere else does nothing; the slot lights up and grows while it is holding
  the drag, and the band names the section you are about to open. Dropping on a slot itself is
  a drop on the island, which means the shelf, the way it is anywhere else on the band. The
  island also stops counting a drag as having left the moment one of its own tiles takes it,
  which is what used to make the shelf's well blink out from under the hand that was over it.
- **The screenshot you just took, on the island.** A capture used to be a camera glyph and the
  words "On the shelf". It is a card now, with the picture itself on it — drag it from there
  into a message or a document and it never has to touch the Desktop — and the three things
  anybody wants: the picture on the pasteboard, the words in the picture on the pasteboard, and
  Open. The words come from Vision, read once while the card is on screen, and **Copy Text**
  appears only where there was something to find, so the card never offers what it cannot give.
  Captures are their own switch in Activities now rather than a side effect of the shelf: with
  the shelf off a screenshot is still announced, where it used to be silent, and the pill says
  what actually happened to it rather than claiming the shelf either way.
- **The island knows about your disks.** Plug an external drive in and its card arrives with
  its name, how full it is, and — where the Mac itself has never put one — an Eject button. The
  reason people yank a drive out is that ejecting it means hunting for its icon on a desktop
  buried under every window; here it is on the thing that just said the drive was ready. Pull
  one out properly and the island says "Safe to unplug"; pull one out early and it says so,
  quietly, instead of the dialog macOS throws. A drive that will not eject says what is true —
  something is still using it — rather than failing in silence. Right-clicking the island while
  a disk is showing offers Open and Eject too, and a Focus holds back the disk that arrives
  while never holding back the one that has gone. Switchable off in Activities.
- **Start typing to find something.** The four sections that are lists of many things —
  Windows, the Clipboard, the Shelf and Notifications — now answer the alphabet. Type on one
  while the panel is pinned open and a field opens with what you typed already in it, narrowing
  the list as you go: a window by its app's name or its title, a copy by its text, a file by its
  name, a banner by its app or its words. Return takes the one you are on — brings that window
  forward, puts that copy back on the pasteboard, opens that file — and Escape leaves the find
  without closing the panel. The letters are claimed from the system only on those four
  sections and handed straight back the moment a find begins, so the field itself is yours to
  type in; and what a key types is read from the layout that is switched on, so the first
  letter is the right one on a French keyboard as much as an American one. There is a
  magnifying glass in each of those headers for the people who would rather click, and the
  clipboard's own search field is that glass now — which also gives that section back the
  arrows, the digits and Space it used to hold onto for a field nobody was typing in.
- **Drop a file on a window tile to open it in that app.** The same thing as dropping it on
  the app's Dock icon, except in front of the window you want it in — and it needs no
  permission at all.
- **Drop a file on a quick action to run the shortcut with it.** The Actions row is a rack of
  droplets now: drag a file onto a tile and the shortcut runs with that file as its input,
  once per file, under one activity. While either of those two sections is on screen a drag
  leaves it alone rather than turning the panel into the shelf's drop well, so a file can
  actually reach a tile; anywhere else on the island a drop still goes to the shelf.
- **A Focus quietens the island.** While one is on, the alerts that arrive on their own are
  held back: a finished download, a device connecting, an event coming up, an alert a script
  pushed, the charger going in. Everything you did yourself still shows — a key, a click, a
  screenshot, a shortcut you ran — and so do a call and a battery that is nearly flat, because
  a Focus is a request not to be disturbed rather than a request to be allowed to run out.
  Switchable off in Activities.
- **Send a window to the next display.** Every zone on a tile rearranged a window on the
  screen it was already on. Where there is more than one display, a tile now offers the move
  the zones could not make, and the window keeps the share of the screen it had — a half stays
  a half, a small window stays small, and nothing arrives hanging off an edge.
- **Another minute.** The thing everybody asks a smart speaker for, and the one thing a
  running countdown could not be told: a `+` on the timer's card, "Add a Minute" in the
  island's menu, and `notchctl timer add`. The total moves out with the end, so the ring keeps
  meaning how much of *this* timer is left rather than jumping backwards. A timer that has
  already rung is not extended — there is nothing left to add to, and Repeat is there instead.
- **Minimise a window from its tile.** Every zone on a window tile moved it somewhere on this
  screen; sometimes where you want it is off the screen. A tile now has both of the corner
  buttons a real window has, in the corners the real ones are in: put it away on the left,
  close it on the right.
- **Right-click the island for its menu.** The island is the app's face and answered nothing
  but a left click. It now leads with whatever it is showing — pause and skip a track, pause
  or cancel the timer, lap the stopwatch, AirDrop the shelf, open the app that is on a call —
  and then offers what is worth having where the pointer already is: Keep Awake, Clear Shelf,
  hiding the island for an hour (or showing it again), Settings and Quit. The panel was
  already being held open for a menu that had never been written; this is that menu. A shelf
  tile's own menu still wins over it.
- **Drag a clipboard entry straight into a document.** Clicking one puts it back on the
  pasteboard; dragging one takes it where you are pointing — the text, the link, the file
  itself or the picture. Only rows with something behind them get the gesture, so a drag never
  starts and then carries nothing.
- **Hold Option while scrolling on the island for the brightness.** A scroll has always been
  the volume; with Option held it is the display instead — the rail's two sliders, without
  opening the panel. It reads the display once when the gesture starts and carries it from
  there, shows the same heads-up display a volume scroll does, and leaves a Mac whose display
  will not say what it is set to on the volume. A section that scrolls by itself still keeps
  its own scroll, whichever key is held.
- **Where the sound is going moved to the control rail.** The output picker was in the Now
  Playing header, which meant it existed only while something was playing and only on that one
  section — and switching to headphones is not something you only want to do mid-track. It is
  on the rail now, under every section, and it appears as soon as there is more than one place
  the sound could go. One control, not two.
- **The panel answers the keyboard.** While it is pinned open — and with nothing held down —
  ← and → step between views the way a sideways swipe does, 1 to 9 go straight to a slot of
  the switcher, Space plays and pauses what is playing, and ↑ and ↓ move the volume, which is
  the keyboard's version of a scroll on the island. The island never takes focus to do it: the
  keys are claimed from the system only while the panel is open, and handed straight back. It
  claims nothing at all while Notes or the clipboard search is showing, where every key is
  yours to type, and there is a switch for it in Settings under Island. Resting the pointer on
  a slot of the switcher shows its number beside its name while the digits are live, so the
  way to reach it is written where you are already looking. On the shelf, Space is Quick Look — where every Mac has taught people to expect it — rather than play and pause. Escape now closes the
  panel whether or not the summon shortcut is switched on.
- `notchctl stopwatch [lap|stop|reset]`, `notchctl timer pomodoro` and `notchctl home
  windows` — all three have been in the URL scheme since the features themselves were, and
  the command-line helper had never wrapped them.
- **Windows.** A section that shows every open window as a live tile: click one to bring it
  forward, or use the zones that appear on it to send it to a half of the screen, fill the
  screen, centre it, or close it. The pictures come from ScreenCaptureKit and the moving from
  Accessibility; without those permissions the windows are still listed by app, and the
  section says what is missing and opens the right pane of System Settings.
- Wi-Fi, Bluetooth and light/dark in the control rail, under every section.
- The shelf takes more than files: drag a picture, a link or a piece of selected text onto
  the island and it becomes a file on the shelf — a PNG, a `.webloc` Finder can open, or a
  text file named after its first line. Anything the island wrote itself goes to the Trash
  when it leaves the shelf; a file that came from Finder is never touched.
- Dragging off the shelf takes the whole selection at once, as one pile, and a Quick Look
  button on each tile (and in its menu) previews without opening anything.
- Favourite apps in the Actions section: up to six sit in front of your Shortcuts, and a click
  opens one and closes the panel. Chosen in Settings under Actions.
- Picking a clipboard item pastes it where you were typing: the panel closes, the keyboard
  goes back to the app in front, and ⌘V follows. Switchable off in the Home Panel settings,
  and it falls back to putting the item on the pasteboard when Accessibility is not granted.
- The switcher band names what the pointer is on, in the space left of the cutout, so the row
  of glyphs teaches itself.
- Stats shows disk usage, and the processor and network draw their recent history.
- Album art for players that hand over none. A browser or a podcast app leaves the cover
  empty, so the track is looked up by name and the cover comes from there; the cover then
  washes into the black behind Now Playing, the way the phone does it. Switchable off in
  Activities, and nothing but the title, artist and album is ever sent.

### Fixed
- **A file the Trash would not take says so.** "Move to Trash" removed the tile and left the
  file where it was when macOS refused — locked, on a read-only volume — with only a line in
  the log. The menu item is also "Remove from Shelf" now, so it is not a bare "Remove" next
  to "Move to Trash", which read as a choice between two kinds of deleting.
- **The card for a timer that rang names the timer.** It said "Timer done" and dropped the
  name you gave it — and several timers can run at once, so which one rang is the only thing
  the card had to say. VoiceOver had been saying "Pasta timer done" all along; the card now
  agrees with it. A paused timer keeps its name too.
- **`notchisland://settings/actions` opens the Actions pane.** Inside the app that pane is
  called `shortcuts`, and the URL scheme only answered to that — but somebody writing a URL
  is reading the sidebar, where it says Actions. Every pane now answers to the name on the
  screen as well as the one in the code.
- **AirDrop that cannot run says why.** The AirDrop button on the rail returned in silence
  when macOS said it could not send — which is what it says with Wi-Fi or Bluetooth off. Both
  of those switches are on the same rail, and it now points at them.
- **A quick action with nothing to run it says so, and the same name is never listed twice.**
  Running a shortcut when `/usr/bin/shortcuts` is missing returned without a word — a button
  in the panel that did nothing at all — and the Actions pane blamed the empty list on there
  being no shortcuts rather than on nothing being able to list them. And because a shortcut's
  name is its identity everywhere, two of them with the same name were two rows nothing could
  tell apart.
- **The disk image says what to do about the first launch.** Every build is signed ad-hoc
  rather than notarized, so macOS refuses to open it the first time, and since macOS 15
  right-click and Open no longer gets past that. The note is in the disk image now, where
  somebody who has just double-clicked the app is actually looking.
- **Weather that has been refused your location says so.** Turning "Weather in Today" on and
  then refusing the location prompt left the line simply absent, which is indistinguishable
  from a switch that does not work. Today's header now offers "Allow Location", the same way
  the Windows section offers the permissions it needs. The temperature and the conditions are
  also separated by the same middle dot the rest of the app uses, rather than two spaces.
- **Privacy lists Reminders and Notifications, which the app asks for and the list left out.**
  Today reads two things from EventKit and macOS grants them separately, and a timer that goes
  off while the island is hidden asks to post a banner; the screen whose whole purpose is to
  say what Notch Island asks of this Mac named none of those. The prompts macOS shows also referred
  to a "Weather tab" and a "Mirror tab", neither of which the app has ever had — they are the
  weather line in Today and the mirror in the control rail.
- **Clearing the scratchpad can be taken back.** "Clear" emptied a note somebody may have
  been keeping for weeks, with no confirmation and no way back — and the panel closes the
  moment you look away, so there was nowhere to put a warning either. For twelve seconds
  after a Clear the button becomes "Undo Clear", and only while the scratchpad is still
  empty, so it can never overwrite something typed since.
- **A drop that comes to nothing says so.** A drag can advertise a kind of content and then
  refuse to hand it over. The island lit up for it, took the drop, and then nothing appeared
  on the shelf and nothing was said — the highlight simply went out. It now says "Nothing to
  keep" and why.
- **A volume key that cannot be answered now says why.** Some outputs — HDMI, a few AirPlay
  targets — carry the sound at whatever level the thing at the other end is set to, and the
  pill answered that key press with an em dash. A dash means "no number", not "not from here",
  so the press still looked broken. It says "Set on the device", or "Set on the display" for
  brightness — the same words the banner uses, from one definition — and falls back to the
  dash only when the menu bar leaves no room for words.
- **Settings rows that named their own section, and a section that named the wrong thing.**
  General's "Appearance" held "Show on all displays" and "Hide in full-screen apps": one says
  where the island is drawn, the other says when it is not drawn at all, and neither is an
  appearance — and the footer under them explained only the second. They are now "Displays"
  and "Hiding", the latter next to the list of apps that hide it. In Activities, the switch at
  the top of "Now Playing" was called "Now Playing", the one under "Privacy indicators" was
  called "Microphone and camera indicators", and the one under "Volume and brightness" was
  called "Show volume and brightness in the island"; each now says what it does instead of
  repeating the heading above it. On Island, two switches were near enough the same sentence —
  "Open when the pointer rests on the island" and "Open the panel when the empty island is
  hovered" — and the second is now "Open from the empty notch too", which is what it means.
- **The tour's seventh choice was not really being offered.** Three of the seven descriptions
  on "Choose What It Shows" ran to two lines, which pushed the last one — volume and
  brightness, the choice that changes the most about the app — under the bottom of the list.
  The list scrolls, but a Mac with overlay scrollbars shows nothing there until somebody
  happens to scroll, so most people would never have seen it. Every description is one line
  now, all seven are on the screen at once, and a test holds them to it.
- **Two rows that did not line up.** In Stats, the battery's meter sat thirteen points above
  the memory and disk meters beside it: the footers were pushed against the floor of each
  column, and the battery is the one column with two lines of small print under its bar, so
  the extra line lifted the bar instead of hanging below it. Every meter now starts at the
  same height. In Windows, four tiles stopped fifty points short of the right edge — the edge
  the header's "4 open" is aligned to — so a full row read as a row that had come up short;
  four tiles and their gaps now fill the section exactly.
- **The scratchpad and the clipboard history are written before the app goes away.** Both are
  saved eight tenths of a second after they change, and a quit from the menu bar is quicker
  than that — so the last sentence somebody typed, and the last thing they copied, were the
  two things they could lose. Nothing waits for a debounce on the way out now: quitting, a
  `kill`, a log out, a restart and going to sleep all write first.
- **Three alerts that had nothing to say now say it.** A custom activity draws an ellipsis in
  the pill when it carries no trailing value, and three of the app's own alerts were relying
  on a title the pill has no room for. Running a Shortcut showed a green tick beside an
  ellipsis instead of "Done", and — worse — a failed one showed a red cross beside an
  ellipsis while the reason the Shortcuts app gave went nowhere at all; a failure now opens as
  the card, names the shortcut, and stays long enough to read the reason. A screenshot says
  "On the shelf", and copied diagnostics say "Copied".
- **"Check for Updates…" no longer says "Up to date" when it could not ask.** A Mac with no
  network, or GitHub answering 403, took the same branch as a successful check and got the
  green tick — the one thing a check like this must never get wrong. There are now three
  answers: the update, "Up to date" (which includes GitHub replying that nothing is published
  yet), and "Couldn't check for updates" with the reason and a way to the releases page. A
  failed check is also no longer recorded as a check, so the next one is an hour away rather
  than a day; and both answers to a manual check open as the card, since "Up to date" as the
  pill was a green tick beside an ellipsis. About now says where the last check got to —
  "Checking…", the version, or the reason it could not be made — so the button answers on the
  screen it is on, and not only on an island that may be hidden or unwatched.
- **What Notch Island keeps on this Mac is yours alone.** Everything you have copied, the
  notes you jot down and the lyrics it caches were written with whatever permissions the
  system happened to hand out — 644 on a stock Mac, which is readable by every other account
  on a shared one. They and the folder around them now belong to the account that wrote them.
  The shelf's dropped files moved in beside them: they were going to a *second* Application
  Support folder, with a space in its name, so deleting the one named after the app left them
  behind. Anything already in the old folder is still recognised as the app's to tidy up.
- **The Privacy pane names what leaves this Mac, one thing at a time.** It used to end with
  "Nothing Notch Island reads ever leaves your Mac", which was not true of the four features
  that ask somebody else a question — the weather, lyrics, a missing cover, and the update
  check. Each is listed now with what it sends, who it asks, and whether it is switched on at
  this moment. A blanket promise is the worst thing to be wrong about on the screen people
  come to in order to check.
- Unlocking the Mac says "Unlocked". The island's compact state is two slots with the camera
  between them, and that one filled only the first, so it came out of the notch as a single
  lock at one end of a long black bar with a void after it. Every other alert made of words
  answers with one on that side.
- **A new Mac is not asked for the calendar before it has been told what this is.** Starting
  the calendar asks macOS for access, and that sheet was the first thing Notch Island put on a
  new machine — ahead of the window that introduces the app, and ahead of the page where Today
  is offered as a switch. It waits for the tour now.
- Running the test suite no longer leaves anything behind on the machine that ran it. The
  writers that turn a dropped picture, link or piece of text into a file are static and put it
  where the app really puts it — which is the point of testing them — and every run added
  another handful to the app's own folder, under a comment saying it touched nothing. And
  rendering the gallery, which borrows the notes and the clipboard history to draw them, wrote
  over both: somebody looking at a change on their own Mac found their scratchpad replaced by
  the sample text.
- **The welcome tour's Done button fits in its window.** The second page — seven things to
  switch on, with a line of explanation each — was taller than the fixed height it was drawn
  in, and the root view clipped: "Done" and "Open at login" were both under the bottom edge of
  the first window a new Mac shows. The choices scroll now if they have to, and the button
  below them stays where it is.
- Weather in Britain reads in Celsius. `Locale.MeasurementSystem` has three cases and only
  one of them is `.metric`; the United Kingdom is its own, and takes its temperature in
  Celsius and its speed in miles per hour. One flag answered both questions, so every reader
  there was shown Fahrenheit.
- A copy stamped `org.nspasteboard.AutoGeneratedType` is no longer recorded in the clipboard
  history. That is the third of the three stamps the convention defines — a copy made by a
  tool rather than by a person — and only two of them were being honoured.
- **The island casts a shadow.** Nothing in the app did, so a black panel over a wallpaper was
  not a surface in front of the screen, it was a hole cut out of it — the one thing every
  floating surface in macOS has and this had none of. It is sized to what casts it, so the
  compact pill lies close to the menu bar and the panel stands off the desktop; a notched
  island at rest still has none, since there it *is* the notch and a shadow would print a halo
  around a camera housing that has never cast one.
- The hairline along the island's edges is now a line you can see. At a tenth of white it
  measured 34 against a menu bar of 20 — present in the code and absent on a dark desktop,
  which is the one place it exists for. The floating pill and the bubble, whose top edge is
  their own, are lit brighter along it and settle down their sides.
- The shelf's drop zone is tinted and solid, the way the system marks a destination that will
  take what you are holding, instead of the grey dashed rectangle that marks one nowhere in
  macOS.
- Names sit under the middle of the thing they name, on the shelf's tiles and in the Actions
  row. Hung from the same leading edge as a picture wider or narrower than they are, they
  landed off it by a different few points for every name.
- The button that closes the panel moved to the leading edge of the band, where every window
  on the Mac keeps it. At the far end it left the whole left of the band empty whenever
  nothing was live, with every glyph in the panel crowded into the right third.
- A file on the shelf shows its name over two lines, the way Finder's icon view does, so one
  screenshot can be told from the next.
- The switcher band no longer names the section you are already looking at. Clicking a slot
  leaves the pointer on it, so the name you had just chosen was printed twice on one screen —
  once in the band and once in that section's own header — for as long as your hand stayed
  still.
- One AirDrop control per screen. The control rail's stood beside the Shelf section's own,
  under the same name and the same glyph, and sent everything where the section's sends what
  you have selected. It stands down on that section and stays everywhere else, which is what
  it is for. While there: the rail's buttons slide over when one of them comes or goes rather
  than jumping, which they also do when a Mac has no Wi-Fi or no Bluetooth to offer.
- **Settings opens.** It did not. Every way in — the rail's gear, the menu bar item, both
  buttons in the Actions section — asked SwiftUI's `Settings` scene for its window through the
  undocumented selector that scene installs, and on an app with no Dock icon that selector
  reports success and makes no window. Nothing said so, because nothing looked. The window is
  built and shown directly now, the way the welcome tour's always has been, through one place
  that every way in goes through. The URL scheme takes a pane too:
  `notchisland://settings/island`. Two things that could only be seen once it opened: the
  window landed with a fifth of itself past the right edge of a small screen, and the sidebar
  showed "Privacy &…".
- Settings' picker for the apps that hide the island can no longer open behind whatever is in
  front. Notch Island runs as an accessory and is not necessarily the active app when a button
  in its own window is clicked; the Actions pane's picker already asked first.
- The Home Panel pane said the control rail always holds eight things. It holds four always,
  three when the Mac has the hardware for them, and AirDrop when there is something on the
  shelf and you are not already looking at it.
- Settings' Island pane had its keyboard shortcuts listed at the top and the control that
  sets them at the bottom, with two unrelated sections in between, and the list told you to
  change the shortcut "under Actions", where there has never been anything to change it with.
  One section now, and it lists the shortcuts only while they exist: switching the keyboard
  off takes all of them away together, since they are registered off the one combination.
- The Mac's appearance is read from AppKit rather than from a cached copy of a defaults key
  that carries no promise of being fresh at the one instant it is asked about — the instant it
  changes. A Wi-Fi switch the system refuses now says no straight away instead of showing what
  was asked for and sliding back on its own a couple of seconds later.
- The empty Actions section offered the same pane of Settings twice, once in its header and
  once in its body. The stopwatch's card follows the timer card's rule for colour — the
  activity's own for what it does next, white for the one that ends it — and puts them in
  that order whichever state it is in.
- **One display for one key press.** With the system bezel replaced, a key the Mac cannot
  answer — an HDMI output with no level of its own, a Mac driving only external displays —
  now goes back to macOS, which still has a bezel for it, rather than being swallowed into
  silence. Whichever hand answers it, the level is set and something is said: a key that
  cannot be answered at all reports that it cannot, and names the output. Switching a display
  off in Activities hands that key back too, so macOS's own bezel returns instead of nothing
  at all.
- The volume display names where the sound is going — the one thing the system's bezel never
  says, and the answer to "why is nothing getting louder" when the AirPods are on the desk.
  It also keeps the click macOS plays, under the Sound setting and with the same Shift
  gesture, and honours the quarter-notch Shift-Option step.
- The island's edge on a dark desktop. macOS draws the menu bar nearly black there, and the
  island dissolved into it: what was in it read as marks floating in a void. It now carries a
  hairline of light along the three edges it really has — never across the top, which is the
  screen's own edge — and none at all at rest, where the island *is* the notch.
- A paused track, or a Mac on battery with animation stopped, showed four bars of one height:
  four dots, not a waveform. The bars now hold the shape of a wave when nothing is driving
  them.
- Three places kept the shape of a camera housing on screens that have none. The compact
  island reserved its width between the two slots, so the floating pill was a long black bar
  with a mark at either end; a card reserved its height above the content, so the card had a
  hole in the top of it; and the switcher band split itself down the middle around it, so
  with nothing live every glyph sat right of centre.
- The support report collects everything the app logged. Half of it went through `NSLog`,
  which stamps no subsystem, and the report asked the unified log for the app's subsystem —
  so the failures it was collected to explain were the ones missing from it.
- The shelf forgets a file that was deleted or moved, but keeps one whose whole folder has
  gone: an unplugged disk no longer empties the shelf.
- With items selected, the shelf's last pill removes those instead of clearing everything.
- Stepping to the next section no longer rebuilds the whole panel. The switcher band and the
  control rail stay where they are and only the section between them moves; the rail's audio
  listeners are no longer dropped and rebuilt on every step.
- Sliders keep the value the user set. CoreAudio and DisplayServices report back a moment
  late, so the fill used to run backwards under the pointer and snap back on release. A drag
  now also holds the panel open, so running past the end of the track no longer closes what
  is being adjusted — the same for the Now Playing scrubber, which no longer jumps back to
  where the track was before the seek.
- The rail's brightness slider follows the brightness keys instead of showing whatever it
  read when it appeared, and dragging the volume up on a muted Mac unmutes it.
- The island holds its place when windows are moved about: it reclaims the top of the window
  order whenever an app is activated or launched, or a Space changes, and the menu bar now
  has to move by more than a hair before the island resizes for it.

- The island's window could never become key, so nothing in it could be typed into. It now
  takes key status only while Notes or the clipboard search is showing, and hands it back
  the moment that section goes or the panel closes.
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
  in their place is a single 720 pt panel with a switcher in the band beside the notch (live
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
- Sections: Today (the rest of today's events, today's open reminders with a checkbox, the
  weather in the header), Notes (a scratchpad kept on disk), and Stats beside the shelf,
  clipboard and actions. Now Playing is a section too, so it is reachable while anything
  else is live. The list is one enum, `HomeSection`, read by the switcher, the keyboard
  ring, the swipes, the URL scheme (`notchisland://home/notes`) and Settings.
- Sneak peek: a track that starts widens the pill for a moment with its title and artist.
- Output picker under Now Playing, backed by CoreAudio: the devices that can play, the one
  that is, and a live volume slider that follows it.
- Clipboard search: a field in the section's header filters the history as you type.
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
