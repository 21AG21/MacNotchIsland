import AppKit
import Combine

/// Apps the user keeps in the island's Actions section: a small dock in the notch.
///
/// Only the path is stored, so an app that is moved or deleted simply stops appearing rather
/// than leaving a tile that opens nothing. Icons come from the file system and are cached for
/// as long as the app is still where it was.
final class FavoriteApps: ObservableObject {
    static let shared = FavoriteApps()

    /// Paths, in the order they are shown.
    @Published private(set) var paths: [String] {
        didSet { UserDefaults.standard.set(paths, forKey: Self.key) }
    }

    static let key = "favoriteApps"
    /// The most apps kept, however few Shortcuts share the row with them. The row holds ten
    /// buttons between the two lists (`QuickActionsRowView.capacity`), and six apps leave four
    /// of them for Shortcuts.
    static let maximum = 6

    private var icons: [String: NSImage] = [:]

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [String] ?? []
        paths = Array(stored.prefix(Self.maximum))
    }

    /// The apps that are still on disk, as (path, name) pairs in the stored order.
    ///
    /// An app that has been deleted or moved is dropped from the list itself, not just from
    /// what is shown: leaving it stored would keep a slot occupied by something the user can
    /// no longer see, or remove.
    var apps: [(path: String, name: String)] {
        let live = paths.filter { FileManager.default.fileExists(atPath: $0) }
        let kept = paths.filter { Self.worthKeeping($0) }
        if kept != paths {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.paths != kept else { return }
                self.paths = kept
            }
        }
        return live.map { ($0, Self.name(of: $0)) }
    }

    /// The apps kept whose disk is not plugged in (`worthKeeping`, and not on disk), as (path,
    /// name) pairs in the stored order. The row does not draw them, but they keep their place
    /// and are back in it when the disk is, so Settings lists them, to be removed.
    var away: [(path: String, name: String)] {
        paths.filter { !FileManager.default.fileExists(atPath: $0) && Self.worthKeeping($0) }
            .map { ($0, Self.name(of: $0)) }
    }

    /// How many buttons the apps take in the Actions row now: the ones on disk, which is what
    /// the row draws (`apps`). What the row is shared out by as it stands — the room Settings
    /// leaves the Shortcuts, its tally, and the Home tile. Settings counted `paths` and the row
    /// `apps`, so an app on a disk that was not plugged in left Settings one Shortcut short of
    /// the room the row actually had. Adding an app counts every app kept (`hasRoom`).
    var inRow: Int { apps.count }

    /// Every app kept, plugged in or not: the row's share once every disk is back.
    var keptCount: Int { paths.filter { Self.worthKeeping($0) }.count }

    /// Whether another app can be kept beside `room`, the most the row leaves the apps. Pure,
    /// so the rule is tested.
    ///
    /// Every app kept counts (`keptCount`), not only the ones the row draws now. Counted as
    /// the row draws them, an app on a disk that was not plugged in left room for one more;
    /// Settings added it, and when the disk came back the row drew both and pushed a favourite
    /// Shortcut out without a word — what `add` is there to prevent.
    static func hasRoom(stored: Int, room: Int) -> Bool {
        stored < min(room, maximum)
    }

    /// `hasRoom`, for the apps kept now.
    func hasRoom(beside room: Int) -> Bool {
        Self.hasRoom(stored: keptCount, room: room)
    }

    /// Whether a path is still worth storing. A deleted app is forgotten; an app whose whole
    /// folder has gone is on a disk that is not plugged in, and comes back when it is.
    static func worthKeeping(_ path: String, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        let folder = (path as NSString).deletingLastPathComponent
        return !folder.isEmpty && !fileManager.fileExists(atPath: folder)
    }

    /// Fills the row for the rendered gallery. Does nothing outside it, so the only defaults
    /// this can ever write to are the test runner's own.
    func seedForGallery(_ paths: [String]) {
        guard RenderMode.isGallery else { return }
        self.paths = Array(paths.prefix(Self.maximum))
    }

    static func name(of path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    func icon(for path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Keeps an app. `room` is how many apps the row can show beside the favourite Shortcuts
    /// it shares with, which Settings works out: an app added past it would push a Shortcut
    /// out of the row without a word, now or when a disk comes back. Counted the way the
    /// button that calls this is, see `hasRoom`.
    func add(_ url: URL, room: Int = FavoriteApps.maximum) {
        let path = url.path
        guard !paths.contains(path), hasRoom(beside: room) else { return }
        paths.append(path)
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        icons[path] = nil
    }

    func move(_ path: String, up: Bool) {
        guard let index = paths.firstIndex(of: path) else { return }
        let target = up ? index - 1 : index + 1
        guard paths.indices.contains(target) else { return }
        paths.swapAt(index, target)
    }

    func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The panel is a place to launch from, not to look at afterwards.
    func launch(_ path: String) {
        ActivityCenter.shared.collapse(reason: "opened an app")
        open(path)
    }
}
