import Foundation

/// The sections of the Home panel, in the order the switcher shows them. The one list the
/// switcher, the keyboard ring, the swipes, the URL scheme and the panel itself all read.
enum HomeSection: String, CaseIterable {
    /// The panel's front door: every section as a tile, with a glimpse of what is in it. The
    /// way Control Centre is arranged, and the way somebody who has never opened this app
    /// finds out that any of the rest of it exists.
    case home
    case music, today, windows, shelf, controls, clipboard, actions, notes, stats

    var title: String {
        switch self {
        case .home: return "Home"
        case .music: return "Now Playing"
        case .controls: return "Controls"
        case .today: return "Today"
        case .windows: return "Windows"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .actions: return "Actions"
        case .notes: return "Notes"
        case .stats: return "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .music: return "music.note"
        case .controls: return "switch.2"
        case .today: return "calendar"
        case .windows: return "macwindow.on.rectangle"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .actions: return "bolt"
        case .notes: return "note.text"
        case .stats: return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    /// Whether the user has this section switched on. Now Playing can never be switched off:
    /// it is what the island is for.
    func isEnabled(_ prefs: Preferences) -> Bool {
        switch self {
        // Neither of these has a switch: one is the way to everything else, the other is what
        // the island is for.
        case .home: return true
        case .music: return true
        case .controls: return prefs.controlsEnabled
        case .today: return prefs.calendarEnabled
        case .windows: return prefs.windowsEnabled
        case .shelf: return prefs.shelfEnabled
        case .clipboard: return prefs.clipboardEnabled
        case .actions: return prefs.quickActionsEnabled
        case .notes: return prefs.notesEnabled
        case .stats: return prefs.statsEnabled
        }
    }

    /// Switches a section on or off. Now Playing has no switch, so it is left alone.
    func setEnabled(_ enabled: Bool, in prefs: Preferences) {
        switch self {
        case .home, .music: break
        case .controls: prefs.controlsEnabled = enabled
        case .today: prefs.calendarEnabled = enabled
        case .windows: prefs.windowsEnabled = enabled
        case .shelf: prefs.shelfEnabled = enabled
        case .clipboard: prefs.clipboardEnabled = enabled
        case .actions: prefs.quickActionsEnabled = enabled
        case .notes: prefs.notesEnabled = enabled
        case .stats: prefs.statsEnabled = enabled
        }
    }

    /// Every section, in the order the user has put them in. The switcher, a sideways swipe,
    /// Tab and the digit keys all walk this, so moving a section moves it everywhere at once.
    static func ordered(_ prefs: Preferences) -> [HomeSection] {
        order(stored: prefs.sectionOrder)
    }

    /// The stored order, made sound: names that are no longer sections are dropped, a name
    /// listed twice counts once, and anything the stored order never mentioned keeps its place
    /// at the end — so a section a later version adds appears rather than vanishing because an
    /// older build wrote the list without it.
    ///
    /// Pure, so the rule can be tested.
    static func order(stored: [String]) -> [HomeSection] {
        var seen: Set<HomeSection> = []
        var result: [HomeSection] = []
        for raw in stored {
            guard let section = HomeSection(rawValue: raw), seen.insert(section).inserted else { continue }
            result.append(section)
        }
        result += allCases.filter { !seen.contains($0) }
        return result
    }

    static func available(_ prefs: Preferences) -> [HomeSection] {
        ordered(prefs).filter { $0.isEnabled(prefs) }
    }

    static let fallback = HomeSection.home

    /// The sections the Home grid shows as tiles: everything but itself.
    static func tiles(_ prefs: Preferences) -> [HomeSection] {
        ordered(prefs).filter { $0 != .home && $0.isEnabled(prefs) }
    }

    /// The section a raw tab name maps to, or the nearest one that is switched on.
    static func resolve(_ raw: String, prefs: Preferences) -> HomeSection {
        let wanted = HomeSection(rawValue: raw) ?? fallback
        let open = available(prefs)
        if open.contains(wanted) { return wanted }
        // Land on the nearest available section rather than always on the first one — nearest
        // in the order the user put them in, which is the order they are stepped through.
        let all = ordered(prefs)
        guard let index = all.firstIndex(of: wanted) else { return fallback }
        let after = all[index...].first { open.contains($0) }
        let before = all[..<index].last { open.contains($0) }
        return after ?? before ?? fallback
    }
}
