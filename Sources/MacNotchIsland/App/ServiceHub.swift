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
    let calls = CallDetector()
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

    func start() {
        energy.start()
        // Warmed here rather than the first time the panel opens. Its first reading builds a
        // CoreWLAN client and talks to the Wi-Fi daemon, and the first time anything asks for
        // it is when the rail is mounted — which is during the spring that opens the panel.
        _ = SystemToggles.shared
        apply()
        LiveActivityAPI.shared.start()
        Preferences.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
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

    private func apply() {
        let p = Preferences.shared
        p.nowPlayingEnabled ? nowPlaying.start() : nowPlaying.stop()
        p.batteryEnabled ? battery.start() : battery.stop()
        p.bluetoothEnabled ? bluetooth.start() : bluetooth.stop()
        // The audio monitor feeds the volume display, the silent-mode alert, the microphone
        // indicator and call detection — but the first two only exist while the island is the
        // one answering the media keys, so on their own they are not a reason to listen.
        let showsVolume = p.hudReplacementEnabled && p.volumeHUDEnabled
        (showsVolume || p.privacyIndicatorsEnabled || p.callDetectionEnabled) ? audio.start() : audio.stop()
        // The brightness monitor exists only to raise that display, and polls a private
        // display call four times a second to do it. With the island not answering the keys
        // there is nothing for it to raise, so it does not run at all.
        (p.hudReplacementEnabled && p.brightnessHUDEnabled) ? brightness.start() : brightness.stop()
        p.privacyIndicatorsEnabled ? camera.start() : camera.stop()
        p.callDetectionEnabled ? calls.start() : calls.stop()
        p.focusEnabled ? focus.start() : focus.stop()
        Self.wantsCalendar(p) ? calendar.start() : calendar.stop()
        p.unlockEnabled ? screenLock.start() : screenLock.stop()
        p.downloadsEnabled ? downloads.start() : downloads.stop()
        p.drivesEnabled ? volumes.start() : volumes.stop()
        p.lowPowerEnabled ? lowPower.start() : lowPower.stop()
        // Either feature needs the Carbon handler installed: the summon combination, and the
        // keys the panel answers on its own while it is open.
        (p.hotkeyEnabled || p.panelKeysEnabled) ? hotkey.start() : hotkey.stop()
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
        // With both displays switched off there is no key left for the island to take, and
        // an event tap that swallows nothing is not worth asking anyone for Accessibility.
        (p.hudReplacementEnabled && (p.volumeHUDEnabled || p.brightnessHUDEnabled))
            ? mediaKeys.start() : mediaKeys.stop()
        p.capsLockEnabled ? capsLock.start() : capsLock.stop()
        if p.quickActionsEnabled && !requestedShortcuts {
            requestedShortcuts = true
            ShortcutsRunner.shared.refresh()
        }
        p.updateChecksEnabled ? updates.start() : updates.stop()
        p.hideInFullscreen ? fullscreen.start() : fullscreen.stop()
        p.hiddenAppBundleIDs.isEmpty ? hiddenApps.stop() : hiddenApps.start()
        // The card is the feature now, and the shelf is one of the things it does: a capture
        // is still announced with the shelf switched off, where it used to be silent.
        p.screenshotsEnabled ? screenshots.start() : screenshots.stop()
        (p.nowPlayingEnabled && p.reactiveVisualizerEnabled) ? audioLevel.start() : audioLevel.stop()
    }
}
