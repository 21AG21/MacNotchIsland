import Foundation
import Combine
import SwiftUI

/// Runs the user's Shortcuts from the island — NotchNook's most-cited feature, with zero
/// extra permissions: it only ever shells out to Apple's own `/usr/bin/shortcuts` CLI.
final class ShortcutsRunner: ObservableObject {
    static let shared = ShortcutsRunner()

    /// Every shortcut installed on this Mac, as reported by `shortcuts list`.
    @Published private(set) var available: [String] = []

    /// Names pinned to the island's quick actions row, in display order. Capped at 8.
    @Published var favorites: [String] {
        didSet { UserDefaults.standard.set(favorites, forKey: Self.favoritesKey) }
    }

    private var symbolOverrides: [String: String]

    private static let favoritesKey = "quickActionFavorites"
    private static let symbolsKey = "quickActionSymbols"
    private static let maxFavorites = 8
    private static let binaryPath = "/usr/bin/shortcuts"
    private static let queue = DispatchQueue(label: "com.macnotchisland.shortcuts", qos: .userInitiated)

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.favoritesKey) as? [String] ?? []
        favorites = Array(stored.prefix(Self.maxFavorites))
        symbolOverrides = UserDefaults.standard.dictionary(forKey: Self.symbolsKey) as? [String: String] ?? [:]
    }

    /// Clears in-memory state. Used by the test suite.
    func resetForTesting() {
        available = []
        favorites = []
        symbolOverrides = [:]
    }

    // MARK: - Discovery

    func refresh() {
        guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else {
            available = []
            return
        }
        Self.queue.async { [weak self] in
            let result = Self.capture(arguments: ["list"])
            let names = Self.parseList(result.output ?? "")
            DispatchQueue.main.async {
                guard let self else { return }
                self.available = names
                guard result.succeeded else { return }
                self.pruneFavorites(against: names)
            }
        }
    }

    /// Drops favourites the Shortcuts app no longer has, so the row never offers a button
    /// that can only fail. Only ever called for a listing that exited cleanly, and never on an
    /// empty one: a Shortcuts app that is busy, missing, or still syncing from iCloud must not
    /// be taken as proof that every favourite has gone.
    private func pruneFavorites(against names: [String]) {
        guard !names.isEmpty else { return }
        let live = favorites.filter { names.contains($0) }
        guard live != favorites else { return }
        favorites = live
    }

    /// Parses `shortcuts list` output: one name per line, trimmed, blank lines dropped.
    static func parseList(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Running

    /// Runs a shortcut by name, showing a Live Activity while it's in flight and a
    /// Done/Failed alert when it exits.
    func run(_ name: String) {
        guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else { return }
        let activityID = "shortcut-\(name)"

        ActivityCenter.shared.upsert(IslandActivity(
            id: activityID, kind: .custom,
            content: .custom(CustomActivity(title: name, subtitle: "Running…", symbol: symbol(for: name), tint: "purple")),
            priority: 75))

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.execute(arguments: ["run", name])
            DispatchQueue.main.async {
                ActivityCenter.shared.end(id: activityID)
                if result.succeeded {
                    // The word goes in the trailing slot, which is the only half of the pill
                    // that carries text. As the title it was invisible: the pill showed a
                    // green tick beside the ellipsis a custom activity draws when it has no
                    // value to put there. The name is still the title, so resting on it names
                    // the shortcut that finished.
                    ActivityCenter.shared.showAlert(IslandActivity(
                        id: activityID + "-result", kind: .custom,
                        content: .custom(CustomActivity(title: name, symbol: "checkmark.circle.fill",
                                                        tint: "green", trailingText: "Done")),
                        priority: 90), duration: 2)
                } else {
                    // A failure opens as the card and stays long enough to read. The reason
                    // the Shortcuts app gave was being handed to a pill that has nowhere to
                    // draw a subtitle, so it went nowhere at all.
                    ActivityCenter.shared.showAlert(IslandActivity(
                        id: activityID + "-result", kind: .custom,
                        content: .custom(CustomActivity(title: name,
                                                        subtitle: Self.reason(from: result.stderrFirstLine),
                                                        symbol: "exclamationmark.triangle.fill",
                                                        tint: "red", trailingText: "Failed")),
                        priority: 90, presentation: .expanded), duration: 5)
                }
            }
        }
    }

    private struct ProcessResult {
        var succeeded: Bool
        var stderrFirstLine: String?
    }

    /// What `shortcuts` printed, tidied into one line of a card: trimmed, and cut at a length
    /// that still ends in a whole word. Nil or blank becomes a sentence rather than a gap,
    /// because a failure with no reason at all still has to say that it failed.
    static func reason(from stderr: String?) -> String {
        let text = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "The Shortcuts app gave no reason." }
        let limit = 64
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(head)
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func execute(arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(succeeded: false, stderrFirstLine: error.localizedDescription)
        }
        // A shortcut that waits on a dialog forever must not pin a Live Activity forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { [process] in
            if process.isRunning { process.terminate() }
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderrText = String(data: errorData, encoding: .utf8) ?? ""
        let firstLine = stderrText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ProcessResult(succeeded: process.terminationStatus == 0, stderrFirstLine: firstLine)
    }

    /// Runs `shortcuts` and returns what it printed, and whether it said it succeeded. The
    /// exit status matters: a listing that failed half way is not evidence that a shortcut
    /// has gone.
    private static func capture(arguments: [String]) -> (output: String?, succeeded: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (nil, false)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8), process.terminationStatus == 0)
    }

    // MARK: - Favorites

    func isFavorite(_ name: String) -> Bool { favorites.contains(name) }

    func toggleFavorite(_ name: String) {
        if let index = favorites.firstIndex(of: name) {
            favorites.remove(at: index)
        } else {
            guard favorites.count < Self.maxFavorites else { return }
            favorites.append(name)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Symbols

    /// The glyph shown for a shortcut: a user override if set, else a keyword-based default.
    func symbol(for name: String) -> String {
        symbolOverrides[name] ?? Self.defaultSymbol(for: name)
    }

    /// Explicit override the user picked for this shortcut, if any (for editing UI).
    func symbolOverride(for name: String) -> String? { symbolOverrides[name] }

    func setSymbol(_ symbol: String, for name: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            symbolOverrides.removeValue(forKey: name)
        } else {
            symbolOverrides[name] = trimmed
        }
        UserDefaults.standard.set(symbolOverrides, forKey: Self.symbolsKey)
    }

    /// A sensible default SF Symbol chosen by keyword in the shortcut's name.
    static func defaultSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("focus") { return "moon.fill" }
        if lower.contains("wifi") { return "wifi" }
        if lower.contains("bluetooth") { return "bolt.horizontal" }
        if lower.contains("dark") || lower.contains("light") { return "circle.lefthalf.filled" }
        if lower.contains("screenshot") { return "camera.viewfinder" }
        return "bolt.fill"
    }
}
