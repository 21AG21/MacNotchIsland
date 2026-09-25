import Foundation
import Combine

/// Starts and stops every monitor according to preferences.
final class ServiceHub {
    let nowPlaying = NowPlayingService.shared
    let battery = BatteryMonitor()
    let bluetooth = BluetoothMonitor()
    let audio = AudioMonitor()
    let brightness = BrightnessMonitor()
    let camera = CameraMonitor()
    let calls = CallDetector.shared
    let focus = FocusMonitor()
    let calendar = CalendarMonitor()
    let screenLock = ScreenLockMonitor()
    let downloads = DownloadMonitor()
    let volumes = VolumeMonitor.shared
    let lowPower = LowPowerMonitor()
    let hotkey = HotKeyService.shared
    let clipboard = ClipboardStore.shared
    let notifications = NotificationWatcher()
    let lyrics = LyricsService.shared
    let mediaKeys = MediaKeyInterceptor()
    let capsLock = CapsLockMonitor()
    let energy = EnergyPolicy.shared
    let updates = UpdateChecker.shared
    let fullscreen = FullscreenMonitor()
    let hiddenApps = HiddenAppsMonitor()
    let screenshots = ScreenshotMonitor()
    let audioLevel = AudioLevelTap.shared
    let menuBar = MenuBarClearance.shared

    private var cancellables = Set<AnyCancellable>()
    private var requestedShortcuts = false
    private var warmedToggles = false

    func start() {
        energy.start()
        // The keyboard's backlight is warmed here rather than the first time the panel opens:
        // opening CoreBrightness and asking its client which keyboards it has is a one-time
        // cost, and the rail asks whether there is one. The rail's radio switches are warmed
        // in `apply()`, once the tour is done, see `warmsToggles`.
        _ = KeyboardLight.shared
        apply()
        LiveActivityAPI.shared.start()
        // The alarms the last run left waiting. Here, with the other things kept between
        // launches, once the copy being replaced has gone and cannot write over them.
        IslandTimer.shared.restoreAlarms()
        Preferences.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
        // Whether there is a backlight decides whether its keys are a reason for the tap, so a
        // change in it is re-applied the way a preference change is. Only a change: the value
        // it starts with is the one `apply()` above has already read. Debounced onto the main
        // run loop for the same reason as the preferences — `@Published` announces a value
        // before it is stored, and `apply()` reads the stored one.
        KeyboardLight.shared.$isAvailable
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
    }

    /// Whether the battery monitor runs — and so whether "Tell me at" can say anything, since
    /// the charge mark is read by that monitor as the level climbs and by nothing else.
    ///
    /// Here rather than inline for that second half. The menu sat under Downloads, a section
    /// away from "Battery and charging", and stayed live with it off: a figure on the screen
    /// that nothing read. Activities greys the menu out by this, the same rule that starts the
    /// monitor, so the two cannot disagree.
    ///
    /// And only where there is a battery. On a Mac mini or an iMac both stayed live — a switch
    /// and a menu for a charge nobody has — so the pane greys them out by the same answer.
    /// `hasBattery` is passed in by the tests; everywhere else it is this Mac's.
    static func wantsBattery(_ p: Preferences, hasBattery: Bool = ServiceHub.hasBattery) -> Bool {
        p.batteryEnabled && hasBattery
    }

    /// Whether this Mac has an internal battery. Read once: nobody adds one to a running Mac.
    static let hasBattery = BatteryMonitor.internalBatteryDescription() != nil

    /// Whether the Bluetooth monitor may run, which is the same as whether macOS may be asked
    /// for Bluetooth.
    ///
    /// Held until the tour has been through, for the calendar's reason. It ships on, and the
    /// first thing it does is register with IOBluetooth, which is what asks — so the Bluetooth
    /// sheet was a new Mac's first sight of the app, ahead of the window that says what it is.
    static func wantsBluetooth(_ p: Preferences) -> Bool {
        p.bluetoothEnabled && p.hasSeenWelcome
    }

    /// Whether the rail's switches may be read ahead of the panel opening. Reading them asks
    /// IOBluetooth whether the radio is on, and that asks macOS for Bluetooth — so the same
    /// wait as the monitor, and for the same reason. Pure, beside the rule it follows.
    static func warmsToggles(_ p: Preferences) -> Bool {
        p.hasSeenWelcome
    }

