import Foundation

/// Type-to-find: the rule for which sections can be searched, and what counts as a match.
///
/// Four of the panel's sections are lists of many things — every open window, every recent
/// copy, everything on the shelf, everything that came past on a banner — and a list of many
/// things is something you look through. The Mac's answer to that has always been to start
/// typing: Finder, Mail, the Font panel and every table in the system narrow to what you
/// typed. The island does the same, and because it must never sit between somebody and their
/// own text it claims the letters only while the panel is pinned open on one of those four.
///
/// Pure, so the rules can be tested without a window server.
enum PanelFind {
    /// The sections a find applies to. Now Playing is one thing, Stats is a dashboard, Notes
    /// and the Today card are read rather than searched — none of them is a list to look
    /// through, so none of them takes the letters.
    static let sections: Set<HomeSection> = [.windows, .clipboard, .shelf, .notifications]

    /// Whether a section answers the letters.
    static func searches(_ section: HomeSection?) -> Bool {
        guard let section else { return false }
        return sections.contains(section)
    }

    /// What is actually searched for: the query without the space either side of it.
    static func needle(_ query: String?) -> String? {
        let trimmed = query?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether one row matches. Any of its fields will do — a window is found by its app's
    /// name or by its title — and the comparison is the one the rest of macOS uses for a
    /// search field: case- and diacritic-insensitive, and numerically sensible, so "cafe"
    /// finds "Café" and "page 2" sorts beside "page 10".
    static func matches(_ fields: [String], query: String?) -> Bool {
        guard let needle = needle(query) else { return true }
        return fields.contains { $0.localizedStandardContains(needle) }
    }

    /// A character worth starting a find with: one letter, and not one the panel already
    /// spends on something else. The digits go to the switcher and Space plays and pauses,
    /// so neither of those may open the field.
    static func opensFind(_ character: String) -> Bool {
        guard character.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    // MARK: - Typing a timer

    /// The sections whose field takes figures rather than a search: Actions, where what is
    /// typed is a timer's minutes or an alarm's time (`TimerEntry.parse`). The same field, the
    /// same way in — start typing — and the same way out, Escape.
    static let entrySections: Set<HomeSection> = [.actions]

    /// Whether a section's field is the timer entry.
    static func takesEntry(_ section: HomeSection?) -> Bool {
        guard let section else { return false }
        return entrySections.contains(section)
    }

    /// A key worth starting a timer with: one of the ten digits. On Actions the digits start
    /// the entry instead of stepping the switcher, which is the one section where a number
    /// means something of its own.
    static func opensEntry(_ character: String) -> Bool {
        guard character.count == 1, let first = character.first else { return false }
        return first.isASCII && first.isNumber
    }

    /// Whether this key press on this section opens the field: a letter on a list, a digit on
    /// Actions, and nothing anywhere else.
    static func begins(with character: String, on section: HomeSection?) -> Bool {
        if opensFind(character) { return searches(section) }
        if opensEntry(character) { return takesEntry(section) }
        return false
    }

    /// Whether the section has a field at all, for the glass or the timer glyph clicked.
    static func hasField(_ section: HomeSection?) -> Bool {
        searches(section) || takesEntry(section)
    }
}
