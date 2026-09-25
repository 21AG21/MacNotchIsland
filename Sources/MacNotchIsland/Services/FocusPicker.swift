import AppKit
import Foundation

/// What the rail's Focus popover lists: Off, then every Focus this Mac has, the one that is on
/// marked — worked out from what could be read and whether there is a way to set one.
///
/// Off comes first and stays there. It is the one row every Mac has, and the only one whose
/// place does not move with how many modes somebody has made, so the hand can learn it.
///
/// Pure, so the popover's contents can be tested without a Focus database or a shortcut.
struct FocusPickerRows: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String
        let tint: String
        let isActive: Bool
        /// What the "Set Focus" shortcut is handed for this row: the mode's name, or "Off".
        /// Nil where a click would change nothing — the row that is already on — or could do
        /// nothing, because there is no shortcut to hand it to.
        let input: String?
        /// What VoiceOver says for the row. The name alone for a mode; Off is "Focus off",
        /// since a lone "Off" says nothing about what is off.
        let spokenLabel: String
        /// "On" for the row that is on, nothing for the rest.
        let spokenValue: String
        /// Why the row does nothing, when it does nothing for want of the shortcut.
        let spokenHint: String?
        /// The tooltip: what a click does, or why it does nothing.
        let help: String
    }

    static let offID = "off"
    /// The word the shortcut is handed for Off. English whatever the Mac's language, like the
    /// shortcut's own name: it is a value for a shortcut to test, not a label for a person.
    static let offInput = "Off"

    let rows: [Row]
    /// There is no shortcut named "Set Focus" yet, and the popover says how to make one.
    let needsShortcut: Bool
    /// The modes could not be read, so only Do Not Disturb — which every Mac has, under that
    /// name — is offered, and the popover says why the rest are missing.
    let modesUnread: Bool

    static let setupNote = "Make a shortcut named \u{201C}Set Focus\u{201D} that sets Focus from its input"
    static let unreadNote = "Your other Focus modes can be listed with Full Disk Access."

    /// `active` is the identifier of the Focus that is on, or nil when none is.
    init(modes: [FocusMode], active: String?, hasShortcut: Bool) {
        modesUnread = modes.isEmpty
        needsShortcut = !hasShortcut
        // Unread, nothing is known to be on — Off included. The folder the modes are listed in
        // is the folder the Focus that is on is read from, so marking Off would be saying no
        // Focus is on, on a Mac where the island cannot see whether one is.
        let known = !modes.isEmpty
        let listed = known ? modes : [FocusMode.doNotDisturb]
        let hint = hasShortcut ? nil : "Needs a shortcut named Set Focus"
        let offOn = known && active == nil
        let off = Row(id: Self.offID, title: "Off", symbol: "circle.slash", tint: "gray", isActive: offOn,
                      input: hasShortcut && !offOn ? Self.offInput : nil,
                      spokenLabel: "Focus off", spokenValue: offOn ? "On" : "", spokenHint: hint,
                      help: hint ?? (offOn ? "No Focus is on" : "Turn Focus off"))
        rows = [off] + listed.map { mode in
            let on = known && mode.identifier == active
            return Row(id: mode.identifier, title: mode.name, symbol: mode.symbol, tint: mode.tint, isActive: on,
                       input: hasShortcut && !on ? mode.name : nil,
                       spokenLabel: mode.name, spokenValue: on ? "On" : "", spokenHint: hint,
                       help: hint ?? (on ? "\(mode.name) is on" : "Turn on \(mode.name)"))
        }
    }
}

/// Sets a Focus the one way a third-party app honestly can: through a shortcut the person has
/// made. macOS has no public call for it, and the private ones change from one release to the
/// next; Shortcuts' own Set Focus action is the supported route, so a pick runs a shortcut
/// named "Set Focus" through `ShortcutsRunner`, the way every other shortcut on the island is
/// run, handed a text file holding the mode's name or "Off".
enum FocusSetter {
    static let shortcutName = "Set Focus"
    static let shortcutsApp = URL(string: "shortcuts://")

    /// The shortcut as the Shortcuts app lists it, when it is there. Matched without regard to
    /// case or the spaces round it, which nobody sees in a list, and run by the name the list
    /// gave, which is the one `shortcuts run` knows.
    static func shortcut(in available: [String]) -> String? {
        available.first {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(shortcutName) == .orderedSame
        }
    }

    /// The input file's name. It is the mode's name, because the island's "Running on …" line
    /// names the file it ran on, and "Work.txt" says what is happening where a random name
    /// would not; a ".txt" so the shortcut is handed text rather than an unknown file. What a
    /// file name cannot hold — a slash, a colon, a leading dot — is replaced, and a name with
    /// nothing left in it is "Focus".
    static func inputFileName(for input: String) -> String {
        var name = input.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return (name.isEmpty ? "Focus" : name) + ".txt"
    }

    /// Writes the input to a file of its own and runs the shortcut on it. The file is in the
    /// island's own temporary folder and is simply written again next time; macOS clears the
    /// folder, and one small file per mode is all it ever holds.
    static func set(_ input: String, shortcut: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Set Focus", isDirectory: true)
        let file = folder.appendingPathComponent(inputFileName(for: input))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // No newline after it: a shortcut that compares its input with "Work" would find
            // "Work\n" was not it.
            try Data(input.utf8).write(to: file, options: .atomic)
        } catch {
            IslandLog.island.error("set focus: could not write the input: \(error.localizedDescription, privacy: .public)")
            return
        }
        ShortcutsRunner.shared.run(shortcut, inputPaths: [file.path])
    }
}
