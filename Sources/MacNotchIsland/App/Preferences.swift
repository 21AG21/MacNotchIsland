import Foundation
import Combine
import ServiceManagement

/// User preferences. Every property persists to UserDefaults on write and publishes
/// a change so views and services can react immediately.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let d = UserDefaults.standard

    // MARK: General
    @Published var showOnAllDisplays: Bool { didSet { d.set(showOnAllDisplays, forKey: "showOnAllDisplays") } }
    @Published var hoverToExpand: Bool { didSet { d.set(hoverToExpand, forKey: "hoverToExpand") } }
    @Published var expandOnIdleHover: Bool { didSet { d.set(expandOnIdleHover, forKey: "expandOnIdleHover") } }
    @Published var hapticsEnabled: Bool { didSet { d.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var alertDuration: Double { didSet { d.set(alertDuration, forKey: "alertDuration") } }

    // MARK: Activities
    @Published var nowPlayingEnabled: Bool { didSet { d.set(nowPlayingEnabled, forKey: "nowPlayingEnabled") } }
    @Published var keepPausedMinutes: Double { didSet { d.set(keepPausedMinutes, forKey: "keepPausedMinutes") } }
    @Published var batteryEnabled: Bool { didSet { d.set(batteryEnabled, forKey: "batteryEnabled") } }
    @Published var bluetoothEnabled: Bool { didSet { d.set(bluetoothEnabled, forKey: "bluetoothEnabled") } }
    @Published var volumeHUDEnabled: Bool { didSet { d.set(volumeHUDEnabled, forKey: "volumeHUDEnabled") } }
    @Published var brightnessHUDEnabled: Bool { didSet { d.set(brightnessHUDEnabled, forKey: "brightnessHUDEnabled") } }
    @Published var privacyIndicatorsEnabled: Bool { didSet { d.set(privacyIndicatorsEnabled, forKey: "privacyIndicatorsEnabled") } }
    @Published var callDetectionEnabled: Bool { didSet { d.set(callDetectionEnabled, forKey: "callDetectionEnabled") } }
    @Published var focusEnabled: Bool { didSet { d.set(focusEnabled, forKey: "focusEnabled") } }
    @Published var calendarEnabled: Bool { didSet { d.set(calendarEnabled, forKey: "calendarEnabled") } }
    @Published var unlockEnabled: Bool { didSet { d.set(unlockEnabled, forKey: "unlockEnabled") } }
    @Published var shelfEnabled: Bool { didSet { d.set(shelfEnabled, forKey: "shelfEnabled") } }
    @Published var timerSoundEnabled: Bool { didSet { d.set(timerSoundEnabled, forKey: "timerSoundEnabled") } }
    @Published var downloadsEnabled: Bool { didSet { d.set(downloadsEnabled, forKey: "downloadsEnabled") } }
    @Published var addDownloadsToShelf: Bool { didSet { d.set(addDownloadsToShelf, forKey: "addDownloadsToShelf") } }
    @Published var lowPowerEnabled: Bool { didSet { d.set(lowPowerEnabled, forKey: "lowPowerEnabled") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardLimit: Double { didSet { d.set(clipboardLimit, forKey: "clipboardLimit") } }
    @Published var shelfExpiryHours: Double { didSet { d.set(shelfExpiryHours, forKey: "shelfExpiryHours") } }
    @Published var lyricsEnabled: Bool { didSet { d.set(lyricsEnabled, forKey: "lyricsEnabled") } }
    @Published var hudReplacementEnabled: Bool { didSet { d.set(hudReplacementEnabled, forKey: "hudReplacementEnabled") } }
    @Published var capsLockEnabled: Bool { didSet { d.set(capsLockEnabled, forKey: "capsLockEnabled") } }
    @Published var quickActionsEnabled: Bool { didSet { d.set(quickActionsEnabled, forKey: "quickActionsEnabled") } }
    @Published var pauseAnimationsOnBattery: Bool { didSet { d.set(pauseAnimationsOnBattery, forKey: "pauseAnimationsOnBattery") } }
    @Published var mirrorEnabled: Bool { didSet { d.set(mirrorEnabled, forKey: "mirrorEnabled") } }
    @Published var statsEnabled: Bool { didSet { d.set(statsEnabled, forKey: "statsEnabled") } }
    @Published var updateChecksEnabled: Bool { didSet { d.set(updateChecksEnabled, forKey: "updateChecksEnabled") } }
    @Published var gesturesEnabled: Bool { didSet { d.set(gesturesEnabled, forKey: "gesturesEnabled") } }
    @Published var weatherEnabled: Bool { didSet { d.set(weatherEnabled, forKey: "weatherEnabled") } }
    @Published var hideInFullscreen: Bool { didSet { d.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    @Published var reactiveVisualizerEnabled: Bool { didSet { d.set(reactiveVisualizerEnabled, forKey: "reactiveVisualizerEnabled") } }
    @Published var hotkeyKeyCode: Double { didSet { d.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") } }
    @Published var hotkeyModifiers: Double { didSet { d.set(hotkeyModifiers, forKey: "hotkeyModifiers") } }
    /// Unix time until which the island stays hidden (0 = not paused).
    @Published var pausedUntil: Double { didSet { d.set(pausedUntil, forKey: "pausedUntil") } }

    // MARK: Geometry overrides (0 = auto-detect)
    @Published var notchWidthOverride: Double { didSet { d.set(notchWidthOverride, forKey: "notchWidthOverride") } }
    @Published var notchHeightOverride: Double { didSet { d.set(notchHeightOverride, forKey: "notchHeightOverride") } }

    // MARK: Launch at login (SMAppService)
    /// SMAppService only makes sense for a real .app bundle (not `swift run` or the test host).
    private static var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin, Self.isBundledApp else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error)")
            }
        }
    }

    private init() {
        func bool(_ key: String, _ def: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
        }
        func double(_ key: String, _ def: Double) -> Double {
            UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.double(forKey: key)
        }
        showOnAllDisplays = bool("showOnAllDisplays", false)
        hoverToExpand = bool("hoverToExpand", true)
        expandOnIdleHover = bool("expandOnIdleHover", true)
        hapticsEnabled = bool("hapticsEnabled", true)
        hoverDelay = double("hoverDelay", 0.2)
        alertDuration = double("alertDuration", 2.8)

        nowPlayingEnabled = bool("nowPlayingEnabled", true)
        keepPausedMinutes = double("keepPausedMinutes", 5)
        batteryEnabled = bool("batteryEnabled", true)
        bluetoothEnabled = bool("bluetoothEnabled", true)
        volumeHUDEnabled = bool("volumeHUDEnabled", true)
        brightnessHUDEnabled = bool("brightnessHUDEnabled", true)
        privacyIndicatorsEnabled = bool("privacyIndicatorsEnabled", true)
        callDetectionEnabled = bool("callDetectionEnabled", true)
        focusEnabled = bool("focusEnabled", true)
        calendarEnabled = bool("calendarEnabled", false)
        unlockEnabled = bool("unlockEnabled", true)
        shelfEnabled = bool("shelfEnabled", true)
        timerSoundEnabled = bool("timerSoundEnabled", true)
        downloadsEnabled = bool("downloadsEnabled", true)
        addDownloadsToShelf = bool("addDownloadsToShelf", false)
        lowPowerEnabled = bool("lowPowerEnabled", true)
        hotkeyEnabled = bool("hotkeyEnabled", true)
        hasSeenWelcome = bool("hasSeenWelcome", false)
        clipboardEnabled = bool("clipboardEnabled", true)
        clipboardLimit = double("clipboardLimit", 50)
        shelfExpiryHours = double("shelfExpiryHours", 24)
        lyricsEnabled = bool("lyricsEnabled", true)
        hudReplacementEnabled = bool("hudReplacementEnabled", false)
        capsLockEnabled = bool("capsLockEnabled", true)
        quickActionsEnabled = bool("quickActionsEnabled", true)
        pauseAnimationsOnBattery = bool("pauseAnimationsOnBattery", false)
        mirrorEnabled = bool("mirrorEnabled", true)
        statsEnabled = bool("statsEnabled", true)
        updateChecksEnabled = bool("updateChecksEnabled", true)
        gesturesEnabled = bool("gesturesEnabled", true)
        weatherEnabled = bool("weatherEnabled", false)
        hideInFullscreen = bool("hideInFullscreen", false)
        reactiveVisualizerEnabled = bool("reactiveVisualizerEnabled", false)
        hotkeyKeyCode = double("hotkeyKeyCode", 49)          // kVK_Space
        hotkeyModifiers = double("hotkeyModifiers", 6144)     // controlKey | optionKey
        pausedUntil = double("pausedUntil", 0)

        notchWidthOverride = double("notchWidthOverride", 0)
        notchHeightOverride = double("notchHeightOverride", 0)

        launchAtLogin = Self.isBundledApp && SMAppService.mainApp.status == .enabled
    }
}