    /// Whether the calendar may run, which is the same as whether macOS may be asked for it.
    ///
    /// Held until the tour has been through. Starting it asks for the calendar, and that sheet
    /// was the first thing a new Mac saw of Notch Island — ahead of the window that introduces
    /// the app, and ahead of the page where Today is offered as a switch. Asking for something
    /// a moment before offering to ask properly is the wrong way round. The hub re-applies on
    /// every preference change, and finishing the tour is one.
    static func wantsCalendar(_ p: Preferences) -> Bool {
        p.calendarEnabled && p.hasSeenWelcome
    }

    /// Whether the folder watchers may run: Downloads, and wherever screenshots are saved.
    ///
    /// Held until the tour has been through, for the calendar's reason. Both are folders macOS
    /// guards, so starting either asks for it, and a new Mac's first sight of the app was two
    /// folder prompts arriving a moment ahead of the window that says what the app is — easy
    /// to refuse, and a refusal leaves the download and screenshot cards dead with nothing to
    /// say so. After the tour the question comes from an app that has introduced itself.
    static func wantsDownloads(_ p: Preferences) -> Bool {
        p.downloadsEnabled && p.hasSeenWelcome
    }

    static func wantsScreenshots(_ p: Preferences) -> Bool {
        p.screenshotsEnabled && p.hasSeenWelcome
    }

    /// Whether the banners on screen may be read, which is the same as whether anything at all
    /// about the notification history happens.
    ///
    /// The switch is the whole rule, and it is here rather than inline so that there is one
    /// place that decides it and one place to read to be sure. This is the feature that writes
    /// down what somebody's messages said: nothing may start it because a section was opened,
    /// because a permission happens to be granted, or because some other switch implies it.
    static func wantsNotifications(_ p: Preferences) -> Bool {
        p.notificationsEnabled
    }

    /// Whether the media-key tap is worth having: the bezel is being replaced and at least one
    /// of the displays it would raise is switched on. The keyboard's counts, so a Mac that wants
    /// only the backlight keys answered still gets them — but only on a Mac that has a backlight
    /// to set. Without one its keys stay macOS's and its switch is greyed out, so it cannot be
    /// the reason for a tap, or for an Accessibility prompt, that nobody could switch off.
    /// `backlightAvailable` is `KeyboardLight.shared.isAvailable`, passed in so the rule stays
    /// pure.
    static func wantsMediaKeys(_ p: Preferences, backlightAvailable: Bool) -> Bool {
        p.hudReplacementEnabled
            && (p.volumeHUDEnabled || p.brightnessHUDEnabled || (p.keyboardLightHUDEnabled && backlightAvailable))
    }

    /// Whether calls are followed at all: for the call card, or for "Only during calls" in
    /// Privacy, which hides the island from a screen share for the length of one.
    ///
    /// Two switches in two panes, and the second used to ride on the first: with Calls off in
    /// Activities nothing watched for a call, so the promise to hide the island during one hid it
    /// during nothing, and said nothing about it. The screen-sharing half counts only in the one
    /// arrangement where `NotchPanel.sharesScreen` asks whether there is a call — hidden during
    /// calls and not always. The card stays the Calls switch's alone: `CallDetector.showsCard`.
    static func wantsCallDetector(_ p: Preferences) -> Bool {
        p.callDetectionEnabled || (p.hideFromScreenSharingDuringCalls && !p.hiddenFromScreenSharing)
    }

    /// Whether the full-screen watch runs: the switch, and only the switch. What it starts at
    /// is where the fault was. It shipped off everywhere, so on a Mac without a notch the watch
    /// never ran and the pill — at the main menu's level, and in every full-screen Space —
    /// stayed over every full-screen film. Until it is set it now follows the island, on where
    /// the island floats (`FloatingDefaults.hidesInFullScreen`), and the rule here is as it was.
    static func wantsFullscreen(_ p: Preferences) -> Bool {
        p.hideInFullscreen
    }

