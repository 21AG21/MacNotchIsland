import AppKit
import Combine
import Foundation

/// One scratchpad, kept on this Mac in Application Support, written a moment after the last
/// keystroke. Nothing syncs, nothing leaves the machine.
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var text: String {
        didSet { if text != oldValue { schedulePersist() } }
    }

    private var persistWork: DispatchWorkItem?
    private static let file: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("MacNotchIsland", isDirectory: true).appendingPathComponent("notes.txt")
    }()

    private init() {
        text = Self.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    func clear() { text = "" }

    func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let snapshot = text
        let work = DispatchWorkItem {
            guard let url = Self.file else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? snapshot.write(to: url, atomically: true, encoding: .utf8)
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
