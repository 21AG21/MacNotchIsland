import AppKit
import CoreGraphics

/// Every button the control rail can carry, in the order they ship. The rail shows the ones that
/// are switched on and that this Mac has, in the order the user has put them in; the ones there
/// is no room for go to a row at the top of the Controls section, so nothing that is switched on
/// is ever simply missing. Settings has no switch and is always the rail's last button.
///
/// The volume, the output picker and the brightness slider are not in here: they are the rail's
/// fixed left-hand end, the way the Mac's own two most-reached-for controls always are.
enum RailControl: String, CaseIterable, Codable {
    case wifi, bluetooth
    /// The Display popover: a slider per display, Dark Mode, Night Shift, True Tone.
    case display
    case keepAwake, mirror, airDrop, focus, microphone, lock, sleepDisplay, screenshot, record
    /// The keyboard's backlight: a disc like Display's, whose popover holds the slider.
    case keyboardLight
    case settings

    /// The order they ship in: the order they are written in, Settings last.
    static let defaultOrder: [RailControl] = allCases

    /// What the button is, for the Settings list and anywhere it has to be named.
    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .display: return "Display"
        case .keepAwake: return "Keep Awake"
        case .mirror: return "Camera Mirror"
        case .airDrop: return "AirDrop the Shelf"
        case .focus: return "Focus"
        case .microphone: return "Microphone Mute"
        case .lock: return "Lock Screen"
        case .sleepDisplay: return "Sleep Display"
        case .screenshot: return "Screenshot"
        case .record: return "Record the Screen"
        case .keyboardLight: return "Keyboard Brightness"
        case .settings: return "Settings"
        }
    }

    /// The glyph it wears at rest. The rail changes some of them with the state they show.
    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        // The rail draws Bluetooth's own rune; SF Symbols has none, and this is what the
        // Controls section already uses for it.
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .display: return "sun.max.fill"
        case .keepAwake: return "cup.and.saucer"
        case .mirror: return "camera"
        case .airDrop: return "dot.radiowaves.right"
        case .focus: return "moon.fill"
        case .microphone: return "mic.fill"
        case .lock: return "lock.fill"
        case .sleepDisplay: return "powersleep"
        case .screenshot: return "camera.viewfinder"
        case .record: return "record.circle"
        case .keyboardLight: return "light.max"
        case .settings: return "gearshape"
        }
    }

    /// Whether a button nobody has switched either way is on. The seven the rail has always had
    /// are, and so is the keyboard's light where there is a backlight; the actions that are new
    /// with the catalog wait to be asked for, so an update does not crowd a rail somebody has
    /// already learned.
    var isOnByDefault: Bool {
        switch self {
        case .wifi, .bluetooth, .display, .keepAwake, .mirror, .airDrop, .keyboardLight, .settings: return true
        case .focus, .microphone, .lock, .sleepDisplay, .screenshot, .record: return false
        }
    }

    /// Where a right-click on the Focus disc goes: macOS's Focus settings. A click opens the
    /// island's own picker (`FocusModuleView`); this is for the settings behind it.
    static let focusSettings = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")

    // MARK: - Order

    /// Every control, in the order the user has put them in.
    static func ordered(_ prefs: Preferences) -> [RailControl] {
        order(stored: prefs.railOrder)
    }

    /// The stored order, made sound the way `HomeSection.order(stored:)` makes the sections':
    /// names that are no longer controls are dropped, a name listed twice counts once, anything
    /// the stored order never mentioned keeps its shipping place at the end — and Settings is
    /// last whatever the list says, because it is the one button that has to be found without
    /// looking.
    ///
    /// Pure, so the rule can be tested.
    static func order(stored: [String]) -> [RailControl] {
        var seen: Set<RailControl> = [.settings]
        var result: [RailControl] = []
        for raw in stored {
            guard let control = RailControl(rawValue: raw), seen.insert(control).inserted else { continue }
            result.append(control)
        }
        result += defaultOrder.filter { !seen.contains($0) }
        result.append(.settings)
        return result
    }

    // MARK: - Switches

    /// Whether a switch has this control on, from the stored switches alone. Settings has none.
    static func isSwitchedOn(_ control: RailControl, switches: [String: Bool]) -> Bool {
        control == .settings || (switches[control.rawValue] ?? control.isOnByDefault)
    }

    /// Whether the user has this control on. The mirror's switch is the one that already existed
    /// for the whole mirror feature, rather than a second one beside it.
    func isEnabled(_ prefs: Preferences) -> Bool {
        switch self {
        case .settings: return true
        case .mirror: return prefs.mirrorEnabled
        default: return Self.isSwitchedOn(self, switches: prefs.railSwitches)
        }
    }

    func setEnabled(_ enabled: Bool, in prefs: Preferences) {
        switch self {
        case .settings: break
        case .mirror: prefs.mirrorEnabled = enabled
        default:
            var switches = prefs.railSwitches
            switches[rawValue] = enabled
            prefs.railSwitches = switches
        }
    }

    // MARK: - What this Mac has

    /// What the hardware and the moment allow, as readings rather than live objects, so the
    /// rule can be tested.
    struct Presence: Equatable {
        var hasWiFi = true
        var hasBluetooth = true
        var hasKeyboardLight = true
        /// The shelf is switched on and has something on it to send.
        var shelfHasFiles = true
    }

    /// Whether the control has anything to do on this Mac right now: Wi-Fi and Bluetooth with the
    /// radio, the keyboard's light with a backlight, AirDrop with something on the shelf.
    func isPresent(_ presence: Presence) -> Bool {
        switch self {
        case .wifi: return presence.hasWiFi
        case .bluetooth: return presence.hasBluetooth
        case .keyboardLight: return presence.hasKeyboardLight
        case .airDrop: return presence.shelfHasFiles
        default: return true
        }
    }

    /// The controls to show, in order: switched on, and present. Pure.
    static func available(order: [RailControl], isEnabled: (RailControl) -> Bool,
                          presence: Presence) -> [RailControl] {
        order.filter { isEnabled($0) && $0.isPresent(presence) }
    }

    /// The same, from the live preferences and hardware.
    static func available(_ prefs: Preferences) -> [RailControl] {
        let presence = Presence(hasWiFi: SystemToggles.shared.hasWiFi,
                                hasBluetooth: SystemToggles.shared.hasBluetooth,
                                hasKeyboardLight: KeyboardLight.shared.isAvailable,
                                shelfHasFiles: prefs.shelfEnabled && !ShelfStore.shared.items.isEmpty)
        return available(order: ordered(prefs), isEnabled: { $0.isEnabled(prefs) }, presence: presence)
    }

    // MARK: - Room

    /// Where each control lands: on the rail, or in the Controls section's row.
    struct Fit: Equatable {
        var rail: [RailControl]
        var spill: [RailControl]
    }

    /// Takes the controls in order while they fit the room — each costs a gap and its own width,
    /// see `RailMetrics.cost(of:)` — and sends the first that does not, and everything after it,
    /// to the spill row. In order rather than wherever a gap is left, so the rail is always the
    /// front of the user's list and the row its back, never a shuffle of both.
    ///
    /// `pinned` controls stay on the rail whatever else does, and their room is kept for them
    /// first: Settings always, and the mirror while it is showing, since the way out of the
    /// mirror must not be in the section the mirror has covered. Pure.
    static func fit(_ controls: [RailControl], room: CGFloat,
                    pinned: Set<RailControl> = [.settings]) -> Fit {
        var left = room - controls.filter { pinned.contains($0) }.reduce(0) { $0 + RailMetrics.cost(of: $1) }
        var result = Fit(rail: [], spill: [])
        var full = false
        for control in controls {
            if pinned.contains(control) {
                result.rail.append(control)
                continue
            }
            let cost = RailMetrics.cost(of: control)
            if !full, cost <= left {
                result.rail.append(control)
                left -= cost
            } else {
                full = true
                result.spill.append(control)
            }
        }
        return result
    }
}
