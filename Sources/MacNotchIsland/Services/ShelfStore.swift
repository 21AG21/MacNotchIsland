import AppKit
import Combine
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One file kept on the shelf. `addedAt` drives the age label and the expiry sweep.
struct ShelfItem: Identifiable, Equatable, Hashable {
    let url: URL
    var addedAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Files dropped on the notch. Persists paths (with the date they landed) across launches,
/// caches thumbnails, sweeps items older than `Preferences.shelfExpiryHours`, and performs
/// the Finder-style actions the shelf offers (open, reveal, AirDrop, share, copy, trash).
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { if items != oldValue { publishActivity() } }
    }
    @Published private var thumbnails: [URL: NSImage] = [:]
    /// Whether this store owns the island's "shelf" activity. Only the shared store does;
    /// the stores the tests build must not touch the real ActivityCenter unless asked.
    var publishesActivity: Bool

    /// Hours after which an item is swept off the shelf (0 = never). Injectable for tests.
    var expiryHoursProvider: () -> Double = { Preferences.shared.shelfExpiryHours }

    private let defaults: UserDefaults
    private let key: String
    private let maxItems: Int
    /// False in tests: no sweep timer and no QuickLook traffic.
    private let backgroundWork: Bool

    private var sweepTimer: Timer?
    private var sharingPicker: NSSharingServicePicker?

    private var thumbnailQueue: [URL] = []
    private var thumbnailsInFlight = 0
    private static let maxConcurrentThumbnails = 4
    private static let baseSweepInterval: TimeInterval = 300

    init(defaults: UserDefaults = .standard,
         key: String = "shelfItems",
         maxItems: Int = 24,
         backgroundWork: Bool = true,
         expiryHours: (() -> Double)? = nil,
         publishesActivity: Bool? = nil) {
        self.defaults = defaults
        self.key = key
        self.maxItems = max(1, maxItems)
        self.backgroundWork = backgroundWork
        self.publishesActivity = publishesActivity ?? backgroundWork
        if let expiryHours { expiryHoursProvider = expiryHours }

        var loaded = Self.load(from: defaults, key: key)
        loaded = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if loaded.count > self.maxItems { loaded = Array(loaded.prefix(self.maxItems)) }
        items = loaded

        sweepExpired()
        persist()
        for item in items { requestThumbnail(item.url) }
        rescheduleSweep()
        // `didSet` does not run during init; announce whatever was loaded.
        publishActivity()
    }

    // MARK: - Island activity

    /// The shelf activity: the island's way of showing that files are waiting. It lives while
    /// the shelf holds anything and ends when the last file leaves.
    static let activityID = "shelf"

    static func activity(for items: [ShelfItem]) -> IslandActivity? {
        guard let latest = items.first else { return nil }
        let type = UTType(filenameExtension: latest.url.pathExtension)
        let state = ShelfState(count: items.count, latestName: latest.name,
                               latestIsImage: type?.conforms(to: .image) ?? false)
        return IslandActivity(id: activityID, kind: .shelf, content: .shelf(state), priority: 30)
    }

    /// Re-evaluates the activity, e.g. when the shelf is switched on or off in Settings.
    func refreshActivity() { publishActivity() }

    private func publishActivity() {
        guard publishesActivity else { return }
        let center = ActivityCenter.shared
        if Preferences.shared.shelfEnabled, let activity = Self.activity(for: items) {
            center.upsert(activity)
        } else {
            center.end(id: Self.activityID)
        }
    }

    // MARK: - Contents

    var urls: [URL] { items.map(\.url) }

    func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        return items.contains { $0.url == target }
    }

    func thumbnail(for url: URL) -> NSImage? { thumbnails[url.standardizedFileURL] }

    func add(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }.map { $0.standardizedFileURL }
        guard !files.isEmpty else { return }

        let now = Date()
        var next = items
        for url in files {
            next.removeAll { $0.url == url }
            next.insert(ShelfItem(url: url, addedAt: now), at: 0)
        }
        // Cap *before* asking for thumbnails so dropping hundreds of files stays cheap.
        if next.count > maxItems { next = Array(next.prefix(maxItems)) }
        items = Self.pruned(next, expiryHours: expiryHoursProvider(), now: now)

        pruneThumbnailCache()
        for item in items { requestThumbnail(item.url) }
        persist()
        rescheduleSweep()
        Haptics.tap()
    }

    func remove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let targets = Set(urls.map { $0.standardizedFileURL })
        let before = items.count
        items.removeAll { targets.contains($0.url) }
        guard items.count != before else { return }
        discardOwned(Array(targets))
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
    }

    func remove(_ url: URL) { remove([url]) }

    func clear() {
        guard !items.isEmpty else { return }
        let leaving = urls
        items.removeAll()
        thumbnails.removeAll()
        thumbnailQueue.removeAll()
        discardOwned(leaving)
        persist()
        rescheduleSweep()
    }

    /// A picture, a link or a piece of text the island itself wrote has nowhere else to live,
    /// so it goes to the Trash when it leaves the shelf — recoverable, and it does not pile up
    /// in Application Support. A file that came from Finder is never touched.
    private func discardOwned(_ urls: [URL]) {
        let owned = urls.filter { Self.isOwned($0) }
        guard backgroundWork, !owned.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in owned {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    // MARK: - Expiry

    /// Pure expiry rule: items added more than `expiryHours` ago are dropped. 0 (or less)
    /// keeps everything forever.
    static func pruned(_ items: [ShelfItem], expiryHours: Double, now: Date = Date()) -> [ShelfItem] {
        guard expiryHours > 0 else { return items }
        let cutoff = now.addingTimeInterval(-expiryHours * 3600)
        return items.filter { $0.addedAt > cutoff }
    }

    /// Whether an item still has a file behind it.
    ///
    /// A file that was moved or deleted is gone from the shelf; a file whose whole folder has
    /// disappeared is on a disk that was unplugged, and the shelf keeps it, because plugging
    /// the disk back in should bring it back rather than having quietly emptied the shelf.
    static func stillThere(_ item: ShelfItem, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: item.url.path) { return true }
        return !fileManager.fileExists(atPath: item.url.deletingLastPathComponent().path)
    }

    /// Drops expired items, and any whose file has gone. Returns true when something was removed.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> Bool {
        let expiredGone = Self.pruned(items, expiryHours: expiryHoursProvider(), now: now)
        let kept = backgroundWork ? expiredGone.filter { Self.stillThere($0) } : expiredGone
        guard kept.count != items.count else { return false }
        let leaving = Set(items.map(\.url)).subtracting(kept.map(\.url))
        items = kept
        discardOwned(Array(leaving))
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
        return true
    }

    private func rescheduleSweep() {
        guard backgroundWork, !items.isEmpty else {
            sweepTimer?.invalidate()
            sweepTimer = nil
            return
        }
        let interval = Self.baseSweepInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
        if let timer = sweepTimer, timer.isValid, abs(timer.timeInterval - interval) < 1 { return }
        sweepTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sweepExpired()
            self.rescheduleSweep()
        }
        timer.tolerance = interval * 0.25
        sweepTimer = timer
    }

    // MARK: - Actions

    func open(_ urls: [URL]) {
        for url in urls { _ = NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        let objects: [Any] = urls
        guard service.canPerform(withItems: objects) else { return }
        // The AirDrop window takes the pointer off the island; keep the panel up and make
        // sure the picker gets focus even though this is a background app.
        ActivityCenter.shared.holdOpen(for: 30)
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: objects)
    }

    /// Share sheet anchored to an AppKit view. With no view (or no window) we fall back to
    /// AirDrop, which is the shelf's most common destination anyway.
    func share(_ urls: [URL], from view: NSView? = nil, rect: NSRect = .zero) {
        guard !urls.isEmpty else { return }
        guard let view, view.window != nil else {
            airDrop(urls)
            return
        }
        let objects: [Any] = urls
        let picker = NSSharingServicePicker(items: objects)
        sharingPicker = picker
        let anchor = rect == .zero ? view.bounds : rect
        ActivityCenter.shared.holdOpen(for: 30)
        NSApp.activate(ignoringOtherApps: true)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        Haptics.tap()
    }

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        remove(urls)
        // Trashing can block on iCloud or network volumes; never do it on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    NSLog("Shelf: could not trash \(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Drops

    /// What the island will take: a file, a picture, a link, or a piece of text. Everything
    /// that is not already a file is written into `dropFolder` first, so the shelf always
    /// holds files and anything on it can be dragged straight into another app.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .text]

    /// Where text, pictures and links dropped on the island are kept. Inside our own
    /// Application Support folder, so nothing lands in the user's Downloads without asking.
    static var dropFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Notch Island/Shelf", isDirectory: true)
    }

    /// True for a file this app made from a drop. Those are ours to delete when they leave the
    /// shelf; a file the user dropped from Finder is never touched.
    static func isOwned(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(dropFolder.standardizedFileURL.path + "/")
    }

    /// SwiftUI `.onDrop` handler. Each provider is asked for the best thing it has, in the
    /// order a person would expect: the file itself, then a picture, then a link, then text.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { provider in
            Self.acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !usable.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in usable {
            group.enter()
            Self.url(from: provider) { url in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(urls)
            ActivityCenter.shared.setDragTargeted(false)
        }
        return true
    }

    /// The picture formats a drag can carry, best first.
    private static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .image]

    /// The file a provider stands for: its own, or one written for it.
    private static func url(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                completion(fileURL(from: item))
            }
            return
        }
        // Ask for a concrete kind of picture rather than the abstract one: a provider that
        // advertises "an image" does not always hand one over when asked in those terms.
        if let type = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data, let image = NSImage(data: data), image.size.width > 1 else { return completion(nil) }
                completion(write(image: image, suggested: provider.suggestedName))
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                guard let url = webURL(from: item) else { return completion(nil) }
                completion(write(link: url))
            }
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            var text: String?
            if let string = item as? String { text = string }
            else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return completion(nil) }
            completion(write(text: text))
        }
    }

    private static func fileURL(from item: Any?) -> URL? {
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let url = item as? URL { return url }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func webURL(from item: Any?) -> URL? {
        if let url = item as? URL, !url.isFileURL { return url }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), !url.isFileURL { return url }
        if let string = item as? String, let url = URL(string: string), url.scheme != nil { return url }
        return nil
    }

    /// A unique file inside `dropFolder`, with the folder made if it is not there yet.
    private static func destination(name: String, extension ext: String) -> URL? {
        let folder = dropFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("Shelf: could not make the drop folder: \(error.localizedDescription)")
            return nil
        }
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "Dropped" : String(safe.prefix(60))
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    /// The stamp that keeps one drop apart from the next: "Image 14.32.05".
    private static func stamp(_ kind: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH.mm.ss"
        return "\(kind) \(formatter.string(from: now))"
    }

    static func write(image: NSImage, suggested: String?) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = (suggested?.isEmpty == false ? (suggested! as NSString).deletingPathExtension : stamp("Image"))
        guard let url = destination(name: name, extension: "png") else { return nil }
        do {
            try png.write(to: url)
            return url
        } catch {
            NSLog("Shelf: could not write the dropped image: \(error.localizedDescription)")
            return nil
        }
    }

    static func write(text: String) -> URL? {
        // The first line names the file, the way Notes titles a note.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = firstLine.trimmingCharacters(in: .whitespaces).isEmpty ? stamp("Text") : firstLine
        guard let url = destination(name: name, extension: "txt") else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("Shelf: could not write the dropped text: \(error.localizedDescription)")
            return nil
        }
    }

    /// A dropped link becomes a `.webloc`, which is what Finder makes and what every browser
    /// opens with a double click.
    static func write(link: URL) -> URL? {
        let name = link.host ?? stamp("Link")
        guard let destination = destination(name: name, extension: "webloc") else { return nil }
        do {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString],
                                                          format: .xml, options: 0)
            try plist.write(to: destination)
            return destination
        } catch {
            NSLog("Shelf: could not write the dropped link: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults, key: String) -> [ShelfItem] {
        // Current format: [["path": String, "addedAt": Date]]
        if let raw = defaults.array(forKey: key) as? [[String: Any]] {
            return raw.compactMap { (entry: [String: Any]) -> ShelfItem? in
                guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
                let added = entry["addedAt"] as? Date ?? Date()
                return ShelfItem(url: URL(fileURLWithPath: path).standardizedFileURL, addedAt: added)
            }
        }
        // Legacy format: a plain array of paths. Treat them as added now so an upgrade
        // doesn't sweep the whole shelf away on first launch.
        if let paths = defaults.stringArray(forKey: key) {
            let now = Date()
            return paths.compactMap { (path: String) -> ShelfItem? in
                guard !path.isEmpty else { return nil }
                return ShelfItem(url: URL(fileURLWithPath: path).standardizedFileURL, addedAt: now)
            }
        }
        return []
    }

    private func persist() {
        let encoded: [[String: Any]] = items.map { ["path": $0.url.path, "addedAt": $0.addedAt] }
        defaults.set(encoded, forKey: key)
    }

    // MARK: - Thumbnails

    private func pruneThumbnailCache() {
        let live = Set(items.map(\.url))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        thumbnailQueue.removeAll { !live.contains($0) }
    }

    private func requestThumbnail(_ url: URL) {
        guard backgroundWork, thumbnails[url] == nil, !thumbnailQueue.contains(url) else { return }
        thumbnailQueue.append(url)
        pumpThumbnails()
    }

    /// Never keeps more than a handful of QuickLook requests in flight, so a big drop can't
    /// spike the CPU.
    private func pumpThumbnails() {
        while thumbnailsInFlight < Self.maxConcurrentThumbnails, !thumbnailQueue.isEmpty {
            let url = thumbnailQueue.removeFirst()
            guard thumbnails[url] == nil else { continue }
            thumbnailsInFlight += 1
            let request = QLThumbnailGenerator.Request(fileAt: url,
                                                       size: CGSize(width: 88, height: 88),
                                                       scale: 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.thumbnailsInFlight = max(0, self.thumbnailsInFlight - 1)
                    if let rep, self.items.contains(where: { $0.url == url }) {
                        self.thumbnails[url] = rep.nsImage
                    }
                    self.pumpThumbnails()
                }
            }
        }
    }
}
