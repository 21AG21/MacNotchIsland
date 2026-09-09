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
    private static let fileName = "notes.txt"

    private init() {
        text = IslandFiles.read(Self.fileName).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
            do {
                try IslandFiles.write(Data(snapshot.utf8), to: Self.fileName)
            } catch {
                IslandLog.store.error("notes save failed: \(String(describing: error), privacy: .public)")
            }
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
