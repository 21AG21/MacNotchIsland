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
    /// True from the moment the text changes until exactly that text has been written.
    private var unsaved = false
    private static let fileName = "notes.txt"

    private init() {
        text = IslandFiles.read(Self.fileName).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func clear() { text = "" }

    /// Writes anything still waiting, now, on the calling thread. The debounce below is eight
    /// tenths of a second and a quit from the menu bar is faster than that, so without this
    /// the last sentence somebody typed is the one they lose. A scratchpad nobody has touched
    /// writes nothing, so no file appears for a feature that was never used.
    func flush() {
        guard unsaved else { return }
        persistWork?.cancel()
        persistWork = nil
        unsaved = false
        persist(text)
    }

    func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func schedulePersist() {
        unsaved = true
        persistWork?.cancel()
        let snapshot = text
        let work = DispatchWorkItem { [weak self] in
            self?.persist(snapshot)
            DispatchQueue.main.async { [weak self] in self?.markSaved(snapshot) }
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Only what was actually written counts as written: a keystroke that landed while the
    /// write was in flight leaves the flag up, so the next write — or the flush on the way
    /// out — still has something to do.
    private func markSaved(_ snapshot: String) {
        if snapshot == text { unsaved = false }
    }

    private func persist(_ snapshot: String) {
        do {
            try IslandFiles.write(Data(snapshot.utf8), to: Self.fileName)
        } catch {
            IslandLog.store.error("notes save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
