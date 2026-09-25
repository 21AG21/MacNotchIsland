import AppKit
import Combine
import Foundation

/// One scratchpad, kept on this Mac in Application Support, written a moment after the last
/// keystroke. Nothing syncs, nothing leaves the machine.
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    /// Empty until `loadIfNeeded` reads the file. A `didSet` that persists means the default
    /// must never be written back on its own: nothing here schedules a save unless the text
    /// actually changes, and loading assigns the file's own contents.
    @Published var text: String = "" {
        didSet { if text != oldValue { schedulePersist() } }
    }

    private var persistWork: DispatchWorkItem?
    /// True from the moment the text changes until exactly that text has been written.
    private var unsaved = false
    private static let fileName = "notes.txt"

    /// Why the scratchpad on screen is not the one on disk, in a few words ("Disk full"); nil
    /// while every write has landed. A write used to fail into the log and nowhere else, so a
    /// full disk or an Application Support nobody may write in lost everything typed after it
    /// without a word — the text sat on screen looking kept until the next launch. The Notes
    /// header shows this as a pill, and the next write that lands takes it down.
    @Published private(set) var saveFailed: String?

    /// The name an unreadable scratchpad was moved aside to at launch, beside where it was.
    /// Set once and never cleared: it is what the empty scratchpad says instead of its usual
    /// invitation, so a week of notes that has seemingly vanished says where it went.
    @Published private(set) var setAsideName: String?

    /// Set when a scratchpad that could not be read could not be moved out of the way either.
    /// Nothing is written over it then, for the rest of the run: it is somebody's notes, in a
    /// form this app cannot read, and the first keystroke used to replace it.
    private var heldBack = false

    /// Whether the scratchpad on disk has been read yet. See `loadIfNeeded`.
    private var loaded = false

    private init() {}

    /// Reads the scratchpad, once, and never from `init` — see the note on
    /// `NotificationInbox.loadIfNeeded`. A singleton built while the copy being replaced is
    /// still writing its last save out reads the old text and then writes it back over the new
    /// one, and a week of somebody's notes goes with it.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        switch Self.readScratchpad() {
        case .text(let saved):
            text = saved
        // Neither of these touches `text`: it is empty unless something was typed before the
        // read, and that is the one thing here that is certainly the user's.
        case .setAside(let name):
            setAsideName = name
            announceSetAside(name)
        case .stuck:
            heldBack = true
            // A write scheduled before the read did not know to hold back.
            persistWork?.cancel()
            persistWork = nil
            saveFailed = Self.heldBackReason
        }
    }

    // MARK: - Reading it back (pure but for the disk, and driven by the tests)

    /// What reading the scratchpad at launch found.
    enum Loaded: Equatable {
        /// What it says, or "" when there is no scratchpad yet.
        case text(String)
        /// It was there but was not text this app can read — not UTF-8, or not readable at
        /// all — and has been renamed to this, beside where it was, before anything could be
        /// written over it. The scratchpad starts empty.
        case setAside(String)
        /// Unreadable, and it could not be moved aside either. See `heldBack`.
        case stuck
    }

    /// Reads the scratchpad without assigning it. A file that is there but is not UTF-8 used
    /// to read as an empty scratchpad, and the first keystroke wrote that over it; a file
    /// saved from another editor in another encoding is still somebody's notes. It is moved
    /// aside, never deleted and never rewritten, and the move comes first, so nothing typed
    /// after it can land on top of it.
    static func readScratchpad(now: Date = Date()) -> Loaded {
        guard let url = IslandFiles.folder?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: url.path) else { return .text("") }
        if let data = try? Data(contentsOf: url), let saved = String(data: data, encoding: .utf8) {
            return .text(saved)
        }
        let folder = url.deletingLastPathComponent()
        let stem = unreadableName(at: now)
        var name = stem
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(n)"
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(name))
            IslandLog.store.error("notes could not be read; moved aside as \(name, privacy: .public)")
            return .setAside(name)
        } catch {
            IslandLog.store.error("notes could not be read or moved aside: \(String(describing: error), privacy: .public)")
            return .stuck
        }
    }

    /// "notes.txt.unreadable-2026-09-25-143205": the day and the second, so a second one does
    /// not land on the first, and a name that still says what the file was.
    static func unreadableName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(fileName).unreadable-\(formatter.string(from: date))"
    }

    /// Said once, at launch, as the island's card; after that the empty scratchpad says it.
    /// A click opens the folder the file is in.
    private func announceSetAside(_ name: String) {
        let custom = CustomActivity(title: "Notes couldn't be read", subtitle: "Kept aside as \(name)",
                                    symbol: "exclamationmark.triangle.fill", tint: "orange")
        var alert = IslandActivity(id: "notes-set-aside", kind: .custom, content: .custom(custom),
                                   priority: 85, presentation: .expanded)
        if let folder = IslandFiles.folder { alert.openAction = .url(folder) }
        ActivityCenter.shared.showAlert(alert, duration: 6)
    }

    /// What the last Clear took away, for as long as the offer to put it back stands. One
    /// stray click on a scratchpad somebody has been keeping for a week is not a pairing to
    /// leave alone, and a panel that closes when you look away is no place for a modal.
    @Published private(set) var clearedText: String?
    private var clearedWork: DispatchWorkItem?
    /// How long "Undo Clear" is offered for.
    static let undoWindow: TimeInterval = 12

    func clear() {
        let previous = text
        text = ""
        // A second Clear supersedes the first: there is one offer at a time, and it is always
        // the most recent thing that was taken away.
        forgetUndo()
        guard !previous.isEmpty else { return }
        clearedText = previous
        let work = DispatchWorkItem { [weak self] in self?.forgetUndo() }
        clearedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: work)
    }

    /// Puts back what Clear took. The offer is only ever shown while the scratchpad is still
    /// empty, so this can never overwrite something typed since.
    func undoClear() {
        guard let clearedText, text.isEmpty else { return }
        text = clearedText
        forgetUndo()
    }

    private func forgetUndo() {
        clearedWork?.cancel()
        clearedWork = nil
        clearedText = nil
    }

    /// Writes anything still waiting, now, on the calling thread. The debounce below is eight
    /// tenths of a second and a quit from the menu bar is faster than that, so without this
    /// the last sentence somebody typed is the one they lose. A scratchpad nobody has touched
    /// writes nothing, so no file appears for a feature that was never used. Also what the
    /// "Not saved" pill does when it is clicked: a write that failed leaves the text waiting,
    /// so this tries it again.
    func flush() {
        guard unsaved else { return }
        persistWork?.cancel()
        persistWork = nil
        let failure = Self.persist(text, heldBack: heldBack)
        unsaved = failure != nil
        saveFailed = failure
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
        let held = heldBack
        let work = DispatchWorkItem { [weak self] in
            let failure = Self.persist(snapshot, heldBack: held)
            DispatchQueue.main.async { self?.markSaved(snapshot, failure: failure) }
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Only what was actually written counts as written: a keystroke that landed while the
    /// write was in flight leaves the flag up, so the next write — or the flush on the way
    /// out — still has something to do. A write that failed leaves it up too, and says why;
    /// one for text that has since changed says nothing either way, since the write of what
    /// is on screen now is already on its way and will.
    private func markSaved(_ snapshot: String, failure: String?) {
        guard snapshot == text else { return }
        if failure == nil { unsaved = false }
        saveFailed = failure
    }

    /// Writes the scratchpad, on whatever thread it is called from. Nil when it landed,
    /// otherwise the few words the pill says.
    private static func persist(_ snapshot: String, heldBack: Bool) -> String? {
        if heldBack { return heldBackReason }
        do {
            try IslandFiles.write(Data(snapshot.utf8), to: fileName)
            return nil
        } catch {
            IslandLog.store.error("notes save failed: \(String(describing: error), privacy: .public)")
            return saveFailedReason(for: error)
        }
    }

    /// What the pill says while an unreadable scratchpad that could not be moved aside is
    /// being left alone.
    static let heldBackReason = "Old notes in the way"

    /// A write's failure in the few words a pill has room for. The error's own description —
    /// "The file “notes.txt” couldn’t be saved because there isn’t enough space." — is a
    /// paragraph; the log keeps that, and the pill says which of the few things it usually
    /// is. Pure, so the table can be tested without filling a disk.
    static func saveFailedReason(for error: Error) -> String {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace: return "Disk full"
            case .fileWriteVolumeReadOnly: return "Disk is read-only"
            case .fileWriteNoPermission: return "No permission"
            default: break
            }
        }
        // Foundation often wraps the system's own answer rather than naming it.
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix = [ns, underlying].compactMap({ $0 }).first(where: { $0.domain == NSPOSIXErrorDomain }) else {
            return "Could not write"
        }
        switch Int32(truncatingIfNeeded: posix.code) {
        case ENOSPC, EDQUOT: return "Disk full"
        case EROFS: return "Disk is read-only"
        case EACCES, EPERM: return "No permission"
        default: return "Could not write"
        }
    }
}
