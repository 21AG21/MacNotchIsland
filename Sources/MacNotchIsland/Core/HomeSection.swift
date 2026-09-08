import Foundation

/// The sections of the Home panel, in the order the switcher shows them. The one list the
/// switcher, the keyboard ring, the swipes, the URL scheme and the panel itself all read.
enum HomeSection: String, CaseIterable {
    case music, today, windows, shelf, clipboard, actions, notes, stats

    var title: String {
        switch self {
        case .music: return "Now Playing"
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
        case .music: return "music.note"
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
        case .music: return true
        case .today: return prefs.calendarEnabled
        case .windows: return prefs.windowsEnabled
        case .shelf: return prefs.shelfEnabled
        case .clipboard: return prefs.clipboardEnabled
        case .actions: return prefs.quickActionsEnabled
        case .notes: return prefs.notesEnabled
        case .stats: return prefs.statsEnabled
        }
    }

    static func available(_ prefs: Preferences) -> [HomeSection] {
        allCases.filter { $0.isEnabled(prefs) }
    }

    static let fallback = HomeSection.music

    /// The section a raw tab name maps to, or the nearest one that is switched on.
    static func resolve(_ raw: String, prefs: Preferences) -> HomeSection {
        let wanted = HomeSection(rawValue: raw) ?? fallback
        let open = available(prefs)
        if open.contains(wanted) { return wanted }
        // Land on the nearest available section rather than always on the first one.
        let all = allCases
        guard let index = all.firstIndex(of: wanted) else { return fallback }
        let after = all[index...].first { open.contains($0) }
        let before = all[..<index].last { open.contains($0) }
        return after ?? before ?? fallback
    }
}
