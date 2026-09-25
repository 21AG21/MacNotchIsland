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
    /// Keep the island still through a Space transition, in a window space of its own.
    @Published var staysPutAcrossSpaces: Bool { didSet { d.set(staysPutAcrossSpaces, forKey: "staysPutAcrossSpaces") } }
    @Published var hoverToExpand: Bool { didSet { d.set(hoverToExpand, forKey: "hoverToExpand") } }
    /// "Open from the empty notch too". Until it is set it follows the island — on under a
    /// notch, off where the island floats — and is not written down: see `FloatingDefaults`
    /// and `followFloatingDefaults`.
    @Published var expandOnIdleHover: Bool {
        didSet { if !followingIsland { d.set(expandOnIdleHover, forKey: "expandOnIdleHover") } }
    }
    @Published var hapticsEnabled: Bool { didSet { d.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var alertDuration: Double { didSet { d.set(alertDuration, forKey: "alertDuration") } }

    // MARK: Activities
    @Published var nowPlayingEnabled: Bool { didSet { d.set(nowPlayingEnabled, forKey: "nowPlayingEnabled") } }
    @Published var keepPausedMinutes: Double { didSet { d.set(keepPausedMinutes, forKey: "keepPausedMinutes") } }
    /// The buttons in the four places beside play, by raw name: two to the left, two to the
    /// right, see `TransportSlot`. All four "none" out of the box, which is Music's row; people
    /// who listen to podcasts will want "back15" and "forward15".
    @Published var transportSlots: [String] { didSet { d.set(transportSlots, forKey: "transportSlots") } }
    @Published var batteryEnabled: Bool { didSet { d.set(batteryEnabled, forKey: "batteryEnabled") } }
    @Published var bluetoothEnabled: Bool { didSet { d.set(bluetoothEnabled, forKey: "bluetoothEnabled") } }
    @Published var volumeHUDEnabled: Bool { didSet { d.set(volumeHUDEnabled, forKey: "volumeHUDEnabled") } }
    @Published var brightnessHUDEnabled: Bool { didSet { d.set(brightnessHUDEnabled, forKey: "brightnessHUDEnabled") } }
    /// The keyboard backlight's display, and with the bezel replaced, its keys.
    @Published var keyboardLightHUDEnabled: Bool { didSet { d.set(keyboardLightHUDEnabled, forKey: "keyboardLightHUDEnabled") } }
    @Published var privacyIndicatorsEnabled: Bool { didSet { d.set(privacyIndicatorsEnabled, forKey: "privacyIndicatorsEnabled") } }
    @Published var callDetectionEnabled: Bool { didSet { d.set(callDetectionEnabled, forKey: "callDetectionEnabled") } }
    @Published var focusEnabled: Bool { didSet { d.set(focusEnabled, forKey: "focusEnabled") } }
    /// Hold back the alerts that can wait while a Focus is on.
    @Published var quietDuringFocus: Bool { didSet { d.set(quietDuringFocus, forKey: "quietDuringFocus") } }
    @Published var calendarEnabled: Bool { didSet { d.set(calendarEnabled, forKey: "calendarEnabled") } }
    @Published var unlockEnabled: Bool { didSet { d.set(unlockEnabled, forKey: "unlockEnabled") } }
    @Published var shelfEnabled: Bool { didSet { d.set(shelfEnabled, forKey: "shelfEnabled") } }
    @Published var timerSoundEnabled: Bool { didSet { d.set(timerSoundEnabled, forKey: "timerSoundEnabled") } }
    @Published var downloadsEnabled: Bool { didSet { d.set(downloadsEnabled, forKey: "downloadsEnabled") } }
    @Published var drivesEnabled: Bool { didSet { d.set(drivesEnabled, forKey: "drivesEnabled") } }
    @Published var screenshotsEnabled: Bool { didSet { d.set(screenshotsEnabled, forKey: "screenshotsEnabled") } }
    @Published var controlsEnabled: Bool { didSet { d.set(controlsEnabled, forKey: "controlsEnabled") } }
    /// Tell me when the battery reaches this, once per charge. 0 is off.
    @Published var chargeAlertPercent: Double { didSet { d.set(chargeAlertPercent, forKey: "chargeAlertPercent") } }
    @Published var addDownloadsToShelf: Bool { didSet { d.set(addDownloadsToShelf, forKey: "addDownloadsToShelf") } }
    @Published var screenshotsToShelfEnabled: Bool { didSet { d.set(screenshotsToShelfEnabled, forKey: "screenshotsToShelfEnabled") } }
    @Published var lowPowerEnabled: Bool { didSet { d.set(lowPowerEnabled, forKey: "lowPowerEnabled") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardLimit: Double { didSet { d.set(clipboardLimit, forKey: "clipboardLimit") } }
    /// Keep the clipboard history across relaunches, which means writing it to disk.
    ///
    /// Off. The history itself is on out of the box, and held in memory it is gone when the
    /// app quits; written down, it is every password, address and message somebody copied
    /// that a password manager did not mark, in a file that outlives the moment it was copied
    /// for. That is not the app's to assume, so it is asked for.
    @Published var clipboardPersists: Bool { didSet { d.set(clipboardPersists, forKey: "clipboardPersists") } }
    @Published var pasteOnPick: Bool { didSet { d.set(pasteOnPick, forKey: "pasteOnPick") } }
    /// Keep a history of the banners that came past.
    ///
    /// The one activity that ships switched off. Everything else here watches the Mac; this
    /// one writes down what somebody's messages said, to a file on their disk, and a feature
    /// like that is not the app's to assume anybody wants. Nothing about it runs — no watcher,
    /// no reading of another process's window tree, no file — until this is turned on.
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    /// Whether a card pushed in from outside may put a button on the island that runs one of
    /// your Shortcuts.
    ///
    /// Off, and not lightly. Anything on this Mac can push a card — that is the point of the
    /// API — and a Shortcut can run a shell script. A card is drawn in the app's own hand, so
    /// a button on one reads as the island asking, and "Update available / Install" is a
    /// sentence anybody would click. Links pushed from outside have always been held to the
    /// web; this is the same rule finally applied to the more dangerous half.
    @Published var apiShortcutsEnabled: Bool { didSet { d.set(apiShortcutsEnabled, forKey: "apiShortcutsEnabled") } }
    /// Keep the island out of screen sharing and screenshots, always. The panel can hold what
    /// was copied, the notes and what the notifications said; see `NotchPanel.sharesScreen`.
    @Published var hiddenFromScreenSharing: Bool { didSet { d.set(hiddenFromScreenSharing, forKey: "hiddenFromScreenSharing") } }
    /// The same, but only while a call is live — which is when a screen is most often shared,
    /// and so on out of the box.
    @Published var hideFromScreenSharingDuringCalls: Bool { didSet { d.set(hideFromScreenSharingDuringCalls, forKey: "hideFromScreenSharingDuringCalls") } }
    @Published var shelfExpiryHours: Double { didSet { d.set(shelfExpiryHours, forKey: "shelfExpiryHours") } }
    @Published var lyricsEnabled: Bool { didSet { d.set(lyricsEnabled, forKey: "lyricsEnabled") } }
    @Published var artworkLookupEnabled: Bool { didSet { d.set(artworkLookupEnabled, forKey: "artworkLookupEnabled") } }
    @Published var hudReplacementEnabled: Bool { didSet { d.set(hudReplacementEnabled, forKey: "hudReplacementEnabled") } }
    @Published var capsLockEnabled: Bool { didSet { d.set(capsLockEnabled, forKey: "capsLockEnabled") } }
    @Published var quickActionsEnabled: Bool { didSet { d.set(quickActionsEnabled, forKey: "quickActionsEnabled") } }
    @Published var pauseAnimationsOnBattery: Bool { didSet { d.set(pauseAnimationsOnBattery, forKey: "pauseAnimationsOnBattery") } }
    @Published var mirrorEnabled: Bool { didSet { d.set(mirrorEnabled, forKey: "mirrorEnabled") } }
    @Published var statsEnabled: Bool { didSet { d.set(statsEnabled, forKey: "statsEnabled") } }
    @Published var windowsEnabled: Bool { didSet { d.set(windowsEnabled, forKey: "windowsEnabled") } }
    @Published var notesEnabled: Bool { didSet { d.set(notesEnabled, forKey: "notesEnabled") } }
    /// Widen the pill for a moment with the title and artist when a track starts or changes.
    @Published var sneakPeekEnabled: Bool { didSet { d.set(sneakPeekEnabled, forKey: "sneakPeekEnabled") } }
    @Published var updateChecksEnabled: Bool { didSet { d.set(updateChecksEnabled, forKey: "updateChecksEnabled") } }
    @Published var gesturesEnabled: Bool { didSet { d.set(gesturesEnabled, forKey: "gesturesEnabled") } }
    /// What a bare vertical scroll on the island means: "volume", the way it always has, or
    /// "openClose" — down on the closed island opens the panel, up on the panel closes it.
    /// See `GestureRouter.VerticalSwipe`.
    @Published var verticalSwipe: String { didSet { d.set(verticalSwipe, forKey: "verticalSwipe") } }
    /// How little a swipe has to travel to open or close the panel, 0.5 to 2 (1 is as it
    /// ships). Read only while `verticalSwipe` is "openClose".
    @Published var swipeSensitivity: Double { didSet { d.set(swipeSensitivity, forKey: "swipeSensitivity") } }
    /// Whether the panel answers the bare arrow keys, the digits, and Space while it is
    /// pinned open. Never while a section that is typed into is showing.
    @Published var panelKeysEnabled: Bool { didSet { d.set(panelKeysEnabled, forKey: "panelKeysEnabled") } }
    /// Only widen the compact island into menu bar space that is actually free.
    @Published var keepClearOfMenuBar: Bool { didSet { d.set(keepClearOfMenuBar, forKey: "keepClearOfMenuBar") } }
    @Published var weatherEnabled: Bool { didSet { d.set(weatherEnabled, forKey: "weatherEnabled") } }
    /// Until it is set this follows the island too — off under a notch, on where the island
    /// floats — for `FloatingDefaults`' reason, and is not written down while it does.
    @Published var hideInFullscreen: Bool {
        didSet { if !followingIsland { d.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    }
    @Published var reactiveVisualizerEnabled: Bool { didSet { d.set(reactiveVisualizerEnabled, forKey: "reactiveVisualizerEnabled") } }
    @Published var hotkeyKeyCode: Double { didSet { d.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") } }
    @Published var hotkeyModifiers: Double { didSet { d.set(hotkeyModifiers, forKey: "hotkeyModifiers") } }
    /// Bundle identifiers of apps that hide the island while they are frontmost.
    @Published var hiddenAppBundleIDs: [String] { didSet { d.set(hiddenAppBundleIDs, forKey: "hiddenAppBundleIDs") } }
    /// The order the panel's sections are in, by raw name. Empty means the order they ship in.
    @Published var sectionOrder: [String] { didSet { d.set(sectionOrder, forKey: "sectionOrder") } }
    /// The order of the control rail's buttons, by raw name. Empty means the order they ship in.
    @Published var railOrder: [String] { didSet { d.set(railOrder, forKey: "railOrder") } }
    /// The rail buttons the user has switched on or off, by raw name. A button that is not in
    /// here has never been touched and is on or off as it ships — see `RailControl.isOnByDefault`.
    @Published var railSwitches: [String: Bool] { didSet { d.set(railSwitches, forKey: "railSwitches") } }
    /// Unix time until which the island stays hidden (0 = not paused).
    @Published var pausedUntil: Double { didSet { d.set(pausedUntil, forKey: "pausedUntil") } }

    // MARK: Geometry overrides (0 = auto-detect)
    @Published var notchWidthOverride: Double { didSet { d.set(notchWidthOverride, forKey: "notchWidthOverride") } }
    @Published var notchHeightOverride: Double { didSet { d.set(notchHeightOverride, forKey: "notchHeightOverride") } }

    // MARK: Motion (1 = the phone's own timing)
    /// A multiplier on every spring's duration.
    @Published var motionDuration: Double { didSet { d.set(motionDuration, forKey: "motionDuration") } }
    /// A multiplier on every spring's bounce. 0 never overshoots.
    @Published var motionBounce: Double { didSet { d.set(motionBounce, forKey: "motionBounce") } }
    // No preset is stored beside them. The two numbers are the whole of the motion, and the
    // Motion pane works out which preset they are; a name kept alongside was written on every
    // slider move and read by nothing.

    // MARK: Following the island

    /// Set while `followFloatingDefaults` moves a switch nobody has set, so that moving it
    /// writes nothing down: written, it would be a choice, and would stop following.
    private var followingIsland = false

    /// Whether `key` has ever been written, and what to, for a switch whose default is not
    /// the same on every Mac.
    private static func storedBool(_ key: String) -> Bool? {
        UserDefaults.standard.object(forKey: key) == nil ? nil : UserDefaults.standard.bool(forKey: key)
    }

    /// Puts the switches that follow the island where `FloatingDefaults` has them for the
    /// islands just built, one entry per panel, true where it floats. A switch that has been
    /// set is left as it was set.
    ///
    /// The floating defaults only while every island floats (`FloatingDefaults.floats`): one
    /// island in a notch keeps the notch's, whatever else is plugged in. Any floating island
    /// used to be enough, so with "Show on all displays" on a monitor gave the MacBook's
    /// island the floating pill's defaults, and took them away again when it was unplugged.
    ///
    /// Called whenever the panels are built, because what was read at load can stop being
    /// true while the app runs: a MacBook opened after launching with the lid shut and a
    /// monitor attached gives the island the notch it did not have. No panels says nothing
    /// about the island — a display that has not come back yet — and moves nothing.
    func followFloatingDefaults(panelsFloating: [Bool]) {
        guard !panelsFloating.isEmpty else { return }
        let floating = !panelsFloating.contains(false)
        let hides = FloatingDefaults.hidesInFullScreen(stored: Self.storedBool("hideInFullscreen"), floating: floating)
        let opens = FloatingDefaults.idleHoverOpens(stored: Self.storedBool("expandOnIdleHover"), floating: floating)
        followingIsland = true
        defer { followingIsland = false }
        if hideInFullscreen != hides { hideInFullscreen = hides }
        if expandOnIdleHover != opens { expandOnIdleHover = opens }
    }

    // MARK: Launch at login (SMAppService)
    /// SMAppService only makes sense for a real .app bundle (not `swift run` or the test host).
    private static var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Whether the checkbox is ticked. What is registered is macOS's to say, not this: after
    /// every change the box is set again from `SMAppService.mainApp.status`, see
    /// `settleLoginItem`.
    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin, Self.isBundledApp, !settlingLoginItem else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                IslandLog.island.error("launch at login change failed: \(String(describing: error), privacy: .public)")
            }
            // A refused register used to leave the tick in place with nothing registered, and
            // one waiting on approval was not told apart from one that worked. Settled on the
            // next turn of the run loop, out of the view update the checkbox wrote this in.
            DispatchQueue.main.async { [weak self] in self?.settleLoginItem() }
        }
    }

    /// The line under "Open at login" when the tick is not the whole story, see `LoginItemRule`.
    @Published private(set) var loginItemNote: String? = nil
    /// Set while the box is being put back to what macOS says, so that doing so asks nothing.
    private var settlingLoginItem = false

    /// Sets the checkbox and its note from what macOS says is registered. Called after every
    /// change, and by the two places the box is shown whenever they are looked at: approval
    /// is given in System Settings, which tells nobody.
    func settleLoginItem() {
        guard Self.isBundledApp else { return }
        let shown = LoginItemRule.shown(status: SMAppService.mainApp.status)
        settlingLoginItem = true
        if launchAtLogin != shown.checked { launchAtLogin = shown.checked }
        settlingLoginItem = false
        if loginItemNote != shown.note { loginItemNote = shown.note }
    }

    private init() {
        func bool(_ key: String, _ def: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
        }
        func double(_ key: String, _ def: Double) -> Double {
            UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.double(forKey: key)
        }
        let onAllDisplays = bool("showOnAllDisplays", false)
        // Whether the island will float, read from the displays before any panel is built, for
        // the two switches that follow it while nobody has set them (`FloatingDefaults`). The
        // panels say so again once they are built, see `followFloatingDefaults`.
        let floating = FloatingDefaults.floatsOnThisMac()
        showOnAllDisplays = onAllDisplays
        staysPutAcrossSpaces = bool("staysPutAcrossSpaces", true)
        hoverToExpand = bool("hoverToExpand", true)
        expandOnIdleHover = FloatingDefaults.idleHoverOpens(stored: Self.storedBool("expandOnIdleHover"), floating: floating)
        hapticsEnabled = bool("hapticsEnabled", true)
        hoverDelay = double("hoverDelay", 0.25)
        alertDuration = double("alertDuration", 1.8)

        nowPlayingEnabled = bool("nowPlayingEnabled", true)
        keepPausedMinutes = double("keepPausedMinutes", 5)
        transportSlots = UserDefaults.standard.stringArray(forKey: "transportSlots") ?? TransportSlot.defaults.map(\.rawValue)
        batteryEnabled = bool("batteryEnabled", true)
        bluetoothEnabled = bool("bluetoothEnabled", true)
        volumeHUDEnabled = bool("volumeHUDEnabled", true)
        brightnessHUDEnabled = bool("brightnessHUDEnabled", true)
        keyboardLightHUDEnabled = bool("keyboardLightHUDEnabled", true)
        privacyIndicatorsEnabled = bool("privacyIndicatorsEnabled", true)
        callDetectionEnabled = bool("callDetectionEnabled", true)
        focusEnabled = bool("focusEnabled", true)
        quietDuringFocus = bool("quietDuringFocus", true)
        calendarEnabled = bool("calendarEnabled", true)
        unlockEnabled = bool("unlockEnabled", true)
        shelfEnabled = bool("shelfEnabled", true)
        timerSoundEnabled = bool("timerSoundEnabled", true)
        downloadsEnabled = bool("downloadsEnabled", true)
        drivesEnabled = bool("drivesEnabled", true)
        screenshotsEnabled = bool("screenshotsEnabled", true)
        controlsEnabled = bool("controlsEnabled", true)
        chargeAlertPercent = d.object(forKey: "chargeAlertPercent") as? Double ?? 0
        addDownloadsToShelf = bool("addDownloadsToShelf", true)
        screenshotsToShelfEnabled = bool("screenshotsToShelfEnabled", true)
        lowPowerEnabled = bool("lowPowerEnabled", true)
        hotkeyEnabled = bool("hotkeyEnabled", true)
        hasSeenWelcome = bool("hasSeenWelcome", false)
        clipboardEnabled = bool("clipboardEnabled", true)
        clipboardLimit = double("clipboardLimit", 50)
        clipboardPersists = bool("clipboardPersists", false)
        pasteOnPick = bool("pasteOnPick", true)
        notificationsEnabled = bool("notificationsEnabled", false)
        apiShortcutsEnabled = bool("apiShortcutsEnabled", false)
        hiddenFromScreenSharing = bool("hiddenFromScreenSharing", false)
        hideFromScreenSharingDuringCalls = bool("hideFromScreenSharingDuringCalls", true)
        shelfExpiryHours = double("shelfExpiryHours", 24)
        lyricsEnabled = bool("lyricsEnabled", true)
        artworkLookupEnabled = bool("artworkLookupEnabled", true)
        hudReplacementEnabled = bool("hudReplacementEnabled", false)
        capsLockEnabled = bool("capsLockEnabled", true)
        quickActionsEnabled = bool("quickActionsEnabled", true)
        pauseAnimationsOnBattery = bool("pauseAnimationsOnBattery", false)
        mirrorEnabled = bool("mirrorEnabled", true)
        statsEnabled = bool("statsEnabled", true)
        windowsEnabled = bool("windowsEnabled", true)
        notesEnabled = bool("notesEnabled", true)
        sneakPeekEnabled = bool("sneakPeekEnabled", true)
        updateChecksEnabled = bool("updateChecksEnabled", true)
        gesturesEnabled = bool("gesturesEnabled", true)
        verticalSwipe = UserDefaults.standard.string(forKey: "verticalSwipe") ?? "volume"
        // Held within the slider's range here too, so a figure edited into defaults by hand
        // shows on the slider at the value the swipe is using.
        swipeSensitivity = min(2, max(0.5, double("swipeSensitivity", 1)))
        panelKeysEnabled = bool("panelKeysEnabled", true)
        keepClearOfMenuBar = bool("keepClearOfMenuBar", true)
        weatherEnabled = bool("weatherEnabled", false)
        hideInFullscreen = FloatingDefaults.hidesInFullScreen(stored: Self.storedBool("hideInFullscreen"), floating: floating)
        reactiveVisualizerEnabled = bool("reactiveVisualizerEnabled", false)
        // ⌃⌥Space, unless macOS switches input sources with it — see
        // `HotKeyService.shippingDefault`. Asked only while nothing has been recorded, and
        // written down the first time it is: left to follow the Mac, it was asked again at
        // every launch, and an input source added or taken away since the last one moved the
        // shortcut the tour had taught without a word. Once written it stays, as a recorded
        // one does; the recorder's Reset asks again.
        if d.object(forKey: "hotkeyKeyCode") == nil {
            let shipping = HotKeyService.shippingDefaultOnThisMac
            d.set(Double(shipping.keyCode), forKey: "hotkeyKeyCode")
            d.set(Double(shipping.modifiers), forKey: "hotkeyModifiers")
        }
        hotkeyKeyCode = double("hotkeyKeyCode", Double(HotKeyService.defaultKeyCode))
        hotkeyModifiers = double("hotkeyModifiers", Double(HotKeyService.defaultModifiers))
        pausedUntil = double("pausedUntil", 0)
        hiddenAppBundleIDs = UserDefaults.standard.stringArray(forKey: "hiddenAppBundleIDs") ?? []
        sectionOrder = UserDefaults.standard.stringArray(forKey: "sectionOrder") ?? []
        railOrder = UserDefaults.standard.stringArray(forKey: "railOrder") ?? []
        railSwitches = UserDefaults.standard.dictionary(forKey: "railSwitches") as? [String: Bool] ?? [:]

        notchWidthOverride = double("notchWidthOverride", 0)
        notchHeightOverride = double("notchHeightOverride", 0)

        // Held within range here as well as where the springs read them, so a number edited
        // into defaults by hand shows on the pane's slider at the figure the island is using.
        let motion = IslandMotion.Tuning(duration: double("motionDuration", 1), bounce: double("motionBounce", 1)).clamped
        motionDuration = motion.duration
        motionBounce = motion.bounce

        // The same reading `settleLoginItem` makes, so an item waiting on approval starts
        // ticked with its note rather than unticked and silent.
        let login: (checked: Bool, note: String?) = Self.isBundledApp
            ? LoginItemRule.shown(status: SMAppService.mainApp.status)
            : (checked: false, note: nil)
        launchAtLogin = login.checked
        loginItemNote = login.note
    }
}

/// What "Open at login" shows for what macOS says is registered.
///
/// The box used to be the preference and nothing else: a `register()` that threw was logged
/// and the tick stayed, so a Mac could show "Open at login" ticked with nothing registered at
/// all; and an item waiting for approval in Login Items read as unticked, with nothing to say
/// what it was waiting for. Pure, so each status can be held to its answer.
enum LoginItemRule {
    static let approvalNote = "Waiting for your approval in System Settings, under Login Items."
    static let notFoundNote = "macOS cannot find this copy of the app to open at login. Move it to Applications and try again."

    static func shown(status: SMAppService.Status) -> (checked: Bool, note: String?) {
        switch status {
        case .enabled: return (true, nil)
        // Registered, and not yet in effect: ticked, since unticking it is how to take the
        // registration back, with the note saying where the rest of it is done.
        case .requiresApproval: return (true, approvalNote)
        case .notRegistered: return (false, nil)
        case .notFound: return (false, notFoundNote)
        @unknown default: return (false, nil)
        }
    }

    /// Whether the note is one the Login Items pane answers, and so comes with a way there.
    static func offersLoginItems(_ note: String?) -> Bool { note == approvalNote }
}
