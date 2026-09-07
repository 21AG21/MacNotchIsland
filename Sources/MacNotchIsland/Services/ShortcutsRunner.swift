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
            let output = Self.capture(arguments: ["list"])
            let names = Self.parseList(output ?? "")
            DispatchQueue.main.async { self?.available = names }
        }
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

        Self.queue.async {
            let result = Self.execute(arguments: ["run", name])
            DispatchQueue.main.async {
                ActivityCenter.shared.end(id: activityID)
                if result.succeeded {
                    ActivityCenter.shared.showAlert(IslandActivity(
                        id: activityID + "-result", kind: .custom,
                        content: .custom(CustomActivity(title: "Done", symbol: "checkmark.circle.fill", tint: "green")),
                        priority: 90), duration: 2)
                } else {
                    ActivityCenter.shared.showAlert(IslandActivity(
                        id: activityID + "-result", kind: .custom,
                        content: .custom(CustomActivity(title: "Failed", subtitle: result.stderrFirstLine, symbol: "xmark.circle.fill", tint: "red")),
                        priority: 90), duration: 2)
                }
            }
        }
    }

    private struct ProcessResult {
        var succeeded: Bool
        var stderrFirstLine: String?
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
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderrText = String(data: errorData, encoding: .utf8) ?? ""
        let firstLine = stderrText
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ProcessResult(succeeded: process.terminationStatus == 0, stderrFirstLine: firstLine)
    }

    private static func capture(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
