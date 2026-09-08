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
    /// The row is shared with the Shortcuts favourites; this is what fits beside them.
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

    /// Whether a path is still worth storing. A deleted app is forgotten; an app whose whole
    /// folder has gone is on a disk that is not plugged in, and comes back when it is.
    static func worthKeeping(_ path: String, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        let folder = (path as NSString).deletingLastPathComponent
        return !folder.isEmpty && !fileManager.fileExists(atPath: folder)
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

    func add(_ url: URL) {
        let path = url.path
        guard !paths.contains(path), paths.count < Self.maximum else { return }
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
