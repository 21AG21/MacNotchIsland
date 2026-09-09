# Changelog

All notable changes to Notch Island. Versions follow the app's `CFBundleShortVersionString`;
the unreleased section is what the next tag will ship.

## Unreleased

### Added
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
  yours to type, and there is a switch for it in Settings under Island. On the shelf, Space is
  Quick Look — where every Mac has taught people to expect it — rather than play and pause. Escape now closes the
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
- Sections: Today (the next 24 hours of events, today's reminders with a checkbox, the
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