    private func apply() {
        let p = Preferences.shared
        p.nowPlayingEnabled ? nowPlaying.start() : nowPlaying.stop()
        Self.wantsBattery(p) ? battery.start() : battery.stop()
        Self.wantsBluetooth(p) ? bluetooth.start() : bluetooth.stop()
        // Warmed once, after the tour, rather than the first time the panel opens. Its first
        // reading builds a CoreWLAN client and talks to the Wi-Fi daemon, and the first time
        // anything asks for it is when the rail is mounted — during the spring that opens the
        // panel. It used to be warmed at launch, which put its Bluetooth question ahead of the tour.
        if Self.warmsToggles(p), !warmedToggles {
            warmedToggles = true
            _ = SystemToggles.shared
        }
        // The audio monitor feeds the volume display, the silent-mode alert, the microphone
        // indicator and call detection — but the first two only exist while the island is the
        // one answering the media keys, so on their own they are not a reason to listen.
        let showsVolume = p.hudReplacementEnabled && p.volumeHUDEnabled
        (showsVolume || p.privacyIndicatorsEnabled || Self.wantsCallDetector(p)) ? audio.start() : audio.stop()
        // The brightness monitor exists only to raise that display, and polls a private
        // display call to do it — every two seconds, and not at all while macOS has the keys.
        // With the island not answering the keys there is nothing for it to raise, so it does
        // not run at all.
        (p.hudReplacementEnabled && p.brightnessHUDEnabled) ? brightness.start() : brightness.stop()
        p.privacyIndicatorsEnabled ? camera.start() : camera.stop()
        calls.showsCard = p.callDetectionEnabled
        Self.wantsCallDetector(p) ? calls.start(following: audio) : calls.stop()
        // Always watching, whatever the Focus switch says: whether a Focus is on is read by
        // more than its alerts — the rail's Focus button, the queue that holds alerts back —
        // and a watch on one folder costs nothing until it changes. The switch decides only
        // whether a change is announced; turning it off no longer makes a Focus read as off.
        focus.alertsEnabled = p.focusEnabled
        focus.start()
        Self.wantsCalendar(p) ? calendar.start() : calendar.stop()
        p.unlockEnabled ? screenLock.start() : screenLock.stop()
        Self.wantsDownloads(p) ? downloads.start() : downloads.stop()
        p.drivesEnabled ? volumes.start() : volumes.stop()
        p.lowPowerEnabled ? lowPower.start() : lowPower.stop()
        // Always installed, whatever the two keyboard switches say: Escape closes whatever is
        // open with both of them off — the Island pane promises it — and it is only ever
        // claimed while something is. The summon combination is registered only while its
        // switch is on, and the panel's own keys only while theirs is.
        hotkey.start()
        // Which of those keys are claimed depends on the switch and on the section the panel
        // is on, so it is re-read whenever a preference changes.
        ActivityCenter.shared.refreshPanelKeys()
        p.keepClearOfMenuBar ? menuBar.start() : menuBar.stop()
        // The shelf is loaded lazily; touching it here puts files kept from last time back
        // on the island at launch, and drops the activity when the shelf is switched off.
        ShelfStore.shared.refreshActivity()
        p.clipboardEnabled ? clipboard.start() : clipboard.stop()
        // Switched off, the watcher's thread is not merely idle: it is not there at all, and
        // nothing has looked at Notification Centre.
        Self.wantsNotifications(p) ? notifications.start() : notifications.stop()
        (p.nowPlayingEnabled && p.lyricsEnabled) ? lyrics.start() : lyrics.stop()
        // With every display switched off there is no key left for the island to take, and
        // an event tap that swallows nothing is not worth asking anyone for Accessibility.
        Self.wantsMediaKeys(p, backlightAvailable: KeyboardLight.shared.isAvailable) ? mediaKeys.start() : mediaKeys.stop()
        p.capsLockEnabled ? capsLock.start() : capsLock.stop()
        if p.quickActionsEnabled && !requestedShortcuts {
            requestedShortcuts = true
            ShortcutsRunner.shared.refresh()
        }
        p.updateChecksEnabled ? updates.start() : updates.stop()
        Self.wantsFullscreen(p) ? fullscreen.start() : fullscreen.stop()
        p.hiddenAppBundleIDs.isEmpty ? hiddenApps.stop() : hiddenApps.start()
        // The card is the feature now, and the shelf is one of the things it does: a capture
        // is still announced with the shelf switched off, where it used to be silent.
        Self.wantsScreenshots(p) ? screenshots.start() : screenshots.stop()
        (p.nowPlayingEnabled && p.reactiveVisualizerEnabled) ? audioLevel.start() : audioLevel.stop()
    }
}
