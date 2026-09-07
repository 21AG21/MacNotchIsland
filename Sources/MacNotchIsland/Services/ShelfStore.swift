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

    @Published private(set) var items: [ShelfItem] = []
    @Published private var thumbnails: [URL: NSImage] = [:]

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
         expiryHours: (() -> Double)? = nil) {
        self.defaults = defaults
        self.key = key
        self.maxItems = max(1, maxItems)
        self.backgroundWork = backgroundWork
        if let expiryHours { expiryHoursProvider = expiryHours }

        var loaded = Self.load(from: defaults, key: key)
        loaded = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if loaded.count > self.maxItems { loaded = Array(loaded.prefix(self.maxItems)) }
        items = loaded

        sweepExpired()
        persist()
        for item in items { requestThumbnail(item.url) }
        rescheduleSweep()
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
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
    }

    func remove(_ url: URL) { remove([url]) }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        thumbnails.removeAll()
        thumbnailQueue.removeAll()
        persist()
        rescheduleSweep()
    }

    // MARK: - Expiry

    /// Pure expiry rule: items added more than `expiryHours` ago are dropped. 0 (or less)
    /// keeps everything forever.
    static func pruned(_ items: [ShelfItem], expiryHours: Double, now: Date = Date()) -> [ShelfItem] {
        guard expiryHours > 0 else { return items }
        let cutoff = now.addingTimeInterval(-expiryHours * 3600)
        return items.filter { $0.addedAt > cutoff }
    }

    /// Drops expired items. Returns true when something was removed.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> Bool {
        let kept = Self.pruned(items, expiryHours: expiryHoursProvider(), now: now)
        guard kept.count != items.count else { return false }
        items = kept
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
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                NSLog("Shelf: could not trash \(url.path): \(error.localizedDescription)")
            }
        }
        remove(urls)
    }

    // MARK: - Drops

    /// SwiftUI `.onDrop` handler. Files only.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                else if let s = item as? String { url = URL(string: s) }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(urls)
            ActivityCenter.shared.setDragTargeted(false)
        }
        return true
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
