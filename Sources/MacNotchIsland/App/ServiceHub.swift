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
    let lowPower = LowPowerMonitor()
    let hotkey = HotKeyService.shared
    let clipboard = ClipboardStore.shared
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
        apply()
        LiveActivityAPI.shared.start()
        Preferences.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
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
        p.calendarEnabled ? calendar.start() : calendar.stop()
        p.unlockEnabled ? screenLock.start() : screenLock.stop()
        p.downloadsEnabled ? downloads.start() : downloads.stop()
        p.lowPowerEnabled ? lowPower.start() : lowPower.stop()
        p.hotkeyEnabled ? hotkey.start() : hotkey.stop()
        p.keepClearOfMenuBar ? menuBar.start() : menuBar.stop()
        // The shelf is loaded lazily; touching it here puts files kept from last time back
        // on the island at launch, and drops the activity when the shelf is switched off.
        ShelfStore.shared.refreshActivity()
        p.clipboardEnabled ? clipboard.start() : clipboard.stop()
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
        (p.shelfEnabled && p.screenshotsToShelfEnabled) ? screenshots.start() : screenshots.stop()
        (p.nowPlayingEnabled && p.reactiveVisualizerEnabled) ? audioLevel.start() : audioLevel.stop()
    }
}
