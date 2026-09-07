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
    let hotkey = HotKeyService()
    let clipboard = ClipboardStore.shared
    let lyrics = LyricsService.shared
    let mediaKeys = MediaKeyInterceptor()
    let capsLock = CapsLockMonitor()
    let energy = EnergyPolicy.shared
    let updates = UpdateChecker.shared
    let fullscreen = FullscreenMonitor()
    let audioLevel = AudioLevelTap.shared

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
        // The audio monitor feeds the volume HUD, silent-mode alert, mic indicator and call detection.
        (p.volumeHUDEnabled || p.privacyIndicatorsEnabled || p.callDetectionEnabled) ? audio.start() : audio.stop()
        p.brightnessHUDEnabled ? brightness.start() : brightness.stop()
        p.privacyIndicatorsEnabled ? camera.start() : camera.stop()
        p.callDetectionEnabled ? calls.start() : calls.stop()
        p.focusEnabled ? focus.start() : focus.stop()
        p.calendarEnabled ? calendar.start() : calendar.stop()
        p.unlockEnabled ? screenLock.start() : screenLock.stop()
        p.downloadsEnabled ? downloads.start() : downloads.stop()
        p.lowPowerEnabled ? lowPower.start() : lowPower.stop()
        p.hotkeyEnabled ? hotkey.start() : hotkey.stop()
        p.clipboardEnabled ? clipboard.start() : clipboard.stop()
        (p.nowPlayingEnabled && p.lyricsEnabled) ? lyrics.start() : lyrics.stop()
        p.hudReplacementEnabled ? mediaKeys.start() : mediaKeys.stop()
        p.capsLockEnabled ? capsLock.start() : capsLock.stop()
        if p.quickActionsEnabled && !requestedShortcuts {
            requestedShortcuts = true
            ShortcutsRunner.shared.refresh()
        }
        p.updateChecksEnabled ? updates.start() : updates.stop()
        p.hideInFullscreen ? fullscreen.start() : fullscreen.stop()
        (p.nowPlayingEnabled && p.reactiveVisualizerEnabled) ? audioLevel.start() : audioLevel.stop()
    }
}
